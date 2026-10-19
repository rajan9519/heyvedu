import SwiftUI

/// The main window's landing page: whether dictation is ready, what it has done for you
/// so far, and your latest dictations.
struct HomeView: View {
    let controller: DictationController
    let navigation: MainNavigation

    var body: some View {
        MainPage(layout: .scroll, spacing: 20) {
            header
            if !controller.canDictate {
                SetupChecklist(controller: controller)
            }
            StatTiles(stats: controller.stats)
            ActivityCard(stats: controller.stats)
            RecentDictations(history: controller.history, copy: controller.copy) {
                navigation.section = .history
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.greeting(at: .now))
                    .font(.largeTitle.weight(.semibold))
                HStack(spacing: 6) {
                    Text("Hold")
                    InlineKeycaps(hotkey: controller.hotkey)
                    Text(controller.handsFreeEnabled
                         ? "anywhere and speak, or double-tap for hands-free"
                         : "anywhere and speak")
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            StatusPill(ready: controller.canDictate)
        }
    }

    private static func greeting(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

/// The hotkey as small keycaps, sized to sit in a line of text.
private struct InlineKeycaps: View {
    let hotkey: Hotkey

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(hotkey.keycaps.enumerated()), id: \.offset) { _, key in
                Text(key.symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.2), radius: 0, y: 1)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                    .help(key.name)
            }
        }
    }
}

private struct StatusPill: View {
    let ready: Bool

    var body: some View {
        let tint: Color = ready ? .green : .orange
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(ready ? "Ready · on-device" : "Setup needed")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .help(ready ? "Your voice is transcribed on this Mac, and nothing leaves it." : "Finish the steps below to start dictating.")
    }
}

// MARK: - Setup

/// What still stands between the user and their first dictation. Shown only until
/// everything is in place.
private struct SetupChecklist: View {
    let controller: DictationController

    private struct Item: Identifiable {
        let id: String
        let title: String
        let done: Bool
        let trailing: AnyView
    }

    var body: some View {
        let items = self.items
        let remaining = items.filter { !$0.done }.count
        VStack(alignment: .leading, spacing: 8) {
            Text(remaining == 0 ? "Almost ready" : remaining == 1 ? "One thing before you can dictate" : "\(remaining) things before you can dictate")
                .font(.headline)
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.done ? .green : .secondary)
                    Text(item.title)
                    Spacer(minLength: 12)
                    item.trailing
                }
                .frame(minHeight: 24)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
    }

    private var items: [Item] {
        let permissions = controller.permissions
        var items = [
            Item(
                id: "mic",
                title: "Microphone access",
                done: permissions.microphoneGranted,
                trailing: permissions.microphoneGranted
                    ? AnyView(Text("Allowed").foregroundStyle(.secondary))
                    : AnyView(Button("Allow…", action: permissions.requestMicrophone))
            ),
            Item(
                id: "ax",
                title: "Accessibility access",
                done: permissions.accessibilityGranted,
                trailing: permissions.accessibilityGranted
                    ? AnyView(Text("Allowed").foregroundStyle(.secondary))
                    : AnyView(Button("Allow…", action: permissions.requestAccessibility))
            ),
            Item(
                id: "model",
                title: "Speech model",
                done: controller.speechModel.isReady,
                trailing: AnyView(SpeechModelStatus(model: controller.speechModel))
            ),
        ]
        if permissions.allGranted && !controller.hotkeyAvailable {
            items.append(Item(
                id: "hotkey",
                title: "Shortcut unavailable. Allow Accessibility again.",
                done: false,
                trailing: AnyView(Button("Open…", action: permissions.requestAccessibility))
            ))
        }
        if controller.devices.inputDevices.isEmpty {
            items.append(Item(
                id: "input",
                title: "Connect a microphone",
                done: false,
                trailing: AnyView(EmptyView())
            ))
        }
        return items
    }
}

private struct SpeechModelStatus: View {
    let model: SpeechModel

    var body: some View {
        switch model.state {
        case .idle:
            Button("Download (\(ByteCountFormatter.string(fromByteCount: SpeechModel.downloadSize, countStyle: .file)))", action: model.prepare)
        case .downloading:
            HStack(spacing: 8) {
                ProgressView(value: model.downloadProgress ?? 0)
                    .frame(width: 90)
                Text("\(Int((model.downloadProgress ?? 0) * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Setting up…").foregroundStyle(.secondary)
            }
        case .ready:
            Text("Ready").foregroundStyle(.secondary)
        case .failed(let reason):
            Button("Try Again", action: model.prepare)
                .help(reason)
        }
    }
}

// MARK: - Stats

private struct StatTiles: View {
    let stats: DictationStats

