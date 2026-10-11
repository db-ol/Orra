import SwiftUI

/// The welcome window's content: the three steps that make Orra ready, in any order, the
/// choice of the talk key, then how to dictate. The download comes first because it takes
/// longest, and it goes on while the user grants the permissions.
struct WelcomeView: View {
    let pushToTalk: PushToTalkController
    let models: ModelInstaller
    let close: () -> Void

    var body: some View {
        let checklist = SetupChecklist(pushToTalk, models)
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Orra")
                        .font(.title2.bold())
                    Text("Hold a key, speak, and let go. Orra types what you said into the app you are using. Your voice is turned into text on this Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SetupStepRow(number: 1, status: checklist.model, title: "Download the speech model") {
                ModelStepDetail(models: models, pushToTalk: pushToTalk)
            }
            SetupStepRow(number: 2, status: checklist.microphone, title: "Allow the microphone") {
                MicrophoneStepDetail(pushToTalk: pushToTalk)
            }
            SetupStepRow(number: 3, status: checklist.accessibility, title: "Allow Accessibility") {
                AccessibilityStepDetail(pushToTalk: pushToTalk)
            }
            // Not part of the checklist: right Control works when the user skips it.
            SetupStepRow(number: 4, status: pushToTalk.hasChosenTalkKeys ? .done : .todo, title: "Choose your talk key") {
                TalkKeyStepDetail(pushToTalk: pushToTalk)
            }
            if checklist.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orra is ready")
                        .font(.headline)
                    Text("Try it in any app: hold the talk key, say something, and let go. The text appears where you are typing.")
                        .fixedSize(horizontal: false, vertical: true)
                    if pushToTalk.handsFreeOn {
                        Text("For a longer text, press the talk key twice quickly and talk hands free. Press it once more to paste.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack {
                Spacer()
                if checklist.isComplete {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now", action: close)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}

/// One step: its number until it is done, a spinner while it runs, a check mark after.
private struct SetupStepRow<Detail: View>: View {
    let number: Int
    let status: SetupChecklist.Status
    let title: LocalizedStringKey
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StepBadge(number: number, status: status)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                detail
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StepBadge: View {
    let number: Int
    let status: SetupChecklist.Status

    var body: some View {
        ZStack {
            switch status {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            case .inProgress:
                ProgressView()
                    .controlSize(.small)
            case .todo:
                Circle()
                    .strokeBorder(.secondary, lineWidth: 1.5)
                Text(number, format: .number)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status == .done ? Text("Done") : Text("Not done yet"))
    }
}

/// The download, with the menu's own lines and button, or how the installed model stands.
private struct ModelStepDetail: View {
    let models: ModelInstaller
    let pushToTalk: PushToTalkController

    var body: some View {
        let total = models.manifest.totalBytes
        VStack(alignment: .leading, spacing: 8) {
            switch models.state {
            case .installed:
                switch pushToTalk.modelState {
                case .ready:
                    Text("The speech model is ready.")
                        .foregroundStyle(.secondary)
                case .notLoaded, .loading:
                    Text("Loading the speech model…")
                        .foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Text(verbatim: reason)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        // As in the menu: checks the files again, hashes included.
                        Task { await models.prepare(checkingHashes: true) }
                    }
                }
            case .downloading(let bytes, _):
                ProgressView(value: Double(min(bytes, total)), total: Double(max(total, 1)))
                    .frame(maxWidth: 360)
                lines(models.state.menuLines(total: total))
            default:
                lines(models.state.menuLines(total: total))
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

    private func lines(_ lines: [String]) -> some View {
        ForEach(lines, id: \.self) { line in
            // Already in the user's language, so shown as it is.
            Text(verbatim: line)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MicrophoneStepDetail: View {
    let pushToTalk: PushToTalkController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch pushToTalk.microphoneAccess {
            case .authorized:
                Text("Orra can use the microphone.")
                    .foregroundStyle(.secondary)
            case .notDetermined:
                Text("Orra records only while you hold the talk key.")
                    .foregroundStyle(.secondary)
                Button("Allow Microphone Access…") {
                    pushToTalk.requestMicrophoneAccess()
                }
            case .denied:
                Text("Microphone access is off. Turn on Orra under Microphone in System Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Microphone Settings…") {
                    pushToTalk.requestMicrophoneAccess()
                }
            case .notConfigured:
                Text("This build has no microphone usage description")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The talk key: which one Orra listens for, which one suits this Mac's keyboard, and the
/// button to choose one by pressing it.
private struct TalkKeyStepDetail: View {
    let pushToTalk: PushToTalkController
    /// Read once when the step appears, not in an initial value, which SwiftUI would
    /// evaluate again each time the window redraws, such as for download progress.
    /// Reading the registry needs no permission. Nil until then.
    @State private var keyboard: KeyboardKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: TalkKey.holdHint(for: pushToTalk.talkKeys))
                .foregroundStyle(.secondary)
            if let keyboard {
                recommendation(for: keyboard)
            }
        }
        .task {
            if keyboard == nil {
                keyboard = KeyboardKind.current()
            }
        }
    }

    @ViewBuilder private func recommendation(for keyboard: KeyboardKind) -> some View {
        let recommended = keyboard.recommendedKey
        Group {
            Group {
                switch keyboard {
                case .builtIn:
                    Text("On this Mac's own keyboard, fn (Globe) at the bottom left is comfortable while your right hand is on the mouse. On an external keyboard, choose right Control, because some, such as the Logitech MX Keys, never send fn.")
                case .external:
                    Text("On an external keyboard, right Control works best, because some, such as the Logitech MX Keys, never send fn. On a Mac's built in keyboard, fn (Globe) at the bottom left is comfortable while your right hand is on the mouse.")
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Also shown while the recommended key is only the default, so keeping it
                // completes the step.
                if !pushToTalk.isChoosingTalkKey, pushToTalk.talkKeys != [recommended] || !pushToTalk.hasChosenTalkKeys {
                    Button("Use \(recommended.nameInSentence)") {
                        pushToTalk.chooseTalkKey(recommended)
                    }
                }
                PressTalkKeyButton(pushToTalk: pushToTalk)
            }
        }
    }
}

private struct AccessibilityStepDetail: View {
    let pushToTalk: PushToTalkController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pushToTalk.isHotkeyActive {
                Text(verbatim: TalkKey.holdHint(for: pushToTalk.talkKeys))
                    .foregroundStyle(.secondary)
            } else {
                Text("Orra needs it to notice the talk key and to paste the text. Turn on Orra in the list that opens, then come back here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Grant Accessibility Access…") {
                    pushToTalk.promptForAccessibility()
                }
            }
        }
    }
}
