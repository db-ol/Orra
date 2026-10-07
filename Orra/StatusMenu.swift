import SwiftUI

/// The menu shown from the menu bar item.
struct StatusMenu: View {
    let pushToTalk: PushToTalkController
    let models: ModelInstaller
    let openAtLogin: OpenAtLogin
    let inputs: AudioInputList
    let showWelcome: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Above the talk key, so the download can start before Accessibility is granted.
        ModelMenuSection(models: models, pushToTalk: pushToTalk)
        if pushToTalk.isHotkeyActive {
            Text(TalkKey.holdHint(for: pushToTalk.talkKeys))
            if let warning = MicrophoneLabels.lidWarning(
                choice: pushToTalk.microphone,
                inputs: inputs.inputs,
                defaultInput: inputs.defaultInput,
                lidClosed: inputs.lidClosed
            ), warning != pushToTalk.problem {
                Text(warning)
            }
            switch pushToTalk.microphoneAccess {
            case .authorized:
                EmptyView()
            case .notDetermined:
                Text("The microphone needs permission")
                Button("Allow Microphone Access…") {
                    pushToTalk.requestMicrophoneAccess()
                }
            case .denied:
                Text("Microphone access is off")
                Button("Open Microphone Settings…") {
                    pushToTalk.requestMicrophoneAccess()
                }
            case .notConfigured:
                Text("This build has no microphone usage description")
            }
            if let problem = pushToTalk.problem {
                Text(problem)
            }
            if let microphoneNotice = pushToTalk.microphoneNotice {
                Text(microphoneNotice)
            }
            if pushToTalk.suggestsSoundSettings {
                Button("Open Sound Settings…") {
                    pushToTalk.openSoundSettings()
                }
            }
            if let notice = pushToTalk.notice {
                Text(notice)
            }
            if let transcript = pushToTalk.lastTranscript {
                Button("Copy Last Dictation") {
                    TextInserter.copy(transcript, to: .general)
                }
            }
        } else {
            Text("The talk key needs Accessibility access")
            Button("Grant Accessibility Access…") {
                pushToTalk.promptForAccessibility()
            }
        }

        Divider()

        Menu("Talk Key") {
            TalkKeyToggles(keys: pushToTalk.talkKeys, setKey: pushToTalk.setTalkKey)
        }
        Menu("Microphone") {
            MicrophoneToggles(inputs: inputs, chosen: pushToTalk.microphone, choose: pushToTalk.setMicrophone)
        }
        Toggle("Open at Login", isOn: Binding(
            get: { openAtLogin.isOn },
            set: { openAtLogin.setOn($0) }
        ))
        if openAtLogin.needsApproval {
            Button("Allow Orra in Login Items…") {
                openAtLogin.openSettings()
            }
        }
        if let problem = openAtLogin.problem {
            Text(problem)
        }

        Divider()

        if !SetupChecklist(pushToTalk, models).isComplete {
            Button("Setup Guide…") {
                showWelcome()
            }
        }
        Button("Settings…") {
            // An accessory app is not the active app when its menu is used.
            // Activate first, otherwise the settings window can open behind
            // the frontmost app. The Settings scene owns a single window, so
            // repeated calls bring the same window forward.
            NSApplication.shared.activate()
            openSettings()
        }

        Divider()

        Button("Quit Orra") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// The speech model's lines at the top of the menu: the download until the model is in
/// place, then whether it loaded.
struct ModelMenuSection: View {
    let models: ModelInstaller
    let pushToTalk: PushToTalkController

    var body: some View {
        if case .installed = models.state {
            switch pushToTalk.modelState {
            case .notLoaded, .loading:
                Text("Loading the speech model…")
            case .ready:
                EmptyView()
            case .unavailable(let reason):
                Text(reason)
                Button("Try Again") {
                    // Checks the files again, hashes included, then loads. A damaged or
                    // missing file leads back to Download.
                    Task { await models.prepare(checkingHashes: true) }
                }
            }
        } else {
            let total = models.manifest.totalBytes
            ForEach(models.state.menuLines(total: total), id: \.self) { line in
                Text(line)
            }
            if let title = models.state.buttonTitle(total: total) {
                Button(title) {
                    if case .downloading = models.state {
                        models.cancel()
                    } else {
                        models.download()
                    }
                }
            }
        }
    }
}
