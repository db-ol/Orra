import SwiftUI

@main struct OrraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(pushToTalk: appDelegate.pushToTalk, models: appDelegate.models, openAtLogin: appDelegate.openAtLogin, inputs: appDelegate.audioInputs, clipboard: appDelegate.clipboard, updater: appDelegate.updater) {
                appDelegate.welcome.show()
            } reportProblem: {
                appDelegate.report.show()
            }
        } label: {
            MenuBarIcon(pushToTalk: appDelegate.pushToTalk, models: appDelegate.models, feedback: appDelegate.feedback)
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
            // Replaces the Help menu's item, which has no help book to open.
            CommandGroup(replacing: .help) {
                Button("Report a Problem…") {
                    appDelegate.report.show()
                }
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
/// the hotkey works, whether the model is ready, and whether the microphone is blocked or
/// the last dictation failed. While the recording indicator is on, the icon does not show
/// listening or transcribing: macOS shows its own microphone indicator in the menu bar
/// while Orra records, and the indicator at the bottom of the screen shows the rest. With
/// the indicator turned off in Settings, the icon is the only sign left, so it fills while
/// Orra listens and turns into a waveform while Orra transcribes.
struct MenuBarIcon: View {
    let pushToTalk: PushToTalkController
    let models: ModelInstaller
    let feedback: RecordingFeedback

    var body: some View {
        Image(systemName: Self.symbolName(
            modelSymbol: models.state.symbolName,
            isHotkeyActive: pushToTalk.isHotkeyActive,
            dictation: pushToTalk.state,
            showsIndicator: feedback.showsIndicator,
            modelState: pushToTalk.modelState,
            microphoneAccess: pushToTalk.microphoneAccess,
            hasProblem: pushToTalk.problem != nil
        ))
        .accessibilityLabel("Orra")
    }

    /// The symbol for the given state. With the recording indicator on, the dictation plays
    /// no part, so the icon does not show listening or transcribing. A press still clears
    /// the last dictation's problem, so a warning triangle turns into the plain mic then.
    static func symbolName(
        modelSymbol: String?,
        isHotkeyActive: Bool,
        dictation: PushToTalkStateMachine.State,
        showsIndicator: Bool,
        modelState: PushToTalkController.ModelState,
        microphoneAccess: MicrophoneAccess,
        hasProblem: Bool
    ) -> String {
        // Until the model is in place, the icon shows where that stands, with or without
        // Accessibility access.
        if let modelSymbol { return modelSymbol }
        guard isHotkeyActive else { return "mic.slash" }
        if !showsIndicator {
            switch dictation {
            case .listening: return "mic.fill"
            case .processing: return "waveform"
            case .idle: break
            }
        }
        switch modelState {
        case .notLoaded, .loading:
            return "hourglass"
        case .unavailable:
            return "exclamationmark.triangle"
        case .ready:
            let microphoneBlocked = microphoneAccess == .denied || microphoneAccess == .notConfigured
            return !hasProblem && !microphoneBlocked ? "mic" : "exclamationmark.triangle"
        }
    }
}
