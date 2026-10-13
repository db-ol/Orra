import AppKit
import Combine
import SwiftUI

/// What the settings window opens over its one page: the options of a row on the page, the
/// vocabulary, the advanced settings and About.
enum SettingsSheet: String, CaseIterable, Identifiable {
    case cleanup
    case translation
    case vocabulary
    case advanced
    case about

    var id: String { rawValue }
}

/// A setting's name with what it does in smaller text right under it, as System Settings
/// shows them, so the explanation sits next to its switch.
private struct DescribedLabel: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// The settings window: one page with the basics, as General in System Settings, and a
/// sheet for the options of a row, the vocabulary, the advanced settings and About.
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
    @State private var sheet: SettingsSheet?

    var body: some View {
        VStack(spacing: 0) {
            GeneralSettings(pushToTalk: pushToTalk, inputs: inputs, openAtLogin: openAtLogin, cleanup: cleanup) { sheet = $0 }
            Divider()
            HStack {
                Button("Advanced…") { sheet = .advanced }
                Spacer()
                Button("About Orra") { sheet = .about }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(item: $sheet) { sheet in
            content(for: sheet)
        }
        // A window that opens shows the sheet asked for, and one that is open already
        // turns to it.
        .onAppear {
            sheet = SettingsWindow.takeOpeningSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.showNotification)) { _ in
            sheet = SettingsWindow.takeOpeningSheet()
        }
        .frame(minWidth: 520, idealWidth: 600, maxWidth: .infinity, minHeight: 400, idealHeight: 480, maxHeight: .infinity)
    }

    /// What a sheet holds.
    @ViewBuilder
    func content(for sheet: SettingsSheet) -> some View {
        switch sheet {
        case .cleanup:
            CleanupOptions(pushToTalk: pushToTalk, cleanup: cleanup)
        case .translation:
            TranslationOptions(cleanup: cleanup)
        case .vocabulary:
            VocabularySettings(pushToTalk: pushToTalk, learning: learning)
        case .advanced:
            AdvancedSettings(pushToTalk: pushToTalk, feedback: feedback, learning: learning, dockIcon: dockIcon, updater: updater)
        case .about:
            AboutSettings(models: models, pushToTalk: pushToTalk)
        }
    }
}

/// The one page: the talk key, the microphone, the switches of the features with their
/// options, the vocabulary and opening at login.
private struct GeneralSettings: View {
    let pushToTalk: PushToTalkController
    let inputs: AudioInputList
    let openAtLogin: OpenAtLogin
    let cleanup: TextCleanup
    let open: (SettingsSheet) -> Void

    var body: some View {
        Form {
            Section {
                // The note about swapped keys shows once, under the translation key while it is
                // on the page.
                TalkKeyRecorder(pushToTalk: pushToTalk, showsLabel: true, showsHint: false, showsSwap: !cleanup.translationIsOn)
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
                    Label("Microphone", systemImage: "mic")
                }
                .help(Text("While this microphone is not connected, Orra uses the system default. With the lid closed, a MacBook's own microphone is off."))
            }
            Section {
                CleanupRow(cleanup: cleanup) { open(.cleanup) }
                TranslationRow(cleanup: cleanup) { open(.translation) }
                // Only while translation is on, since the key does nothing otherwise.
                if cleanup.translationIsOn {
                    TalkKeyRecorder(pushToTalk: pushToTalk, slot: .translation, showsLabel: true, showsHint: false)
                }
                LabeledContent {
                    HStack(spacing: 12) {
                        Group {
                            if pushToTalk.vocabulary.count == 1 {
                                Text("1 word")
                            } else {
                                Text("\(pushToTalk.vocabulary.count) words")
                            }
                        }
                        .foregroundStyle(.secondary)
                        Button("Edit…") { open(.vocabulary) }
                    }
                } label: {
                    Label("Vocabulary", systemImage: "character.book.closed")
                }
            }
            Section {
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
            }
        }
        .formStyle(.grouped)
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

/// The switch for cleanup with the local model and Options… for the rest. While the model
/// is on its way, one line under the name says where it stands.
private struct CleanupRow: View {
    @Bindable var cleanup: TextCleanup
    let showOptions: () -> Void

