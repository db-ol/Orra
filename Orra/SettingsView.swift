import AppKit
import Combine
import SwiftUI

/// The tabs in the sidebar of the settings window, in their order. Projects shows only in
/// builds that show it, see `visible(projectsVisible:)`.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case dictation
    case translation
    case meeting
    case vocabulary
    case projects
    case about

    var id: String { rawValue }

    /// The name in the sidebar and the window's title.
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .translation: "Translation"
        case .meeting: "Meeting Interpretation"
        case .vocabulary: "Vocabulary"
        case .projects: "Projects"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .dictation: "mic.fill"
        case .translation: "translate"
        case .meeting: "captions.bubble.fill"
        case .vocabulary: "character.book.closed.fill"
        case .projects: "briefcase.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The color behind the icon, as System Settings gives each pane its own.
    var tint: Color {
        switch self {
        case .general: .gray
        case .dictation: .pink
        case .translation: .green
        case .meeting: .orange
        case .vocabulary: .blue
        case .projects: .teal
        case .about: .indigo
        }
    }

    /// Whether the sidebar marks the tab as a preview, which may still change.
    var isPreview: Bool {
        self == .projects
    }

    /// The tabs the sidebar shows, in their order: Projects only where the build shows it.
    static func visible(projectsVisible: Bool = ProjectsAvailability.isVisible) -> [SettingsTab] {
        allCases.filter { $0 != .projects || projectsVisible }
    }

    /// The tab the window turns to when asked for this one: General in place of a tab the
    /// sidebar does not show.
    func shown(projectsVisible: Bool = ProjectsAvailability.isVisible) -> SettingsTab {
        Self.visible(projectsVisible: projectsVisible).contains(self) ? self : .general
    }
}

/// A part of a page that the window scrolls to when it opens: Keys, at the bottom of
/// General, for Change Talk Key… in the menu.
enum SettingsSection: Hashable {
    case keys
}

/// A symbol in a colored rounded square, as in the sidebar of System Settings.
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.gradient))
            .accessibilityHidden(true)
    }
}

/// A tab's icon and name in the sidebar.
struct SettingsTabLabel: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            if tab.isPreview {
                // Under the name, since a label beside it leaves no room in Japanese or
                // Spanish.
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title)
                    Text("Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(tab.title)
            }
        } icon: {
            SettingsIcon(symbol: tab.symbol, tint: tab.tint)
        }
    }
}

/// A setting's name with what it does in smaller text right under it, as System Settings
/// shows them, so the explanation sits next to its switch. A note, when there is one, is a
/// line of its own under the explanation.
struct DescribedLabel: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    var note: LocalizedStringKey? = nil

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// The settings window: a sidebar with General, Dictation, Translation, Meeting
/// Interpretation, Vocabulary, Projects and About, like System Settings. General holds the
/// system, the microphone and the keys. Dictation holds the dictation language, Clean Up
/// Text and what helps recognition. Translation holds the translation key's switch and its
/// target. Meeting Interpretation holds live captions and speaking translations to others.
/// Projects holds its switch and its data, in builds that show it.
struct SettingsView: View {
    let pushToTalk: PushToTalkController
    let inputs: AudioInputList
    @Bindable var feedback: RecordingFeedback
    let openAtLogin: OpenAtLogin
    let models: ModelInstaller
    let cleanup: TextCleanup
    let learning: CorrectionLearning
    let dockIcon: DockIcon
    let updater: AppUpdater
    /// The parts of Meeting Interpretation, nil where its page is shown without them.
    var captions: MeetingCaptions? = nil
    var speech: TranslationSpeech? = nil
    var voiceModels: VoiceModels? = nil
    /// The Projects switch, nil where the page is shown without it, which hides its tab.
    var projects: ProjectsSwitch? = nil
    @State private var tab = SettingsTab.general
    /// The part of the page to scroll to, until the page has scrolled there.
    @State private var scrollTarget: SettingsSection?
    /// The sidebar always shows, like the one of System Settings. Without it a user who drags
    /// the divider to the edge, or picks Hide Sidebar, has no way back to the other tabs.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // A click on the empty part of the sidebar keeps the tab that is shown.
            List(SettingsTab.visible(projectsVisible: projectsVisible), selection: Binding<SettingsTab?>(
                get: { tab },
                set: { if let new = $0 { tab = new } }
            )) { tab in
                SettingsTabLabel(tab: tab)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            page(for: tab)
        }
        .onChange(of: columns) { _, new in
            if new != .all { columns = .all }
        }
        // A window that opens shows the tab and the part asked for, and one that is open
        // already turns to them.
        .onAppear(perform: takeRequest)
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.showNotification)) { _ in
            takeRequest()
        }
        .frame(minWidth: 680, idealWidth: SettingsWindow.defaultSize.width, maxWidth: .infinity, minHeight: 440, idealHeight: SettingsWindow.defaultSize.height, maxHeight: .infinity)
    }

    /// Whether the sidebar shows Projects: in builds that show it, with its switch at hand.
    private var projectsVisible: Bool {
        projects?.isVisible ?? false
    }

    private func takeRequest() {
        let request = SettingsWindow.takeRequest()
        tab = request.tab.shown(projectsVisible: projectsVisible)
        scrollTarget = request.section
    }

    /// The page on the right of the sidebar. `section` stands in for the part the window
    /// was asked to scroll to, for a page drawn outside the window.
    @ViewBuilder
    func page(for tab: SettingsTab, scrollingTo section: Binding<SettingsSection?>? = nil) -> some View {
        switch tab {
        case .general:
            GeneralSettings(pushToTalk: pushToTalk, inputs: inputs, feedback: feedback, openAtLogin: openAtLogin, cleanup: cleanup, dockIcon: dockIcon, scrollTarget: section ?? $scrollTarget)
        case .dictation:
            DictationSettings(pushToTalk: pushToTalk, cleanup: cleanup, learning: learning)
        case .translation:
            TranslationSettings(pushToTalk: pushToTalk, cleanup: cleanup)
        case .meeting:
            MeetingInterpretationSettings(pushToTalk: pushToTalk, captions: captions, speech: speech, voiceModels: voiceModels, cleanup: cleanup)
        case .vocabulary:
            VocabularySettings(pushToTalk: pushToTalk, learning: learning)
        case .projects:
            if let projects {
                ProjectsSettings(projects: projects, cleanup: cleanup)
            }
        case .about:
            AboutSettings(models: models, pushToTalk: pushToTalk, updater: updater)
        }
    }
}

