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
        case .general: "gearshape"
        case .microphone: "mic"
        case .vocabulary: "character.book.closed"
        case .about: "info.circle"
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
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(170)
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
        .frame(width: 660, height: 460)
    }
}

/// The talk keys, the feedback while dictating, Open at Login and the Dock icon.
private struct GeneralSettings: View {
    let pushToTalk: PushToTalkController
    @Bindable var feedback: RecordingFeedback
    let openAtLogin: OpenAtLogin
    @Bindable var dockIcon: DockIcon

    var body: some View {
        Form {
            Section {
                TalkKeyToggles(keys: pushToTalk.talkKeys, setKey: pushToTalk.setTalkKey)
            } header: {
                Text("Talk Key")
            } footer: {
                Text("Hold a key on its own, speak, and let go. fn (Globe) is at the bottom left of a MacBook keyboard. Right Control suits most external keyboards.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show the recording indicator", isOn: $feedback.showsIndicator)
                Toggle("Play sounds when recording starts and stops", isOn: $feedback.playsSounds)
                Toggle("Show a small bar at the bottom of the screen while Orra is ready", isOn: $feedback.showsIdleBar)
            } header: {
                Text("While you dictate")
            }
            Section {
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
                    Text(verbatim: problem)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show Orra in the Dock", isOn: $dockIcon.showsInDock)
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
