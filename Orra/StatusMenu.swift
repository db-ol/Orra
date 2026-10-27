import SwiftUI

/// The menu shown from the menu bar item.
struct StatusMenu: View {
    let pushToTalk: PushToTalkController
    let models: ModelInstaller
    let captions: MeetingCaptions
    let openAtLogin: OpenAtLogin
    let inputs: AudioInputList
    let clipboard: ClipboardWord
    let updater: AppUpdater
    let speech: TranslationSpeech
    /// Projects: Open Projects Window while it is on, and Set Up Projects… while it is off on
    /// a Mac where it can be turned on.
    let projects: ProjectsRuntime
    let showWelcome: () -> Void
    let reportProblem: () -> Void
    let showProjects: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Above the talk key, so the download can start before Accessibility is granted.
        ModelMenuSection(models: models, pushToTalk: pushToTalk)
        if pushToTalk.isHotkeyActive {
            Text(pushToTalk.talkHint())
            if pushToTalk.translationKeyIsOn {
                Text(pushToTalk.translateHint())
            }
            if speech.state == .speaking {
                Button("Stop Speaking") {
                    speech.stop()
                }
            }
            if speech.isOn, let problem = speech.problem {
                Text(problem)
            }
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
            // One line each, since a menu item does not wrap.
            ForEach(pushToTalk.notices, id: \.self) { notice in
                Text(notice)
            }
            if let transcript = pushToTalk.lastTranscript {
                Button("Copy Last Dictation") {
                    ConcealedClipboard.copy(transcript, to: .general)
                }
            }
            if pushToTalk.originalText != nil {
                // The dictation as it was before the model translated it or cleaned it up.
                Button("Paste Original Text") {
                    Task { await pushToTalk.pasteOriginal() }
                }
            }
        } else {
            Text("The talk key needs Accessibility access")
            Button("Grant Accessibility Access…") {
                pushToTalk.promptForAccessibility()
            }
        }

        if let copied = clipboard.word {
            Divider()
            // Works in every app, also where Orra cannot read the text to learn from it.
            Button("Add “\(copied)” from the Clipboard to Vocabulary") {
                pushToTalk.addToVocabulary(copied)
                clipboard.clear()
            }
        }

        // A meeting where each side speaks another language: captions for what the other
        // side says, and a voice for what you say. At the top level, so captions turn on
        // without a submenu. A section draws its heading and the dividers above and below
        // it, so no Divider goes next to it.
        Section("Meeting Interpretation") {
            // The sound the Mac plays, transcribed and translated in a floating window. The
            // shortcut shows as text after the name. As a key equivalent of the item it
            // might turn captions on and off twice while the menu is open.
            Toggle(isOn: Binding(
                get: { captions.isOn },
                set: { captions.setOn($0) }
            )) {
                if let shortcut = pushToTalk.liveCaptionsShortcut {
                    Text("Live Captions") + Text(verbatim: "    \(shortcut.title())")
                } else {
                    Text("Live Captions")
                }
            }
            // The whole meeting the way the window shows it, also after the window is
            // closed, and the meeting before the last start. Each only when it has a
            // final sentence.
            if captions.store.hasFinalSentences {
                Button("Copy Captions") {
                    captions.copy(captions.store.transcript)
                }
            }
            if !captions.store.previous.isEmpty {
                Button("Copy Previous Captions") {
                    captions.copy(captions.store.previous)
                }
            }
            // Also while on after Translation was turned off, so the menu can turn it off.
            if speech.canSpeak, pushToTalk.translationKeyIsOn || speech.isOn {
                Toggle("Speak Translations to Others", isOn: Binding(
                    get: { speech.isOn },
                    set: { speech.setOn($0) }
                ))
            }
        }

        // Projects, only while it is on, with the count of mail waiting for a reply. It
        // names the window it opens and carries the outline of the icon of Projects in
        // Settings, as a symbol next to text, so it stands out among the lines of text. A
        // heading of its own would draw a second divider next to the one the section above
        // draws.
        if projects.showsMenuItem {
            Button {
                showProjects()
            } label: {
                Label(ProjectsWindowText.menuTitle(replyDue: projects.replyDueCount), systemImage: "briefcase")
            }
            Divider()
        } else if Self.offersProjectsSetup(projects.projects) {
            // Where Open Projects Window stands while Projects is on. It opens Settings on
            // Projects, as Change Talk Key… opens it on the keys.
            Button {
                NSApplication.shared.activate()
                SettingsWindow.show(.projects)
                openWindow(id: SettingsWindow.id)
            } label: {
                Label("Set Up Projects…", systemImage: "briefcase")
            }
            Divider()
        }

        Menu("Talk Key") {
            // A menu shows text as a line that cannot be clicked. The key is chosen by
            // pressing it, which a menu cannot do, so Settings does that.
            Text("Talk Key: \(pushToTalk.talkKey.fullName())")
            if let second = pushToTalk.secondTalkKey {
                Text("Second Key: \(second.fullName())")
            }
            // The keys are at the bottom of General, so the window scrolls to them.
            Button("Change Talk Key…") {
                NSApplication.shared.activate()
                SettingsWindow.show(.general, section: .keys)
                openWindow(id: SettingsWindow.id)
            }
            if pushToTalk.translationKeyIsOn {
                Text("Translation Key: \(pushToTalk.translationKey.fullName())")
                Button("Change Translation Key…") {
                    NSApplication.shared.activate()
                    SettingsWindow.show(.general, section: .keys)
                    openWindow(id: SettingsWindow.id)
                }
            }
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

        // Also after setup, so Orra is ready and Try next stay in reach of a user who closed
        // the window during the download, or who set up Orra before 0.4.0 added Try next.
        Button(SetupChecklist(pushToTalk, models).menuTitle()) {
            showWelcome()
        }
        if let version = updater.waitingUpdate {
            Button("Install Orra \(version)…") {
                updater.checkForUpdates()
            }
        } else {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
        Button("Report a Problem…") {
            reportProblem()
        }
        Button("Settings…") {
            // An accessory app is not the active app when its menu is used. Activate
            // first, otherwise the window can open behind the frontmost app. The window
            // is a single one, so repeated calls bring the same window forward.
            NSApplication.shared.activate()
            openWindow(id: SettingsWindow.id)
        }

        Divider()

        Button("Quit Orra") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension StatusMenu {
    /// Whether the menu offers Set Up Projects…: while Projects is off, in a build that shows
    /// it, on a Mac with the memory it needs. ProjectsSwitch is observable, so the menu
    /// follows the switch.
    static func offersProjectsSetup(_ projects: ProjectsSwitch) -> Bool {
        projects.canTurnOn && !projects.isOn
    }

    /// The Dock icon's menu while Projects is on: Open Projects Window, as in the menu bar
    /// menu, so a user who looks in the Dock finds the window too. Nil while Projects is
    /// off, which leaves macOS's own items alone.
    static func dockMenu(projects: ProjectsRuntime, target: AnyObject, action: Selector) -> NSMenu? {
        guard projects.showsMenuItem else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: ProjectsWindowText.menuTitle(replyDue: projects.replyDueCount), action: action, keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        return menu
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
            case .unavailable(let problem):
                Text(verbatim: problem.message())
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
