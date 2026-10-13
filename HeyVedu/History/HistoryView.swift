import SwiftUI

/// Opt-in dictation history: the main window's History page. Shows only what was pasted
/// and when, grouped by day; the other pipeline stages stay in the file for feedback
/// reports. History is turned on and off in Settings › Privacy.
struct HistoryView: View {
    let history: DictationHistory
    let copy: (String) -> Void
    let openPrivacySettings: () -> Void

    @State private var query = ""
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if !history.isEnabled {
                ContentUnavailableView {
                    Label("History is off", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Turn it on to find and copy past dictations. They're saved on this Mac only.")
                } actions: {
                    Button("Turn On History") { history.isEnabled = true }
                    Button("Privacy Settings…", action: openPrivacySettings)
                        .buttonStyle(.link)
                }
            } else if history.entries.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "waveform",
                    description: Text("Everything you dictate from now on shows up here.")
                )
            } else {
                list
            }
        }
        .confirmationDialog("Clear history?", isPresented: $confirmingClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("All \(history.entries.count) saved dictations will be deleted.")
        }
    }

    private var list: some View {
        let days = Self.groupedByDay(filtered)
        return List {
            ForEach(days, id: \.day) { group in
                Section(Self.title(for: group.day)) {
                    ForEach(group.entries) { entry in
                        HistoryRow(
                            entry: entry,
                            copy: { copy(entry.finalText) },
                            delete: { history.delete(entry.id) }
                        )
                    }
                }
            }
        }
        .overlay {
            if days.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search dictations")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(history.entries.count) of up to \(DictationHistory.limit) kept on this Mac")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…") { confirmingClear = true }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var filtered: [DictationHistory.Entry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history.entries }
        return history.entries.filter { $0.finalText.localizedCaseInsensitiveContains(query) }
    }

    /// Newest day first; entries keep their newest-first order.
    private static func groupedByDay(_ entries: [DictationHistory.Entry]) -> [(day: Date, entries: [DictationHistory.Entry])] {
        let calendar = Calendar.current
        var groups: [(day: Date, entries: [DictationHistory.Entry])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if groups.last?.day == day {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((day, [entry]))
            }
        }
        return groups
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

private struct HistoryRow: View {
    let entry: DictationHistory.Entry
    let copy: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.finalText)
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Copy", systemImage: "doc.on.doc", action: copy)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy", action: copy)
            Button("Delete", role: .destructive, action: delete)
        }
    }
}