    var body: some View {
        let now = Date.now
        HStack(spacing: 12) {
            StatTile(
                icon: "textformat",
                title: "Words",
                value: stats.totalWords.formatted(),
                detail: "\(stats.wordsThisWeek(now: now).formatted()) this week"
            )
            StatTile(
                icon: "clock",
                title: "Time saved",
                value: Self.format(stats.timeSaved),
                detail: "vs typing at \(Int(DictationStats.typingWordsPerMinute)) wpm"
            )
            StatTile(
                icon: "gauge.with.needle",
                title: "Pace",
                value: stats.wordsPerMinute.map { "\(Int($0.rounded())) wpm" } ?? "–",
                detail: stats.wordsPerMinute.map {
                    "\(($0 / DictationStats.typingWordsPerMinute).formatted(.number.precision(.fractionLength(1))))× typing speed"
                } ?? "Shows after a dictation"
            )
            StatTile(
                icon: "flame",
                title: "Streak",
                value: Self.days(stats.currentStreak(now: now)),
                detail: "Best \(Self.days(stats.bestStreak))"
            )
        }
    }

    private static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min" }
        return "\((seconds / 3600).formatted(.number.precision(.fractionLength(1)))) h"
    }
}

private struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A GitHub-style calendar of words dictated per day in one calendar year, this one by
/// default, with month and weekday labels. Cells grow to fill wide windows; narrow ones
/// scroll sideways instead of squeezing, starting at the latest week.
private struct ActivityCard: View {
    let stats: DictationStats

    @State private var width: CGFloat = 0
    @State private var year = Calendar.current.component(.year, from: .now)
    /// The day under the pointer; its tip shows at once, unlike `.help`'s system delay.
    @State private var hovered: Date?
    @State private var tipWidth: CGFloat = 0

    private let gap: CGFloat = 3
    private let minCell: CGFloat = 10
    /// Big enough to fill a wide window, small enough that early January doesn't look odd.
    private let maxCell: CGFloat = 22
    private let legendCell: CGFloat = 11
    private let weekdayColumn: CGFloat = 30
    private let monthRow: CGFloat = 16

    private static let levels: [Color] = [
        Color(red: 0.62, green: 0.88, blue: 0.80),
        Color(red: 0.36, green: 0.79, blue: 0.65),
        Color(red: 0.11, green: 0.62, blue: 0.46),
        Color(red: 0.06, green: 0.43, blue: 0.34),
    ]