/// General: the system, the microphone and the keys, each in a block of its own. The
/// system comes first, with the two signs that Orra records, for either key. The keys come
/// last, and Change Talk Key… in the menu scrolls down to them. A setting shows one short
/// line under its name, and the rest of what it does when the pointer rests on it. The
/// page scrolls when the window is short.
private struct GeneralSettings: View {
    let pushToTalk: PushToTalkController
    let inputs: AudioInputList
    @Bindable var feedback: RecordingFeedback
    let openAtLogin: OpenAtLogin
    let cleanup: TextCleanup
    @Bindable var dockIcon: DockIcon
    /// The part to scroll to, set back to nil once the page has scrolled there.
    @Binding var scrollTarget: SettingsSection?

    /// The talk key's help in its mode. The line under the mode picker says how each mode
    /// works.
    private var talkKeyHelp: Text {
        if pushToTalk.talkMode == .hold {
            Text("Hold the talk key on its own, speak, and let go. A left Control, Option or Command key starts recording only after you hold it alone for a moment, so its shortcuts keep working.")
        } else {
            Text("Use the talk key on its own. A press together with another key is a shortcut and records nothing, so shortcuts with a left Control, Option or Command key keep working.")
        }
    }

    /// The translation key's help in its mode. A press in Double press records nothing, so
    /// only the other modes start recording at the press. Double press for hands free works
    /// only in Hold, so only then does the help name it.
    private var translationKeyHelp: Text {
        var help = Text("The translation key can be fn, Control, Option or Command on the left or right, or a combination. Pick the talk key and the two keys swap.") + Text(verbatim: "\n") + Text("Use the translation key on its own. A press together with another key is a shortcut and records nothing, so its shortcuts and the characters Option types keep working.")
        if pushToTalk.translationMode != .doubleTap {
            help = help + Text(verbatim: "\n") + Text("As fn or a right Control, Option or Command key, the translation key starts recording when you press it.")
        }
        if pushToTalk.translationMode == .hold {
            help = help + Text(verbatim: "\n") + Text("With Double press in Hold to keep recording on, press the translation key twice quickly and it keeps recording after you let go.")
        }
        return help
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    InterfaceLanguageRow()
                    Picker(selection: $feedback.onScreenHint) {
                        ForEach(OnScreenHint.choices(current: feedback.onScreenHint)) { hint in
                            Text(hint.title).tag(hint)
                        }
                    } label: {
                        DescribedLabel(
                            title: "On screen hint",
                            detail: "Bars at the bottom of the screen that move with your voice.",
                            systemImage: "waveform"
                        )
                    }
                    .help(Text("While you dictate, white bars at the bottom of the screen move with your voice, and say why when nothing is pasted. Always also keeps a small bar there while Orra is ready, which shows how to talk when you point at it."))
                    Toggle(isOn: $feedback.playsSounds) {
                        Label("Play sounds when recording starts and stops", systemImage: "speaker.wave.2")
                    }
                    Toggle(isOn: Binding(
                        get: { openAtLogin.isOn },
                        set: { openAtLogin.setOn($0) }
                    )) {
                        Label("Open at Login", systemImage: "power")
                    }
                    if openAtLogin.needsApproval {
                        Button("Allow Orra in Login Items…") {
                            openAtLogin.openSettings()
                        }
                    }
                    if let problem = openAtLogin.problem {
                        Text(verbatim: problem)
                            .foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $dockIcon.showsInDock) {
                        DescribedLabel(
                            title: "Show Orra in the Dock",
                            detail: "Orra is always in the menu bar. While this is off, it shows in the Dock only while one of its windows is open.",
                            systemImage: "dock.rectangle"
                        )
                    }
                } header: {
                    Text("System")
                }
                Section {
                    Picker(selection: Binding(
                        get: { pushToTalk.microphone?.uid ?? "" },
                        set: { uid in pushToTalk.setMicrophone(choice(forUID: uid)) }
                    )) {
                        Text(MicrophoneLabels.systemDefault(inputs.defaultInput, lidClosed: inputs.lidClosed)).tag("")
                        ForEach(inputs.inputs, id: \.uid) { input in
                            Text(MicrophoneLabels.device(input, lidClosed: inputs.lidClosed)).tag(input.uid)
                        }
                        if let chosen = pushToTalk.microphone, !inputs.inputs.contains(where: { $0.uid == chosen.uid }) {
                            Text(MicrophoneLabels.missing(chosen)).tag(chosen.uid)
                        }
                    } label: {
                        Label("Input device", systemImage: "mic")
                    }
                    .help(Text("While this microphone is not connected, Orra uses the system default. With the lid closed, a MacBook's own microphone is off."))
                } header: {
                    Text("Microphone")
                }
                Section {
                    // The note about swapped keys shows once, under the translation key.
                    TalkKeyRecorder(pushToTalk: pushToTalk, showsLabel: true, showsHint: false, showsSwap: false, showsShortcutNote: false)
                        .help(talkKeyHelp + Text(verbatim: "\n") + Text("Recommended: fn on a Mac's built in keyboard, right Control on an external keyboard."))
                    SecondTalkKeyPicker(pushToTalk: pushToTalk)
                    TriggerModePicker(pushToTalk: pushToTalk, slot: .talk)
                    VStack(alignment: .leading, spacing: 6) {
                        TalkKeyRecorder(pushToTalk: pushToTalk, slot: .translation, showsLabel: true, showsHint: false, showsShortcutNote: false)
                            // The key does nothing while translation is off.
                            .disabled(!cleanup.translationIsOn)
                        if !cleanup.translationIsOn {
                            Text("Turn on Translation on the Translation page to use this key.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .help(translationKeyHelp)
                    TriggerModePicker(pushToTalk: pushToTalk, slot: .translation)
                        .disabled(!cleanup.translationIsOn)
                    // An option of Hold, so it shows only while a key it works on is in Hold,
                    // right under the pickers that set it.
                    if pushToTalk.handsFreeApplies {
                        HandsFreeToggle(pushToTalk: pushToTalk)
                    }
                    LiveCaptionsShortcutRecorder(pushToTalk: pushToTalk)
                } header: {
                    Text("Keys")
                }
                .id(SettingsSection.keys)
            }
            .formStyle(.grouped)
            // A window that just opened, or a page that just turned, may not have laid out
            // its rows yet. So the page scrolls once now and once more a moment later, and
            // only then forgets the target.
            .task(id: scrollTarget) {
                guard let target = scrollTarget else { return }
                await Task.yield()
                proxy.scrollTo(target, anchor: .top)
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo(target, anchor: .top)
                scrollTarget = nil
            }
        }
        .navigationTitle("General")
        .onAppear { inputs.refresh() }
    }

