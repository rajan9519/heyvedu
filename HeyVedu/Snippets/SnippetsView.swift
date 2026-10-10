import SwiftUI

/// Editor for snippets: the main window's Snippets section.
struct SnippetsView: View {
    @Bindable var library: SnippetLibrary
    /// Applied in the Try it preview, the same way a dictation is.
    let dictionary: DictionaryMatcher

    @State private var trigger = ""
    @State private var expansion = ""
    /// The snippet loaded into the fields for editing, if any.
    @State private var editing: SnippetLibrary.Snippet.ID?
    @State private var sample = ""
    @FocusState private var focus: Field?

    private enum Field { case trigger, expansion }

    private var trimmedTrigger: String { trigger.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedExpansion: String { expansion.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Another snippet already uses this trigger (same words, ignoring case and punctuation).
    private var duplicate: SnippetLibrary.Snippet? {
        let key = DictionaryMatcher.normalized(trigger)
        guard !key.isEmpty else { return nil }
        return library.snippets.first { $0.id != editing && DictionaryMatcher.normalized($0.trigger) == key }
    }

    private var canSave: Bool {
        !DictionaryMatcher.normalized(trigger).isEmpty && !trimmedExpansion.isEmpty && duplicate == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Say a phrase, get your text.")
                    .font(.headline)
                Text("Say the trigger anywhere in a dictation and HeyVedu inserts the text exactly as you typed it. Pick a phrase you wouldn't say otherwise, like “my calendly link”.")
                    .foregroundStyle(.secondary)
            }

            editor

            List {
                if library.snippets.isEmpty {
                    Text("No snippets yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.snippets) { snippet in
                    SnippetRow(snippet: snippet, edit: { load(snippet) }, delete: { delete(snippet) })
                }
            }
            .frame(minHeight: 150)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Try it", text: $sample, prompt: Text("Type or dictate a sentence to test"))
                    .textFieldStyle(.roundedBorder)
                if !sample.isEmpty {
                    Text(library.expander.expand(sample, dictionary: dictionary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focus = .trigger }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("When I say")
                TextField("When I say", text: $trigger, prompt: Text("e.g. my calendly link"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .trigger)
                    .onSubmit { focus = .expansion }
            }
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Insert")
                // Grows with the text; Option-Return adds a line break.
                TextField("Insert", text: $expansion, prompt: Text("Text to insert. Option-Return for a new line"), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)
                    .focused($focus, equals: .expansion)
            }
            HStack {
                if let duplicate {
                    Label("“\(duplicate.trigger)” is already a snippet.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 100)
                }
                Spacer()
                if editing != nil {
                    Button("Cancel", action: clearFields)
                }
                Button(editing == nil ? "Add Snippet" : "Save Snippet", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .frame(width: 92, alignment: .trailing)
    }

    private func commit() {
        guard canSave else { return }
        // Line breaks inside the expansion are kept; only the ends are trimmed.
        if let editing, let index = library.snippets.firstIndex(where: { $0.id == editing }) {
            library.snippets[index].trigger = trimmedTrigger
            library.snippets[index].expansion = trimmedExpansion
        } else {
            library.snippets.append(.init(trigger: trimmedTrigger, expansion: trimmedExpansion))
        }
        clearFields()
    }

    private func load(_ snippet: SnippetLibrary.Snippet) {
        editing = snippet.id
        trigger = snippet.trigger
        expansion = snippet.expansion
        focus = .trigger
    }

    private func delete(_ snippet: SnippetLibrary.Snippet) {
        library.snippets.removeAll { $0.id == snippet.id }
        if editing == snippet.id { clearFields() }
    }

    private func clearFields() {
        editing = nil
        trigger = ""
        expansion = ""
        focus = .trigger
    }
}

private struct SnippetRow: View {
    let snippet: SnippetLibrary.Snippet
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(snippet.trigger)”")
                    .fontWeight(.medium)
                Text(snippet.expansion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
