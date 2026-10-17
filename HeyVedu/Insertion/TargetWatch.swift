#if DEBUG
import Foundation

/// Debug harness: `open "HeyVedu Dev.app" --args --watch-target [seconds]` logs the detected
/// dictation target (app, page host, format) to the debug log every time the frontmost app
/// or its page changes, for `seconds` (60 by default), then exits. Launch it with `open` so
/// it runs with the app's own Accessibility and Automation grants. Hosts only, never URLs.
enum TargetWatch {
    static let flag = "--watch-target"

    static func run() async {
        let arguments = CommandLine.arguments
        let seconds = arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 60
        DebugTrace.write("target-watch: start, \(seconds)s")
        let deadline = ContinuousClock.now + .seconds(seconds)
        var last: String?
        while ContinuousClock.now < deadline {
            let started = ContinuousClock.now
            if let target = await DictationTarget.current() {
                let line = target.summary
                if line != last {
                    DebugTrace.write("target-watch: \(line) in \(ContinuousClock.now - started)")
                    print(line)
                    last = line
                }
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
        DebugTrace.write("target-watch: done")
    }
}
#endif
