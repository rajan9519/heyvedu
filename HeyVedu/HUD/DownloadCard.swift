import AppKit
import Observation
import SwiftUI

/// A model download that dictation waits for, as the download card shows it.
struct ModelDownload {
    enum Model: Equatable {
        /// Without it nothing can be transcribed.
        case speech
        /// The named cleanup engine; until it's ready, raw transcripts can be pasted instead.
        case cleanup(String)
    }

    let model: Model
    /// 0...1 while downloading; nil once downloaded, while the model is set up.
    let progress: Double?
    /// Bytes to download, when known.
    let size: Int64?
    /// Why the download stopped, if it did.
    let failure: String?

    var name: String {
        switch model {
        case .speech: return "the speech model"
        case .cleanup(let name): return name
        }
    }

    var allowsRawTranscripts: Bool { model != .speech }
}

@Observable
final class DownloadCardModel {
    enum Reason {
        /// A download just started; the card is informational.
        case started
        /// The hotkey was pressed while dictation waits for the download.
        case hotkeyPressed
    }

    var reason: Reason = .started
    /// Bumped on every hotkey press while the card is up, to nudge it.
    var nudges = 0
}

/// A floating card in the middle of the screen that shows a model download and, when the
/// hotkey is pressed meanwhile, lets the person wait or paste raw transcripts. Unlike the
/// recording HUD it takes clicks, but it never takes focus from the app being dictated into.
final class DownloadCard {
    /// Called when the person chooses raw transcripts until the download finishes.
    var onUseRawTranscripts: (() -> Void)?
    /// Called when the person retries a failed download.
    var onRetry: (() -> Void)?

    private let model = DownloadCardModel()
    private let download: () -> ModelDownload?
    private var panel: NSPanel?
    private var hosting: NSHostingView<DownloadCardView>?
    /// The visible area of the screen the card is centred on.
    private var area: NSRect?

    private static let fadeDuration: TimeInterval = 0.15

    /// `download` is read while the card draws, so progress stays live.
    init(download: @escaping () -> ModelDownload?) {
        self.download = download
    }

