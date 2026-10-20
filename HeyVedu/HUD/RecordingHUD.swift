import AppKit
import Observation
import SwiftUI

/// Where the floating indicator appears.
enum HUDPosition: String, CaseIterable, Identifiable {
    case bottom
    case top
    /// Hangs from the camera notch like an extension of it; `top` on screens without one.
    case notch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "Bottom of screen"
        case .top: return "Top of screen"
        case .notch: return "Notch"
        }
    }

    private static let key = "hudPosition"

    static var saved: HUDPosition {
        UserDefaults.standard.string(forKey: key).flatMap(HUDPosition.init(rawValue:)) ?? .bottom
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}

@Observable
final class HUDModel {
    enum Phase: Equatable {
        case waitingForAudio
        case listening
        case processing(String)
        case message(String)
        /// Not a problem, just something the user should know (e.g. text was copied).
        case info(String)
        /// Something finished and is ready to use.
        case success(String)
    }

    /// How the indicator is drawn, decided each time it is shown.
    enum Layout: Equatable {
        /// A glass capsule; the notice sits on the side away from the screen edge.
        case capsule(atTop: Bool)
        /// A black shape that grows out of the notch; content starts below the camera.
        /// Collapsed, it is exactly the notch's size, so it disappears into it.
        case notch(height: CGFloat, notchWidth: CGFloat, width: CGFloat)
    }

    static let barCount = 24

    var phase: Phase = .waitingForAudio
    var layout: Layout = .capsule(atTop: false)
    var notice: String?
    /// A short label beside the waveform, e.g. that the transcript will be pasted raw.
    var tag: String?
    /// The notch layout is open. Animated, so the shape grows from and shrinks back into
    /// the notch instead of popping in and out.
    var expanded = false
    var handsFree = false
    /// When the current hands-free recording locked, for the elapsed timer.
    var handsFreeSince: Date?
    var levels = [Float](repeating: 0, count: HUDModel.barCount)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = [Float](repeating: 0, count: Self.barCount)
    }
}

/// Floating indicator. The panel is non-activating and ignores the mouse so it never
/// steals focus from the app receiving the dictation.
final class RecordingHUD {
    var position: HUDPosition = .saved

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// Bumped by every show and hide, so a finished closing animation only orders the
    /// panel out if nothing re-opened it meanwhile.
    private var generation = 0

    private static let capsuleSize = NSSize(width: 320, height: 72)
    private static let edgeMargin: CGFloat = 8
    private static let topMargin: CGFloat = 8
    /// Room below the notch for the content row and a notice.
    private static let notchContentHeight: CGFloat = 64
    private static let minimumNotchWidth: CGFloat = 340
    private static let openAnimation = Animation.spring(duration: 0.4, bounce: 0.25)
    private static let closeAnimation = Animation.spring(duration: 0.3, bounce: 0)
    private static let closeDuration: Duration = .milliseconds(300)
    private static let fadeDuration: TimeInterval = 0.15

    func showRecording(notice: String?, listening: Bool, handsFree: Bool = false, tag: String? = nil) {
        model.notice = notice
        model.tag = tag
        if handsFree, !model.handsFree { model.handsFreeSince = .now }
        model.handsFree = handsFree
        if !handsFree { model.handsFreeSince = nil }
        model.phase = listening ? .listening : .waitingForAudio
        present()
    }

    func setListening() {
        model.resetLevels()
        if model.phase == .waitingForAudio { model.phase = .listening }
    }

    /// Replaces the line under the indicator without changing anything else.
    func setNotice(_ notice: String?) {
        model.notice = notice
    }

    func push(level: Float) {
        model.push(level)
    }

    func showProcessing(_ text: String) {
        resetRecordingState()
        model.phase = .processing(text)
        present()
    }

    func flash(_ message: String, for duration: Duration = .seconds(1.5)) {
        show(.message(message), for: duration)
    }

    func flashInfo(_ message: String, for duration: Duration = .seconds(1.5)) {
        show(.info(message), for: duration)
    }

    func flashSuccess(_ message: String, for duration: Duration = .seconds(1.5)) {
        show(.success(message), for: duration)
    }

