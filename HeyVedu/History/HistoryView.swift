import SwiftUI

/// Opt-in dictation history: the main window's History section. Shows only what was
/// pasted and when; the other pipeline stages stay in the file for feedback reports.
struct HistoryView: View {
    let history: DictationHistory
    let copy: (String) -> Void

    @State private var confirmingTurnOff = false
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: toggleBinding) {
                    Text("Keep dictation history")
                    Text("Saved on this Mac only, so you can find and copy past dictations. Nothing is sent anywhere. Turning this off deletes the history.")
                }
            }

            if history.isEnabled {
                Section {
                    if history.entries.isEmpty {
                        Text("No dictations yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(history.entries) { entry in
                        HistoryRow(
                            entry: entry,
                            copy: { copy(entry.finalText) },
                            delete: { history.delete(entry.id) }
                        )
                    }
                } footer: {
                    HStack {
                        Text("\(history.entries.count) of up to \(DictationHistory.limit) kept")
                        Spacer()
                        Button("Clear History…") { confirmingClear = true }
                            .disabled(history.entries.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Turn off history?", isPresented: $confirmingTurnOff) {
            Button("Turn Off and Delete", role: .destructive) { history.isEnabled = false }
        } message: {
            Text("All \(history.entries.count) saved dictations will be deleted.")
        }
        .confirmationDialog("Clear history?", isPresented: $confirmingClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("All \(history.entries.count) saved dictations will be deleted.")
        }
    }

    /// Asks before turning off, since that deletes what's saved.
    private var toggleBinding: Binding<Bool> {
        Binding {
            history.isEnabled
        } set: { on in
            if on || history.entries.isEmpty {
                history.isEnabled = on
            } else {
                confirmingTurnOff = true
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: DictationHistory.Entry
    let copy: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.finalText)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text(entry.date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy", systemImage: "doc.on.doc", action: copy)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            Button("Delete", systemImage: "trash", action: delete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}
