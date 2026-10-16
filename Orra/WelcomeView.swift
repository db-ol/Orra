import Combine
import SwiftUI

/// The welcome window's content: the guide with its line for the step the user is on, the
/// language, the three steps that make Orra ready, in any order, the choice of the talk
/// key, then how to dictate. The download step holds the choice of cleanup, since its one
/// download includes the cleanup model when cleanup is on. The download comes before the
/// permissions because it takes longest, and it goes on while the user grants them.
///
/// The window shows the language picked in it right away, without a restart: SwiftUI looks
/// up text literals in the `locale` of the environment, and text built in code is looked
/// up in `interfaceLocale`. The rest of Orra keeps the language it started with, see
/// WelcomeWindow for the restart.
struct WelcomeView: View {
    let pushToTalk: PushToTalkController
    let setup: SetupDownload
    let close: () -> Void
    /// Tells the window the localization shown, so its title follows.
    let localizationChanged: (String) -> Void
    /// Tells the window the language the user picked in it, not one that came from
    /// Settings, so only a choice made here can restart Orra when the window closes.
    let languagePicked: (AppLanguage) -> Void
    /// Shows the guide beside System Settings after a button here opened it.
    let guideSettings: (PermissionDemo.Kind) -> Void
    @State private var language: AppLanguage
    /// The localization the window shows, such as "zh-Hans". Kept, so a redraw for the
    /// download's progress does not read the Mac's languages again.
    @State private var localization: String
    /// The height of the steps, measured, so they scroll only when the screen is too short
    /// for them. The tallest at first, so the window opens on the screen and shrinks to fit.
    @State private var stepsHeight: CGFloat
    /// Whether the steps scroll on a short screen. Off only to draw the whole window.
    let limitsHeight: Bool

    init(pushToTalk: PushToTalkController, setup: SetupDownload, language: AppLanguage, limitsHeight: Bool = true, close: @escaping () -> Void, localizationChanged: @escaping (String) -> Void, languagePicked: @escaping (AppLanguage) -> Void, guideSettings: @escaping (PermissionDemo.Kind) -> Void = { _ in }) {
        self.limitsHeight = limitsHeight
        _stepsHeight = State(initialValue: Self.tallestSteps)
        self.pushToTalk = pushToTalk
        self.setup = setup
        self.close = close
        self.localizationChanged = localizationChanged
        self.languagePicked = languagePicked
        self.guideSettings = guideSettings
        _language = State(initialValue: language)
        _localization = State(initialValue: language.localization())
    }