    var body: some View {
        let columns = self.columns
        let shown = columns.joined().compactMap { $0.flatMap(stats.day(on:)) }
        let busiest = shown.map(\.words).max() ?? 0

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                HStack(spacing: 3) {
                    Text(summary(dictations: shown.reduce(0) { $0 + $1.dictations }))
                    yearPicker
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 4) {
                weekdayLabels
                ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 4) {
                        monthLabels(columns)
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(columns.indices, id: \.self) { index in
                                VStack(spacing: gap) {
                                    ForEach(0..<7, id: \.self) { weekday in
                                        dayCell(columns[index][weekday], busiest: busiest)
                                    }
                                }
                                .id(index)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                // Open on today; older weeks are a scroll away when the window is narrow.
                .onAppear { scrollToToday(proxy) }
                .onChange(of: width) { scrollToToday(proxy) }
                .onChange(of: year) { scrollToToday(proxy) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                }
            }
            HStack(spacing: 4) {
                Label("Counts only, never your words", systemImage: "lock")
                Spacer()
                Text("Less")
                RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(width: legendCell, height: legendCell)
                ForEach(Self.levels.indices, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(Self.levels[level]).frame(width: legendCell, height: legendCell)
                }
                Text("More")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .overlayPreferenceValue(HoveredCellKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor, let hovered {
                    let rect = proxy[anchor]
                    let half = tipWidth / 2
                    dayTip(hovered)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tipWidth = $0 }
                        // Above the cell, kept inside the card at the edges.
                        .position(x: min(max(rect.midX, half + 4), proxy.size.width - half - 4),
                                  y: rect.minY - 16)
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private func dayTip(_ date: Date) -> some View {
        let words = stats.day(on: date)?.words ?? 0
        return Text("\(words == 1 ? "1 word" : "\(words.formatted()) words") on \(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))")
            .font(.caption)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    /// Fills the available width, within limits; below the minimum the calendar scrolls.
    private var cell: CGFloat {
        let weeks = CGFloat(weekCount)
        guard width > 0, weeks > 0 else { return minCell }
        return min(maxCell, max(minCell, (width + gap) / weeks - gap))
    }

    /// Waits a turn of the run loop so the scroll view knows its content size first.
    private func scrollToToday(_ proxy: ScrollViewProxy) {
        let last = columns.count - 1
        DispatchQueue.main.async { proxy.scrollTo(last, anchor: .trailing) }
    }

    /// Every year from the first dictation to now, newest first.
    private var years: [Int] {
        let current = Calendar.current.component(.year, from: .now)
        let first = stats.days.keys.compactMap { Int($0.prefix(4)) }.min() ?? current
        return Array((min(first, current)...current).reversed())
    }

    /// The year as part of the summary sentence; a borderless menu of years once there's history.
    @ViewBuilder private var yearPicker: some View {
        let years = self.years
        if years.count > 1 {
            Menu {
                Picker("Year", selection: $year) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 2) {
                    Text(String(year))
                    Image(systemName: "chevron.down").imageScale(.small)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Text(String(year))
        }
    }

    /// Every other weekday, like GitHub, pinned while the calendar scrolls.
    private var weekdayLabels: some View {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? symbols[(calendar.firstWeekday - 1 + row) % 7] : "")
                    .frame(height: cell)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: weekdayColumn, alignment: .leading)
        .padding(.top, monthRow + 4)
    }

    /// Month names over the week each month starts in.
    private func monthLabels(_ columns: [[Date?]]) -> some View {
        let calendar = Calendar.current
        var labels: [(column: Int, text: String)] = []
        var previousMonth: Int?
        for (index, column) in columns.enumerated() {
            guard let first = column.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: first)
            if month != previousMonth {
                labels.append((index, first.formatted(.dateTime.month(.abbreviated))))
            }
            previousMonth = month
        }

        return ZStack(alignment: .topLeading) {
            ForEach(labels, id: \.column) { label in
                Text(label.text)
                    .fixedSize()
                    .offset(x: CGFloat(label.column) * (cell + gap))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: CGFloat(columns.count) * (cell + gap) - gap, height: monthRow, alignment: .topLeading)
    }

    /// One array per week of `year`, oldest first, through today for the current year; nil
    /// for days outside the year or after today.
    private var columns: [[Date?]] {
        guard let range = shownRange else { return [] }
        let calendar = Calendar.current
        return (0..<weekCount).map { column in
            let weekStart = calendar.date(byAdding: .weekOfYear, value: column, to: range.firstWeek) ?? range.firstWeek
            return (0..<7).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
                return date < range.first || date > range.last ? nil : date
            }
        }
    }

    private var weekCount: Int {
        guard let range = shownRange else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: range.firstWeek, to: range.last).day ?? 0
        return days / 7 + 1
    }

    /// The first and last day shown, and the start of the week holding the first.
    private var shownRange: (first: Date, last: Date, firstWeek: Date)? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let nextYear = calendar.date(byAdding: .year, value: 1, to: first),
              let lastOfYear = calendar.date(byAdding: .day, value: -1, to: nextYear),
              first <= today else { return nil }
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        return (first, min(today, lastOfYear), firstWeek)
    }

    @ViewBuilder private func dayCell(_ date: Date?, busiest: Int) -> some View {
        if let date {
            let words = stats.day(on: date)?.words ?? 0
            RoundedRectangle(cornerRadius: cell * 0.2)
                .fill(words == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Self.levels[level(words, busiest: busiest)]))
                .frame(width: cell, height: cell)
                .onHover { inside in
                    if inside { hovered = date } else if hovered == date { hovered = nil }
                }
                .anchorPreference(key: HoveredCellKey.self, value: .bounds) { hovered == date ? $0 : nil }
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }

    private func level(_ words: Int, busiest: Int) -> Int {
        guard busiest > 0 else { return 0 }
        let ratio = Double(words) / Double(busiest)
        return min(Self.levels.count - 1, Int(ratio * Double(Self.levels.count)))
    }

    private func summary(dictations: Int) -> String {
        dictations == 1 ? "1 dictation in" : "\(dictations.formatted()) dictations in"
    }
}

/// The bounds of the hovered day cell, for placing its tip over the whole card.
private struct HoveredCellKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

// MARK: - Recent

private struct RecentDictations: View {
    let history: DictationHistory
    let copy: (String) -> Void
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                if history.isEnabled, !history.entries.isEmpty {
                    Button("See All", action: showAll)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.brandText)
                }
            }
            .padding(.bottom, 8)

            if !history.isEnabled {
                HStack {
                    Text("Turn on history to see your latest dictations here. It stays on this Mac.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Turn On") { history.isEnabled = true }
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Divider() }
            } else if history.entries.isEmpty {
                Text("Your dictations will show up here.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Divider() }
            } else {
                ForEach(history.entries.prefix(5)) { entry in
                    RecentRow(entry: entry) { copy(entry.finalText) }
                }
            }
        }
    }
}

private struct RecentRow: View {
    let entry: DictationHistory.Entry
    let copy: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.finalText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if hovering {
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            Text(entry.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { Divider() }
        .onHover { hovering = $0 }
    }
}
