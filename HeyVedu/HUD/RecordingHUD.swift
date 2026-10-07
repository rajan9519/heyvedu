import AppKit
import Observation
import SwiftUI

@Observable
final class HUDModel {
    enum Phase: Equatable {
        case waitingForAudio
        case listening
        case processing(String)
        case message(String)
    }

    static let barCount = 24

    var phase: Phase = .waitingForAudio
    var notice: String?
    var handsFree = false
    var levels = [Float](repeating: 0, count: HUDModel.barCount)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = [Float](repeating: 0, count: Self.barCount)
    }
}

/// Floating pill near the bottom of the screen. The panel is non-activating and ignores
/// the mouse so it never steals focus from the app receiving the dictation.
final class RecordingHUD {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private static let panelSize = NSSize(width: 320, height: 72)
    private static let bottomMargin: CGFloat = 56

    func showRecording(notice: String?, listening: Bool, handsFree: Bool = false) {
        model.notice = notice
        model.handsFree = handsFree
        model.phase = listening ? .listening : .waitingForAudio
        present()
    }

    func setListening() {
        model.resetLevels()
        if model.phase == .waitingForAudio { model.phase = .listening }
    }

    func push(level: Float) {
        model.push(level)
    }

    func showProcessing(_ text: String) {
        model.notice = nil
        model.handsFree = false
        model.phase = .processing(text)
        present()
    }

    func flash(_ message: String, for duration: Duration = .seconds(1.5)) {
        model.notice = nil
        model.handsFree = false
        model.phase = .message(message)
        present()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide(caller: String = #function) {
        DebugTrace.write("hud: hide from \(caller)")
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func present() {
        DebugTrace.write("hud: present phase=\(model.phase)")
        hideTask?.cancel()
        hideTask = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    /// Centre on whichever screen the pointer is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.panelSize.width / 2,
            y: visible.minY + Self.bottomMargin
        )
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
    }
}

private struct HUDView: View {
    let model: HUDModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                icon
                content
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)

            if let notice = model.notice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: model.phase)
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
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .waitingForAudio, .listening:
            Waveform(levels: model.levels, active: model.phase == .listening)
        case .processing(let text), .message(let text):
            Text(text).font(.callout).lineLimit(1)
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