    private var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ reason: DownloadCardModel.Reason) {
        let wasVisible = isVisible
        if wasVisible, reason == .hotkeyPressed { model.nudges += 1 }
        // Pressing the hotkey turns a passing notice into the choice; never the reverse.
        if !(wasVisible && model.reason == .hotkeyPressed) { model.reason = reason }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !wasVisible {
            place(panel)
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        // Also brings back a card that was fading out.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Shown again while fading out.
            guard let self, self.panel?.alphaValue == 0 else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = ClickablePanel(
            contentRect: .zero,
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
        panel.hidesOnDeactivate = false
        // Buttons don't need key status, so clicking one leaves focus where it was.
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: DownloadCardView(
            model: model,
            download: download,
            useRaw: { [weak self] in
                self?.hide()
                self?.onUseRawTranscripts?()
            },
            retry: { [weak self] in self?.onRetry?() },
            close: { [weak self] in self?.hide() },
            resized: { [weak self] in DispatchQueue.main.async { self?.center() } }
        ))
        // The card sizes and centres its own window; SwiftUI resizing it too, from the
        // bottom-left corner, made the two fight on every progress update. The intrinsic
        // size is kept: `fittingSize`, which centring uses, is zero without it.
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    /// On whichever screen the pointer is on.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        area = screen?.visibleFrame
        center()
    }

    /// Sizes the window to the card and centres it on its screen, in whole points so
    /// repeated calls land on the same frame.
    private func center() {
        guard let panel, let hosting, let area else { return }
        let size = hosting.fittingSize
        let width = size.width.rounded(.up), height = size.height.rounded(.up)
        let frame = NSRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(),
                           width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

/// Borderless panels can't become key by default, which stops their buttons from
/// tracking clicks. With `becomesKeyOnlyIfNeeded`, a button click still doesn't make it key.
private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct DownloadCardView: View {
    let model: DownloadCardModel
    let download: () -> ModelDownload?
    let useRaw: () -> Void
    let retry: () -> Void
    let close: () -> Void
    let resized: () -> Void

    @State private var nudgeOffset: CGFloat = 0

    private static let width: CGFloat = 380

    var body: some View {
        Group {
            if let download = download() {
                card(download)
            } else {
                // Finished while the card was up; the controller hides it.
                Color.clear.frame(width: Self.width, height: 1)
            }
        }
        // Room for the shadow and the nudge, which would otherwise be clipped at the window edge.
        .padding(20)
        .offset(x: nudgeOffset)
        .onChange(of: model.nudges) { nudge() }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in resized() }
    }

    private func card(_ download: ModelDownload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: download.failure == nil ? "arrow.down" : "exclamationmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(download.failure == nil ? Color.brand : Color.orange, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(download)).font(.body.weight(.semibold))
                    Text(subtitle(download))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide")
            }

            if download.failure == nil {
                VStack(spacing: 4) {
                    ProgressBar(value: download.progress)
                    HStack {
                        Text(amount(download))
                        Spacer()
                        Text(download.progress.map { "\(Int($0 * 100))%" } ?? "")
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            buttons(download)
        }
        .padding(16)
        .frame(width: Self.width)
        // Follows the app's appearance: the material takes the window's light or dark look,
        // so the text must too, or it ends up white on a light card.
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    /// The × closes the card, so there are buttons only for a real choice.
    @ViewBuilder private func buttons(_ download: ModelDownload) -> some View {
        if download.failure != nil {
            HStack(spacing: 8) {
                Spacer()
                if download.allowsRawTranscripts {
                    Button("Paste Raw Transcripts for Now", action: useRaw)
                }
                Button("Try Again", action: retry).keyboardShortcut(.defaultAction)
            }
        } else if model.reason == .hotkeyPressed, download.allowsRawTranscripts {
            HStack(spacing: 8) {
                Spacer()
                Button("Wait", action: close)
                Button("Paste Raw Transcripts for Now", action: useRaw).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func title(_ download: ModelDownload) -> String {
        if download.failure != nil { return "Couldn't download \(download.name)" }
        if model.reason == .hotkeyPressed { return "HeyVedu is getting ready" }
        return download.progress == nil ? "Setting up \(download.name)" : "Downloading \(download.name)"
    }

    private func subtitle(_ download: ModelDownload) -> String {
        if let failure = download.failure {
            return download.allowsRawTranscripts
                ? "\(failure). You can try again, or paste raw transcripts until it works."
                : "\(failure). Dictation starts once the download finishes."
        }
        switch (download.model, model.reason) {
        case (.speech, .started):
            return "HeyVedu needs it to turn your voice into text. Dictation starts once it finishes."
        case (.speech, .hotkeyPressed):
            return "Dictation needs the speech model. It starts as soon as the download finishes."
        case (.cleanup(let name), .started):
            return "\(name) turns your speech into tidy, punctuated text. Until it's ready, you can paste raw transcripts or wait."
        case (.cleanup(let name), .hotkeyPressed):
            return "Dictation starts once \(name) finishes downloading. Raw transcripts are pasted as spoken, without cleanup."
        }
    }

    private func amount(_ download: ModelDownload) -> String {
        guard let progress = download.progress else { return "Setting up…" }
        guard let size = download.size else { return "Downloading…" }
        let done = Int64(Double(size) * progress)
        return "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    /// A short shake, so a hotkey press visibly registers on a card that's already up.
    private func nudge() {
        Task { @MainActor in
            for offset in [-6.0, 6, -4, 3, 0] {
                withAnimation(.easeInOut(duration: 0.06)) { nudgeOffset = offset }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }
}

/// Drawn rather than a `ProgressView`, which turns grey in a window that isn't key, and
/// this card never is. Nil `value` pulses while the model is set up.
private struct ProgressBar: View {
    let value: Double?

    @State private var pulsing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule()
                    .fill(Color(nsColor: .systemBlue))
                    .frame(width: proxy.size.width * (value ?? 1))
                    .opacity(value == nil && pulsing ? 0.4 : 1)
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.3), value: value)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulsing = true }
        }
    }
}
