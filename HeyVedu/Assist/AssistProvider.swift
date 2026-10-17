import Foundation

/// One AI Assist engine. `AssistRouter` owns one instance per `AssistProviderID` and sends
/// each request to the route it picks. Mirrors `CleanupBackend`.
///
/// Providers run one request at a time; the router queues the rest.
protocol AssistProvider: AnyObject {
    var id: AssistProviderID { get }
    /// True when nothing leaves the Mac.
    var isLocal: Bool { get }

    /// Installed? Signed in? Version OK? Cheap enough to call at app launch.
    func availability() async -> AssistAvailability

    /// The models this account and CLI version offer, discovered live.
    func models() async throws -> [AssistModel]

    /// Start the process a task will use, so the first request doesn't pay for startup.
    func warmUp(_ call: AssistCall, route: AssistRoute)

    /// Free processes and memory. The next request starts fresh.
    func shutdown()

    func run(_ call: AssistCall, route: AssistRoute) async throws -> AssistRawResult
}

extension AssistProvider {
    func warmUp(_ call: AssistCall, route: AssistRoute) {}
    func shutdown() {}
}

/// Lets one async caller in at a time, in arrival order.
final class AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
