import AppKit
import SwiftUI

/// Window for editing the personal dictionary. Moves into the Settings window's
/// Dictionary tab when that exists (roadmap 1.7).
final class DictionaryWindowController: NSObject, NSWindowDelegate {
    private let dictionary: PersonalDictionary
    private var window: NSWindow?

    init(dictionary: PersonalDictionary) {
        self.dictionary = dictionary
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: DictionaryView(dictionary: dictionary)))
        window.title = "Dictionary"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

private struct DictionaryView: View {
    @Bindable var dictionary: PersonalDictionary

    @State private var term = ""
    /// Alternatives for the entry being written, one per chip.
    @State private var alternatives: [String] = []
    @State private var newAlternative = ""
    /// The entry loaded into the fields for editing, if any.
    @State private var editing: PersonalDictionary.Entry.ID?
    @State private var sample = ""
    @FocusState private var focus: Field?

    private enum Field { case term, alternative }

    private var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Names and terms HeyVedu should always spell your way.")
                .font(.headline)

            entryEditor

            List {
                if dictionary.entries.isEmpty {
                    Text("No words yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(dictionary.entries) { entry in
                    EntryRow(entry: entry, edit: { load(entry) }, delete: { delete(entry) })
                }
            }
            .frame(minHeight: 150)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Try it", text: $sample, prompt: Text("Type or dictate a sentence to test"))
                    .textFieldStyle(.roundedBorder)
                if !sample.isEmpty {
                    Text(dictionary.matcher.apply(to: sample))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 500, minHeight: 600, idealHeight: 660)
        .onAppear { focus = .term }
    }

    private var entryEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Word")
                TextField("Word", text: $term, prompt: Text("e.g. HeyVedu"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .term)
                    .onSubmit { focus = .alternative }
            }
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Also heard as")
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Also heard as", text: $newAlternative, prompt: Text("Optional, press Return to add"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .alternative)
                            .onSubmit(submitAlternative)
                        Button("Add Alternative", systemImage: "plus", action: addAlternative)
                            .labelStyle(.iconOnly)
                            .disabled(newAlternative.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !alternatives.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(alternatives, id: \.self) { alternative in
                                Chip(text: alternative) { alternatives.removeAll { $0 == alternative } }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                if editing != nil {
                    Button("Cancel", action: clearFields)
                }
                Button(editing == nil ? "Add Word" : "Save Word", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedTerm.isEmpty)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .frame(width: 92, alignment: .trailing)
    }

    /// Return in the alternative field adds it; Return on an empty field saves the word.
    private func submitAlternative() {
        if newAlternative.trimmingCharacters(in: .whitespaces).isEmpty {
            commit()
        } else {
            addAlternative()
        }
    }

    private func addAlternative() {
        let alternative = newAlternative.trimmingCharacters(in: .whitespacesAndNewlines)
        newAlternative = ""
        focus = .alternative
        guard !alternative.isEmpty,
              !alternatives.contains(where: { $0.caseInsensitiveCompare(alternative) == .orderedSame })
        else { return }
        alternatives.append(alternative)
    }

    private func commit() {
        guard !trimmedTerm.isEmpty else { return }
        // Text typed but not yet added as a chip still counts.
        addAlternative()
        if let editing, let index = dictionary.entries.firstIndex(where: { $0.id == editing }) {
            dictionary.entries[index].term = trimmedTerm
            dictionary.entries[index].alternatives = alternatives
        } else {
            dictionary.entries.append(.init(term: trimmedTerm, alternatives: alternatives))
        }
        clearFields()
    }

    private func load(_ entry: PersonalDictionary.Entry) {
        editing = entry.id
        term = entry.term
        alternatives = entry.alternatives
        newAlternative = ""
        focus = .term
    }

    private func delete(_ entry: PersonalDictionary.Entry) {
        dictionary.entries.removeAll { $0.id == entry.id }
        if editing == entry.id { clearFields() }
    }

    private func clearFields() {
        editing = nil
        term = ""
        alternatives = []
        newAlternative = ""
        focus = .term
    }
}

private struct EntryRow: View {
    let entry: PersonalDictionary.Entry
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term)
                    .fontWeight(.medium)
                if !entry.alternatives.isEmpty {
                    // Quoted, since an alternative can contain a comma.
                    Text("also heard as " + entry.alternatives.map { "“\($0)”" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Edit", systemImage: "pencil", action: edit)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            Button("Delete", systemImage: "trash", action: delete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

private struct Chip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Button("Remove \(text)", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