    /// The choice for a UID from the picker. The empty tag is the system default.
    private func choice(forUID uid: String) -> MicrophoneChoice? {
        guard !uid.isEmpty else { return nil }
        if let input = inputs.inputs.first(where: { $0.uid == uid }) {
            return MicrophoneChoice(uid: input.uid, name: input.name)
        }
        return pushToTalk.microphone?.uid == uid ? pushToTalk.microphone : nil
    }
}

/// Double press for hands free, an option of Hold: with it on, a key in Hold still records
/// while held, and a quick double press keeps recording after the user lets go.
private struct HandsFreeToggle: View {
    let pushToTalk: PushToTalkController

    var body: some View {
        Toggle(isOn: Binding(
            get: { pushToTalk.handsFreeOn },
            set: { pushToTalk.setHandsFreeOn($0) }
        )) {
            DescribedLabel(
                title: "Double press in Hold to keep recording",
                detail: "Press a key in Hold mode twice quickly to keep recording after you let go.",
                systemImage: "hand.raised"
            )
        }
        .help(Text("With a key in Hold mode, press it twice quickly and Orra keeps recording after you let go. Press the key once more to paste, or Escape to cancel. Holding the key works as before."))
    }
}

/// The row under the switch of cleanup or of translation, while that switch is on and the
/// model is not ready: where the model stands, with its buttons. Its text starts where the
/// names of the rows do, behind the hidden `symbol` of the switch.
struct ModelStatusRow: View {
    let cleanup: TextCleanup
    let use: CleanupLabels.Use
    let symbol: String

