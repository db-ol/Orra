import SwiftUI

/// One line of the vocabulary table in Settings.
nonisolated struct VocabularyRow: Identifiable, Equatable, Sendable {
    /// The word ignoring case, as `VocabularyWord.id`.
    let id: String
    let word: String
    /// True when Orra learned the word from a correction: the learning store holds accepted
    /// pairs for it.
    let isLearned: Bool
    /// The misheard spellings learning saw for the word, comma separated. Empty for words
    /// the user added.
    let heardAs: String
    let lastUsed: Date?
    /// When the word was added or last used, the order the speech model chooses by.
    let lastActive: Date

    /// For sorting by Last used, with words never used last.
    var lastUsedOrder: Date { lastUsed ?? .distantPast }
}

/// What the vocabulary table shows and what its buttons do, apart from the view so tests
/// can check it.
enum VocabularyList {
    /// A row per word, with what learning knows about it.
    static func rows(_ words: [VocabularyWord], store: CorrectionStore) -> [VocabularyRow] {
        var heard: [String: [String]] = [:]
        for entry in store.entries where entry.state == .accepted {
            let key = entry.correction.corrected.lowercased()
            if !(heard[key] ?? []).contains(entry.correction.heard) {
                heard[key, default: []].append(entry.correction.heard)
            }
        }
        return words.map { word in
            let spellings = heard[word.id] ?? []
            return VocabularyRow(
                id: word.id,
                word: word.text,
                isLearned: !spellings.isEmpty,
                heardAs: spellings.joined(separator: ", "),
                lastUsed: word.lastUsed,
                lastActive: word.lastActive
            )
        }
    }

    /// Takes the words out of the vocabulary through the same path as before, so learning
    /// forgets their accepted pairs and learns them again on the next fix.
    static func remove(_ ids: Set<String>, pushToTalk: PushToTalkController, learning: CorrectionLearning) {
        let words = pushToTalk.vocabulary.filter { ids.contains($0.id) }.map(\.text)
        guard !words.isEmpty else { return }
        pushToTalk.removeFromVocabulary(words)
        for word in words {
            learning.removedFromVocabulary(word)
        }
    }

    /// The line above the table: the count, and how many words the model gets once there
    /// are more than it takes.
    static func summary(count: Int) -> String {
        if count > Vocabulary.modelLimit {
            String(localized: "\(count) words. Orra gives the \(Vocabulary.modelLimit) most recently added or used to the speech model.")
        } else if count == 1 {
            String(localized: "1 word")
        } else {
            String(localized: "\(count) words")
        }
    }
}

/// The words in a table, as System Settings shows text replacements: sortable by word and
/// last use, searchable, and with several rows selected at once removed by the minus
/// button or the Delete key.
struct VocabularyTable: View {
    let pushToTalk: PushToTalkController
    let learning: CorrectionLearning
    @State private var search = ""
    @State private var selection = Set<VocabularyRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\VocabularyRow.lastActive, order: .reverse)]

    var body: some View {
        let all = VocabularyList.rows(pushToTalk.vocabulary, store: learning.store)
        let shown = (search.isEmpty ? all : all.filter {
            $0.word.localizedCaseInsensitiveContains(search) || $0.heardAs.localizedCaseInsensitiveContains(search)
        }).sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $search, prompt: Text("Search"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Word", value: \.word, comparator: .localizedStandard) { row in
                    Text(verbatim: row.word)
                }
                TableColumn("Source") { row in
                    Text(row.isLearned ? "Learned" : "Added by you")
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Heard as") { row in
                    Text(verbatim: row.heardAs)
                        .foregroundStyle(.secondary)
                        .help(row.heardAs)
                }
                TableColumn("Last used", value: \.lastUsedOrder) { row in
                    if let used = row.lastUsed {
                        Text(used, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: "-")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Never used")
                    }
                }
                .width(min: 80, ideal: 110)
            }
            .frame(height: 280)
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if all.isEmpty {
                    Text("No words yet")
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: removeSelected) {
                Image(systemName: "minus")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(selection.isEmpty)
            .help("Remove the selected words")
            .accessibilityLabel("Remove")
        }
        .onChange(of: pushToTalk.vocabulary) {
            // Rows that left the list, such as an undone learned word, are not selected.
            let ids = Set(pushToTalk.vocabulary.map(\.id))
            selection.formIntersection(ids)
        }
    }

    private func removeSelected() {
        VocabularyList.remove(selection, pushToTalk: pushToTalk, learning: learning)
        selection = []
    }
}