    private func show(_ phase: HUDModel.Phase, for duration: Duration) {
        resetRecordingState()
        model.phase = phase
        present()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func resetRecordingState() {
        model.notice = nil
        model.tag = nil
        model.handsFree = false
        model.handsFreeSince = nil
    }

    func hide(caller: String = #function) {
        DebugTrace.write("hud: hide from \(caller)")
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        generation += 1
        let closing = generation
        let duration: Duration
        if case .notch = model.layout {
            withAnimation(Self.closeAnimation) { model.expanded = false }
            duration = Self.closeDuration
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            }
            duration = .seconds(Self.fadeDuration)
        }
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, self.generation == closing else { return }
            panel.orderOut(nil)
        }
    }

    private func present() {
        DebugTrace.write("hud: present phase=\(model.phase)")
        hideTask?.cancel()
        hideTask = nil
        generation += 1
        let opening = generation
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible
        place(panel)

        if case .notch = model.layout {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            // Also re-opens a panel that is still closing.
            guard !model.expanded else { return }
            Task { [weak self] in
                // Let the collapsed shape draw once, so there is something to grow from.
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.generation == opening else { return }
                withAnimation(Self.openAnimation) { self.model.expanded = true }
            }
        } else {
            model.expanded = true
            if !wasVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 1
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.capsuleSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // Above the menu bar, so the notch layout can cover the strip beside the notch.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // The open/close animations are ours; no system fade on top of them.
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    /// On whichever screen the pointer is on.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame: NSRect
        switch position {
        case .notch where Self.notchWidth(of: screen) != nil:
            let notchHeight = screen.safeAreaInsets.top
            let notchWidth = Self.notchWidth(of: screen)!
            let width = max(Self.minimumNotchWidth, notchWidth + 120)
            let height = notchHeight + Self.notchContentHeight
            let layout = HUDModel.Layout.notch(height: notchHeight, notchWidth: notchWidth, width: width)
            // A different screen or a switch from another position starts closed.
            if model.layout != layout { model.expanded = false }
            model.layout = layout
            frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        case .top, .notch:
            let visible = screen.visibleFrame
            model.layout = .capsule(atTop: true)
            frame = NSRect(
                origin: NSPoint(x: visible.midX - Self.capsuleSize.width / 2, y: visible.maxY - Self.capsuleSize.height - Self.topMargin),
                size: Self.capsuleSize
            )
        case .bottom:
            let visible = screen.visibleFrame
            model.layout = .capsule(atTop: false)
            frame = NSRect(
                origin: NSPoint(x: visible.midX - Self.capsuleSize.width / 2, y: visible.minY + Self.edgeMargin),
                size: Self.capsuleSize
            )
        }
        panel.setFrame(frame, display: true)
    }

    /// Width of the camera housing, or nil on screens without one.
    private static func notchWidth(of screen: NSScreen) -> CGFloat? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        return width > 0 ? width : nil
    }
}

private struct HUDView: View {
    let model: HUDModel

    /// Roughly the camera housing's own corners, so the closed shape matches it.
    private static let notchCornerRadius: CGFloat = 10

    var body: some View {
        switch model.layout {
        case .capsule(let atTop):
            VStack(spacing: 4) {
                row
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .capsuleGlass()
                if let notice = model.notice {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .capsuleGlass()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atTop ? .top : .bottom)
            .animation(.easeOut(duration: 0.15), value: model.phase)
        case .notch(let notchHeight, let notchWidth, let width):
            let shape = UnevenRoundedRectangle(
                bottomLeadingRadius: model.expanded ? 18 : Self.notchCornerRadius,
                bottomTrailingRadius: model.expanded ? 18 : Self.notchCornerRadius
            )
            VStack(spacing: 2) {
                row.frame(height: 32)
                if let notice = model.notice {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, notchHeight)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            // Laid out at full size throughout, so the shape reveals it rather than squeezing it.
            .frame(width: width)
            .opacity(model.expanded ? 1 : 0)
            .blur(radius: model.expanded ? 0 : 6)
            .frame(
                width: model.expanded ? width : notchWidth,
                height: model.expanded ? nil : notchHeight,
                alignment: .top
            )
            .background(.black, in: shape)
            .clipShape(shape)
            // White content on the black shape in light mode too.
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(duration: 0.3, bounce: 0.15), value: model.notice)
            .animation(.easeOut(duration: 0.15), value: model.phase)
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            icon
            content
            if model.handsFree, let since = model.handsFreeSince, model.phase == .listening {
                ElapsedTime(since: since)
            }
            if let tag = model.tag, model.phase == .waitingForAudio || model.phase == .listening {
                Text(tag)
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .waitingForAudio:
            Image(systemName: "mic").foregroundStyle(.secondary)
        case .listening:
            Image(systemName: model.handsFree ? "lock.fill" : "mic.fill").foregroundStyle(.red)
        case .processing:
            ProgressView().controlSize(.small)
        case .message:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .info:
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .waitingForAudio, .listening:
            Waveform(levels: model.levels, active: model.phase == .listening)
        case .processing(let text), .message(let text), .info(let text), .success(let text):
            Text(text).font(.body).lineLimit(1)
        }
    }
}

/// Minutes and seconds since hands-free recording started.
private struct ElapsedTime: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct Waveform: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(active ? Color.primary : Color.secondary.opacity(0.5))
                    .frame(width: 3, height: 4 + CGFloat(levels[index]) * 20)
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

private extension View {
    /// Liquid Glass on macOS 26; a translucent material capsule before it.
    @ViewBuilder func capsuleGlass() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
        }
    }
}