    var body: some View {
        if CleanupLabels.status(cleanup.models.state, engine: cleanup.engineState, total: cleanup.models.manifest.totalBytes, use: use) != nil {
            Label {
                LocalModelStatus(cleanup: cleanup, use: use)
            } icon: {
                Image(systemName: symbol)
                    .hidden()
            }
        }
    }
}

/// The model's download and loading under the switch of cleanup or of translation, while
/// that switch is on: progress, Download or Try Again, or nothing once the model is ready.
private struct LocalModelStatus: View {
    let cleanup: TextCleanup
    let use: CleanupLabels.Use

    var body: some View {
        let total = cleanup.models.manifest.totalBytes
        let state = cleanup.models.state
        switch state {
        case .installed:
            switch cleanup.engineState {
            case .unloaded, .loading:
                Text(CleanupLabels.loading(use))
                    .foregroundStyle(.secondary)
            case .ready, .unloadedWhileIdle:
                EmptyView()
            case .failed:
                HStack {
                    Text(CleanupLabels.failedToLoad(use))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") {
                        Task { await cleanup.retryLoading() }
                    }
                }
            }
        case .checking:
            // A look at the files on disk, over in a moment.
            EmptyView()
        case .verifying:
            ForEach(state.menuLines(total: total), id: \.self) { line in
                Text(verbatim: line)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let bytes, let source):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(bytes), total: Double(max(total, 1))) {
                    Text(CleanupLabels.progress(bytes: bytes, total: total, use: use))
                } currentValueLabel: {
                    if let source {
                        Text(String(localized: "From \(source.rawValue)"))
                    }
                }
                Button("Cancel Download") {
                    cleanup.cancelDownload()
                }
            }
        case .missing, .failed:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CleanupLabels.lines(state, total: total, use: use), id: \.self) { line in
                        Text(verbatim: line)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button(CleanupLabels.downloadButton(state, total: total)) {
                    cleanup.download()
                }
            }
        }
    }
}

/// The text about the cleanup model's download, kept apart so tests can read it.
nonisolated enum CleanupLabels {
    /// Which page the text is for. Clean Up Text calls the model the cleanup model, and
    /// Translation calls the same model the local model.
    nonisolated enum Use: Equatable, Sendable {
        case cleanup
        case translation
    }

    static func progress(bytes: Int64, total: Int64, use: Use = .cleanup) -> String {
        let percent = ModelInstaller.State.percent(bytes, of: total)
        let size = ModelInstaller.State.size(total)
        return switch use {
        case .cleanup: String(localized: "Downloading the cleanup model: \(percent)% of \(size)")
        case .translation: String(localized: "Downloading the local model: \(percent)% of \(size)")
        }
    }

    static func loading(_ use: Use) -> String {
        switch use {
        case .cleanup: String(localized: "Loading the cleanup model…")
        case .translation: String(localized: "Loading the local model…")
        }
    }

    static func failedToLoad(_ use: Use) -> String {
        switch use {
        case .cleanup: String(localized: "The cleanup model could not be loaded")
        case .translation: String(localized: "The local model could not be loaded")
        }
    }

    /// Download with the size, or how much is left when part of it is on disk already.
    static func downloadButton(_ state: ModelInstaller.State, total: Int64) -> String {
        switch state {
        case .missing(let bytes) where bytes > 0:
            String(localized: "Resume Download (\(ModelInstaller.State.size(total - bytes)) left)")
        case .failed:
            String(localized: "Try Again")
        default:
            String(localized: "Download (\(ModelInstaller.State.size(total)))")
        }
    }

    /// What stands in the way while cleanup or translation is on and the model is not in
    /// place.
    static func lines(_ state: ModelInstaller.State, total: Int64, use: Use = .cleanup) -> [String] {
        switch (state, use) {
        case (.missing, .cleanup):
            [String(localized: "The cleanup model is not on this Mac yet. Until it is, Orra pastes the text without cleanup.")]
        case (.missing, .translation):
            [String(localized: "The local model is not on this Mac yet. Until it is, Orra pastes the text without translation.")]
        default:
            state.menuLines(total: total)
        }
    }

    /// One line on the page under Clean Up Text or Translation while it is on and the
    /// model is not ready, or nil once it is. The status row under the switch shows the details.
    static func status(_ state: ModelInstaller.State, engine: TextCleanup.EngineState, total: Int64, use: Use) -> String? {
        switch state {
        case .installed:
            switch engine {
            case .unloaded, .loading: loading(use)
            case .ready, .unloadedWhileIdle: nil
            case .failed: failedToLoad(use)
            }
        case .checking:
            nil
        case .downloading(let bytes, _):
            progress(bytes: bytes, total: total, use: use)
        case .verifying, .missing, .failed:
            lines(state, total: total, use: use).joined(separator: " ")
        }
    }
}

