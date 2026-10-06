import SwiftUI

@main struct OrraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(pushToTalk: appDelegate.pushToTalk, openAtLogin: appDelegate.openAtLogin, inputs: appDelegate.audioInputs)
        } label: {
            MenuBarIcon(pushToTalk: appDelegate.pushToTalk)
        }

        Settings {
            SettingsView(pushToTalk: appDelegate.pushToTalk, inputs: appDelegate.audioInputs)
        }
    }
}

/// The menu bar icon. It shows whether the hotkey works, whether the speech model is
/// ready, whether Orra is listening or processing, and whether the microphone is blocked
/// or the last dictation failed.
struct MenuBarIcon: View {
    let pushToTalk: PushToTalkController

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel("Orra")
    }

    private var symbolName: String {
        guard pushToTalk.isHotkeyActive else { return "mic.slash" }
        switch pushToTalk.state {
        case .listening:
            return "mic.fill"
        case .processing:
            return "waveform"
        case .idle:
            switch pushToTalk.modelState {
            case .notLoaded, .loading:
                return "hourglass"
            case .unavailable:
                return "exclamationmark.triangle"
            case .ready:
                let microphoneBlocked = pushToTalk.microphoneAccess == .denied || pushToTalk.microphoneAccess == .notConfigured
                return pushToTalk.problem == nil && !microphoneBlocked ? "mic" : "exclamationmark.triangle"
            }
        }
    }
}
