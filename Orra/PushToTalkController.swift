import AppKit
import ApplicationServices
import Observation
import os

/// What the recording indicator and the sounds follow. A dictation sends listening,
/// transcribing, recordingStopped and finished, in that order. Listening waits until the
/// hold has lasted a moment and the microphone has started, so a shortcut with the talk
/// key, such as right Control+C, sends nothing. A hands free dictation sends handsFree in
/// place of listening, or after it when a hold turned into one. A hold that ends early
/// skips to finished, which comes only when there is a message to show or an indicator to
/// clear.
nonisolated enum DictationCue: Equatable, Sendable {
    /// The hold has lasted long enough to be a dictation, and the microphone is recording.
    /// `translation` is the direction when the translation key started it, so the
    /// indicator shows that the text will be pasted translated.
    case listening(translation: TranslationDirection?)
    /// A hands free dictation records. The hint says how to finish it, such as "Press
    /// right Control to finish". `translation` as for listening.
    case handsFree(finishHint: String, translation: TranslationDirection? = nil)

    /// A dictation of the talk key is recording.
    static let listening = DictationCue.listening(translation: nil)
    /// The talk key was released after a hold long enough to transcribe.
    case transcribing
    /// The microphone stopped after a hold long enough to transcribe. A recording without
    /// sound or without speech then ends with a message.
    case recordingStopped
    /// The hold is over. The message says why nothing was pasted, when there is a reason.
    case finished(message: String?)
}

/// Connects the talk key, the microphone, the speech model and text insertion, and
/// publishes the state for the menu bar.
///
/// A hold records. The release stops the recording, the speech model turns it into text
/// off the main actor, and the text is pasted into the frontmost app. A quick double press
/// records hands free until the next press of the key, see PushToTalkStateMachine.
///
/// While translation is on, the translation key works the same way, and its dictation is
/// translated after the rule steps, see TranslationStep. Whenever the translation cannot
/// be used, the text is pasted without it, never nothing.
@Observable
final class PushToTalkController {
    nonisolated enum ModelState: Equatable, Sendable {
        case notLoaded
        case loading
        case ready
        /// Why the model is not there to use. The menu and the welcome window show it.
        case unavailable(ModelProblem)
    }

    /// Why the speech model could not be loaded.
    nonisolated enum ModelProblem: Equatable, Sendable {
        case missing
        case failedToLoad

        /// The reason as the menu shows it, in the language of `locale`.
        func message(in locale: Locale = .interface) -> String {
            switch self {
            case .missing: String(localized: LocalizedStringResource("The speech model is not on this Mac", locale: locale))
            case .failedToLoad: String(localized: LocalizedStringResource("The speech model could not be loaded", locale: locale))
            }
        }
    }

    /// The current push to talk state.
    private(set) var state: PushToTalkStateMachine.State = .idle
    /// The key that starts a dictation when held on its own. Saved through `saveTalkKey`
    /// whenever it changes.
    private(set) var talkKey: TalkKey
    /// Whether the user has chosen the talk key, here or in an earlier launch. The welcome
    /// window marks its talk key step as done then.
    private(set) var hasChosenTalkKey: Bool
    /// The key that starts a dictation that is pasted translated, while translation is
    /// on, see `translationKeyIsOn`. Never the talk key. Saved through
    /// `saveTranslationKey` when the user picks it, or when picking the talk key moved it.
    private(set) var translationKey: TalkKey
    /// Whether the translation key is watched: translation is on. AppDelegate keeps it in
    /// step with the Translation switch in Settings.
    private(set) var translationKeyIsOn = false
    /// Whether a quick double press of the talk key, or of the translation key, starts a
    /// hands free dictation. Saved through `saveHandsFree` whenever it changes.
    private(set) var handsFreeOn: Bool
    /// Which key the user records by pressing it, if any.
    private(set) var choosingKeySlot: KeySlot?
    /// True while the user records a talk key by pressing it.
    var isChoosingTalkKey: Bool {
        choosingKeySlot == .talk
    }
    /// Why the last press while recording a key cannot be one, such as Shift.
    private(set) var keyChoiceRejection: KeyRecorder.Rejection?
    /// What the recorder says about that press, in the language Orra started with.
    var keyChoiceNote: String? {
        keyChoiceRejection?.message(for: choosingKeySlot ?? .talk)
    }
    /// Set when the latest key the user picked was the other key's, so the two keys
    /// swapped. Cleared when the user records a key again.
    private(set) var keySwap: KeySwap?
    /// The microphone the user chose in Orra, or nil for the system default input. Saved
    /// through `saveMicrophone` whenever it changes.
    private(set) var microphone: MicrophoneChoice?
    /// The user's words and names with their dates. The speech model gets the most recent
    /// of them with every dictation, see `Vocabulary.forModel(_:)`. Saved through
    /// `saveVocabulary` whenever they change, also when a paste uses one. Never logged.
    private(set) var vocabulary: [VocabularyWord]
    /// Whether fillers such as 呃 and um are removed before the paste, see FillerRules.
    /// Saved through `saveRemovesFillerWords` whenever it changes.
    private(set) var removesFillerWords: Bool
    /// Whether numbers spoken in Chinese, such as 百分之五十, are written as digits before
    /// the paste, see NumberRules. Saved through `saveWritesNumbersAsDigits` whenever it
    /// changes.
    private(set) var writesNumbersAsDigits: Bool
    /// True while the keyboard tap is installed, which needs Accessibility access.
    private(set) var isHotkeyActive = false
    /// Microphone permission as last seen. Refreshed at start, on every hold, and after
    /// a request.
    private(set) var microphoneAccess: MicrophoneAccess = .notDetermined
    /// Whether the speech model can take dictation yet.
    private(set) var modelState: ModelState = .notLoaded
    /// The latest error, shown in the menu until the next hold.
    private(set) var problem: String?
    /// The latest note that is not an error, shown in the menu until the next hold.
    private(set) var notice: String?
    /// What to do about the microphone after the latest hold, or which microphone recorded
    /// because the chosen one was not connected. Kept apart from `notice`, so a paste
    /// notice cannot hide it. Shown in the menu until the next hold.
    private(set) var microphoneNotice: String?
    /// True when Sound settings can help with the latest problem: the system default input
    /// delivered no sound, or the chosen microphone could not start and has to be picked
    /// there. The menu then offers the Sound settings.
    private(set) var suggestsSoundSettings = false
    /// The text of the latest dictation, kept in memory only, so the menu can copy it when
    /// the paste missed. Never logged.
    private(set) var lastTranscript: String?
    /// The latest dictation before the model changed it, so Paste Original Text in the
    /// menu can bring it back: the text before translation when the paste was translated,
    /// and otherwise the text as the rule steps left it, when the cleanup model changed it.
    /// In memory only, never logged.
    private(set) var originalText: String?
    /// Receives the cues for the recording indicator and the sounds. AppDelegate sets it.
    @ObservationIgnored var onCue: (DictationCue) -> Void = { _ in }
    /// Told after each paste, with the text, the app it went into and the text before the
    /// cleanup model changed it, if it did, so Orra can learn from a correction. Never told
    /// about a translated paste, since a fix of a translation is no misheard word.
    /// AppDelegate sets it.
    @ObservationIgnored var onPasted: (_ text: String, _ app: pid_t, _ beforeCleanup: String?) -> Void = { _, _, _ in }
    /// Told when Paste Original Text pastes over a cleaned paste, with the cleaned text, so
    /// learning stops following it.
    @ObservationIgnored var onPasteOriginal: (_ cleaned: String) -> Void = { _ in }

