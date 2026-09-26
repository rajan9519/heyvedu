import SwiftUI

struct VocabularyView: View {
    let store: VocabularyStore

    @State private var newTerm = ""
    @State private var message: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names, product terms and jargon, spelled exactly as you want them written. Cleanup uses them to fix misheard words — for example \u{201C}git hub\u{201D} → \u{201C}GitHub\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Add a term", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error = message ?? store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            List {
                ForEach(store.terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            store.remove(term)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \u{201C}\(term)\u{201D}")
                    }
                }
            }
            .overlay {
                if store.terms.isEmpty {
                    ContentUnavailableView("No terms yet", systemImage: "text.book.closed")
                }
            }

            Text("\(store.terms.count) of \(VocabularyStore.maxTerms) terms · used only when cleanup is on")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 380, minHeight: 380, idealHeight: 460)
        .onAppear {
            store.reload()
            fieldFocused = true
        }
    }

    private func add() {
        message = store.add(newTerm)
        if message == nil { newTerm = "" }
    }
}
