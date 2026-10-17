import Foundation

/// A child process spoken to in newline-delimited JSON over stdin/stdout.
///
/// - Runs in its own process group, so `terminate()` also stops anything it started.
/// - Lines longer than `maxLineBytes` kill the process; only the last `maxStderrBytes` of
///   stderr are kept (for error messages, never logged with request text).
/// - One reader at a time calls `nextLine()`; it returns nil once stdout closes.
nonisolated final class LineProcess: @unchecked Sendable {
    static let maxLineBytes = 4 << 20
    static let maxStderrBytes = 16 << 10

    let pid: pid_t
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var stdoutClosed = false
    private var exited = false
    private var stderrTail = Data()
    private var exitSource: DispatchSourceProcess?
    private var endReason: AssistError?

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) throws {
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw AssistError.unavailable("Couldn't create pipes")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if #available(macOS 26, *) {
            posix_spawn_file_actions_addchdir(&actions, directory.path)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group; close every inherited descriptor except the three above.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var child: pid_t = 0
        let status = posix_spawn(&child, executable.path, &actions, &attributes, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard status == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw AssistError.unavailable("Couldn't start \(executable.lastPathComponent): \(String(cString: strerror(status)))")
        }
        pid = child
        // A write after the child exits must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)
        stdin = FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: true)
        stdout = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        stderr = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)

        stdout.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { handle.readabilityHandler = nil; return }
            if data.isEmpty { handle.readabilityHandler = nil; self.closeStdout() } else { self.receive(data) }
        }
        stderr.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            self.lock.withLock {
                self.stderrTail.append(data)
                if self.stderrTail.count > Self.maxStderrBytes {
                    self.stderrTail = self.stderrTail.suffix(Self.maxStderrBytes)
                }
            }
        }
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            self?.lock.withLock { self?.exited = true }
            self?.exitSource?.cancel()
        }
        exitSource = source
        source.resume()
    }

    deinit {
        terminate()
    }

    var isRunning: Bool { lock.withLock { !exited && !stdoutClosed } }

    var stderrText: String { lock.withLock { String(decoding: stderrTail, as: UTF8.self) } }

    func write(line: Data) throws {
        var data = line
        data.append(0x0A)
        do { try stdin.write(contentsOf: data) } catch { throw AssistError.unavailable("The CLI stopped") }
    }

    func write(json object: Any) throws {
        try write(line: JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
    }

    /// The next stdout line, or nil once stdout closed (exit, crash or `terminate()`).
    func nextLine() async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                continuation.resume(returning: line)
            } else if stdoutClosed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    /// Why `terminate(because:)` stopped the process, if it did.
    var endedBecause: AssistError? { lock.withLock { endReason } }

    /// SIGTERM to the whole group, SIGKILL two seconds later if it's still there.
    func terminate(because reason: AssistError? = nil) {
        let pid = self.pid
        if let reason { lock.withLock { if endReason == nil { endReason = reason } } }
        guard lock.withLock({ !exited }) else { closeStdout(); return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(-pid, SIGKILL) }
        try? stdin.close()
        closeStdout()
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var ready: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { ready.append(Data(line)) }
        }
        let tooLong = buffer.count > Self.maxLineBytes
        lines.append(contentsOf: ready)
        let resume = deliverLocked()
        lock.unlock()
        resume?()
        if tooLong { terminate(because: .badOutput("The CLI sent a line over \(Self.maxLineBytes) bytes")) }
    }

    private func closeStdout() {
        lock.lock()
        stdoutClosed = true
        let resume = deliverLocked()
        lock.unlock()
        resume?()
    }

    /// Hands a waiting reader its line; call with the lock held, run the result after.
    private func deliverLocked() -> (() -> Void)? {
        guard let waiter else { return nil }
        if !lines.isEmpty {
            let line = lines.removeFirst()
            self.waiter = nil
            return { waiter.resume(returning: line) }
        }
        if stdoutClosed {
            self.waiter = nil
            return { waiter.resume(returning: nil) }
        }
        return nil
    }
}

/// Runs `body` against a process, stopping the process when `timeout` passes or the task is
/// cancelled; `body` then sees stdout close and can report `process.endedBecause`.
func withDeadline<T>(
    _ process: LineProcess, _ timeout: Duration,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async throws -> T {
    let timer = Task.detached {
        try? await Task.sleep(for: timeout)
        if !Task.isCancelled { process.terminate(because: .timeout) }
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler(operation: body) {
        process.terminate(because: .cancelled)
    }
}