    @ObservationIgnored private let capture: AudioCapture
    @ObservationIgnored private let transcription: Transcription
    @ObservationIgnored private let cleanup: CleanupModel
    @ObservationIgnored private let translation: TranslationModel
    /// The direction of the dictation under way when the translation key started it, read
    /// at its start. Nil for a dictation of the talk key.
    @ObservationIgnored private var holdTranslation: TranslationDirection?
    @ObservationIgnored private let insert: @MainActor (String) async -> InsertionResult
    @ObservationIgnored private let frontmostApp: @MainActor () -> pid_t?
    @ObservationIgnored private let lidIsClosed: @MainActor () -> Bool
    @ObservationIgnored private let isTrusted: @MainActor () -> Bool
    @ObservationIgnored private let installTap: HotkeyTap.Install
    @ObservationIgnored private let maximumRecordingDuration: Duration
    @ObservationIgnored private let minimumHold: Duration
    @ObservationIgnored private let releaseTail: Duration
    @ObservationIgnored private let accessCheckDelay: Duration
    @ObservationIgnored private let listeningCueDelay: Duration
    /// Sends the listening cue once the hold has lasted `listeningCueDelay`.
    @ObservationIgnored private var listeningCueTask: Task<Void, Never>?
    /// Whether the current hold has shown the indicator, so its end has to clear it.
    @ObservationIgnored private var indicatorShown = false
    @ObservationIgnored private var recordingLimitTask: Task<Void, Never>?
    /// Starts the microphone off the main thread. Its value tells whether it started.
    @ObservationIgnored private var captureStart: Task<Bool, Never>?
    /// Stops the microphone after a cancelled hold. The next start waits for it, so a
    /// late cancel cannot stop the recording of a newer hold.
    @ObservationIgnored private var captureCancel: Task<Void, Never>?
    /// Counts the holds that started the microphone, so a late failure of an older start
    /// leaves the current hold alone.
    @ObservationIgnored private var holdNumber = 0
    @ObservationIgnored private var pressedAt: ContinuousClock.Instant?
    /// The microphone chosen when the current hold started.
    @ObservationIgnored private var holdMicrophone: MicrophoneChoice?
    /// Why the current hold ended without a paste, for the indicator, when neither
    /// `problem` nor `notice` says it. The menu shows these states in its own lines.
    @ObservationIgnored private var holdMessage: String?
    /// Held from the start of a recording until its text is pasted or the hold ends.
    /// Orra is a menu bar app without windows, which App Nap may throttle, and someone is
    /// waiting for this work.
    @ObservationIgnored private var userActivity: (any NSObjectProtocol)?
    @ObservationIgnored private var machine = PushToTalkStateMachine()
    @ObservationIgnored private var tap: HotkeyTap?
    @ObservationIgnored private let saveTalkKey: (TalkKey) -> Void
    @ObservationIgnored private let saveTranslationKey: (TalkKey) -> Void
    @ObservationIgnored private let saveHandsFree: (Bool) -> Void
    /// Watches Orra's own key presses while the user chooses a talk key and the tap is not
    /// installed, which needs no permission.
    /// The local event monitors while the user records a talk key.
    @ObservationIgnored private var keyChoiceMonitors: [Any] = []
    /// Ends the recording of a talk key when Orra stops being the active app.
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
    /// Follows the presses while the user records a talk key.
    @ObservationIgnored private var keyRecorder = KeyRecorder()
    @ObservationIgnored private let saveMicrophone: (MicrophoneChoice?) -> Void
    @ObservationIgnored private let saveVocabulary: ([VocabularyWord]) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let saveRemovesFillerWords: (Bool) -> Void
    @ObservationIgnored private let saveWritesNumbersAsDigits: (Bool) -> Void
    @ObservationIgnored private var accessCheckTask: Task<Void, Never>?
    @ObservationIgnored private var accessObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "push-to-talk")

    /// - Parameters:
    ///   - capture: The microphone. The app passes `.live()`, tests pass fakes.
    ///   - transcription: The speech model. Tests pass fakes.
    ///   - cleanup: The cleanup model, which runs after the rule steps when it is ready.
    ///     Tests pass fakes.
    ///   - translation: The model's translations, for dictations of the translation key.
    ///     Tests pass fakes.
    ///   - insert: Puts text into the frontmost app. Tests pass fakes.
    ///   - frontmostApp: The process ID of the frontmost app. Tests pass fakes.
    ///   - lidIsClosed: Whether the MacBook's lid is closed, read when a recording holds
    ///     no sound at all. Tests pass fakes.
    ///   - isTrusted: Whether Orra has Accessibility access. The app asks
    ///     AXIsProcessTrusted, whose answer can be stale, see `watchAccess()`. Tests pass
    ///     fakes.
    ///   - installTap: Creates the keyboard tap, see `HotkeyTap.Install`. Tests pass fakes,
    ///     so they never install a real tap.
    ///   - maximumRecordingDuration: A hold longer than this is processed as if the key
    ///     had been released.
    ///   - minimumHold: Holds shorter than this are discarded.
    ///   - releaseTail: How long recording goes on after the talk key is released.
    ///   - accessCheckDelay: How long Orra waits before it checks access again, see
    ///     `watchAccess()`.
    ///   - listeningCueDelay: How long a hold lasts before the indicator shows and the
    ///     start sound plays. A shortcut with the talk key is over sooner.
    ///   - talkKey: The key that starts a dictation, as saved by the user.
    ///   - saveTalkKey: Saves the key after the user changes it.
    ///   - talkKeyChosen: Whether the user has saved a talk key before.
    ///   - translationKey: The translation key, as saved, or nil for the default next to
    ///     the talk key, see `TalkKey.defaultTranslationKey(talkKey:)`.
    ///   - saveTranslationKey: Saves the translation key after it changes.
    ///   - handsFree: Whether a double press starts a hands free dictation, as saved.
    ///   - saveHandsFree: Saves the choice after the user changes it.
    ///   - microphone: The microphone the user chose, or nil for the system default.
    ///   - saveMicrophone: Saves the choice after the user changes it.
    ///   - vocabulary: The user's words and names, as saved.
    ///   - saveVocabulary: Saves the words after they change.
    ///   - removesFillerWords: Whether fillers are removed, as saved.
    ///   - saveRemovesFillerWords: Saves the choice after the user changes it.
    ///   - writesNumbersAsDigits: Whether spoken numbers become digits, as saved.
    ///   - saveWritesNumbersAsDigits: Saves the choice after the user changes it.
    ///   - now: The time, for the dates of the vocabulary. Tests pass fakes.
    init(
        capture: AudioCapture,
        transcription: Transcription,
        cleanup: CleanupModel = .off,
        translation: TranslationModel = .off,
        insert: @escaping @MainActor (String) async -> InsertionResult,
        frontmostApp: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        lidIsClosed: @escaping @MainActor () -> Bool = { Lid.isClosed() },
        isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        installTap: @escaping HotkeyTap.Install = HotkeyTap.installLive,
        maximumRecordingDuration: Duration = RecordingLimits.maximumDuration,
        minimumHold: Duration = RecordingLimits.minimumHold,
        releaseTail: Duration = RecordingLimits.releaseTail,
        accessCheckDelay: Duration = .seconds(2),
        listeningCueDelay: Duration = .milliseconds(150),
        talkKey: TalkKey = TalkKey.defaultKey,
        saveTalkKey: @escaping (TalkKey) -> Void = { _ in },
        talkKeyChosen: Bool = false,
        translationKey: TalkKey? = nil,
        saveTranslationKey: @escaping (TalkKey) -> Void = { _ in },
        handsFree: Bool = true,
        saveHandsFree: @escaping (Bool) -> Void = { _ in },
        microphone: MicrophoneChoice? = nil,
        saveMicrophone: @escaping (MicrophoneChoice?) -> Void = { _ in },
        vocabulary: [VocabularyWord] = [],
        saveVocabulary: @escaping ([VocabularyWord]) -> Void = { _ in },
        removesFillerWords: Bool = true,
        saveRemovesFillerWords: @escaping (Bool) -> Void = { _ in },
        writesNumbersAsDigits: Bool = true,
        saveWritesNumbersAsDigits: @escaping (Bool) -> Void = { _ in },
        now: @escaping () -> Date = { Date() }
    ) {
        self.capture = capture
        self.transcription = transcription
        self.cleanup = cleanup
        self.translation = translation
        self.insert = insert
        self.frontmostApp = frontmostApp
        self.lidIsClosed = lidIsClosed
        self.isTrusted = isTrusted
        self.installTap = installTap
        self.maximumRecordingDuration = maximumRecordingDuration
        self.minimumHold = minimumHold
        self.releaseTail = releaseTail
        self.accessCheckDelay = accessCheckDelay
        self.listeningCueDelay = listeningCueDelay
        self.talkKey = talkKey
        self.saveTalkKey = saveTalkKey
        self.hasChosenTalkKey = talkKeyChosen
        self.translationKey = translationKey.flatMap { $0 == talkKey ? nil : $0 } ?? TalkKey.defaultTranslationKey(talkKey: talkKey)
        self.saveTranslationKey = saveTranslationKey
        self.handsFreeOn = handsFree
        self.saveHandsFree = saveHandsFree
        self.microphone = microphone
        self.saveMicrophone = saveMicrophone
        self.vocabulary = vocabulary
        self.saveVocabulary = saveVocabulary
        self.removesFillerWords = removesFillerWords
        self.saveRemovesFillerWords = saveRemovesFillerWords
        self.writesNumbersAsDigits = writesNumbersAsDigits
        self.saveWritesNumbersAsDigits = saveWritesNumbersAsDigits
        self.now = now
    }

    /// Starts watching for the hotkey. Without Accessibility access it waits: the welcome
    /// window and the menu offer the system prompt, and the tap is installed once access
    /// is granted. The speech model loads once ModelInstaller has it in place, see
    /// AppDelegate.
    func start() {
        guard tap == nil else { return }
        microphoneAccess = capture.access()
        tap = HotkeyTap(keys: watchedKeys, delayedKeys: delayedKeys, handsFree: handsFreeOn, install: installTap) { [weak self] event in
            self?.handle(event, key: self?.tap?.activeKey)
        } onSwitchedOff: { [weak self] reason in
            self?.tapWasSwitchedOff(reason)
        }
        syncTapWithAccess()
        if !isHotkeyActive {
            logger.info("Waiting for Accessibility access")
        }
        watchAccess()
    }

    /// Loads the speech model, and again after a failed load, for example once the model
    /// files are in place again. Does nothing while loading or once loaded. ModelInstaller
    /// calls it through AppDelegate whenever the model is installed. Internal so tests can
    /// drive it.
    func loadModel() async {
        switch modelState {
        case .loading, .ready:
            return
        case .notLoaded, .unavailable:
            break
        }
        modelState = .loading
        let started = ContinuousClock.now
        do {
            try await transcription.load()
            modelState = .ready
            logger.info("Speech model loaded in \(started.duration(to: .now), privacy: .public)")
        } catch TranscriptionError.modelMissing {
            modelState = .unavailable(.missing)
        } catch {
            modelState = .unavailable(.failedToLoad)
            logger.error("Speech model failed to load: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replaces the vocabulary for the next dictations and saves it.
    func setVocabulary(_ words: [VocabularyWord]) {
        guard words != vocabulary else { return }
        vocabulary = words
        saveVocabulary(words)
    }

    /// Adds a word, typed, copied or learned, dated now. Refused only at the sanity cap,
    /// `Vocabulary.maximumCount`. An empty word adds nothing and counts as already there.
    @discardableResult
    func addToVocabulary(_ term: String, source: VocabularyWord.Source = .user) -> VocabularyAddition {
        guard let word = Vocabulary.cleaned(term), !Vocabulary.contains(word, in: vocabulary) else {
            return .alreadyThere
        }
        guard vocabulary.count < Vocabulary.maximumCount else { return .full }
        setVocabulary(Vocabulary.adding(word, to: vocabulary, at: now(), source: source))
        return .added
    }

    /// Takes the words out of the vocabulary, ignoring case.
    func removeFromVocabulary(_ terms: some Sequence<String>) {
        setVocabulary(Vocabulary.removing(terms, from: vocabulary))
    }

    /// Whether the vocabulary holds the word, ignoring case.
    func vocabularyContains(_ term: String) -> Bool {
        Vocabulary.contains(term, in: vocabulary)
    }

    /// Dates the last use of the words a pasted transcript holds. Keeps no text.
    private func markVocabularyUsed(in text: String) {
        guard !vocabulary.isEmpty else { return }
        setVocabulary(Vocabulary.markingUsed(in: text, vocabulary, at: now()))
    }

    /// Turns filler removal on or off for the next dictations and saves the choice.
    func setRemovesFillerWords(_ on: Bool) {
        guard on != removesFillerWords else { return }
        removesFillerWords = on
        saveRemovesFillerWords(on)
    }

    /// Turns writing spoken numbers as digits on or off for the next dictations and saves
    /// the choice.
    func setWritesNumbersAsDigits(_ on: Bool) {
        guard on != writesNumbersAsDigits else { return }
        writesNumbersAsDigits = on
        saveWritesNumbersAsDigits(on)
    }

    /// Chooses the microphone for the next dictations, or the system default for nil, and
    /// saves the choice.
    func setMicrophone(_ choice: MicrophoneChoice?) {
        guard choice != microphone else { return }
        microphone = choice
        saveMicrophone(choice)
    }

    /// Makes `key` the talk key and saves the choice. Saved even when it is the key in use
    /// already, such as the default, so the welcome window counts the step as done on the
    /// next launch too. When `key` is the translation key, the translation key becomes the
    /// old talk key and `keySwap` says so.
    func chooseTalkKey(_ key: TalkKey) {
        hasChosenTalkKey = true
        keySwap = nil
        if key == translationKey, key != talkKey {
            translationKey = talkKey
            saveTranslationKey(talkKey)
            keySwap = KeySwap(talkKey: key, translationKey: translationKey)
        }
        talkKey = key
        saveTalkKey(key)
        updateTapKeys()
    }

    /// Makes `key` the translation key and saves the choice. When `key` is the talk key,
    /// the talk key becomes the old translation key and `keySwap` says so.
    func chooseTranslationKey(_ key: TalkKey) {
        keySwap = nil
        if key == talkKey, key != translationKey {
            talkKey = translationKey
            hasChosenTalkKey = true
            saveTalkKey(talkKey)
            keySwap = KeySwap(talkKey: talkKey, translationKey: key)
        }
        translationKey = key
        saveTranslationKey(key)
        updateTapKeys()
    }

    /// Starts or stops watching the translation key, when translation is turned on or off.
    /// Turning it off ends a dictation the translation key started, as a change of keys
    /// does.
    func setTranslationKeyOn(_ on: Bool) {
        guard on != translationKeyIsOn else { return }
        translationKeyIsOn = on
        updateTapKeys()
    }

    /// The keys the tap watches: the talk key, and the translation key while translation
    /// is on.
    private var watchedKeys: Set<TalkKey> {
        translationKeyIsOn ? [talkKey, translationKey] : [talkKey]
    }

    /// The translation key waits before it records, as a left hand key does, so Option
    /// shortcuts and the characters right Option types keep working. The talk key does
    /// not.
    private var delayedKeys: Set<TalkKey> {
        translationKeyIsOn ? [translationKey] : []
    }

    private func updateTapKeys() {
        tap?.setKeys(watchedKeys, delayedKeys: delayedKeys)
    }

    /// Turns double press for hands free on or off and saves the choice.
    func setHandsFreeOn(_ on: Bool) {
        guard on != handsFreeOn else { return }
        handsFreeOn = on
        saveHandsFree(on)
        tap?.setHandsFree(on)
    }

    /// Starts recording the key the user wants as the talk key, see `startChoosingKey`.
    func startChoosingTalkKey() {
        startChoosingKey(for: .talk)
    }

    /// Starts recording the key the user wants for `slot`, see KeyRecorder. A key that can
    /// be a talk key, pressed and released on its own, becomes the key. Anything else
    /// leaves a note and the recording goes on. Escape, a click anywhere in Orra, or
    /// switching to another app stops it. Only presses in Orra count: the tap checks that
    /// Orra is the active app, and without the tap a local monitor sees only Orra's own
    /// events. Neither needs a new permission. A recording for the other slot stops first.
    func startChoosingKey(for slot: KeySlot) {
        guard choosingKeySlot != slot else { return }
        stopChoosingKey()
        choosingKeySlot = slot
        keyChoiceRejection = nil
        keySwap = nil
        keyRecorder = KeyRecorder()
        tap?.chooseKey { [weak self] type, keyCode, flags in
            self?.keyChoice(type: type, keyCode: keyCode, flags: flags)
        }
        keyChoiceMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                // The tap has seen the event first when it is installed.
                guard let self, choosingKeySlot != nil, tap?.isInstalled != true else { return event }
                let flags = event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                let type: CGEventType = event.type == .keyDown ? .keyDown : .flagsChanged
                keyChoice(type: type, keyCode: Int64(event.keyCode), flags: flags)
                // As the tap does: a key pressed to record types nothing, and Escape does
                // not close the window.
                return type == .keyDown ? nil : event
            },
            // A click anywhere in Orra ends the recording, as in the shortcut recorders of
            // Mac apps. The click itself goes on to what was clicked.
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.stopChoosingKey()
                return event
            },
        ].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopChoosingKey()
            }
        }
    }

    /// Stops recording a key without changing it.
    func stopChoosingKey() {
        guard choosingKeySlot != nil else { return }
        choosingKeySlot = nil
        keyChoiceRejection = nil
        tap?.chooseKey(nil)
        keyChoiceMonitors.forEach(NSEvent.removeMonitor)
        keyChoiceMonitors = []
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
    }

    /// One key down or flags changed event while the user records a key. Internal so tests
    /// can drive it.
    func keyChoice(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        guard let slot = choosingKeySlot else { return }
        guard let outcome = keyRecorder.handle(type: type, keyCode: keyCode, flags: flags) else {
            // A key that can be the talk key is down, so the note about an earlier press
            // no longer applies.
            if keyRecorder.candidate != nil {
                keyChoiceRejection = nil
            }
            return
        }
        switch outcome {
        case .chosen(let key):
            stopChoosingKey()
            switch slot {
            case .talk: chooseTalkKey(key)
            case .translation: chooseTranslationKey(key)
            }
        case .rejected(let rejection):
            keyChoiceRejection = rejection
        case .cancelled:
            stopChoosingKey()
        }
    }

    /// The key that finishes the hands free dictation in progress, for the indicator: the
    /// key that started it, or the talk key.
    private var handsFreeKey: TalkKey {
        tap?.activeKey ?? talkKey
    }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility.
    func promptForAccessibility() {
        // The key is the value of kAXTrustedCheckOptionPrompt. Swift 6 rejects
        // reading that C global because it is imported as a mutable variable,
        // so the string is spelled out. Its value was checked on macOS 26.6.2.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Asks for microphone access when the user has not decided yet, or opens the
    /// microphone pane of System Settings when access is off.
    func requestMicrophoneAccess() {
        switch capture.access() {
        case .notDetermined:
            Task { [weak self] in
                guard let self else { return }
                microphoneAccess = await capture.requestAccess()
            }
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .authorized, .notConfigured:
            microphoneAccess = capture.access()
        }
    }

    /// Applies one push to talk event. `key` is the key the event is about, which tells a
    /// dictation of the translation key from one of the talk key. Internal so tests can
    /// drive it.
    func handle(_ event: PushToTalkStateMachine.Event, key: TalkKey? = nil) {
        // The tap keeps Escape and the next press for a hands free dictation only while one
        // runs. It may have ended here some other way, or never started.
        defer {
            if machine.state != .handsFree {
                tap?.endHandsFree()
            }
        }
        guard let transition = machine.handle(event) else { return }
        state = machine.state
        logger.debug("Push to talk transition: \(String(describing: transition), privacy: .public)")
        switch transition {
        case .startedListening, .startedHandsFree, .resumedListening:
            // The direction is read once, so the indicator and the paste agree.
            holdTranslation = translationKeyIsOn && key == translationKey ? translation.direction() : nil
        default:
            break
        }
        switch transition {
        case .startedListening, .startedHandsFree:
            problem = nil
            notice = nil
            microphoneNotice = nil
            suggestsSoundSettings = false
            holdMessage = nil
            indicatorShown = false
            // The previous hold's start belongs to that hold only.
            captureStart = nil
            guard modelState == .ready else {
                // The menu bar icon and the menu say why too.
                holdMessage = Self.notReadyMessage(modelState)
                handle(.cancelled)
                return
            }
            startRecording(cueDelay: transition == .startedHandsFree ? .zero : listeningCueDelay)
        case .awaitingSecondPress:
            // The recording goes on until the second press or the end of the window.
            break
        case .resumedListening:
            // The second press after a tap. The recording goes on. If the press turns out
            // to be a hold, its cue comes like any hold's. A double press replaces it with
            // the hands free cue at the release.
            listeningCueTask?.cancel()
            scheduleListeningCue(after: listeningCueDelay, hold: holdNumber)
        case .switchedToHandsFree:
            listeningCueTask?.cancel()
            scheduleListeningCue(after: .zero, hold: holdNumber)
        case .startedProcessing:
            recordingLimitTask?.cancel()
            listeningCueTask?.cancel()
            let released = ContinuousClock.now
            let heldFor = pressedAt.map { $0.duration(to: released) } ?? .zero
            if heldFor >= minimumHold {
                indicatorShown = true
                onCue(.transcribing)
            } else {
                // Cleared at once, because a slow microphone can take seconds to stop.
                endCue(nil)
            }
            let target = frontmostApp()
            let start = captureStart
            let chosen = holdMicrophone
            let translating = holdTranslation
            Task { [weak self] in
                await self?.finishRecording(start: start, chosen: chosen, heldFor: heldFor, target: target, translating: translating, releasedAt: released)
                self?.handle(.processingFinished)
            }
        case .cancelledListening:
            recordingLimitTask?.cancel()
            listeningCueTask?.cancel()
            endUserActivity()
            let start = captureStart
            captureCancel = Task { [capture] in
                if await start?.value == true {
                    await capture.cancel()
                }
            }
            endCue(holdMessage ?? problem)
        case .finished:
            endUserActivity()
            endCue(holdMessage ?? problem ?? notice)
        }
    }

    /// Ends the hold for the indicator: shows the message when there is one, and otherwise
    /// clears the indicator if this hold showed it. A hold that showed nothing, such as a
    /// shortcut, leaves an earlier message alone.
    private func endCue(_ message: String?) {
        if let message {
            onCue(.finished(message: message))
        } else if indicatorShown {
            onCue(.finished(message: nil))
        }
        indicatorShown = false
    }

    /// The peak of the latest audio while recording, from 0 to 1, for the indicator.
    func inputLevel() -> Float {
        capture.level()
    }

    /// Reads microphone permission again, for the welcome window while the user may be
    /// changing it in System Settings. Reading never shows a prompt.
    func refreshMicrophoneAccess() {
        let access = capture.access()
        if access != microphoneAccess {
            microphoneAccess = access
        }
    }

    /// Why a hold cannot record while the speech model is not ready.
    private static func notReadyMessage(_ state: ModelState) -> String {
        switch state {
        case .notLoaded, .ready:
            String(localized: "The speech model is not ready. The Orra menu shows what is missing.")
        case .loading:
            String(localized: "The speech model is still loading")
        case .unavailable(let problem):
            problem.message()
        }
    }

    /// True while Orra tells macOS that a dictation is in progress. Internal for tests.
    var isKeepingDictationAwake: Bool {
        userActivity != nil
    }

    private func beginUserActivity() {
        guard userActivity == nil else { return }
        userActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Recording and transcribing a dictation")
    }

    private func endUserActivity() {
        if let userActivity {
            ProcessInfo.processInfo.endActivity(userActivity)
        }
        userActivity = nil
    }

    /// Starts the microphone for a hold, or ends the hold when that is not possible.
    /// The first hold asks for microphone access and is cancelled, because the prompt
    /// takes the focus while the talk key is still down.
    private func startRecording(cueDelay: Duration) {
        microphoneAccess = capture.access()
        switch microphoneAccess {
        case .authorized:
            pressedAt = .now
            beginUserActivity()
            holdNumber += 1
            let hold = holdNumber
            let previousCancel = captureCancel
            let chosen = microphone
            holdMicrophone = chosen
            // The hardware starts off the main thread, so the key event is answered at once.
            // A cancelled hold may still be stopping the microphone, so that goes first.
            captureStart = Task { [weak self, capture] in
                await previousCancel?.value
                do {
                    try await capture.start(chosen?.uid)
                    return true
                } catch {
                    self?.recordingFailedToStart(error, hold: hold, chosen: chosen)
                    return false
                }
            }
            recordingLimitTask = Task { [weak self, maximumRecordingDuration] in
                try? await Task.sleep(for: maximumRecordingDuration)
                guard !Task.isCancelled, let self, state == .listening || state == .handsFree else { return }
                logger.info("Recording reached its maximum length")
                // The audio buffer holds no more, so the dictation ends here and says why.
                notice = String(localized: "Orra records up to 1 minute at a time, so the recording stopped there.")
                handle(.released)
            }
            scheduleListeningCue(after: cueDelay, hold: hold)
        case .notDetermined:
            // The system prompt that follows says enough.
            handle(.cancelled)
            requestMicrophoneAccess()
        case .denied:
            holdMessage = String(localized: "Microphone access is off")
            handle(.cancelled)
        case .notConfigured:
            holdMessage = String(localized: "This build has no microphone usage description")
            handle(.cancelled)
        }
    }

    /// Sends the listening cue, or the hands free cue, once `delay` has passed and the
    /// microphone has started, if the hold is still the current one and still records.
    private func scheduleListeningCue(after delay: Duration, hold: Int) {
        let started = captureStart
        listeningCueTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            // The cue also waits for the microphone, which can take 0.3 s for a USB
            // microphone, so whoever starts talking at the sound is recorded from the
            // first syllable. A microphone that fails to start sends no cue.
            guard await started?.value == true else { return }
            guard !Task.isCancelled, let self, holdNumber == hold else { return }
            switch state {
            case .listening:
                indicatorShown = true
                onCue(.listening(translation: holdTranslation))
            case .handsFree:
                indicatorShown = true
                onCue(.handsFree(finishHint: handsFreeKey.finishHint(), translation: holdTranslation))
            case .idle, .waitingForSecondPress, .processing:
                break
            }
        }
    }

    private func recordingFailedToStart(_ error: any Error, hold: Int, chosen: MicrophoneChoice?) {
        logger.error("Could not start recording: \(String(describing: error), privacy: .public)")
        // A newer hold has started since. This one was cancelled and nobody waits for it.
        guard hold == holdNumber else { return }
        if case AudioRecorderError.inputUnitFailed = error, let chosen {
            problem = String(localized: "\(chosen.name) could not start")
            // System Default records another way, so it is the way out. With the lid
            // closed the default can be the internal microphone, so the device has to be
            // picked in Sound settings too.
            microphoneNotice = String(localized: "Choose System Default under Microphone, then pick \(chosen.name) in Sound settings.")
            suggestsSoundSettings = true
        } else {
            problem = String(localized: "The microphone could not start")
        }
        if machine.isRecording {
            handle(.cancelled)
        }
    }

    /// Ends a hold that was released: waits for the microphone to have started, records
    /// the short tail, stops, and transcribes unless the hold was too short or cut.
    /// `translating` is the direction when the translation key started the dictation.
    private func finishRecording(start: Task<Bool, Never>?, chosen: MicrophoneChoice?, heldFor: Duration, target: pid_t?, translating: TranslationDirection?, releasedAt released: ContinuousClock.Instant) async {
        // A failed start already set the problem.
        guard await start?.value == true else { return }
        if releaseTail > .zero {
            try? await Task.sleep(for: releaseTail)
        }
        let recording = await capture.stop()
        if recording.wasCut {
            problem = String(localized: "The microphone changed during the recording. Try again.")
            return
        }
        guard heldFor >= minimumHold else {
            logger.debug("Hold too short, recording discarded")
            return
        }
        onCue(.recordingStopped)
        if let chosen, recording.input?.uid != chosen.uid {
            // The chosen microphone was not connected, so the system default recorded.
            if let name = recording.input?.name {
                microphoneNotice = String(localized: "\(chosen.name) is not connected, so \(name) recorded.")
            } else {
                microphoneNotice = String(localized: "\(chosen.name) is not connected, so the system default input recorded.")
            }
        }
        await transcribeAndInsert(recording, chosen: chosen, target: target, translating: translating, releasedAt: released)
    }

    /// Turns a recording into text and pastes it, translated when `translating` is set and
    /// the translation passes its checks. Logs timings, never the text.
    private func transcribeAndInsert(_ recording: AudioRecording, chosen: MicrophoneChoice?, target: pid_t?, translating: TranslationDirection?, releasedAt released: ContinuousClock.Instant) async {
        do {
            let (samples, silent) = await Self.prepared(recording)
            guard !samples.isEmpty else {
                problem = String(localized: "The recording could not be transcribed")
                logger.error("No samples after resampling \(recording.samples.count, privacy: .public) recorded samples")
                return
            }
            if silent {
                // The microphone delivered zeros, so there is nothing to transcribe. Say why
                // instead of doing nothing.
                let situation = MicrophoneSituation(lidClosed: lidIsClosed(), input: recording.input)
                problem = Silence.advice(for: situation)
                if let chosen, recording.input?.uid == chosen.uid {
                    // The chosen microphone records whatever input Sound settings names, so
                    // the way out is Orra's own choice.
                    microphoneNotice = String(localized: "\(chosen.name) is chosen under Microphone. Choose another microphone or System Default there.")
                } else {
                    suggestsSoundSettings = true
                }
                logger.notice("The microphone delivered no sound for \(recording.duration, privacy: .public) s, lid closed: \(situation.lidClosed, privacy: .public)")
                return
            }
            let raw = try await transcription.transcribe(samples, vocabulary: Vocabulary.forModel(vocabulary), audioSeconds: recording.duration)
            var text = ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: recording.duration))
            if removesFillerWords {
                text = FillerRules.removingFillers(from: text)
            }
            if writesNumbersAsDigits {
                text = NumberRules.writingNumbersAsDigits(in: text)
            }
            guard !text.isEmpty else {
                holdMessage = String(localized: "No speech was recognized")
                logger.notice("No speech recognized in \(recording.duration, privacy: .public) s of audio")
                return
            }
            // The rule steps come first, so the model sees their result, and any problem
            // with the model leaves exactly that text.
            let ruled = text
            let translated = await translate(text, translating)
            if let translated {
                // In place of the cleanup step, since the translation prompt cleans up too.
                text = translated.text
            } else if cleanup.isReady(), CleanupStep.isWorthCleaning(text) {
                text = await CleanupStep.run(text, complete: cleanup.complete).text
            }
            let isTranslation = translated?.isTranslation == true
            if isTranslation {
                originalText = translated?.untranslated
            } else {
                originalText = text == ruled ? nil : ruled
            }
            lastTranscript = text
            // Paste only into the app that was in front when the key was released.
            if let target, let current = frontmostApp(), current != target {
                notice = String(localized: "Another app came to the front, so the text was not pasted. Use Copy Last Dictation.")
                return
            }
            switch await insert(text) {
            case .pasted:
                // Notice rather than info, so the timing stays in the log store for later
                // checks. Numbers only.
                logger.notice("Release to paste took \(released.duration(to: .now), privacy: .public) for \(recording.duration, privacy: .public) s of audio")
                // The words are in the text before translation.
                markVocabularyUsed(in: isTranslation ? originalText ?? text : text)
                // Orra never learns from a translated paste: a fix of the translation is no
                // misheard word.
                if !isTranslation, let app = target ?? frontmostApp() {
                    onPasted(text, app, originalText)
                }
            case .skippedPasswordField:
                notice = String(localized: "Orra does not paste into password fields. Use Copy Last Dictation.")
            case .nothingToInsert:
                break
            }
        } catch {
            problem = String(localized: "The recording could not be transcribed")
            logger.error("Transcription failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Paste Original Text in the menu: pastes the latest dictation as it was before the
    /// model translated it or cleaned it up, into the frontmost app. Orra does not learn
    /// from this paste, and Copy Last Dictation still copies what was pasted first.
    func pasteOriginal() async {
        guard state == .idle, let originalText else { return }
        if let lastTranscript {
            onPasteOriginal(lastTranscript)
        }
        switch await insert(originalText) {
        case .pasted, .nothingToInsert:
            break
        case .skippedPasswordField:
            notice = String(localized: "Orra does not paste into password fields. Use Copy Last Dictation.")
        }
    }

    /// The translation of a dictation of the translation key, or nil when the translation
    /// step did not run: not a dictation of the translation key, the model not ready, the
    /// text too long, or nothing in it to translate, such as digits only. The step's result
    /// holds the text without translation whenever the translation cannot be used. Every
    /// case that pastes the text untranslated, other than one with nothing to translate or
    /// already in the target language, leaves a notice that says so.
    private func translate(_ text: String, _ direction: TranslationDirection?) async -> TranslationStep.Result? {
        guard let direction else { return nil }
        guard translation.isReady() else {
            notice = String(localized: "The local model is not ready, so the text was pasted without translation.")
            return nil
        }
        guard let target = direction.target(for: text) else { return nil }
        guard text.count <= TranslationStep.maximumLength else {
            notice = String(localized: "Dictations over \(TranslationStep.maximumLength) characters are pasted without translation.")
            return nil
        }
        let result = await TranslationStep.run(text, into: target, cleansUp: cleanup.isReady(), complete: translation.complete)
        switch result.outcome {
        case .translated, .unchanged:
            break
        case .unreadable, .heldBack, .timedOut, .failed:
            notice = String(localized: "This dictation was pasted without translation.")
        }
        return result
    }

    /// Resampling and the silence check run off the main actor, because a long recording
    /// takes a moment.
    @concurrent
    nonisolated private static func prepared(_ recording: AudioRecording) async -> (samples: [Float], silent: Bool) {
        let samples = AudioResampler.monoAt16kHz(recording)
        return (samples, Silence.isSilent(samples))
    }

    /// Opens System Settings at Sound, where the user picks the input device.
    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Installs the tap when access is granted and removes it when access is
    /// gone.
    private func syncTapWithAccess() {
        guard let tap else { return }
        let trusted = isTrusted()
        if trusted, !tap.isInstalled {
            if tap.start() {
                logger.info("Hotkey active")
            } else {
                // AXIsProcessTrusted may still say yes after access is gone.
                logger.notice("The system refused the keyboard tap")
            }
        } else if !trusted, tap.isInstalled {
            tap.stop()
            logger.info("Accessibility access is gone, keyboard tap removed")
        }
        publishTapState()
    }

    /// Tells the menu and the icon whether the tap is installed.
    private func publishTapState() {
        let installed = tap?.isInstalled ?? false
        if isHotkeyActive != installed {
            isHotkeyActive = installed
        }
    }

    /// The system switched the keyboard tap off, and the tap removed itself, see
    /// `HotkeyTap.handle(type:keyCode:flags:)`. The menu shows the talk key as off at
    /// once. After the same pause as after an access change, `syncTapWithAccess` installs
    /// a new tap, which the system refuses without access, even while AXIsProcessTrusted
    /// still says yes.
    private func tapWasSwitchedOff(_ reason: CGEventType) {
        let why = reason == .tapDisabledByTimeout ? "a timeout" : "user input"
        logger.notice("The system switched the keyboard tap off after \(why, privacy: .public), tap removed")
        publishTapState()
        scheduleAccessCheck()
    }

    /// Checks access again two seconds after the system reports a change to the
    /// Accessibility list.
    ///
    /// AXIsProcessTrusted answers from a cache inside Orra that only this
    /// notification clears, and System Settings posts the notification before
    /// it writes the change. That was read from the macOS 26.6 binaries and is
    /// not documented. Reading access right away, or polling, could therefore
    /// cache the old answer until the next change. For the same reason the tap
    /// does not ask when the system switches it off. Removing Orra from the list
    /// may not post the notification at all, so Orra may not notice it.
    private func watchAccess() {
        accessObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleAccessCheck()
            }
        }
    }

    private func scheduleAccessCheck() {
        accessCheckTask?.cancel()
        accessCheckTask = Task { [weak self, accessCheckDelay] in
            try? await Task.sleep(for: accessCheckDelay)
            guard !Task.isCancelled else { return }
            self?.syncTapWithAccess()
        }
    }
}
