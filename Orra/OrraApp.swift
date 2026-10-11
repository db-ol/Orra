import SwiftUI

@main struct OrraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(pushToTalk: appDelegate.pushToTalk, models: appDelegate.models, openAtLogin: appDelegate.openAtLogin, inputs: appDelegate.audioInputs, clipboard: appDelegate.clipboard, updater: appDelegate.updater) {
                appDelegate.welcome.show()
            }
        } label: {
            MenuBarIcon(pushToTalk: appDelegate.pushToTalk, models: appDelegate.models)
        }

        // A plain window rather than SwiftUI's Settings scene, whose window cannot be
        // resized. It opens only when asked for, never at launch.
        Window("Orra Settings", id: SettingsWindow.id) {
            SettingsView(pushToTalk: appDelegate.pushToTalk, inputs: appDelegate.audioInputs, feedback: appDelegate.feedback, openAtLogin: appDelegate.openAtLogin, models: appDelegate.models, learning: appDelegate.learning, dockIcon: appDelegate.dockIcon, updater: appDelegate.updater)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 780, height: 620)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsMenuItem()
            }
        }
    }
}

/// The settings window's identity, for openWindow.
enum SettingsWindow {
    static let id = "settings"
}

/// Settings… with Command comma in the app menu, which also lets AppKit code open the
/// window through that item, see DockIcon.openSettings.
struct SettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            NSApplication.shared.activate()
            openWindow(id: SettingsWindow.id)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// The menu bar icon. It shows whether the speech model still needs its download, whether
/// the hotkey works, whether the model is ready, whether Orra is listening or processing,
/// and whether the microphone is blocked or the last dictation failed.
struct MenuBarIcon: View {
    let pushToTalk: PushToTalkController
    let models: ModelInstaller

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel("Orra")
    }

    private var symbolName: String {
        // Until the model is in place, the icon shows where that stands, with or without
        // Accessibility access.
        if let symbol = models.state.symbolName { return symbol }
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
