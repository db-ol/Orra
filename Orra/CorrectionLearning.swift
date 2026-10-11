import AppKit
import ApplicationServices
import Observation
import os

/// One text field in another app, as the Accessibility API names it. Accessibility
/// elements may be used from any thread.
nonisolated final class FieldHandle: @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }
}

/// Reads the field Orra pasted into, through the Accessibility API. Checks that a field is a
/// plain text field before asking for its text, so a password field's value is never
/// requested.
nonisolated enum FieldReader {
    /// A longer text is not read, so a big document is never copied.
    static let maximumLength = 20_000

    /// The focused element of the app, when it is a plain text field.
    @concurrent
    static func focusedTextField(inApp pid: pid_t) async -> FieldHandle? {
        guard let field = focusedElement(inApp: pid), kind(of: field) == .plainText else { return nil }
        return FieldHandle(field)
    }

    /// The field's text, while it is still the focused element of the app and a plain text
    /// field, and no longer than `maximumLength`. Nil otherwise.
    @concurrent
    static func text(of field: FieldHandle, inApp pid: pid_t) async -> String? {
        guard let focused = focusedElement(inApp: pid), CFEqual(focused, field.element),
              kind(of: field.element) == .plainText else { return nil }
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(field.element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let number = count as? Int, number > maximumLength {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field.element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, text.count <= maximumLength else { return nil }
        return text
    }

    private static func focusedElement(inApp pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, FocusedField.timeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let field = focused as! AXUIElement
        // A timeout applies only to the element it was set on.
        AXUIElementSetMessagingTimeout(field, FocusedField.timeout)
        return field
    }

    private static func kind(of field: AXUIElement) -> FocusedField.Kind {
        var values: CFArray?
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(field, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
              let read = values as? [Any], read.count == 2 else { return .unknown }
        return FocusedField.kind(role: read[0] as? String, subrole: read[1] as? String)
    }
}

/// Follows the field Orra just pasted into, for up to 3 minutes, and reports the user's
/// correction of a misheard word. Reads only that field, and only while its app is in
/// front without secure input and the field has the focus. Otherwise it waits, so
/// switching away and coming back to fix a line works. Each paste has its own watch, up to
/// five at a time, so dictating several lines and then fixing them works. A watch pushed
/// out by a sixth paste reports what it found. PasteTracker follows where each paste is while other lines
/// change. It looks for corrections after every change and reports them once the field has
/// not changed for a reading, so the user hears back a second or two after the fix. Separate
/// fixes in one paste are followed apart, by the span of the pasted text they cover. A later
/// fix over the same span replaces the earlier one, so a word the user typed past without
/// a pause is never learned. When the user changes the same span again, as when finishing a half
/// typed word, the new correction is reported as replacing the earlier one. Offered words are reported before
/// learned ones, and the notice shows them in turn. Logs states only,
/// never text.
@MainActor
final class CorrectionWatcher {
    struct Environment {
        /// Opens the focused text field of the app, giving a function that reads it.
        var open: @MainActor (pid_t) async -> (@MainActor () async -> String?)?
        var frontmost: @MainActor () -> pid_t?
        var secureInputHolder: @MainActor () -> pid_t?
        var sleep: @MainActor (Duration) async throws -> Void

        static func live() -> Environment {
            Environment(
                open: { pid in
                    guard let field = await FieldReader.focusedTextField(inApp: pid) else { return nil }
                    return { await FieldReader.text(of: field, inApp: pid) }
                },
                frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                secureInputHolder: { SecureInput.holder() },
                sleep: { try await Task.sleep(for: $0) }
            )
        }
    }

    static let readings = 180
    static let maximumWatches = 5
    /// Readings without a change before a correction is reported: a second after the user
    /// stops typing. A word still being typed is replaced once it is finished.
    static let quietReadings = 1

    /// Tells a running watch to end early and report what it found.
    private final class Control {
        var finish = false
    }

    private let environment: Environment
    private var watches: [(id: Int, task: Task<Void, Never>, control: Control)] = []
    private var nextID = 0
    private let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "learning")

    init(environment: Environment = .live()) {
        self.environment = environment
    }

    /// Starts following a paste. The oldest watch ends and reports when five are running.
    /// `onCorrection` gets each finding and the earlier one it replaces, if any.
    func watch(pasted: String, in pid: pid_t, onCorrection: @escaping (Finding, Finding?) -> Void) {
        if watches.count >= Self.maximumWatches {
            watches.removeFirst().control.finish = true
        }
        nextID += 1
        let id = nextID
        let control = Control()
        let environment = environment
        let logger = logger
        let task = Task { @MainActor [weak self] in
            defer { self?.watches.removeAll { $0.id == id } }
            @MainActor func allowed() -> Bool {
                environment.frontmost() == pid && environment.secureInputHolder() != pid
            }
            // The paste lands a moment after Command V.
            try? await environment.sleep(.milliseconds(900))
            guard !Task.isCancelled else { return }
            guard allowed() else {
                logger.notice("Learning: the app is no longer in front, or holds secure input")
                return
            }
            guard let read = await environment.open(pid) else {
                logger.notice("Learning: the focused element is not a text field Orra can read")
                return
            }
            guard let before = await read(), var tracker = PasteTracker(pasted: pasted, field: before) else {
                logger.notice("Learning: the pasted text is not in the field")
                return
            }
            var latest = before
            // The findings so far. A later finding over the same text of the paste replaces
            // the earlier one, so a word the user typed past, such as a half typed word, is
            // dropped. A finding stays when the paste is gone, as after sending a message.
            var found: [CorrectionFinder.Located] = []
            // The findings reported, by the span of the pasted text they cover. A finding
            // over the same text replaces the earlier one, so going back and forth over a
            // word leaves one pair.
            var reported: [CorrectionFinder.Located] = []
            @MainActor func report() {
                let waiting = found.filter { item in
                    !reported.contains { $0.finding == item.finding && $0.span.overlaps(item.span) }
                }
                // Offered words first. The notice shows them in turn.
                for item in waiting.filter({ !$0.finding.isWord }) + waiting.filter(\.finding.isWord) {
                    let earlier = reported.last { $0.span.overlaps(item.span) }?.finding
                    reported.removeAll { $0.span.overlaps(item.span) }
                    reported.append(item)
                    onCorrection(item.finding, earlier)
                }
            }
            var quiet = 0
            var readings = 0
            var paused = 0
            for _ in 1...Self.readings {
                try? await environment.sleep(.seconds(1))
                guard !Task.isCancelled else { return }
                guard !control.finish else { break }
                // Away from the field: wait for the user to come back.
                guard allowed(), let text = await read() else {
                    paused += 1
                    continue
                }
                readings += 1
                if text != latest {
                    latest = text
                    quiet = 0
                    tracker.update(to: text)
                    let latest = await Self.find(pasted: pasted, edited: tracker.pasteNow)
                    found.removeAll { earlier in latest.contains { $0.span.overlaps(earlier.span) } }
                    found += latest
                } else {
                    quiet += 1
                }
                guard !Task.isCancelled else { return }
                if quiet >= Self.quietReadings {
                    report()
                }
            }
            logger.notice("Learning: watch ended after \(readings, privacy: .public) readings and \(paused, privacy: .public) seconds away, corrections found: \(found.count, privacy: .public)")
            guard !Task.isCancelled else { return }
            report()
        }
        watches.append((id, task, control))
    }

    /// Off the main actor, because the keyboard tap runs there.
    @concurrent
    private static func find(pasted: String, edited: String) async -> [CorrectionFinder.Located] {
        CorrectionFinder.locatedFindings(pasted: pasted, edited: edited)
    }

    func stop() {
        for watch in watches {
            watch.task.cancel()
        }
        watches = []
    }
}

/// Learning from the user's corrections: off until the user turns it on. Keeps the word
/// pairs it saw. The first time a word is corrected, adds it to the vocabulary and tells
/// `onLearned`, which shows a notice with Undo. A word learned before takes a new misheard
/// spelling quietly. A learned word the user takes out of the vocabulary is forgotten, so
/// the next fix learns it again with the notice. A word the user undid is never learned
/// again. After a fix of one Chinese character it
/// adds nothing on its own, and tells `onSuggest`, which offers the guessed word for the
/// user to add. The text itself is never changed: the vocabulary only helps the model hear
/// the word.
@Observable
final class CorrectionLearning {
    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            saveSetting(isOn)
            if !isOn { watcher.stop() }
        }
    }
    private(set) var store: CorrectionStore

    /// A word Orra learned on its own, or could not add because the vocabulary holds
    /// `Vocabulary.maximumCount` words, a cap against runaway data that nobody should meet:
    /// the misheard spelling and the pairs it accepted, so Undo takes back only those.
    struct Learned: Equatable {
        enum Outcome: Equatable {
            case added
            /// The vocabulary is at `Vocabulary.maximumCount`.
            case vocabularyFull
        }

        let correction: Correction
        let pairs: [Correction]
        let outcome: Outcome
    }

    /// Called when a word was added on its own, or could not be added.
    @ObservationIgnored var onLearned: ((Learned) -> Void)?
    /// Called with a word to offer after a fix of one Chinese character.
    @ObservationIgnored var onSuggest: ((WordSuggestion) -> Void)?
    /// Words added in this session, so a half typed fix that a finished one replaces can be
    /// taken back.
    @ObservationIgnored private var added: [Learned] = []

    @ObservationIgnored private let watcher: CorrectionWatcher
    @ObservationIgnored private let saveSetting: (Bool) -> Void
    @ObservationIgnored private let saveStore: (CorrectionStore) -> Void
    @ObservationIgnored private let addToVocabulary: (String) -> VocabularyAddition
    @ObservationIgnored private let removeFromVocabulary: (String) -> Void
    @ObservationIgnored private let isInVocabulary: (String) -> Bool
    @ObservationIgnored private let now: () -> Date

    init(
        isOn: Bool,
        store: CorrectionStore,
        watcher: CorrectionWatcher,
        saveSetting: @escaping (Bool) -> Void,
        saveStore: @escaping (CorrectionStore) -> Void,
        addToVocabulary: @escaping (String) -> VocabularyAddition,
        removeFromVocabulary: @escaping (String) -> Void,
        isInVocabulary: @escaping (String) -> Bool = { _ in false },
        now: @escaping () -> Date = { Date() }
    ) {
        self.isOn = isOn
        self.store = store
        self.watcher = watcher
        self.saveSetting = saveSetting
        self.saveStore = saveStore
        self.addToVocabulary = addToVocabulary
        self.removeFromVocabulary = removeFromVocabulary
        self.isInVocabulary = isInVocabulary
        self.now = now
    }

    /// The app's learning, with the setting in UserDefaults and the pairs in
    /// ~/Library/Application Support/io.github.db-ol.Orra/corrections.json.
    static func live(
        addToVocabulary: @escaping (String) -> VocabularyAddition,
        removeFromVocabulary: @escaping (String) -> Void,
        isInVocabulary: @escaping (String) -> Bool
    ) -> CorrectionLearning {
        let url = storeURL
        let learning = CorrectionLearning(
            isOn: UserDefaults.standard.bool(forKey: settingKey),
            store: CorrectionStore.load(from: url),
            watcher: CorrectionWatcher(),
            saveSetting: { UserDefaults.standard.set($0, forKey: settingKey) },
            saveStore: { store in
                do {
                    try store.save(to: url)
                } catch {
                    Logger(subsystem: "io.github.db-ol.Orra", category: "learning").error("Could not save the learned corrections")
                }
            },
            addToVocabulary: addToVocabulary,
            removeFromVocabulary: removeFromVocabulary,
            isInVocabulary: isInVocabulary
        )
        learning.forgetRemovedWords()
        return learning
    }

    static let settingKey = "learnsFromCorrections"
    static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.db-ol.Orra/corrections.json")
    }

    /// Called after each paste. Does nothing while learning is off.
    func pasted(_ text: String, in pid: pid_t) {
        guard isOn else { return }
        watcher.watch(pasted: text, in: pid) { [weak self] finding, earlier in
            switch finding {
            case .word(let correction):
                self?.record(correction, replacing: earlier?.correction)
            case .suggestion(let suggestion):
                self?.suggest(suggestion, replacing: earlier?.correction)
            }
        }
    }

    /// Offers the guessed word, unless it is in the vocabulary, this pair was declined, or
    /// the word was learned or undone before. A pair only seen, as when the vocabulary was
    /// full, is offered again. Records nothing until the user answers.
    func suggest(_ suggestion: WordSuggestion, replacing earlier: Correction? = nil) {
        if let earlier, earlier != suggestion.pair {
            forget(earlier)
        }
        let word = suggestion.guess
        let state = store.state(of: suggestion.pair)
        guard state == nil || state == .seen, !isInVocabulary(word),
              !store.has(.dismissed, for: word), !store.has(.accepted, for: word) else { return }
        onSuggest?(suggestion)
    }

    /// The user added an offered word, maybe edited: keeps its pair as accepted and puts the
    /// word in the vocabulary. Tells `onLearned` only when the vocabulary is full.
    func add(_ suggestion: WordSuggestion, as text: String) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let pair = suggestion.pair(for: word)
        store.record(pair, at: now())
        switch addToVocabulary(word) {
        case .added, .alreadyThere:
            _ = store.acceptSeen(of: word)
            saveStore(store)
        case .full:
            saveStore(store)
            onLearned?(Learned(correction: pair, pairs: [], outcome: .vocabularyFull))
        }
    }

    /// The user closed an offered word, or let it go: the same pair is not offered again.
    func decline(_ suggestion: WordSuggestion) {
        store.record(suggestion.pair, at: now())
        store.decline(suggestion.pair)
        saveStore(store)
    }

    /// Keeps the pair, and learns its word the first time. An earlier correction of the same
    /// words, such as a half typed one, is forgotten first.
    func record(_ correction: Correction, replacing earlier: Correction? = nil) {
        if let earlier, earlier != correction {
            forget(earlier)
        }
        store.record(correction, at: now())
        let word = correction.corrected
        // Undone before: never again. Learned before: the new mishearing is kept quietly.
        // A word the user took out of the vocabulary has no accepted pairs left, so it is
        // learned again.
        guard !store.has(.dismissed, for: word), !store.has(.accepted, for: word) else {
            if !store.has(.dismissed, for: word) {
                _ = store.acceptSeen(of: word)
            }
            saveStore(store)
            return
        }
        switch addToVocabulary(word) {
        case .added:
            let learned = Learned(correction: correction, pairs: store.acceptSeen(of: word), outcome: .added)
            saveStore(store)
            added.append(learned)
            onLearned?(learned)
        case .alreadyThere:
            // The user added it before: nothing to tell.
            _ = store.acceptSeen(of: word)
            saveStore(store)
        case .full:
            // Stays seen, so a fix after the user made room adds it.
            saveStore(store)
            onLearned?(Learned(correction: correction, pairs: [], outcome: .vocabularyFull))
        }
    }

    /// Takes back a word learned on its own: never learns it again, and takes it out of the
    /// vocabulary when learning put it there.
    func undo(_ learned: Learned) {
        store.dismiss(learned.pairs, at: now())
        saveStore(store)
        if learned.outcome == .added {
            removeFromVocabulary(learned.correction.corrected)
        }
        added.removeAll { $0 == learned }
    }

    /// Forgets a pair the user went on editing. When it was the only pair of a word this
    /// session added, the word leaves the vocabulary too.
    private func forget(_ correction: Correction) {
        store.forget(correction)
        saveStore(store)
        let word = correction.corrected
        guard let index = added.firstIndex(where: { $0.pairs.contains(correction) }),
              !store.has(.accepted, for: word) else { return }
        added.remove(at: index)
        removeFromVocabulary(word)
    }

    /// The user took a word out of the vocabulary: forgets its accepted pairs, so the next
    /// fix learns it again and shows the notice. A word the user undid stays undone.
    func removedFromVocabulary(_ word: String) {
        let lowered = word.lowercased()
        added.removeAll { $0.correction.corrected.lowercased() == lowered }
        guard store.acceptedWords.contains(where: { $0.lowercased() == lowered }) else { return }
        store.forgetAccepted(of: word)
        saveStore(store)
    }

    /// Forgets the accepted pairs of learned words that are no longer in the vocabulary,
    /// such as words removed before Orra forgot them on removal.
    func forgetRemovedWords() {
        let removed = store.acceptedWords.filter { !isInVocabulary($0) }
        guard !removed.isEmpty else { return }
        for word in removed {
            store.forgetAccepted(of: word)
        }
        saveStore(store)
    }

    /// Forgets every pair, the undone ones too. The vocabulary keeps its words.
    func removeAll() {
        store.removeAll()
        saveStore(store)
    }
}
