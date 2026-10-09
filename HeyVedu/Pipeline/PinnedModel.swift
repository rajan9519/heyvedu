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

    /// Every file of this revision is on disk and passed its hash check.
    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: verifiedMarker.path)
            && files.allSatisfy { Self.size(of: directory.appending(path: $0.name)) == $0.size }
    }

    /// Downloads and verifies missing files, then returns the model directory.
    /// `progress` receives the completed fraction (0...1) while downloading.
    func ensureDownloaded(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fileManager = FileManager.default
        if isDownloaded {
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
        // The system deletes the downloaded file once the completion handler returns, so it
        // is moved somewhere we control from inside the handler.
        let kept = FileManager.default.temporaryDirectory.appending(path: "\(folder)-\(UUID().uuidString)")
        let model = displayName
        let download = ProgressReportingDownload()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                download.start(url: url, progress: progress) { location, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    guard let location, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        return continuation.resume(throwing: DownloadError.download(
                            model: model, reason: "HTTP \(status) for \(name)"))
                    }
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: kept)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            download.cancel()
        }
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

/// One download task that reports bytes received as they arrive.
///
/// The async `URLSession.download(from:delegate:)` never calls the delegate's
/// `didWriteData`, so progress stayed at 0% until the file finished. Observing the task's
/// byte count reports bytes as they arrive.
private nonisolated final class ProgressReportingDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false

    func start(
        url: URL, progress: @escaping @Sendable (Int64) -> Void,
        completion: @escaping @Sendable (URL?, URLResponse?, (any Error)?) -> Void
    ) {
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            self.finish()
            completion(location, response, error)
        }
        // Not `task.progress`: its unit counts stall during large downloads.
        let observation = task.observe(\.countOfBytesReceived) { task, _ in
            progress(task.countOfBytesReceived)
        }
        let cancelled = lock.withLock {
            self.task = task
            self.observation = observation
            return isCancelled
        }
        if cancelled { task.cancel() }
        task.resume()
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    private func finish() {
        let observation = lock.withLock {
            defer { self.observation = nil; self.task = nil }
            return self.observation
        }
        observation?.invalidate()
    }
}
