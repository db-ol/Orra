import AppKit
import os

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
    lazy var pushToTalk: PushToTalkController = { [self] in
        let talkKey = TalkKeyPreference.loadHotkey()
        let translationKey = TranslationKeyPreference.loadHotkey(talkKey: talkKey)
        // Reading either permission never shows a prompt.
        let setUpBefore = TriggerModePreference.wasSetUpBefore(
            talkKeySaved: TalkKeyPreference.isSaved(),
            microphone: MicrophoneAccess.current(),
            accessibilityAllowed: AXIsProcessTrusted()
        )
        let controller = PushToTalkController(
            capture: .live(),
            transcription: transcription,
            cleanup: cleanup.model.sharing(turns),
            translation: cleanup.translation,
            voice: speech.voiceForDictation,
            insert: TextInserter.live().insert,
            talkKey: talkKey,
            saveTalkKey: { TalkKeyPreference.saveHotkey($0) },
            talkKeyChosen: TalkKeyPreference.isSaved(),
            translationKey: translationKey,
            saveTranslationKey: { TranslationKeyPreference.saveHotkey($0) },
            secondTalkKey: SecondTalkKeyPreference.load(talkKey: talkKey, translationKey: translationKey),
            saveSecondTalkKey: { SecondTalkKeyPreference.save($0) },
            talkMode: TriggerModePreference.load(for: .talk, setUpBefore: setUpBefore),
            translationMode: TriggerModePreference.load(for: .translation, setUpBefore: setUpBefore),
            saveTriggerMode: { TriggerModePreference.save($0, for: $1) },
            handsFree: HandsFreePreference.load(),
            saveHandsFree: { HandsFreePreference.save($0) },
            liveCaptionsShortcut: LiveCaptionsShortcutPreference.load(
                defaultShortcut: LiveCaptionsShortcut.defaultShortcut(keyCodeForC: KeyboardLayout.keyCode(for: "c", withCommand: true))
            ),
            saveLiveCaptionsShortcut: { LiveCaptionsShortcutPreference.save($0) },
            microphone: MicrophonePreference.load(),
            saveMicrophone: { MicrophonePreference.save($0) },
            vocabulary: VocabularyPreference.load(),
            saveVocabulary: { VocabularyPreference.saveInBackground($0) },
            removesFillerWords: FillerPreference.load(),
            saveRemovesFillerWords: { FillerPreference.save($0) },
            writesNumbersAsDigits: NumberPreference.load(),
            saveWritesNumbersAsDigits: { NumberPreference.save($0) },
            usesScreenNames: ScreenNamesPreference.load(),
            saveUsesScreenNames: { ScreenNamesPreference.save($0) },
            dictationLanguage: DictationLanguagePreference.load(setUpBefore: setUpBefore),
            dictationLanguageFollows: DictationLanguagePreference.follows(setUpBefore: setUpBefore),
            // Translation goes between English and the dictation language, so the model
            // reads the prompts of the new language ahead.
            saveDictationLanguage: { [cleanup] in
                DictationLanguagePreference.save($0)
                cleanup.setDictationLanguage($0)
            },
            saveDictationLanguagePicked: { DictationLanguagePreference.savePicked() }
        )
        cleanup.setDictationLanguage(controller.dictationLanguage)
        return controller
    }()
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
        save: { $0.save() },
        voiceFile: .live
    )
    /// Meeting captions, off at every launch. Lazy, because they read the controller's
    /// speech model state.
    lazy var captions = MeetingCaptions(
        source: .live(),
        engines: .live(
            transcription: transcription,
            isSpeechReady: { [pushToTalk] in pushToTalk.modelState == .ready },
            language: { [pushToTalk] in pushToTalk.dictationLanguage },
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
    /// The welcome window's one download of the speech model and the cleanup model.
    lazy var setup = SetupDownload(speech: models, cleanup: cleanup)
    lazy var welcome = WelcomeWindow(pushToTalk: pushToTalk, setup: setup) { [dockIcon] in
        dockIcon.willShowWindow()
    }
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
    private var menuObserver: (any NSObjectProtocol)?

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

    /// Reads the login item, the microphones and the copied word again each time a menu
    /// opens, Orra's menu bar menu included, so the open menu shows them as they are now.
    private func refreshWhenMenusOpen() {
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [openAtLogin, audioInputs, clipboard] _ in
            MainActor.assumeIsolated {
                openAtLogin.refresh()
                audioInputs.refresh()
                clipboard.refresh()
            }
        }
    }

    /// The Live Captions shortcut turns captions on, or off as closing the window does. The
    /// window is the only other sign, so VoiceOver hears which.
    private func toggleCaptionsFromShortcut() {
        captions.setOn(!captions.isOn)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: LiveCaptionsShortcut.announcement(captionsOn: captions.isOn),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
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
            LaunchWindow.openSettings(dockIcon: dockIcon)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The vocabulary saves on a background queue. The last save must be written.
        VocabularyPreference.flush()
        guard !Self.isHostedByXcode else { return }
        // Remove or Remember my voice turned off just before Quit: the voice sample's file
        // is deleted now, not by a task that may not run.
        speech.removeVoiceFileBeforeQuit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Xcode runs this app to host unit tests and SwiftUI previews. Those
        // copies must not install the keyboard tap or show the welcome window.
        guard !Self.isHostedByXcode else { return }
        // The Apple event that launched Orra is current only now, see LaunchWindow. Whether
        // the launch was a default one is logged for the login test, nothing reads it yet.
        let launchedAtLogin = LaunchWindow.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
        let defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        // Checks only once the user allowed it, so launching stays offline until then.
        updater.start()
        // The installer is what loads the speech model: at launch when the model is in
        // place, and again after a download or Try Again.
        // The cleanup model's download from the welcome window follows the speech model's.
        models.onInstalled = { [pushToTalk, setup] _ in
            Task { await pushToTalk.loadModel() }
            setup.speechInstalled()
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
        speech.waitForSpeechModel = { [pushToTalk] in
            while pushToTalk.modelState != .ready {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = pushToTalk.modelState
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
        // Remember my voice: the voice sample saved on this Mac, once the speech model is
        // loaded and while Speak translations is on. Local files only.
        speech.restoreVoice()
        voiceModels.onInstalled = { [speech] in speech.prepare() }
        speech.onEngineChange = { [voiceModels] kind in
            voiceModels.select(kind)
            Task { await voiceModels.prepare() }
        }
        captions.showWindow = { [captionWindow] in captionWindow.show() }
        captions.closeWindow = { [captionWindow] in captionWindow.close() }
        pushToTalk.onLiveCaptionsShortcut = { [weak self] in self?.toggleCaptionsFromShortcut() }
        // The steps that keep a user's settings across versions. A version that changes
        // what a setting starts as adds its step inside, not here.
        LaunchMigrations.run(pushToTalk)
        // Before the tap is installed, so it watches the translation key from the start.
        followTranslation()
        pushToTalk.start()
        followReadiness()
        refreshWhenMenusOpen()
        // Local files only. Launching never touches the network. The welcome window walks
        // a new user through what is missing, and comes back at launch until nothing is.
        // After that, a launch by the user opens Settings, see LaunchWindow.
        Task { [models, pushToTalk, welcome, cleanup, setup, speech, voiceModels, openAtLogin, dockIcon] in
            await models.prepare()
            // Loads the cleanup model when cleanup or translation is on and the model is in
            // place. Before the welcome window, so its download step knows what is on disk.
            await cleanup.start()
            // Whether the welcome window's download includes the cleanup model.
            setup.lookAtLaunch()
            openAtLogin.refresh()
            let window = LaunchWindow.choose(
                needsUser: SetupChecklist(pushToTalk, models).needsUser,
                launchedAtLogin: launchedAtLogin,
                openAtLogin: openAtLogin.isOn
            )
            let defaultName = defaultLaunch.map { String($0) } ?? "unknown"
            Logger.launch.notice("Launch window: \(String(describing: window), privacy: .public), login item launch: \(launchedAtLogin, privacy: .public), default launch: \(defaultName, privacy: .public), open at login: \(openAtLogin.isOn, privacy: .public)")
            switch window {
            case .welcome: welcome.show()
            case .settings: LaunchWindow.openSettings(dockIcon: dockIcon)
            case .noWindow: break
            }
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

/// The steps at launch that save or move settings, so a user keeps what they had when a
/// version changes what a setting starts as. Each such change adds its step here. They run
/// before the tap is installed, and each runs again at every launch, so each step must
/// leave alone what it already saved.
enum LaunchMigrations {
    static func run(_ pushToTalk: PushToTalkController, in defaults: UserDefaults = .standard) {
        // A new user's talk key stays in Press to start and stop once Orra is set up, and an
        // earlier user's in Hold, see TriggerModePreference.
        TriggerModePreference.keepTalkMode(pushToTalk.talkMode, in: defaults)
        // The translation key stays in Press to start and stop once Translation is turned on,
        // and in Hold for a user who turned it on before, see TriggerModePreference.
        TriggerModePreference.keepTranslationMode(pushToTalk.translationMode, in: defaults)
        // The dictation language stays the same way, see DictationLanguagePreference, and a
        // new user's follows the welcome window until it is picked or setup is done.
        DictationLanguagePreference.keep(pushToTalk.dictationLanguage, follows: pushToTalk.dictationLanguageFollows, in: defaults)
        // Everyone gets the Live Captions shortcut, unless a key clashes with it, see
        // LiveCaptionsShortcutPreference.
        pushToTalk.setLiveCaptionsShortcut(LiveCaptionsShortcutPreference.keep(
            pushToTalk.liveCaptionsShortcut,
            beside: [pushToTalk.talkKey, pushToTalk.translationKey],
            in: defaults
        ))
    }
}