/// The user's words and names, laid out as System Settings shows text replacements: a
/// field to add a word, then the words in a table, over the full height of the window.
private struct VocabularySettings: View {
    let pushToTalk: PushToTalkController
    let learning: CorrectionLearning
    @State private var newTerm = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    // A visible box with the hint inside it, so it reads as a place to type.
                    TextField("New word", text: $newTerm, prompt: Text("Type a word or name, then press Return"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit(add)
                    Button(action: add) {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pushToTalk.vocabulary.count >= Vocabulary.maximumCount)
                }
            } footer: {
                Text("People, products and terms you use. Orra gives them to the speech model so it writes them your way. They stay on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                VocabularyTable(pushToTalk: pushToTalk, learning: learning)
            } header: {
                Text(verbatim: VocabularyList.summary(count: pushToTalk.vocabulary.count))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulary")
        .onAppear { fieldFocused = true }
    }

    private func add() {
        defer { fieldFocused = true }
        pushToTalk.addToVocabulary(newTerm)
        newTerm = ""
    }
}

/// The language of Orra's menus and windows, with Restart Orra while it differs from the one
/// Orra started in.
private struct InterfaceLanguageRow: View {
    @State private var language = AppLanguage.load()

    var body: some View {
        Picker(selection: $language) {
            ForEach(AppLanguage.allCases) { language in
                if let name = language.nativeName {
                    Text(verbatim: name).tag(language)
                } else {
                    Text("Same as the Mac").tag(language)
                }
            }
        } label: {
            Label("Interface language", systemImage: "globe")
        }
        .help(Text("The language of Orra's menus and windows."))
        .onChange(of: language) { _, language in
            language.save()
        }
        // The welcome window can change the language while Settings is open. The
        // vocabulary is saved on another thread, so changes are read on the main one.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
            let saved = AppLanguage.load()
            if saved != language {
                language = saved
            }
        }
        // Compared with what macOS loaded at launch, so a language picked in the welcome
        // window counts, and picking English on a Mac in English needs no restart.
        if language.localization() != AppLanguage.launchLocalization {
            HStack {
                Text("Orra shows the new language after it restarts.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restart Orra") {
                    AppLanguage.restart()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

extension OnScreenHint {
    /// The name in the picker.
    var title: LocalizedStringKey {
        switch self {
        case .always: "Always"
        case .whileDictating: "Only while dictating"
        case .off: "Off"
        case .whileReady: "Only while ready"
        }
    }
}

/// The version and its updates, the speech model, and what Orra does with speech.
private struct AboutSettings: View {
    let models: ModelInstaller
    let pushToTalk: PushToTalkController
    @Bindable var updater: AppUpdater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Orra")
                            .font(.headline)
                        // A build run from Xcode has the project's placeholder version.
                        Group {
                            if AppUpdater.updatesEnabled {
                                Text("Version \(Self.version)")
                            } else {
                                Text("Development build, updates are off")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Speech model") {
                    Text(modelStatus)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                // The line under the version says when a build run from Xcode has updates
                // off, see AppUpdater.updatesEnabled.
                Toggle(isOn: $updater.checksAutomatically) {
                    DescribedLabel(
                        title: "Check for updates automatically",
                        detail: "About once a day Orra asks GitHub for the latest version. Like any web request, the check carries your preferred languages, and nothing else about your Mac. Each update is installed only after you choose it.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(!AppUpdater.updatesEnabled)
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            } header: {
                Text("Updates")
            }
            Section {
                Text("Speech is turned into text on this Mac, and so is the optional cleanup. Orra goes online only to download the speech model or the cleanup model when you ask it to, and to check for updates when you allow it.")
                    .foregroundStyle(.secondary)
                Link("Source code and privacy details", destination: URL(string: "https://github.com/db-ol/Orra")!)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var modelStatus: LocalizedStringKey {
        switch models.state {
        case .installed:
            pushToTalk.modelState == .ready ? "Ready" : "Loading…"
        case .checking, .verifying:
            "Checking…"
        case .downloading:
            "Downloading…"
        case .missing, .failed:
            "Not downloaded"
        }
    }
}

/// One item per microphone in the menu, with a check mark on the one in use for Orra.
/// Choosing the checked item again changes nothing. A chosen microphone that is not
/// connected stays listed, so the user sees why the system default records instead.
struct MicrophoneToggles: View {
    let inputs: AudioInputList
    let chosen: MicrophoneChoice?
    let choose: (MicrophoneChoice?) -> Void

    var body: some View {
        Toggle(MicrophoneLabels.systemDefault(inputs.defaultInput, lidClosed: inputs.lidClosed), isOn: Binding(
            get: { chosen == nil },
            set: { if $0 { choose(nil) } }
        ))
        Divider()
        ForEach(inputs.inputs, id: \.uid) { input in
            Toggle(MicrophoneLabels.device(input, lidClosed: inputs.lidClosed), isOn: Binding(
                get: { chosen?.uid == input.uid },
                set: { if $0 { choose(MicrophoneChoice(uid: input.uid, name: input.name)) } }
            ))
        }
        if let chosen, !inputs.inputs.contains(where: { $0.uid == chosen.uid }) {
            Toggle(MicrophoneLabels.missing(chosen), isOn: .constant(true))
                .disabled(true)
        }
    }
}

/// The optional second talk key: None, or a single key that is neither the talk key nor the
/// translation key. It works just as the talk key does, in the talk key's mode.
private struct SecondTalkKeyPicker: View {
    let pushToTalk: PushToTalkController

    var body: some View {
        Picker(selection: Binding(
            get: { pushToTalk.secondTalkKey },
            set: { pushToTalk.setSecondTalkKey($0) }
        )) {
            Text("None").tag(TalkKey?.none)
            ForEach(pushToTalk.secondTalkKeyChoices) { key in
                Text(verbatim: key.fullName()).tag(TalkKey?.some(key))
            }
        } label: {
            DescribedLabel(
                title: "Second key",
                detail: "Handy when you switch to an external keyboard that never sends fn.",
                systemImage: "plus.rectangle.on.rectangle"
            )
        }
    }
}

/// How the key of one slot starts a dictation: hold, press to start and stop, or double
/// press, with a line that says how it works. A menu in Settings, and radio buttons in the
/// welcome window.
struct TriggerModePicker: View {
    let pushToTalk: PushToTalkController
    let slot: KeySlot
    /// Whether every mode shows as a radio button, with the line under them, in place of a
    /// menu.
    var showsEveryMode = false
    /// The language of the mode names, which the welcome window sets to the one picked
    /// there.
    @Environment(\.interfaceLocale) private var interfaceLocale

    private var mode: TriggerMode {
        slot == .talk ? pushToTalk.talkMode : pushToTalk.translationMode
    }

    private var title: LocalizedStringKey {
        slot == .talk ? "Talk key mode" : "Translation key mode"
    }

    private var detail: LocalizedStringKey {
        switch mode {
        case .hold: "Hold the key while you speak, and let go to paste."
        case .toggle: "Press the key once to start, and once more to paste. Escape cancels."
        case .doubleTap: "Press the key twice quickly to start, and once more to paste. Escape cancels."
        }
    }

    var body: some View {
        if showsEveryMode {
            VStack(alignment: .leading, spacing: 6) {
                picker {
                    Text(title)
                }
                .pickerStyle(.radioGroup)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            picker {
                DescribedLabel(title: title, detail: detail, systemImage: "hand.tap")
            }
        }
    }

    private func picker<PickerLabel: View>(@ViewBuilder label: () -> PickerLabel) -> some View {
        Picker(selection: Binding(
            get: { mode },
            set: { pushToTalk.setTriggerMode($0, for: slot) }
        )) {
            ForEach(TriggerMode.allCases) { mode in
                Text(verbatim: mode.title(in: interfaceLocale)).tag(mode)
            }
        } label: {
            label()
        }
    }
}

/// The key recorder, like the shortcut recorders of Mac apps: a field that shows the talk
/// key or the translation key, such as "⌥ Right Option (Alt)". Clicking it, or Change…,
/// starts recording, and the next key the user presses and releases on its own becomes
/// the key. A press that cannot be one shows why under the field, and so does a swap of
/// the two keys. The talk key's recorder is in Settings and in the welcome window, the
/// translation key's in Settings.
struct TalkKeyRecorder: View {
    let pushToTalk: PushToTalkController
    /// Which key this field shows and records.
    var slot: KeySlot = .talk
    /// Whether "Talk key" is shown in front of the field, as a row in Settings.
    var showsLabel = false
    /// Whether the line with the keys that work is shown under the field before the user
    /// starts recording. The settings page leaves it out to stay short.
    var showsHint = true
    /// Whether the note about swapped keys shows under the field. Settings shows it under
    /// one of its two fields only.
    var showsSwap = true
    /// Whether the line with the recommended keys is shown under the field.
    var showsRecommendation = false
    /// Whether the note that pressing the Live Captions shortcut may start a dictation of
    /// this key shows under the field. Settings shows it under the shortcut instead.
    var showsShortcutNote = true
    /// The language of the text built here, which the welcome window sets to the one
    /// picked there.
    @Environment(\.interfaceLocale) private var interfaceLocale
    /// Whether this recorder started the recording in progress. The welcome window and
    /// Settings each show one, and closing one must not end a recording started in the
    /// other.
    @State private var startedHere = false

    private var isRecording: Bool {
        pushToTalk.choosingKeySlot == slot
    }

    private var key: Hotkey {
        slot == .talk ? pushToTalk.talkKey : pushToTalk.translationKey
    }

    private var name: Text {
        slot == .talk ? Text("Talk key") : Text("Translation key")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLabel {
                LabeledContent {
                    fieldAndButton
                } label: {
                    // The field carries the same label for VoiceOver, so it is read once.
                    Label {
                        name
                    } icon: {
                        Image(systemName: slot == .talk ? "keyboard" : "character.bubble")
                    }
                    .accessibilityHidden(true)
                }
            } else {
                fieldAndButton
            }
            if isRecording {
                if let note = pushToTalk.keyChoiceRejection?.message(in: interfaceLocale, for: slot) {
                    // Already in the language of the window, so shown as it is.
                    // Orange on the icon only: orange text that small is too faint on a
                    // light background.
                    Label {
                        Text(verbatim: note)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // Also under a refused press, so the user sees which keys work.
                Text("Use fn, Control, Option or Command on its own, or a combination such as ⌃ ⌥ or ⇧ ⌘ D. Escape cancels.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if showsSwap, let swap = pushToTalk.keySwap {
                    // Already in the language of the window, so shown as it is.
                    Label {
                        Text(verbatim: swap.message(in: interfaceLocale))
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if showsShortcutNote, let shortcut = pushToTalk.liveCaptionsShortcut, pushToTalk.liveCaptionsShortcutMayStartDictation(with: slot) {
                    ShortcutDictationNote(shortcut: shortcut)
                }
                // Which keys can be the key, before the user starts recording.
                if showsHint {
                    Group {
                        if slot == .talk {
                            Text("The talk key can be fn, Control, Option or Command on the left or right, or a combination.")
                        } else {
                            Text("The translation key can be fn, Control, Option or Command on the left or right, or a combination. Pick the talk key and the two keys swap.")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showsRecommendation {
                Text("Recommended: fn on a Mac's built in keyboard, right Control on an external keyboard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear {
            if startedHere {
                pushToTalk.stopChoosingKey()
            }
        }
        .onChange(of: pushToTalk.choosingKeySlot) { old, new in
            guard old == slot, new != slot else { return }
            // VoiceOver reads a swap of the keys, which only shows as text under the field.
            if startedHere, new == nil, let swap = pushToTalk.keySwap {
                AccessibilityNotification.Announcement(swap.message(in: interfaceLocale)).post()
            }
            startedHere = false
        }
        .onChange(of: pushToTalk.keyChoiceRejection) { _, rejection in
            // VoiceOver reads a refused press, which only shows as text under the field.
            // Only the recorder that started the recording speaks, so it is said once.
            if startedHere, let note = rejection?.message(in: interfaceLocale, for: slot) {
                let keys = String(localized: LocalizedStringResource("Use fn, Control, Option or Command on its own, or a combination such as ⌃ ⌥ or ⇧ ⌘ D. Escape cancels.", locale: interfaceLocale))
                AccessibilityNotification.Announcement("\(note) \(keys)").post()
            }
        }
    }

    private var fieldAndButton: some View {
        HStack(spacing: 8) {
            Button(action: start) {
                field
            }
            .buttonStyle(.plain)
            // While recording, a click on the field ends the recording, as any click in
            // Orra does, rather than starting it again.
            .allowsHitTesting(!isRecording)
            .accessibilityLabel(name)
            .accessibilityValue(isRecording ? Text("Press a key or a combination") : Text(verbatim: key.fullName(in: interfaceLocale)))
            if isRecording {
                Button("Cancel") {
                    pushToTalk.stopChoosingKey()
                }
            } else {
                Button("Change…", action: start)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 4) {
            if isRecording {
                Text("Press a key or a combination")
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(verbatim: key.title(in: interfaceLocale))
                if let other = key.otherLabelInParentheses(in: interfaceLocale) {
                    Text(verbatim: other)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .modifier(RecorderFieldBox(isRecording: isRecording))
    }

    private func start() {
        pushToTalk.startChoosingKey(for: slot)
        startedHere = true
        // Only the field's value changes, which VoiceOver does not read on its own.
        AccessibilityNotification.Announcement(
            String(localized: LocalizedStringResource("Press a key or a combination. Use fn, Control, Option or Command on its own, or a combination such as ⌃ ⌥ or ⇧ ⌘ D. Escape cancels.", locale: interfaceLocale))
        ).post()
    }
}

/// The box around a recorder's field, like the shortcut fields of Mac apps, drawn in the
/// accent color while it records.
private struct RecorderFieldBox: ViewModifier {
    let isRecording: Bool
    var minWidth: CGFloat = 220

    func body(content: Content) -> some View {
        content
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: minWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isRecording ? 2 : 1)
            )
            .contentShape(Rectangle())
    }
}

/// The note that pressing the Live Captions shortcut may start a dictation for a moment,
/// since a key is a combination of modifiers only, all of them in the shortcut, such as
/// ⌃ ⌥ beside ⌃ ⌥ ⌘ C.
private struct ShortcutDictationNote: View {
    let shortcut: KeyCombination
    @Environment(\.interfaceLocale) private var interfaceLocale

    var body: some View {
        Label {
            Text("Pressing \(shortcut.title(in: interfaceLocale)) may start a dictation for a moment.")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Live Captions shortcut, recorded like the keys above it: a field that shows it, such
/// as "⌃ ⌥ ⌘ C", or None. Clicking the field starts recording, and the next shortcut the
/// user presses becomes it. A press that cannot be one shows why under the field. None
/// turns the shortcut off. A note warns when pressing it may start a dictation for a moment,
/// and when macOS refused it.
private struct LiveCaptionsShortcutRecorder: View {
    let pushToTalk: PushToTalkController
    @Environment(\.interfaceLocale) private var interfaceLocale
    /// Whether this row started the recording in progress, so only it speaks to VoiceOver
    /// and ends the recording when it goes away.
    @State private var startedHere = false

    private var isRecording: Bool {
        pushToTalk.isChoosingLiveCaptionsShortcut
    }

    private var shortcutName: Text {
        pushToTalk.liveCaptionsShortcut.map { Text(verbatim: $0.title(in: interfaceLocale)) } ?? Text("None")
    }

    private var prompt: LocalizedStringResource {
        LocalizedStringResource("Press a shortcut, such as ⌃ ⌥ ⌘ C. Escape cancels.", locale: interfaceLocale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                HStack(spacing: 8) {
                    Button(action: start) {
                        HStack(spacing: 4) {
                            if isRecording {
                                Text("Press a shortcut")
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                shortcutName
                                    .foregroundStyle(pushToTalk.liveCaptionsShortcut == nil ? HierarchicalShapeStyle.secondary : .primary)
                            }
                        }
                        // A shortcut is short, so the name beside it gets more room.
                        .modifier(RecorderFieldBox(isRecording: isRecording, minWidth: 160))
                    }
                    .buttonStyle(.plain)
                    // While recording, a click on the field ends the recording, as any click
                    // in Orra does, rather than starting it again.
                    .allowsHitTesting(!isRecording)
                    .accessibilityLabel(Text("Live Captions shortcut"))
                    .accessibilityValue(isRecording ? Text("Press a shortcut") : shortcutName)
                    if isRecording {
                        Button("Cancel") {
                            pushToTalk.stopChoosingKey()
                        }
                    } else if pushToTalk.liveCaptionsShortcut != nil {
                        Button("None") {
                            pushToTalk.setLiveCaptionsShortcut(nil)
                        }
                    }
                }
            } label: {
                // The field carries the same name for VoiceOver, so only the description is
                // read here. A long name wraps rather than being cut.
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Captions shortcut")
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                        Text("Turns Live Captions on and off from any app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "captions.bubble")
                        .accessibilityHidden(true)
                }
            }
            // Under the whole row, as the translation key's note, so the field keeps its
            // place beside the name.
            if isRecording {
                if let note = pushToTalk.shortcutChoiceRejection?.message(in: interfaceLocale) {
                    // Already in the language of the window, so shown as it is.
                    Label {
                        Text(verbatim: note)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let shortcut = pushToTalk.liveCaptionsShortcut {
                if pushToTalk.liveCaptionsShortcutRefused {
                    // Another app may hold the combination for itself.
                    Label {
                        Text("macOS refused \(shortcut.title(in: interfaceLocale)). Another app may already use it.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if pushToTalk.liveCaptionsShortcutMayStartDictation {
                    ShortcutDictationNote(shortcut: shortcut)
                }
            }
        }
        .onDisappear {
            if startedHere {
                pushToTalk.stopChoosingKey()
            }
        }
        .onChange(of: pushToTalk.isChoosingLiveCaptionsShortcut) { _, recording in
            if !recording {
                startedHere = false
            }
        }
        .onChange(of: pushToTalk.shortcutChoiceRejection) { _, rejection in
            // VoiceOver reads a refused press, which only shows as text under the field.
            if startedHere, let note = rejection?.message(in: interfaceLocale) {
                AccessibilityNotification.Announcement("\(note) \(String(localized: prompt))").post()
            }
        }
    }

    private func start() {
        pushToTalk.startChoosingLiveCaptionsShortcut()
        startedHere = true
        // Only the field's value changes, which VoiceOver does not read on its own.
        AccessibilityNotification.Announcement(String(localized: prompt)).post()
    }
}

#Preview {
    SettingsView(
        pushToTalk: PushToTalkController(
            capture: .live(),
            transcription: .qwen3(),
            insert: { _ in .nothingToInsert }
        ),
        inputs: AudioInputList { AudioInputList.Reading(inputs: [], defaultInput: nil, lidClosed: false) },
        feedback: RecordingFeedback(preferences: .init(), inputLevel: { 0 }, present: { _ in }, play: { _ in }, save: { _ in }),
        openAtLogin: .live(),
        models: .live(),
        cleanup: .live(),
        learning: CorrectionLearning(isOn: false, store: CorrectionStore(), watcher: CorrectionWatcher(), saveSetting: { _ in }, saveStore: { _ in }, addToVocabulary: { _ in .added }, removeFromVocabulary: { _ in }),
        dockIcon: DockIcon(showsInDock: true, save: { _ in }, setPolicy: { _ in }, hasOpenWindow: { true }),
        updater: AppUpdater(),
        projects: ProjectsSwitch()
    )
}
