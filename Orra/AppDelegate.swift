import AppKit

/// Orra lives in the menu bar, so it runs as an accessory app: no Dock icon and
/// no window at launch. The policy is set here at launch rather than through
/// LSUIElement because the Info.plist is generated from build settings.
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
        saveVocabulary: { VocabularyPreference.save($0) }
    )
    let audioInputs = AudioInputList.live()
    let openAtLogin = OpenAtLogin.live()
    let models = ModelInstaller.live()
    /// The recording indicator and the sounds. Lazy, because it reads the controller's
    /// microphone level.
    lazy var feedback = RecordingFeedback.live { [pushToTalk] in pushToTalk.inputLevel() }
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
        }
    )
    lazy var learnedNotice = LearnedNoticePanel(notice: LearnedNotice()) { [learning] learned in
        learning.undo(learned)
    }

    /// True when Xcode runs this process to host unit tests or SwiftUI previews.
    nonisolated static var isHostedByXcode: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Xcode runs this app to host unit tests and SwiftUI previews. Those
        // copies must not install the keyboard tap or show the welcome window.
        guard !Self.isHostedByXcode else { return }
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
        pushToTalk.start()
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
