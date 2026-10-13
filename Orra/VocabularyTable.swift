import SwiftUI

/// One line of the vocabulary table in Settings.
nonisolated struct VocabularyRow: Identifiable, Equatable, Sendable {
    /// The word ignoring case, as `VocabularyWord.id`.
    let id: String
    let word: String
    /// True when Orra learned the word, from a correction or as an offered word the user
    /// added. For a word kept from Orra 0.1.0, which did not record how a word came, true
    /// when the learning store holds accepted pairs for it.
    let isLearned: Bool
    /// The misheard spellings learning saw for the word, comma separated. Empty for words
    /// the user added.
    let heardAs: String
    let lastUsed: Date?
    /// When the word was added or last used, the order the speech model chooses by.
    let lastActive: Date

    /// The word and its misheard spellings in lowercase, for the search field.
    let searchKey: String

    init(id: String, word: String, isLearned: Bool, heardAs: String, lastUsed: Date?, lastActive: Date) {
        self.id = id
        self.word = word
        self.isLearned = isLearned
        self.heardAs = heardAs
        self.lastUsed = lastUsed
        self.lastActive = lastActive
        searchKey = (word + "\n" + heardAs).lowercased()
    }

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
                isLearned: word.source.map { $0 == .learned } ?? !spellings.isEmpty,
                heardAs: spellings.joined(separator: ", "),
                lastUsed: word.lastUsed,
                lastActive: word.lastActive
            )
        }
    }

    /// The rows whose word or misheard spellings hold the search, ignoring case. All rows
    /// for an empty search.
    static func filter(_ rows: [VocabularyRow], by search: String) -> [VocabularyRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? rows : rows.filter { $0.searchKey.contains(query) }
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
/// button or the Delete key. The rows are built and sorted only when the words, the
/// learning store or the order change, not on every redraw or search keystroke, since the
/// main thread also runs the keyboard tap.
struct VocabularyTable: View {
    let pushToTalk: PushToTalkController
    let learning: CorrectionLearning
    @State private var search = ""
    @State private var selection = Set<VocabularyRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\VocabularyRow.lastActive, order: .reverse)]
    /// All rows in the chosen order.
    @State private var sorted: [VocabularyRow] = []

    var body: some View {
        let shown = VocabularyList.filter(sorted, by: search)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search", text: $search, prompt: Text("Search"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                // The column titles sort too, but few people know they can be clicked.
                // The name stands apart from the picker, which in a grouped form would
                // otherwise stretch over the row and squeeze the search field.
                Text("Sort by")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Picker("Sort by", selection: sortChoice) {
                    Text("Recently used").tag(SortChoice.recent)
                    Text("Word").tag(SortChoice.word)
                }
                .labelsHidden()
                .fixedSize()
            }
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
            .frame(height: Self.height(rows: shown.count))
            .onDeleteCommand(perform: removeSelected)
            .contextMenu(forSelectionType: VocabularyRow.ID.self) { ids in
                Button(ids.count > 1 ? "Remove \(ids.count) Words" : "Remove", role: .destructive) {
                    selection = ids
                    removeSelected()
                }
            }
            .overlay {
                if sorted.isEmpty {
                    Text("No words yet")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Select words, then choose Remove or press Delete. Right-click a word to remove it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: removeSelected) {
                    Label(selection.count > 1 ? "Remove \(selection.count) Words" : "Remove", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
        .onAppear(perform: rebuild)
        .onChange(of: learning.store) { rebuild() }
        .onChange(of: sortOrder) { rebuild() }
        .onChange(of: pushToTalk.vocabulary) {
            rebuild()
            // Rows that left the list, such as an undone learned word, are not selected.
            let ids = Set(pushToTalk.vocabulary.map(\.id))
            selection.formIntersection(ids)
        }
    }

    /// Tall enough for every row up to `maximumHeight`, then the table scrolls. So the Remove
    /// button and its hint sit right under the last word instead of under empty space.
    nonisolated static func height(rows: Int) -> CGFloat {
        let header: CGFloat = 28
        let row: CGFloat = 24
        let shownRows = max(rows, 3)
        return min(header + row * CGFloat(shownRows) + 6, maximumHeight)
    }

    nonisolated static let maximumHeight: CGFloat = 320

    /// The two orders the Sort by menu offers, matching the sortable columns.
    enum SortChoice: Hashable {
        case recent
        case word
    }

    private var sortChoice: Binding<SortChoice> {
        Binding(
            get: { sortOrder.first?.keyPath == (\VocabularyRow.word as PartialKeyPath<VocabularyRow>) ? .word : .recent },
            set: { choice in
                switch choice {
                case .recent: sortOrder = [KeyPathComparator(\VocabularyRow.lastActive, order: .reverse)]
                case .word: sortOrder = [KeyPathComparator(\VocabularyRow.word, comparator: .localizedStandard)]
                }
            }
        )
    }

    private func rebuild() {
        sorted = VocabularyList.rows(pushToTalk.vocabulary, store: learning.store).sorted(using: sortOrder)
    }

    private func removeSelected() {
        VocabularyList.remove(selection, pushToTalk: pushToTalk, learning: learning)
        selection = []
    }
}
