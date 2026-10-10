import AppKit
import ApplicationServices
import Observation
import os

/// What the recording indicator and the sounds follow. A dictation sends listening,
/// transcribing, recordingStopped and finished, in that order. Listening waits until the
/// hold has lasted a moment and the microphone has started, so a shortcut with the talk
/// key, such as right Control+C, sends nothing. A hold that ends early skips to finished, which comes only when there is
/// a message to show or an indicator to clear.
nonisolated enum DictationCue: Equatable, Sendable {
    /// The hold has lasted long enough to be a dictation, and the microphone is recording.
    case listening
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
/// off the main actor, and the text is pasted into the frontmost app.
@Observable
final class PushToTalkController {
    nonisolated enum ModelState: Equatable, Sendable {
        case notLoaded
        case loading
        case ready
        /// The reason, as shown in the menu.
        case unavailable(String)
    }

    /// The current push to talk state.
    private(set) var state: PushToTalkStateMachine.State = .idle
    /// The keys that start a dictation when held on their own. Saved through
    /// `saveTalkKeys` whenever they change.
    private(set) var talkKeys: Set<TalkKey>
    /// The microphone the user chose in Orra, or nil for the system default input. Saved
    /// through `saveMicrophone` whenever it changes.
    private(set) var microphone: MicrophoneChoice?
    /// The user's words and names, which the speech model gets with every dictation. Saved
    /// through `saveVocabulary` whenever they change. Never logged.
    private(set) var vocabulary: [String]
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
    /// Receives the cues for the recording indicator and the sounds. AppDelegate sets it.
    @ObservationIgnored var onCue: (DictationCue) -> Void = { _ in }
    /// Told after each paste, with the text and the app it went into, so Orra can learn
    /// from a correction. AppDelegate sets it.
    @ObservationIgnored var onPasted: (_ text: String, _ app: pid_t) -> Void = { _, _ in }

    @ObservationIgnored private let capture: AudioCapture
    @ObservationIgnored private let transcription: Transcription
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
    @ObservationIgnored private let saveTalkKeys: (Set<TalkKey>) -> Void
    @ObservationIgnored private let saveMicrophone: (MicrophoneChoice?) -> Void
    @ObservationIgnored private let saveVocabulary: ([String]) -> Void
    @ObservationIgnored private var accessCheckTask: Task<Void, Never>?
    @ObservationIgnored private var accessObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "push-to-talk")

    /// - Parameters:
    ///   - capture: The microphone. The app passes `.live()`, tests pass fakes.
    ///   - transcription: The speech model. Tests pass fakes.
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
    ///   - talkKeys: The keys that start a dictation, as saved by the user.
    ///   - saveTalkKeys: Saves the keys after the user changes them.
    ///   - microphone: The microphone the user chose, or nil for the system default.
    ///   - saveMicrophone: Saves the choice after the user changes it.
    init(
        capture: AudioCapture,
        transcription: Transcription,
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
        talkKeys: Set<TalkKey> = TalkKey.defaultKeys,
        saveTalkKeys: @escaping (Set<TalkKey>) -> Void = { _ in },
        microphone: MicrophoneChoice? = nil,
        saveMicrophone: @escaping (MicrophoneChoice?) -> Void = { _ in },
        vocabulary: [String] = [],
        saveVocabulary: @escaping ([String]) -> Void = { _ in }
    ) {
        self.capture = capture
        self.transcription = transcription
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
        self.talkKeys = talkKeys.isEmpty ? TalkKey.defaultKeys : talkKeys
        self.saveTalkKeys = saveTalkKeys
        self.microphone = microphone
        self.saveMicrophone = saveMicrophone
        self.vocabulary = vocabulary
        self.saveVocabulary = saveVocabulary
    }

    /// Starts watching for the hotkey. Without Accessibility access it waits: the welcome
    /// window and the menu offer the system prompt, and the tap is installed once access
    /// is granted. The speech model loads once ModelInstaller has it in place, see
    /// AppDelegate.
    func start() {
        guard tap == nil else { return }
        microphoneAccess = capture.access()
        tap = HotkeyTap(keys: talkKeys, install: installTap) { [weak self] event in
            self?.handle(event)
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
            modelState = .unavailable(String(localized: "The speech model is not on this Mac"))
        } catch {
            modelState = .unavailable(String(localized: "The speech model could not be loaded"))
            logger.error("Speech model failed to load: \(String(describing: error), privacy: .public)")
        }
    }

    /// Chooses the microphone for the next dictations, or the system default for nil, and
    /// saves the choice.
    /// Replaces the vocabulary for the next dictations and saves it.
    func setVocabulary(_ terms: [String]) {
        guard terms != vocabulary else { return }
        vocabulary = terms
        saveVocabulary(terms)
    }

    func setMicrophone(_ choice: MicrophoneChoice?) {
        guard choice != microphone else { return }
        microphone = choice
        saveMicrophone(choice)
    }

    /// Turns a talk key on or off and saves the choice. The last key stays on, so
    /// dictation cannot be switched off by accident.
    func setTalkKey(_ key: TalkKey, on: Bool) {
        var keys = talkKeys
        if on {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
        guard !keys.isEmpty, keys != talkKeys else { return }
        talkKeys = keys
        saveTalkKeys(keys)
        tap?.setKeys(keys)
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

    /// Applies one push to talk event. Internal so tests can drive it.
    func handle(_ event: PushToTalkStateMachine.Event) {
        guard let transition = machine.handle(event) else { return }
        state = machine.state
        logger.debug("Push to talk transition: \(String(describing: transition), privacy: .public)")
        switch transition {
        case .startedListening:
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
            startRecording()
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
            Task { [weak self] in
                await self?.finishRecording(start: start, chosen: chosen, heldFor: heldFor, target: target, releasedAt: released)
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
        case .unavailable(let reason):
            reason
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
    private func startRecording() {
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
                guard !Task.isCancelled, let self, state == .listening else { return }
                logger.info("Recording reached its maximum length")
                handle(.released)
            }
            let started = captureStart
            listeningCueTask = Task { [weak self, listeningCueDelay] in
                try? await Task.sleep(for: listeningCueDelay)
                // The cue also waits for the microphone, which can take 0.3 s for a USB
                // microphone, so whoever starts talking at the sound is recorded from the
                // first syllable. A microphone that fails to start sends no cue.
                guard await started?.value == true else { return }
                guard !Task.isCancelled, let self, holdNumber == hold, state == .listening else { return }
                indicatorShown = true
                onCue(.listening)
            }
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
        if state == .listening {
            handle(.cancelled)
        }
    }

    /// Ends a hold that was released: waits for the microphone to have started, records
    /// the short tail, stops, and transcribes unless the hold was too short or cut.
    private func finishRecording(start: Task<Bool, Never>?, chosen: MicrophoneChoice?, heldFor: Duration, target: pid_t?, releasedAt released: ContinuousClock.Instant) async {
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
        await transcribeAndInsert(recording, chosen: chosen, target: target, releasedAt: released)
    }

    /// Turns a recording into text and pastes it. Logs timings, never the text.
    private func transcribeAndInsert(_ recording: AudioRecording, chosen: MicrophoneChoice?, target: pid_t?, releasedAt released: ContinuousClock.Instant) async {
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
            let raw = try await transcription.transcribe(samples, Vocabulary.context(vocabulary))
            let text = ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: recording.duration))
            guard !text.isEmpty else {
                holdMessage = String(localized: "No speech was recognized")
                logger.notice("No speech recognized in \(recording.duration, privacy: .public) s of audio")
                return
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
                if let app = target ?? frontmostApp() {
                    onPasted(text, app)
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