    var body: some View {
        let models = cleanup.models
        let total = models.manifest.totalBytes
        LabeledContent {
            HStack(spacing: 12) {
                Toggle("Clean up with a local model", isOn: Binding(
                    get: { cleanup.isOn },
                    set: { $0 ? cleanup.turnOn() : cleanup.turnOff() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                // Off while Orra looks for the model on disk, a moment at launch.
                .disabled(!cleanup.isOn && !cleanup.canTurnOn)
                Button("Options…", action: showOptions)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean Up Text")
                    if cleanup.isOn, let status = CleanupLabels.status(models.state, engine: cleanup.engineState, total: total, use: .cleanup) {
                        Text(verbatim: status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: "wand.and.sparkles")
            }
        }
        .alert("Download the cleanup model?", isPresented: $cleanup.isConfirmingDownload) {
            Button(CleanupLabels.downloadButton(models.state, total: total)) {
                cleanup.confirmDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model comes from Hugging Face or a mirror. Your text stays on this Mac.")
        }
    }
}

/// A sheet of the settings window: its title, a grouped form, and Done.
private struct SettingsSheetContent<Content: View>: View {
    let title: LocalizedStringKey
    var width: CGFloat = 540
    var height: CGFloat = 520
    /// Whether the user can make the sheet larger, for a long list.
    var resizable = false
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                content
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(
            minWidth: width, idealWidth: width, maxWidth: resizable ? .infinity : width,
            minHeight: resizable ? 400 : height, idealHeight: height, maxHeight: resizable ? .infinity : height
        )
    }
}

/// The options of cleanup: the local model, its download and loading, and the rules that
/// run on every dictation.
private struct CleanupOptions: View {
    let pushToTalk: PushToTalkController
    let cleanup: TextCleanup

    var body: some View {
        let size = ModelInstaller.State.size(cleanup.models.manifest.totalBytes)
        SettingsSheetContent(title: "Clean Up Text", height: 560) {
            Section {
                DescribedLabel(
                    title: "Clean up with a local model",
                    detail: "Removes fillers and applies spoken self corrections, such as “三点，哦不对，四点”. It needs a \(size) download and about 4 GB of memory, adds under a second to a short dictation and more to a long one, and runs on this Mac. Paste Original Text in the Orra menu brings back the text from before the cleanup.",
                    systemImage: "wand.and.sparkles"
                )
                if cleanup.isOn {
                    LocalModelStatus(cleanup: cleanup, use: .cleanup)
                }
            } header: {
                Text("Local model")
            }
            Section {
                Toggle(isOn: Binding(
                    get: { pushToTalk.removesFillerWords },
                    set: { pushToTalk.setRemovesFillerWords($0) }
                )) {
                    DescribedLabel(
                        title: "Remove filler words such as um and uh",
                        detail: "Removes um, uh and erm where they only fill a pause, and the same sounds in Chinese. Words that carry meaning stay as you said them.",
                        systemImage: "text.badge.minus"
                    )
                }
                Toggle(isOn: Binding(
                    get: { pushToTalk.writesNumbersAsDigits },
                    set: { pushToTalk.setWritesNumbersAsDigits($0) }
                )) {
                    DescribedLabel(
                        title: "Write numbers as digits",
                        detail: "Numbers spoken in Chinese, such as dates, times, prices and percentages, are written as digits. Small counts, rough numbers and idioms stay in words.",
                        systemImage: "number"
                    )
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("The rules run on every dictation, with or without the local model, and before it.")
                    .foregroundStyle(.secondary)
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
            case .ready:
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
    /// model is not ready, or nil once it is. Options… shows the details.
    static func status(_ state: ModelInstaller.State, engine: TextCleanup.EngineState, total: Int64, use: Use) -> String? {
        switch state {
        case .installed:
            switch engine {
            case .unloaded, .loading: loading(use)
            case .ready: nil
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

/// The switch for translation with the translation key and Options… for the rest, as for
/// cleanup. While the model is on its way, one line under the name says where it stands.
private struct TranslationRow: View {
    @Bindable var cleanup: TextCleanup
    let showOptions: () -> Void

    var body: some View {
        let models = cleanup.models
        let total = models.manifest.totalBytes
        LabeledContent {
            HStack(spacing: 12) {
                Toggle("Translate with the translation key", isOn: Binding(
                    get: { cleanup.translationIsOn },
                    set: { $0 ? cleanup.turnOnTranslation() : cleanup.turnOffTranslation() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                // Off while Orra looks for the model on disk, a moment at launch.
                .disabled(!cleanup.translationIsOn && !cleanup.canTurnOn)
                Button("Options…", action: showOptions)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translation")
                    if cleanup.translationIsOn, let status = CleanupLabels.status(models.state, engine: cleanup.engineState, total: total, use: .translation) {
                        Text(verbatim: status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: "translate")
            }
        }
        .alert("Download the model for translation?", isPresented: $cleanup.isConfirmingTranslationDownload) {
            Button(CleanupLabels.downloadButton(models.state, total: total)) {
                cleanup.confirmTranslationDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model comes from Hugging Face or a mirror. Your text stays on this Mac.")
        }
    }
}

/// The options of translation: what it does with the model's download and loading, the
/// direction, and what to expect.
private struct TranslationOptions: View {
    let cleanup: TextCleanup

    var body: some View {
        let size = ModelInstaller.State.size(cleanup.models.manifest.totalBytes)
        SettingsSheetContent(title: "Translation", height: 600) {
            Section {
                DescribedLabel(
                    title: "Translate with the translation key",
                    detail: "Hold the translation key, speak, and let go. Orra pastes what you said in the other language. It uses the local model of Clean Up Text, also while cleanup is off: a \(size) download that needs about 4 GB of memory and runs on this Mac.",
                    systemImage: "translate"
                )
                if cleanup.translationIsOn {
                    LocalModelStatus(cleanup: cleanup, use: .translation)
                }
            } header: {
                Text("Local model")
            }
            Section {
                Picker(selection: Binding(
                    get: { cleanup.translationDirection },
                    set: { cleanup.setTranslationDirection($0) }
                )) {
                    ForEach(TranslationDirection.allCases, id: \.self) { direction in
                        Text(direction.title).tag(direction)
                    }
                } label: {
                    DescribedLabel(
                        title: "Translate into",
                        detail: cleanup.translationDirection.detail,
                        systemImage: "arrow.left.arrow.right"
                    )
                }
            } header: {
                Text("Translation key")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The translation key can be fn, or Control, Option or Command on the left or right. Pick the talk key and the two keys swap.")
                    Text("The translation key waits a moment before it records, so its shortcuts and the characters Option types keep working. With Double press for hands free on, press it twice quickly to translate hands free.")
                }
                .foregroundStyle(.secondary)
            }
            Section {
                Label {
                    Text("Dictations over \(TranslationStep.maximumLength) characters are pasted without translation, and so is a translation that fails Orra's checks or takes too long, so nothing you say is lost.")
                } icon: {
                    Image(systemName: "text.badge.checkmark")
                }
                Label {
                    Text("Paste Original Text in the Orra menu brings back the text from before the translation, and Copy Last Dictation copies the translation.")
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
                Label {
                    Text("Orra never learns corrections from a translated paste.")
                } icon: {
                    Image(systemName: "character.cursor.ibeam")
                }
            } header: {
                Text("Good to know")
            }
            .foregroundStyle(.secondary)
        }
    }
}

extension TranslationDirection {
    /// The name in the picker.
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .english: "English"
        case .chinese: "Chinese"
        }
    }

    /// What the choice does, under the picker.
    var detail: LocalizedStringKey {
        switch self {
        case .automatic: "Chinese is translated into English, and English into Chinese. Mixed text goes by the language most of it is in."
        case .english: "Everything you say is pasted in English."
        case .chinese: "Everything you say is pasted in Chinese. Common English terms, such as PR or iPhone, may stay in English."
        }
    }
}

/// The user's words and names, laid out as System Settings shows text replacements: a
/// field to add a word, then the words in a table.
private struct VocabularySettings: View {
    let pushToTalk: PushToTalkController
    let learning: CorrectionLearning
    @State private var newTerm = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        SettingsSheetContent(title: "Vocabulary", width: 680, height: 600, resizable: true) {
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
        .onAppear { fieldFocused = true }
    }

    private func add() {
        defer { fieldFocused = true }
        pushToTalk.addToVocabulary(newTerm)
        newTerm = ""
    }
}

/// Everything that is set once or rarely: the language, hands free, what Orra shows and
/// plays while dictating, learning from corrections, the Dock icon and updates.
private struct AdvancedSettings: View {
    let pushToTalk: PushToTalkController
    @Bindable var feedback: RecordingFeedback
    @Bindable var learning: CorrectionLearning
    @Bindable var dockIcon: DockIcon
    @Bindable var updater: AppUpdater
    @State private var language = AppLanguage.load()

    var body: some View {
        SettingsSheetContent(title: "Advanced", width: 600, height: 640, resizable: true) {
            Section {
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
                // Compared with what macOS loaded at launch, so a language picked in the
                // welcome window counts, and picking English on a Mac in English needs no
                // restart.
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
            } header: {
                Text("Language")
            }
            Section {
                Toggle(isOn: Binding(
                    get: { pushToTalk.handsFreeOn },
                    set: { pushToTalk.setHandsFreeOn($0) }
                )) {
                    DescribedLabel(
                        title: "Double press for hands free",
                        detail: "Press the talk key twice quickly and Orra keeps recording after you let go. Press the key once more to paste, or Escape to cancel. Holding the key works as before.",
                        systemImage: "hand.raised"
                    )
                }
            } header: {
                Text("Talk Key")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hold the talk key on its own, speak, and let go. A left Control, Option or Command key starts recording only after you hold it alone for a moment, so its shortcuts keep working.")
                    Text("Recommended: fn on a Mac's built in keyboard, right Control on an external keyboard.")
                }
                .foregroundStyle(.secondary)
            }
            Section {
                Picker(selection: $feedback.onScreenHint) {
                    ForEach(OnScreenHint.choices(current: feedback.onScreenHint)) { hint in
                        Text(hint.title).tag(hint)
                    }
                } label: {
                    DescribedLabel(
                        title: "On screen hint",
                        detail: "While you dictate, white bars at the bottom of the screen move with your voice, and say why when nothing is pasted. Always also keeps a small bar there while Orra is ready, which shows how to talk when you point at it.",
                        systemImage: "waveform"
                    )
                }
                Toggle(isOn: $feedback.playsSounds) {
                    Label("Play sounds when recording starts and stops", systemImage: "speaker.wave.2")
                }
            } header: {
                Text("While you dictate")
            }
            Section {
                Toggle(isOn: $learning.isOn) {
                    DescribedLabel(
                        title: "Learn from my corrections",
                        detail: "When this is on, Orra reads the text of the field you dictated into for up to 3 minutes after each paste, while you are in that field, never a password field. When you fix a misheard word, Orra adds the right spelling to your vocabulary and shows a notice where you can undo it. Orra keeps only the word pairs, on this Mac. It works in apps that let macOS read their text, such as Notes, Mail and Safari, but not in some editors and terminals. There, copy the right word and add it from the Orra menu.",
                        systemImage: "character.cursor.ibeam"
                    )
                }
                if !learning.store.entries.isEmpty {
                    Button("Forget Learned Corrections") {
                        learning.removeAll()
                    }
                }
            } header: {
                Text("Learning")
            }
            Section {
                Toggle(isOn: $dockIcon.showsInDock) {
                    DescribedLabel(
                        title: "Show Orra in the Dock",
                        detail: "Orra is always in the menu bar. While this is off, it shows in the Dock only while one of its windows is open.",
                        systemImage: "dock.rectangle"
                    )
                }
            }
            Section {
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
                // A build run from Xcode never updates, see AppUpdater.updatesEnabled.
                if !AppUpdater.updatesEnabled {
                    Text("Development build, updates are off")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
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

/// The version, the speech model, and what Orra does with speech.
private struct AboutSettings: View {
    let models: ModelInstaller
    let pushToTalk: PushToTalkController

    var body: some View {
        SettingsSheetContent(title: "About Orra", height: 380) {
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
            }
            Section {
                LabeledContent("Speech model") {
                    Text(modelStatus)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Speech is turned into text on this Mac, and so is the optional cleanup. Orra goes online only to download the speech model or the cleanup model when you ask it to, and to check for updates when you allow it.")
                    .foregroundStyle(.secondary)
                Link("Source code and privacy details", destination: URL(string: "https://github.com/db-ol/Orra")!)
            }
        }
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

    private var key: TalkKey {
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
                Text("Use fn, Control, Option or Command on its own. Escape cancels.")
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
                // Which keys can be the key, before the user starts recording.
                if showsHint {
                    Group {
                        if slot == .talk {
                            Text("The talk key can be fn, or Control, Option or Command on the left or right.")
                        } else {
                            Text("The translation key can be fn, or Control, Option or Command on the left or right. Pick the talk key and the two keys swap.")
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
                let keys = String(localized: LocalizedStringResource("Use fn, Control, Option or Command on its own. Escape cancels.", locale: interfaceLocale))
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
            .accessibilityValue(isRecording ? Text("Press the key you want to hold") : Text(verbatim: key.fullName(in: interfaceLocale)))
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
                Text("Press the key you want to hold")
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
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isRecording ? 2 : 1)
        )
        .contentShape(Rectangle())
    }

    private func start() {
        pushToTalk.startChoosingKey(for: slot)
        startedHere = true
        // Only the field's value changes, which VoiceOver does not read on its own.
        AccessibilityNotification.Announcement(
            String(localized: LocalizedStringResource("Press the key you want to hold. Use fn, Control, Option or Command on its own. Escape cancels.", locale: interfaceLocale))
        ).post()
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
        updater: AppUpdater()
    )
}
