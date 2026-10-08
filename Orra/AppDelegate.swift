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
        saveMicrophone: { MicrophonePreference.save($0) }
    )
    let audioInputs = AudioInputList.live()
    let openAtLogin = OpenAtLogin.live()
    let models = ModelInstaller.live()
    /// The recording indicator and the sounds. Lazy, because it reads the controller's
    /// microphone level.
    lazy var feedback = RecordingFeedback.live { [pushToTalk] in pushToTalk.inputLevel() }
    lazy var welcome = WelcomeWindow(pushToTalk: pushToTalk, models: models)

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
        pushToTalk.start()
        openAtLogin.refreshWhenMenusOpen()
        audioInputs.refreshWhenMenusOpen()
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
