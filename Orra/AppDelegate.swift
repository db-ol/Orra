import AppKit

/// Orra lives in the menu bar, and in the Dock too unless the user turns that off, see
/// DockIcon. The policy is set here at launch rather than through LSUIElement, so it can
/// follow the setting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Cleanup and translation with the local text model, off until the user turns them on.
    let cleanup = TextCleanup.live()
    /// The speech model, one for dictation and meeting captions.
    let transcription = Transcription.qwen3()
    /// How captions give way to dictation on the shared models, see EngineTurns.
    let turns = EngineTurns()
    lazy var pushToTalk = PushToTalkController(
        capture: .live(),
        transcription: transcription,
        cleanup: cleanup.model.sharing(turns),
        translation: cleanup.translation,
        voice: speech.voiceForDictation,
        insert: TextInserter.live().insert,
        talkKey: TalkKeyPreference.loadHotkey(),
        saveTalkKey: { TalkKeyPreference.saveHotkey($0) },
        talkKeyChosen: TalkKeyPreference.isSaved(),
        translationKey: TranslationKeyPreference.loadHotkey(talkKey: TalkKeyPreference.loadHotkey()),
        saveTranslationKey: { TranslationKeyPreference.saveHotkey($0) },
        secondTalkKey: SecondTalkKeyPreference.load(
            talkKey: TalkKeyPreference.loadHotkey(),
            translationKey: TranslationKeyPreference.loadHotkey(talkKey: TalkKeyPreference.loadHotkey())
        ),
        saveSecondTalkKey: { SecondTalkKeyPreference.save($0) },
        talkMode: TriggerModePreference.load(for: .talk),
        translationMode: TriggerModePreference.load(for: .translation),
        saveTriggerMode: { TriggerModePreference.save($0, for: $1) },
        handsFree: HandsFreePreference.load(),
        saveHandsFree: { HandsFreePreference.save($0) },
        microphone: MicrophonePreference.load(),
        saveMicrophone: { MicrophonePreference.save($0) },
        vocabulary: VocabularyPreference.load(),
        saveVocabulary: { VocabularyPreference.saveInBackground($0) },
        removesFillerWords: FillerPreference.load(),
        saveRemovesFillerWords: { FillerPreference.save($0) },
        writesNumbersAsDigits: NumberPreference.load(),
        saveWritesNumbersAsDigits: { NumberPreference.save($0) }
    )
    /// The voice models this build links, see VoiceEngines.
    let voiceEngines = VoiceEngines.live
    /// The downloads of the voice model that speaks, for Speak Translation.
    lazy var voiceModels = VoiceModels.live(
        kind: VoiceEngineChoice.resolve(saved: SpeechPreference.voiceModel(), available: voiceEngines.available) ?? VoiceEngineChoice.preferred
    )
    /// Speak Translation. No voice model in a build without speech-swift's Qwen3TTS or
    /// CosyVoiceTTS.
    lazy var speech = TranslationSpeech(
        engines: voiceEngines,
        playback: SpeechPlayer(),
        outputs: { AudioOutput.all() },
        folders: { [voiceModels] in voiceModels.folders },
        settings: .load(),
        save: { $0.save() }
    )
    /// Meeting captions, off at every launch. Lazy, because they read the controller's
    /// speech model state.
    lazy var captions = MeetingCaptions(
        source: .live(),
        engines: .live(
            transcription: transcription,
            isSpeechReady: { [pushToTalk] in pushToTalk.modelState == .ready },
            cleanup: cleanup,
            turns: turns
        ),
        started: { [cleanup] in cleanup.captionsStarted() },
        stopped: { [cleanup] in cleanup.captionsStopped() },
        displayMode: CaptionDisplayMode.load(),
        saveDisplayMode: { $0.save() }
    )
    lazy var captionWindow = CaptionWindow(captions: captions, pushToTalk: pushToTalk, cleanup: cleanup)
    let audioInputs = AudioInputList.live()
    let openAtLogin = OpenAtLogin.live()
    let dockIcon = DockIcon.live()
    let updater = AppUpdater()
    let models = ModelInstaller.live()
    /// The recording indicator and the sounds. Lazy, because it reads the controller's
    /// microphone level.
    lazy var feedback = RecordingFeedback.live(
        inputLevel: { [pushToTalk] in pushToTalk.inputLevel() },
        holdHint: { [pushToTalk] in pushToTalk.talkHint() }
    )
    lazy var welcome = WelcomeWindow(pushToTalk: pushToTalk, models: models)
    lazy var clipboard = ClipboardWord(
        isDictating: { [pushToTalk] in pushToTalk.state != .idle },
        vocabulary: { [pushToTalk] in pushToTalk.vocabulary.map(\.text) }
    )
    lazy var learning = CorrectionLearning.live(
        addToVocabulary: { [pushToTalk] word in pushToTalk.addToVocabulary(word, source: .learned) },
        removeFromVocabulary: { [pushToTalk] word in pushToTalk.removeFromVocabulary([word]) },
        isInVocabulary: { [pushToTalk] word in pushToTalk.vocabularyContains(word) }
    )
    lazy var report = ReportWindow(reporter: .live(
        pushToTalk: pushToTalk,
        models: models,
        inputs: audioInputs,
        feedback: feedback,
        openAtLogin: openAtLogin,
        dockIcon: dockIcon,
        learning: learning,
        cleanup: cleanup,
        updater: updater
    ))
    lazy var learnedNotice: LearnedNoticePanel = LearnedNoticePanel(
        notice: LearnedNotice(),
        undo: { [learning] learned in learning.undo(learned) },
        add: { [learning] suggestion, word in learning.add(suggestion, as: word) },
        decline: { [learning] suggestion in learning.decline(suggestion) },
        // Add sets the key only when the tip still fits, since the user may have set a
        // second key or changed the talk key while it showed. Either way it is answered.
        addSecondKey: { [weak self] key in
            guard let self else { return }
            if keyboardTip.stillOffers(key, in: keyboardTipSituation()) {
                pushToTalk.setSecondTalkKey(key)
            }
            answerKeyboardTip()
        },
        dismissTip: { [weak self] _ in self?.answerKeyboardTip() },
        tipApplies: { [weak self] key in
            guard let self else { return false }
            return keyboardTip.stillOffers(key, in: keyboardTipSituation())
        }
    )
    /// Whether an external keyboard is connected, for the keyboard tip.
    let externalKeyboards = ExternalKeyboardMonitor()
    /// Offers a second talk key once, when an external keyboard meets an fn talk key.
    lazy var keyboardTip: ExternalKeyboardTip = ExternalKeyboardTip { [weak self] key in
        self?.learnedNotice.offerKeyboardTip(key)
    }

    /// True when Xcode runs this process to host unit tests or SwiftUI previews.
    nonisolated static var isHostedByXcode: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
    }

    /// Tells the feedback whether a hold would dictate, now and after every change, so the
    /// idle bar shows only then.
    private func followReadiness() {
        feedback.canDictate = withObservationTracking {
            pushToTalk.isHotkeyActive && pushToTalk.modelState == .ready
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.followReadiness()
            }
        }
    }

    /// What decides whether the keyboard tip shows now.
    private func keyboardTipSituation() -> ExternalKeyboardTip.Situation {
        ExternalKeyboardTip.Situation(
            talkKey: pushToTalk.talkKey,
            translationKey: pushToTalk.translationKey,
            secondTalkKey: pushToTalk.secondTalkKey,
            externalKeyboard: externalKeyboards.isConnected,
            setupComplete: SetupChecklist(pushToTalk, models).isComplete,
            welcomeOpen: welcome.isVisible
        )
    }

    /// Offers the keyboard tip when the situation calls for it, see ExternalKeyboardTip.
    private func checkKeyboardTip() {
        keyboardTip.check(keyboardTipSituation())
    }

    /// The tip was answered and never shows again, so the keyboards need no watching.
    private func answerKeyboardTip() {
        keyboardTip.answer()
        externalKeyboards.stop()
    }

    /// Checks the keyboard tip now and whenever setup or the talk keys change, until it was
    /// offered. A keyboard connected and the welcome window closing check it on their own.
    private func followKeyboardTip() {
        guard !keyboardTip.offered, !keyboardTip.answered else { return }
        withObservationTracking {
            checkKeyboardTip()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.followKeyboardTip()
            }
        }
    }

    /// Watches the translation key while translation is on, now and after every change of
    /// the switch.
    private func followTranslation() {
        pushToTalk.setTranslationKeyOn(withObservationTracking {
            cleanup.translationIsOn
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.followTranslation()
            }
        })
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isHostedByXcode else {
            NSApplication.shared.setActivationPolicy(.accessory)
            return
        }
        dockIcon.update()
        dockIcon.followWindows()
    }

    /// A click on the Dock icon, or opening Orra while it runs: the welcome window while
    /// setup needs the user, Settings otherwise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !Self.isHostedByXcode, !hasVisibleWindows else { return true }
        if SetupChecklist(pushToTalk, models).needsUser {
            welcome.show()
        } else {
            DockIcon.openSettings()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The vocabulary saves on a background queue. The last save must be written.
        VocabularyPreference.flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Xcode runs this app to host unit tests and SwiftUI previews. Those
        // copies must not install the keyboard tap or show the welcome window.
        guard !Self.isHostedByXcode else { return }
        // Checks only once the user allowed it, so launching stays offline until then.
        updater.start()
        // The installer is what loads the speech model: at launch when the model is in
        // place, and again after a download or Try Again.
        models.onInstalled = { [pushToTalk] _ in
            Task { await pushToTalk.loadModel() }
        }
        // Cues can come from inside the keyboard tap's callback, which every key press on
        // the Mac waits for. The indicator and the sounds follow right after it returns,
        // in the same order.
        pushToTalk.onCue = { [feedback] cue in
            DispatchQueue.main.async {
                feedback.handle(cue)
            }
        }
        pushToTalk.onPasted = { [learning] text, app, beforeCleanup, replacements in
            learning.pasted(text, in: app, beforeCleanup: beforeCleanup, replacements: replacements)
        }
        pushToTalk.replacementPairs = { [learning] in learning.replacementPairs }
        pushToTalk.onPasteOriginal = { [learning] cleaned in learning.pastedOriginal(replacing: cleaned) }
        learning.onLearned = { [learnedNotice] learned in learnedNotice.show(learned) }
        learning.onSuggest = { [learnedNotice] suggestion in learnedNotice.suggest(suggestion) }
        // The voice waits while the user dictates.
        speech.isDictating = { [pushToTalk] in pushToTalk.state != .idle }
        speech.transcribeVoice = { [pushToTalk] sample in try await pushToTalk.transcribeVoiceSample(sample) }
        speech.transcribeSpeech = { [pushToTalk] audio, language in try await pushToTalk.transcribeSpeech(audio, in: language) }
        voiceModels.onInstalled = { [speech] in speech.prepare() }
        speech.onEngineChange = { [voiceModels] kind in
            voiceModels.select(kind)
            Task { await voiceModels.prepare() }
        }
        captions.showWindow = { [captionWindow] in captionWindow.show() }
        captions.closeWindow = { [captionWindow] in captionWindow.close() }
        // Before the tap is installed, so it watches the translation key from the start.
        followTranslation()
        pushToTalk.start()
        followReadiness()
        openAtLogin.refreshWhenMenusOpen()
        audioInputs.refreshWhenMenusOpen()
        clipboard.refreshWhenMenusOpen()
        // Local files only. Launching never touches the network. The welcome window walks
        // a new user through what is missing, and comes back at launch until nothing is.
        Task { [models, pushToTalk, welcome, cleanup, speech, voiceModels] in
            await models.prepare()
            if SetupChecklist(pushToTalk, models).needsUser {
                welcome.show()
            }
            // Loads the cleanup model when cleanup or translation is on and the model is in
            // place.
            await cleanup.start()
            // Local files only. Loads the voice model when Speak Translation is on.
            if speech.canSpeak {
                await voiceModels.prepare()
            }
        }
        // The tip about a second talk key waits until setup is done and the welcome window
        // is closed. Reading the registry needs no permission and never opens a device.
        if !keyboardTip.answered {
            externalKeyboards.onChange = { [weak self] in self?.checkKeyboardTip() }
            welcome.onClose = { [weak self] in self?.checkKeyboardTip() }
            externalKeyboards.start()
            followKeyboardTip()
        }
    }
}
