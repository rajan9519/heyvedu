import SwiftUI

/// Above Settings at the bottom of the main window's sidebar: the app version and update
/// status, clickable to check for updates. Once an update has downloaded it turns into a
/// card with a Relaunch button.
struct UpdateFooter: View {
    let updates: UpdateController

    var body: some View {
        Group {
            if case .readyToInstall(let version) = updates.state {
                ReadyCard(version: version, relaunch: updates.installAndRelaunch)
            } else {
                statusRow
            }
        }
        .padding(.horizontal, 10)
        .animation(.easeInOut(duration: 0.2), value: updates.state)
        .animation(.easeInOut(duration: 0.2), value: updates.lastCheckResult)
    }

    @ViewBuilder private var statusRow: some View {
        switch updates.state {
        case .checking:
            FooterRow(title: "Checking for updates…", subtitle: versionLabel) {
                ProgressView().controlSize(.small)
            }
        case .downloading(let version):
            FooterRow(title: "Downloading \(version)…", subtitle: "Installs when it's ready") {
                ProgressView().controlSize(.small)
            }
        case .idle, .readyToInstall:
            if !updates.isAvailable {
                FooterRow(title: versionLabel, subtitle: nil) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
            } else {
                Button(action: updates.checkForUpdates) {
                    switch updates.lastCheckResult {
                    case .upToDate:
                        FooterRow(title: "You're up to date", subtitle: versionLabel) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    case .failed:
                        FooterRow(title: "Couldn't check — try again", subtitle: versionLabel) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    case nil:
                        FooterRow(title: "Check for updates", subtitle: versionLabel) {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(FooterButtonStyle())
                .help(helpText)
            }
        }
    }

    private var versionLabel: String { "HeyVedu \(UpdateController.currentVersion)" }

    private var helpText: String {
        if case .failed(let message) = updates.lastCheckResult { return message }
        return "HeyVedu checks daily and downloads updates in the background."
    }
}

private struct FooterRow<Icon: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct FooterButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
            )
            .onHover { hovering = $0 }
    }
}

private struct ReadyCard: View {
    let version: String
    let relaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.brandText)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update ready")
                        .font(.callout.weight(.semibold))
                    Text("HeyVedu \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Button(action: relaunch) {
                Text("Relaunch to Update")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.brand)
            .controlSize(.regular)
            Text("Or it installs the next time you quit.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
