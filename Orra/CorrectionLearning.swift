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
/// change. It looks for a correction after every change and keeps the latest, so sending a
/// chat message, which empties the field, does not lose it. Logs states only, never text.
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
    func watch(pasted: String, in pid: pid_t, onCorrection: @escaping (Correction) -> Void) {
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
            var found: Correction?
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
                    tracker.update(to: text)
                    if let correction = await Self.find(pasted: pasted, edited: tracker.pasteNow) {
                        found = correction
                    }
                }
            }
            logger.notice("Learning: watch ended after \(readings, privacy: .public) readings and \(paused, privacy: .public) seconds away, correction found: \(found != nil, privacy: .public)")
            guard !Task.isCancelled, let found else { return }
            onCorrection(found)
        }
        watches.append((id, task, control))
    }

    /// Off the main actor, because the keyboard tap runs there.
    @concurrent
    private static func find(pasted: String, edited: String) async -> Correction? {
        CorrectionFinder.correction(pasted: pasted, edited: edited)
    }

    func stop() {
        for watch in watches {
            watch.task.cancel()
        }
        watches = []
    }
}

/// Learning from the user's corrections: off until the user turns it on. Keeps the word
/// pairs it saw, suggests one after it was seen twice within 7 days, adds an accepted one
/// to the vocabulary, and applies accepted ones before each paste.
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

    @ObservationIgnored private let watcher: CorrectionWatcher
    @ObservationIgnored private let saveSetting: (Bool) -> Void
    @ObservationIgnored private let saveStore: (CorrectionStore) -> Void
    @ObservationIgnored private let addToVocabulary: (String) -> Void
    @ObservationIgnored private let now: () -> Date

    init(
        isOn: Bool,
        store: CorrectionStore,
        watcher: CorrectionWatcher,
        saveSetting: @escaping (Bool) -> Void,
        saveStore: @escaping (CorrectionStore) -> Void,
        addToVocabulary: @escaping (String) -> Void,
        now: @escaping () -> Date = { Date() }
    ) {
        self.isOn = isOn
        self.store = store
        self.watcher = watcher
        self.saveSetting = saveSetting
        self.saveStore = saveStore
        self.addToVocabulary = addToVocabulary
        self.now = now
    }

    /// The app's learning, with the setting in UserDefaults and the pairs in
    /// ~/Library/Application Support/io.github.db-ol.Orra/corrections.json.
    static func live(addToVocabulary: @escaping (String) -> Void) -> CorrectionLearning {
        let url = storeURL
        return CorrectionLearning(
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
            addToVocabulary: addToVocabulary
        )
    }

    static let settingKey = "learnsFromCorrections"
    static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.db-ol.Orra/corrections.json")
    }

    var suggestions: [Correction] { store.suggestions }

    /// Called after each paste. Does nothing while learning is off.
    func pasted(_ text: String, in pid: pid_t) {
        guard isOn else { return }
        watcher.watch(pasted: text, in: pid) { [weak self] correction in
            self?.record(correction)
        }
    }

    func record(_ correction: Correction) {
        store.record(correction, at: now())
        saveStore(store)
    }

    func accept(_ correction: Correction) {
        store.decide(correction, .accepted)
        saveStore(store)
        addToVocabulary(correction.corrected)
    }

    /// Stops applying an accepted pair.
    func remove(_ correction: Correction) {
        store.remove(correction)
        saveStore(store)
    }

    func dismiss(_ correction: Correction) {
        store.decide(correction, .dismissed)
        saveStore(store)
    }

    /// Forgets every pair, the accepted ones too. The vocabulary keeps its words.
    func removeAll() {
        store.removeAll()
        saveStore(store)
    }

    /// The text with the accepted corrections applied.
    func apply(to text: String) -> String {
        Replacements.apply(store.accepted, to: text)
    }
}
