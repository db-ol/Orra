import AppKit
import SwiftUI

/// The pages of the settings window, in the sidebar's order.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case microphone
    case vocabulary
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .microphone: "Microphone"
        case .vocabulary: "Vocabulary"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .microphone: "mic.fill"
        case .vocabulary: "character.book.closed.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The color behind the icon, as System Settings gives each pane its own.
    var tint: Color {
        switch self {
        case .general: .gray
        case .microphone: .orange
        case .vocabulary: .blue
        case .about: .indigo
        }
    }

    /// One line under the page's title.
    var summary: LocalizedStringKey {
        switch self {
        case .general: "Your language, the talk key, what you see and hear while dictating, and how Orra starts."
        case .microphone: "Which microphone Orra records from."
        case .vocabulary: "Words and names that Orra should write your way, and learning from your corrections."
        case .about: "Version, speech model, updates and privacy."
        }
    }
}

/// A symbol in a colored rounded square, as in the sidebar of System Settings.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.gradient))
            .accessibilityHidden(true)
    }
}

/// The top of each page: its icon, title and what it holds.
private struct PageHeader: View {
    let page: SettingsPage

    var body: some View {
        Section {
            HStack(spacing: 14) {
                SettingsIcon(symbol: page.symbol, tint: page.tint, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title)
                        .font(.title2.weight(.semibold))
                    Text(page.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The settings window: a sidebar with one page per topic, like System Settings.
struct SettingsView: View {
    let pushToTalk: PushToTalkController
    let inputs: AudioInputList
    @Bindable var feedback: RecordingFeedback
    let openAtLogin: OpenAtLogin
    let models: ModelInstaller
    let learning: CorrectionLearning
    let dockIcon: DockIcon
    let updater: AppUpdater
    @State private var page: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { page in
                Label {
                    Text(page.title)
                } icon: {
                    SettingsIcon(symbol: page.symbol, tint: page.tint)
                }
                .padding(.vertical, 2)
                .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch page ?? .general {
            case .general:
                GeneralSettings(pushToTalk: pushToTalk, feedback: feedback, openAtLogin: openAtLogin, dockIcon: dockIcon)
            case .microphone:
                MicrophoneSettings(pushToTalk: pushToTalk, inputs: inputs)
            case .vocabulary:
                VocabularySettings(pushToTalk: pushToTalk, learning: learning)
            case .about:
                AboutSettings(models: models, pushToTalk: pushToTalk, updater: updater)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 700, idealWidth: 780, maxWidth: .infinity, minHeight: 500, idealHeight: 620, maxHeight: .infinity)
    }
}

/// The talk keys, the feedback while dictating, Open at Login and the Dock icon.
private struct GeneralSettings: View {
    let pushToTalk: PushToTalkController
    @Bindable var feedback: RecordingFeedback
    let openAtLogin: OpenAtLogin
    @Bindable var dockIcon: DockIcon
    /// The language this copy of Orra started with, to tell when a restart is due.
    @State private var startedWith = AppLanguage.load()
    @State private var language = AppLanguage.load()

    var body: some View {
        Form {
            PageHeader(page: .general)
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
                if language != startedWith {
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
                TalkKeyToggles(keys: pushToTalk.talkKeys, setKey: pushToTalk.setTalkKey)
            } header: {
                Text("Talk Key")
            } footer: {
                Text("Hold a key on its own, speak, and let go. fn (Globe) is at the bottom left of a MacBook keyboard. Right Control suits most external keyboards.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $feedback.showsIndicator) {
                    Label("Show the recording indicator", systemImage: "waveform")
                }
                Toggle(isOn: $feedback.playsSounds) {
                    Label("Play sounds when recording starts and stops", systemImage: "speaker.wave.2")
                }
                Toggle(isOn: $feedback.showsIdleBar) {
                    Label("Show a small bar at the bottom of the screen while Orra is ready", systemImage: "minus.rectangle")
                }
                Toggle(isOn: Binding(
                    get: { pushToTalk.removesFillerWords },
                    set: { pushToTalk.setRemovesFillerWords($0) }
                )) {
                    Label("Remove filler words such as um and uh", systemImage: "text.badge.minus")
                }
                Toggle(isOn: Binding(
                    get: { pushToTalk.writesNumbersAsDigits },
                    set: { pushToTalk.setWritesNumbersAsDigits($0) }
                )) {
                    Label("Write numbers as digits", systemImage: "number")
                }
            } header: {
                Text("While you dictate")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Removes um, uh and erm where they only fill a pause, and the same sounds in Chinese. Words that carry meaning stay as you said them.")
                    Text("Numbers spoken in Chinese, such as dates, times, prices and percentages, are written as digits. Small counts, rough numbers and idioms stay in words.")
                }
                .foregroundStyle(.secondary)
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
                Toggle(isOn: $dockIcon.showsInDock) {
                    Label("Show Orra in the Dock", systemImage: "dock.rectangle")
                }
            } header: {
                Text("Starting and finding Orra")
            } footer: {
                Text("Orra is always in the menu bar. While this is off, it shows in the Dock only while one of its windows is open.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

/// Which microphone records.
private struct MicrophoneSettings: View {
    let pushToTalk: PushToTalkController
    let inputs: AudioInputList

    var body: some View {
        Form {
            PageHeader(page: .microphone)
            Section {
                Picker("Microphone", selection: Binding(
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
                }
            } footer: {
                Text("While this microphone is not connected, Orra uses the system default. With the lid closed, a MacBook's own microphone is off.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Microphone")
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

/// The user's words and names: a field to add one, and the list with a delete button
/// per word.
private struct VocabularySettings: View {
    let pushToTalk: PushToTalkController
    @Bindable var learning: CorrectionLearning
    @State private var newTerm = ""
    @State private var filter = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let terms = pushToTalk.vocabulary
        let shown = filter.isEmpty ? terms : terms.filter { $0.localizedCaseInsensitiveContains(filter) }
        Form {
            PageHeader(page: .vocabulary)
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
                    .disabled(terms.count >= Vocabulary.limit)
                }
            } footer: {
                Text("People, products and terms you use. Orra gives them to the speech model so it writes them your way. They stay on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if terms.count > 8 {
                    TextField("Search", text: $filter, prompt: Text("Search"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                if terms.isEmpty {
                    Text("No words yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.self) { term in
                    HStack {
                        Text(verbatim: term)
                        Spacer()
                        Button {
                            pushToTalk.setVocabulary(Vocabulary.removing(term, from: terms))
                            learning.removedFromVocabulary(term)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove")
                    }
                }
            } header: {
                Text("\(terms.count) of \(Vocabulary.limit) words")
            }
            Section {
                Toggle("Learn from my corrections", isOn: $learning.isOn)
                if !learning.store.entries.isEmpty {
                    Button("Forget Learned Corrections") {
                        learning.removeAll()
                    }
                }
            } header: {
                Text("Learning")
            } footer: {
                Text("When this is on, Orra reads the text of the field you dictated into for up to 3 minutes after each paste, while you are in that field, never a password field. When you fix a misheard word, Orra adds the right spelling to your vocabulary and shows a notice where you can undo it. Orra keeps only the word pairs, on this Mac. It works in apps that let macOS read their text, such as Notes, Mail and Safari, but not in some editors and terminals. There, copy the right word and add it from the Orra menu.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulary")
        .onAppear { fieldFocused = true }
    }

    private func add() {
        defer { fieldFocused = true }
        let updated = Vocabulary.adding(newTerm, to: pushToTalk.vocabulary)
        if updated != pushToTalk.vocabulary {
            pushToTalk.setVocabulary(updated)
        }
        newTerm = ""
    }
}

/// The version, the speech model, and what Orra does with speech.
private struct AboutSettings: View {
    let models: ModelInstaller
    let pushToTalk: PushToTalkController
    @Bindable var updater: AppUpdater

    var body: some View {
        Form {
            PageHeader(page: .about)
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Orra")
                            .font(.headline)
                        Text("Version \(Self.version)")
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
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            } footer: {
                Text("About once a day Orra asks GitHub for the latest version. Like any web request, the check carries your preferred languages, and nothing else about your Mac. Each update is installed only after you choose it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Speech is turned into text on this Mac. Orra goes online only to download the speech model when you ask it to, and to check for updates when you allow it.")
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

/// One switch per talk key, in the menu and in Settings. The last key that is on cannot be
/// turned off.
struct TalkKeyToggles: View {
    let keys: Set<TalkKey>
    let setKey: (TalkKey, Bool) -> Void

    var body: some View {
        ForEach(TalkKey.allCases) { key in
            Toggle(key.name, isOn: Binding(
                get: { keys.contains(key) },
                set: { setKey(key, $0) }
            ))
            .disabled(keys == [key])
        }
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
        learning: CorrectionLearning(isOn: false, store: CorrectionStore(), watcher: CorrectionWatcher(), saveSetting: { _ in }, saveStore: { _ in }, addToVocabulary: { _ in .added }, removeFromVocabulary: { _ in }),
        dockIcon: DockIcon(showsInDock: true, save: { _ in }, setPolicy: { _ in }, hasOpenWindow: { true }),
        updater: AppUpdater()
    )
}
