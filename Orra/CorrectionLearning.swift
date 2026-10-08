import AppKit
import ApplicationServices
import Observation

/// Reads the text of the focused field in another app through the Accessibility API.
nonisolated enum FieldReader {
    /// Longer text is not read, so a huge document is never copied.
    static let maximumLength = 20_000

    /// The focused field's text, or nil when it cannot be read in time, is a password
    /// field, or is too long. Off the main actor, because the app answers and may be slow.
    @concurrent
    static func text(inApp pid: pid_t) async -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, FocusedField.timeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let field = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(field, FocusedField.timeout)
        var values: CFArray?
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(field, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
              let read = values as? [Any], read.count == 3,
              FocusedField.kind(role: read[0] as? String, subrole: read[1] as? String) == .plainText,
              let text = read[2] as? String, text.count <= maximumLength else { return nil }
        return text
    }
}

/// Follows the field Orra just pasted into, for up to 30 seconds, and reports the user's
/// correction of a misheard word. Stops when the user leaves the app, when secure input is
/// on in it, when the field cannot be read, or 4 seconds after the last change.
@MainActor
final class CorrectionWatcher {
    struct Environment {
        var read: @MainActor (pid_t) async -> String?
        var frontmost: @MainActor () -> pid_t?
        var secureInputHolder: @MainActor () -> pid_t?
        var sleep: @MainActor (Duration) async throws -> Void

        static func live() -> Environment {
            Environment(
            read: { pid in await FieldReader.text(inApp: pid) },
            frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            secureInputHolder: { SecureInput.holder() },
            sleep: { try await Task.sleep(for: $0) }
            )
        }
    }

    static let readings = 30
    static let quietReadings = 4

    private let environment: Environment
    private var task: Task<Void, Never>?

    init(environment: Environment = .live()) {
        self.environment = environment
    }

    /// Starts following a paste, and stops following an earlier one.
    func watch(pasted: String, in pid: pid_t, onCorrection: @escaping (Correction) -> Void) {
        task?.cancel()
        let environment = environment
        task = Task { @MainActor in
            @MainActor func readable() async -> String? {
                guard environment.frontmost() == pid, environment.secureInputHolder() != pid else { return nil }
                return await environment.read(pid)
            }
            // The paste lands a moment after Command V.
            try? await environment.sleep(.milliseconds(900))
            guard !Task.isCancelled, let before = await readable(), before.contains(pasted) else { return }
            var latest = before
            var lastChange: Int?
            for reading in 1...Self.readings {
                try? await environment.sleep(.seconds(1))
                guard !Task.isCancelled else { return }
                guard let text = await readable() else { break }
                if text != latest {
                    latest = text
                    lastChange = reading
                } else if let lastChange, reading - lastChange >= Self.quietReadings {
                    break
                }
            }
            guard !Task.isCancelled, let correction = CorrectionFinder.correction(pasted: pasted, before: before, after: latest) else { return }
            onCorrection(correction)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
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
            saveStore: { try? $0.save(to: url) },
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
