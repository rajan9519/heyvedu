import CryptoKit
import Foundation

/// A model on Hugging Face pinned to one commit, with every file's size and SHA-256.
///
/// Files are downloaded into `Application Support/HeyVedu/Models/<folder>/<revision>`. Each app
/// release pins the revision it was tested with, so an app update that pins a new revision
/// downloads the new weights on next use and then deletes the revisions it no longer uses.
/// Changes on Hugging Face never reach an app version that didn't pin them.
nonisolated struct PinnedModel: Sendable {
    struct File: Sendable {
        let name: String
        let size: Int64
        let sha256: String
    }

    enum DownloadError: LocalizedError {
        case download(model: String, reason: String)
        case integrity(model: String, file: String)

        var errorDescription: String? {
            switch self {
            case .download(let model, let reason): return "\(model) download failed: \(reason)"
            case .integrity(let model, let file): return "\(model) file failed verification: \(file)"
            }
        }
    }

    /// Shown in progress and error messages.
    let displayName: String
    /// Folder under `Models/` that holds one subfolder per revision.
    let folder: String
    let repository: String
    let revision: String
    let files: [File]

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    private var folderURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "HeyVedu/Models/\(folder)", directoryHint: .isDirectory)
    }

    var directory: URL { folderURL.appending(path: revision, directoryHint: .isDirectory) }

    /// Written after every file has passed its hash check, so later launches only compare
    /// sizes instead of re-hashing the weights.
    private var verifiedMarker: URL { directory.appending(path: ".verified") }

    /// Downloads and verifies missing files, then returns the model directory.
    /// `progress` receives the completed fraction (0...1) while downloading.
    func ensureDownloaded(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: verifiedMarker.path),
           files.allSatisfy({ Self.size(of: directory.appending(path: $0.name)) == $0.size }) {
            removeOtherRevisions()
            return directory
        }

        // A symlink here was a development install; never write through it.
        if (try? folderURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            try fileManager.removeItem(at: folderURL)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: verifiedMarker)

        let total = totalSize
        var completed: Int64 = 0
        progress(0)
        for file in files {
            try Task.checkCancellation()
            let destination = directory.appending(path: file.name)
            if Self.size(of: destination) == file.size, try await Self.sha256(of: destination) == file.sha256 {
                completed += file.size
                continue
            }
            try? fileManager.removeItem(at: destination)

            let base = completed
            let temporary = try await download(file.name) { written in
                progress(Double(base + min(written, file.size)) / Double(total))
            }
            defer { try? fileManager.removeItem(at: temporary) }
            guard try await Self.sha256(of: temporary) == file.sha256 else {
                throw DownloadError.integrity(model: displayName, file: file.name)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            completed += file.size
        }
        try Data(revision.utf8).write(to: verifiedMarker, options: .atomic)
        DebugTrace.write("\(folder): downloaded and verified \(files.count) files at \(revision)")
        removeOtherRevisions()
        return directory
    }

    /// Folders of models the app no longer uses, deleted once by `removeRetiredModels()`.
    private static let retiredFolders = ["s1-mini"]

    /// Frees the disk space of models from engines that were removed.
    static func removeRetiredModels() {
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "HeyVedu/Models", directoryHint: .isDirectory)
        for folder in retiredFolders {
            try? FileManager.default.removeItem(at: models.appending(path: folder, directoryHint: .isDirectory))
        }
    }

    /// Deletes revisions left behind by earlier app versions, keeping only this one.
    private func removeOtherRevisions() {
        let fileManager = FileManager.default
        guard (try? folderURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              let entries = try? fileManager.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != revision {
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// HTTPS from the pinned revision only. Redirects to Hugging Face's CDN are followed;
    /// integrity comes from the SHA-256 check, not from where the bytes were served.
    @concurrent
    private func download(_ name: String, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)") else {
            throw DownloadError.download(model: displayName, reason: "bad URL for \(name)")
        }
        let delegate = DownloadProgressDelegate(progress: progress)
        let (location, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: location)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DownloadError.download(model: displayName, reason: "HTTP \(status) for \(name)")
        }
        // The system deletes `location` once this returns; move it somewhere we control.
        let kept = FileManager.default.temporaryDirectory.appending(path: "\(folder)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: location, to: kept)
        return kept
    }

    /// Streams the file through SHA-256 in 4 MB blocks, off the main actor.
    @concurrent
    private static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Reports bytes written for one download task.
private nonisolated final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progress: @Sendable (Int64) -> Void

    init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async `download(from:delegate:)` call.
    }
}
