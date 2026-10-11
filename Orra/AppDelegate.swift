import AppKit

/// Orra lives in the menu bar, and in the Dock too unless the user turns that off, see
/// DockIcon. The policy is set here at launch rather than through LSUIElement, so it can
/// follow the setting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let pushToTalk = PushToTalkController(
        capture: .live(),
        transcription: .qwen3(),
        insert: TextInserter.live().insert,
        talkKeys: TalkKeyPreference.load(),
        saveTalkKeys: { TalkKeyPreference.save($0) },
        microphone: MicrophonePreference.load(),
        saveMicrophone: { MicrophonePreference.save($0) },
        vocabulary: VocabularyPreference.load(),
        saveVocabulary: { VocabularyPreference.save($0) },
        removesFillerWords: FillerPreference.load(),
        saveRemovesFillerWords: { FillerPreference.save($0) },
        writesNumbersAsDigits: NumberPreference.load(),
        saveWritesNumbersAsDigits: { NumberPreference.save($0) }
    )
    let audioInputs = AudioInputList.live()
    let openAtLogin = OpenAtLogin.live()
    let dockIcon = DockIcon.live()
    let updater = AppUpdater()
    let models = ModelInstaller.live()
    /// The recording indicator and the sounds. Lazy, because it reads the controller's
    /// microphone level.
    lazy var feedback = RecordingFeedback.live(
        inputLevel: { [pushToTalk] in pushToTalk.inputLevel() },
        holdHint: { [pushToTalk] in TalkKey.holdHint(for: pushToTalk.talkKeys) }
    )
    lazy var welcome = WelcomeWindow(pushToTalk: pushToTalk, models: models)
    lazy var clipboard = ClipboardWord(
        isDictating: { [pushToTalk] in pushToTalk.state != .idle },
        vocabulary: { [pushToTalk] in pushToTalk.vocabulary }
    )
    lazy var learning = CorrectionLearning.live(
        addToVocabulary: { [pushToTalk] word in
            let terms = pushToTalk.vocabulary
            if terms.contains(where: { $0.lowercased() == word.lowercased() }) { return .alreadyThere }
            let updated = Vocabulary.adding(word, to: terms)
            guard updated != terms else { return .full }
            pushToTalk.setVocabulary(updated)
            return .added
        },
        removeFromVocabulary: { [pushToTalk] word in
            pushToTalk.setVocabulary(Vocabulary.removing(word, from: pushToTalk.vocabulary))
        },
        isInVocabulary: { [pushToTalk] word in
            pushToTalk.vocabulary.contains { $0.lowercased() == word.lowercased() }
        }
    )
    lazy var report = ReportWindow(reporter: .live(
        pushToTalk: pushToTalk,
        models: models,
        inputs: audioInputs,
        feedback: feedback,
        openAtLogin: openAtLogin,
        dockIcon: dockIcon,
        learning: learning,
        updater: updater
    ))
    lazy var learnedNotice = LearnedNoticePanel(
        notice: LearnedNotice(),
        undo: { [learning] learned in learning.undo(learned) },
        add: { [learning] suggestion, word in learning.add(suggestion, as: word) },
        decline: { [learning] suggestion in learning.decline(suggestion) }
    )

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
        pushToTalk.onPasted = { [learning] text, app in learning.pasted(text, in: app) }
        learning.onLearned = { [learnedNotice] learned in learnedNotice.show(learned) }
        learning.onSuggest = { [learnedNotice] suggestion in learnedNotice.suggest(suggestion) }
        pushToTalk.start()
        followReadiness()
        openAtLogin.refreshWhenMenusOpen()
        audioInputs.refreshWhenMenusOpen()
        clipboard.refreshWhenMenusOpen()
        // Local files only. Launching never touches the network. The welcome window walks
        // a new user through what is missing, and comes back at launch until nothing is.
        Task { [models, pushToTalk, welcome] in
            await models.prepare()
            if SetupChecklist(pushToTalk, models).needsUser {
                welcome.show()
            }
        }
    }
}