    var body: some View {
        let locale = Locale(identifier: localization)
        content
            .environment(\.locale, locale)
            .environment(\.interfaceLocale, locale)
            .onChange(of: language) { _, language in
                language.save()
                localization = language.localization()
            }
            .onChange(of: localization) { _, localization in
                localizationChanged(localization)
            }
            // Settings can change the language while the window is open. The vocabulary is
            // saved on another thread, so changes are read on the main one.
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
                let saved = AppLanguage.load()
                if saved != language {
                    language = saved
                }
            }
    }

    @ViewBuilder private var content: some View {
        let checklist = SetupChecklist(pushToTalk, setup.speech)
        let summary = setup.summary(locale: Locale(identifier: localization))
        let downloadingCleanup = summary.active == .cleanup && setup.cleanup.models.state.isBusy
        let step = GuideStep.current(
            checklist: checklist,
            talkKeyChosen: pushToTalk.hasChosenTalkKey,
            downloadingCleanup: downloadingCleanup
        )
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Orra")
                    .font(.title2.bold())
                Text("Hold a key, speak, and let go. Orra types what you said into the app you are using. Your voice is turned into text on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            HStack(alignment: .center, spacing: 10) {
                OrraGuide(waves: step == .ready)
                    .frame(width: 76, height: 76)
                GuideBubble(line: step.line(locale: Locale(identifier: localization)))
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .padding(.bottom, 6)
            .padding(.horizontal, 28)
            if limitsHeight {
                ScrollView {
                    steps(checklist: checklist, summary: summary, step: step, downloadingCleanup: downloadingCleanup)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stepsHeight = $0 }
                }
                .frame(height: min(stepsHeight, Self.tallestSteps))
            } else {
                steps(checklist: checklist, summary: summary, step: step, downloadingCleanup: downloadingCleanup)
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
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .frame(width: 560)
    }

    /// The most the steps take before they scroll: the screen's height less the title bar,
    /// the header with the guide and the buttons.
    private static var tallestSteps: CGFloat {
        max((NSScreen.main?.visibleFrame.height ?? 900) - 300, 320)
    }

    private func steps(checklist: SetupChecklist, summary: DownloadSummary, step: GuideStep, downloadingCleanup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            LanguageRow(language: Binding {
                language
            } set: { picked in
                language = picked
                languagePicked(picked)
            })
            SetupStepRow(number: 1, status: downloadingCleanup ? .inProgress : checklist.model, title: setup.wantsCleanup ? "Download the models" : "Download the speech model", isCurrent: step == .download || step == .downloading) {
                ModelStepDetail(setup: setup, summary: summary, pushToTalk: pushToTalk)
            }
            SetupStepRow(number: 2, status: checklist.microphone, title: "Allow the microphone", isCurrent: step == .microphone) {
                MicrophoneStepDetail(pushToTalk: pushToTalk, guideSettings: guideSettings)
            }
            SetupStepRow(number: 3, status: checklist.accessibility, title: "Allow Accessibility", isCurrent: step == .accessibility) {
                AccessibilityStepDetail(pushToTalk: pushToTalk, guideSettings: guideSettings)
            }
            // Not part of the checklist: right Control works when the user skips it.
            SetupStepRow(number: 4, status: pushToTalk.hasChosenTalkKey ? .done : .todo, title: "Choose your talk key", isCurrent: step == .talkKey) {
                TalkKeyStepDetail(pushToTalk: pushToTalk)
            }
            if checklist.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orra is ready")
                        .font(.headline)
                    Text("Try it in any app: hold the talk key, say something, and let go. The text appears where you are typing.")
                        .fixedSize(horizontal: false, vertical: true)
                    if pushToTalk.handsFreeOn, pushToTalk.talkMode == .hold {
                        Text("For a longer text, press the talk key twice quickly and talk hands free. Press it once more to paste.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        // Room for the tint of the current step, which reaches past the steps.
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }
}

/// The language of Orra, with the same choices as in Settings. Each language reads in its
/// own name, so a user who cannot read the window's language still finds theirs.
private struct LanguageRow: View {
    @Binding var language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: $language) {
                ForEach(AppLanguage.allCases) { language in
                    if let name = language.nativeName {
                        Text(verbatim: name).tag(language)
                    } else {
                        Text("Same as the Mac").tag(language)
                    }
                }
            } label: {
                Label("Language", systemImage: "globe")
            }
            .fixedSize()
            Text("You can change this later in Settings, under General.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One step: its number until it is done, a spinner while it runs, a check mark after.
private struct SetupStepRow<Detail: View>: View {
    let number: Int
    let status: SetupChecklist.Status
    let title: LocalizedStringKey
    /// The step the guide talks about, shown with a tint.
    var isCurrent = false
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
        .padding(8)
        .background(
            Color.accentColor.opacity(isCurrent ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(-8)
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
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

/// The one download of the speech model and, with cleanup on, the cleanup model: how the
/// speech model stands, one bar for the bytes of both, the lines, the cleanup switch, and
/// the button, which follows the switch.
private struct ModelStepDetail: View {
    let setup: SetupDownload
    let summary: DownloadSummary
    let pushToTalk: PushToTalkController
    @Environment(\.interfaceLocale) private var interfaceLocale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .installed = setup.speech.state {
                switch pushToTalk.modelState {
                case .ready:
                    // While the cleanup model downloads, its own line says so already.
                    if summary.active != .cleanup {
                        Text("The speech model is ready.")
                            .foregroundStyle(.secondary)
                    }
                case .notLoaded, .loading:
                    Text("Loading the speech model…")
                        .foregroundStyle(.secondary)
                case .unavailable(let problem):
                    Text(verbatim: problem.message(in: interfaceLocale))
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        // As in the menu: checks the files again, hashes included.
                        Task { await setup.speech.prepare(checkingHashes: true) }
                    }
                }
            }
            if let progress = summary.progress {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 360)
            }
            ForEach(summary.lines, id: \.self) { line in
                // Already in the window's language, so shown as it is.
                Text(verbatim: line)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CleanupOption(setup: setup)
            if let title = summary.button {
                Button(title) {
                    if summary.cancels {
                        setup.cancel()
                    } else {
                        setup.start()
                    }
                }
            }
        }
    }
}

/// The cleanup switch in the download step, with an example, its cost, and a line on what
/// is lost when the user turns it off on a Mac with the memory for it. Not part of the
/// checklist: dictation works without it.
private struct CleanupOption: View {
    let setup: SetupDownload

    var body: some View {
        let size = ModelInstaller.State.size(setup.cleanup.models.manifest.totalBytes)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { setup.wantsCleanup },
                set: { setup.setCleanup($0) }
            )) {
                HStack(spacing: 6) {
                    Text("Also clean up what you say")
                    if setup.hasEnoughMemory {
                        RecommendedBadge()
                    }
                }
            }
            .toggleStyle(.switch)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Text("Before")
                        .foregroundStyle(.secondary)
                    Text("Let’s meet at three, no wait, four.")
                }
                GridRow {
                    Text("After")
                        .foregroundStyle(.secondary)
                    Text("Let’s meet at four.")
                }
            }
            .font(.subheadline)
            Text("It needs a \(size) download and about 4 GB of memory while it runs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !setup.hasEnoughMemory, !setup.wantsCleanup {
                Text("Off at first, because this Mac has \(setup.memoryGigabytes) GB of memory.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if setup.turnedCleanupOff, !setup.wantsCleanup {
                // Orange on the icon only, as in Settings: orange text that small is too faint
                // on a light background. Not red, which means something went wrong.
                Label {
                    Text("Without cleanup, Orra types exactly what it hears, fillers and corrections included.")
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("You can change this later in Settings, under General.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: 400, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}

private struct MicrophoneStepDetail: View {
    let pushToTalk: PushToTalkController
    let guideSettings: (PermissionDemo.Kind) -> Void

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
                if PermissionDemo.isShown(for: .microphone, microphone: pushToTalk.microphoneAccess, hotkeyActive: pushToTalk.isHotkeyActive) {
                    PermissionDemo(kind: .microphone)
                }
                Button("Open Microphone Settings…") {
                    pushToTalk.requestMicrophoneAccess()
                    guideSettings(.microphone)
                }
            case .notConfigured:
                Text("This build has no microphone usage description")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The talk key: the recorder that shows the key and changes it, and which key suits this
/// Mac's keyboard.
private struct TalkKeyStepDetail: View {
    let pushToTalk: PushToTalkController
    /// Read once when the step appears, not in an initial value, which SwiftUI would
    /// evaluate again each time the window redraws, such as for download progress.
    /// Reading the registry needs no permission. Nil until then.
    @State private var keyboard: KeyboardKind?
    @Environment(\.interfaceLocale) private var interfaceLocale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TalkKeyRecorder(pushToTalk: pushToTalk)
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
            // Also shown while the recommended key is only the default, so keeping it
            // completes the step.
            if !pushToTalk.isChoosingTalkKey, pushToTalk.talkKey != .key(recommended) || !pushToTalk.hasChosenTalkKey {
                Button("Use \(recommended.sentenceName(in: interfaceLocale))") {
                    pushToTalk.chooseTalkKey(.key(recommended))
                }
            }
        }
    }
}

private struct AccessibilityStepDetail: View {
    let pushToTalk: PushToTalkController
    let guideSettings: (PermissionDemo.Kind) -> Void
    @Environment(\.interfaceLocale) private var interfaceLocale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pushToTalk.isHotkeyActive {
                Text(verbatim: pushToTalk.talkKey.talkHint(mode: pushToTalk.talkMode, in: interfaceLocale))
                    .foregroundStyle(.secondary)
            } else {
                Text("Orra needs it to notice the talk key and to paste the text. Turn on Orra in the list that opens, then come back here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if PermissionDemo.isShown(for: .accessibility, microphone: pushToTalk.microphoneAccess, hotkeyActive: pushToTalk.isHotkeyActive) {
                    PermissionDemo(kind: .accessibility)
                }
                Button("Grant Accessibility Access…") {
                    pushToTalk.promptForAccessibility()
                    guideSettings(.accessibility)
                }
            }
        }
    }
}
