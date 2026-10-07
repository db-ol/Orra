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
        // copies must not install the keyboard tap or show the Accessibility
        // prompt.
        guard !Self.isHostedByXcode else { return }
        // The installer is what loads the speech model: at launch when the model is in
        // place, and again after a download or Try Again.
        models.onInstalled = { [pushToTalk] _ in
            Task { await pushToTalk.loadModel() }
        }
        pushToTalk.start()
        openAtLogin.refreshWhenMenusOpen()
        audioInputs.refreshWhenMenusOpen()
        // Local files only. Launching never touches the network.
        Task { [models] in
            await models.prepare()
        }
    }
}
