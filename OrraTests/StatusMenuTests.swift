import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orra

/// The menu bar menu, read from the menu SwiftUI makes of StatusMenu: Live Captions under
/// a Meeting Interpretation heading, when the copy items and Speak Translations to Others
/// show, what the Talk Key submenu holds, and Projects… only while Projects is on.
@MainActor
struct StatusMenuTests {
    let mic = FakeMicrophone()
    let dictation = FakeSpeech()
    let inserter = FakeInserter()
    let temporary = TemporaryModelFolders()

    @Test func liveCaptionsIsAtTheTopLevelUnderItsHeading() throws {
        let lines = lines(translationOn: false, speakingOn: false)
        let heading = try #require(lines.firstIndex(of: "# Meeting Interpretation"))
        #expect(lines[heading - 1] == "---")
        // Off at every launch.
        #expect(Array(lines[heading...].prefix(3)) == ["# Meeting Interpretation", "Live Captions", "---"])
        #expect(!lines.contains("Meeting Interpretation >"))
        // The section brings its own dividers, so no two stand next to each other.
        #expect(!zip(lines, lines.dropFirst()).contains { $0 == "---" && $1 == "---" })
    }

    @Test func speakTranslationsShowsWithTranslationOrWhileOn() {
        #expect(meetingLines(translationOn: true, speakingOn: false) == ["Live Captions", "Speak Translations to Others"])
        #expect(meetingLines(translationOn: true, speakingOn: true) == ["Live Captions", "Speak Translations to Others (on)"])
        // After Translation was turned off, so the menu can still turn it off.
        #expect(meetingLines(translationOn: false, speakingOn: true) == ["Live Captions", "Speak Translations to Others (on)"])
        #expect(meetingLines(translationOn: false, speakingOn: false) == ["Live Captions"])
    }

    @Test func aBuildWithoutAVoiceModelHasNoSpeakTranslations() {
        #expect(meetingLines(translationOn: true, speakingOn: true, voiceModel: false) == ["Live Captions"])
    }

    @Test func copyCaptionsAndCopyPreviousCaptionsShowOnlyWithFinalSentences() {
        let store = CaptionStore()
        func shown() -> [String] {
            meetingLines(translationOn: false, speakingOn: false, store: store)
        }
        #expect(shown() == ["Live Captions"])
        // A line still being heard is nothing to copy yet.
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Hello", translation: .none, isInterim: true))
        #expect(shown() == ["Live Captions"])
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Hello everyone.", translation: .pending))
        #expect(shown() == ["Live Captions", "Copy Captions"])
        // Captions start again: the meeting is the previous one.
        store.startOver()
        #expect(shown() == ["Live Captions", "Copy Previous Captions"])
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Next slide please.", translation: .none))
        #expect(shown() == ["Live Captions", "Copy Captions", "Copy Previous Captions"])
    }

    /// The Live Captions shortcut shows as text after the name, not as a key equivalent.
    @Test func liveCaptionsShowsItsShortcut() throws {
        let shortcut = KeyCombination(modifiers: [.control, .option, .command], keyCode: 0x69)
        let item = try #require(menu(translationOn: false, speakingOn: false, shortcut: shortcut).items.first { $0.title.hasPrefix("Live Captions") })
        #expect(item.title == "Live Captions    ⌃ ⌥ ⌘ F13")
        #expect(item.keyEquivalent.isEmpty)
    }

    /// Double press for hands free left the menu. Settings shows it under Keys, and only
    /// while a key is in Hold.
    @Test func talkKeyHasNoHandsFreeSwitch() throws {
        let talkKey = try #require(menu(translationOn: true, speakingOn: false).items.first { $0.title == "Talk Key" }?.submenu)
        let lines = Self.lines(of: talkKey)
        #expect(lines.contains("Change Talk Key…"))
        #expect(lines.contains("Change Translation Key…"))
        #expect(!lines.contains { $0.localizedCaseInsensitiveContains("hands free") })
        // Nothing follows the last button, not even a divider.
        #expect(lines.last == "Change Translation Key…")
    }

    /// Projects… shows below Meeting Interpretation only while Projects is on, with the
    /// count of mail waiting for a reply.
    @Test func projectsShowsOnlyWhileItIsOnWithTheMailWaitingForAReply() async throws {
        let suite = "io.github.db-ol.OrraTests.status-menu-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatusMenuTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let storage = ProjectsStorage(root: root)
        let projects = ProjectsSwitch(defaults: defaults, isVisible: true, physicalMemory: 32 << 30, storage: storage)
        let runtime = Self.projects(projects, storage: storage, defaults: defaults)
        runtime.follow()
        #expect(!Self.lines(of: menu(translationOn: false, speakingOn: false, projects: runtime)).contains { $0.hasPrefix("Projects") })

        projects.turnOn()
        for _ in 0..<2_000 where runtime.phase != .on {
            try await Task.sleep(for: .milliseconds(5))
        }
        var lines = Self.lines(of: menu(translationOn: false, speakingOn: false, projects: runtime))
        let item = try #require(lines.firstIndex(of: "Projects…"))
        #expect(Array(lines[(item - 3)...(item + 2)]) == ["# Meeting Interpretation", "Live Captions", "---", "Projects…", "---", "Talk Key >"])

        // An email that asks the user something waits for a reply once sorted.
        let store = try #require(runtime.running?.store)
        try await store.save([MailStore.Message(
            messageID: "q@harbor.example", date: Date(timeIntervalSinceNow: -3_600),
            sender: MailStore.Person(name: "Mei Tan", address: "mei@harbor.example"),
            to: [MailStore.Person(address: "me@studio.example")], subject: "The plan",
            text: "Could you send the plan by Friday?", visibleText: "Could you send the plan by Friday?"
        )], ownAddresses: ["me@studio.example"], at: Date())
        runtime.requestSort()
        for _ in 0..<2_000 where runtime.replyDueCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        lines = Self.lines(of: menu(translationOn: false, speakingOn: false, projects: runtime))
        #expect(lines.contains("Projects (1 to Reply)…"))

        await projects.turnOff(keepingData: false)
        for _ in 0..<2_000 where runtime.phase != .off {
            try await Task.sleep(for: .milliseconds(5))
        }
        lines = Self.lines(of: menu(translationOn: false, speakingOn: false, projects: runtime))
        #expect(!lines.contains { $0.hasPrefix("Projects") })
        #expect(!zip(lines, lines.dropFirst()).contains { $0 == "---" && $1 == "---" })
    }

    /// Projects with a Mail that never runs and a model that is never there.
    private static func projects(_ projects: ProjectsSwitch, storage: ProjectsStorage, defaults: UserDefaults) -> ProjectsRuntime {
        let mail = MailBridge(
            isRunning: { false },
            permission: { _ in .mailNotRunning },
            lastPermission: { nil },
            accounts: { throw MailBridgeError.mailNotRunning },
            mailboxes: { throw MailBridgeError.mailNotRunning },
            count: { _ in throw MailBridgeError.mailNotRunning },
            listing: { _, _ in throw MailBridgeError.mailNotRunning },
            headers: { _ in throw MailBridgeError.mailNotRunning },
            source: { _ in throw MailBridgeError.mailNotRunning },
            attachments: { _ in throw MailBridgeError.mailNotRunning },
            mailbox: { _ in throw MailBridgeError.mailNotRunning },
            selection: { throw MailBridgeError.mailNotRunning },
            reply: { _, _ in throw MailBridgeError.mailNotRunning }
        )
        return ProjectsRuntime(projects: projects, dependencies: ProjectsRuntime.Dependencies(
            storage: storage,
            bridge: mail,
            choice: MailChoice(defaults: defaults, suggestsInboxAndSent: false),
            ownerOverride: { SortingService.Owner(addresses: ["me@studio.example"]) },
            language: .en,
            isDictating: { false },
            modelEnvironment: { _ in
                ProjectsModelEnvironment(
                    startJob: { _, _ in throw RewriteError.notLoaded },
                    readSlice: { _, _ in throw RewriteError.notLoaded },
                    writeBurst: { _, _ in throw RewriteError.notLoaded },
                    endJob: { _ in throw RewriteError.notLoaded },
                    isDictating: { false },
                    captionsOn: { false },
                    memoryPressure: { .normal },
                    voiceLoaded: { false },
                    physicalMemory: 32 << 30,
                    waitUntilLoaded: { false },
                    holdModel: {},
                    releaseModel: {},
                    sleep: { try await Task.sleep(for: $0) }
                )
            },
            modelIsInstalled: { false },
            loadTokenCounter: { nil },
            handoff: ReplyHandoff(copy: { _ in true }, mail: mail, isOrraActive: { true }, bringMailToFront: {}),
            watchesMemoryPressure: false,
            watchFolders: { _, _, _ in {} },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        ))
    }

    /// The lines under the Meeting Interpretation heading, up to the divider after them.
    private func meetingLines(translationOn: Bool, speakingOn: Bool, voiceModel: Bool = true, store: CaptionStore = CaptionStore()) -> [String] {
        let lines = lines(translationOn: translationOn, speakingOn: speakingOn, voiceModel: voiceModel, store: store)
        guard let heading = lines.firstIndex(of: "# Meeting Interpretation") else { return [] }
        return Array(lines[(heading + 1)...].prefix { $0 != "---" })
    }

    /// The menu's top level, one line for each item, see `lines(of:)`. Without
    /// Accessibility access and with the speech model not downloaded, as in a test.
    private func lines(translationOn: Bool, speakingOn: Bool, voiceModel: Bool = true, store: CaptionStore = CaptionStore()) -> [String] {
        Self.lines(of: menu(translationOn: translationOn, speakingOn: speakingOn, voiceModel: voiceModel, store: store))
    }

    /// One line for each item: "# " starts a section heading, " >" ends a submenu, " (on)"
    /// ends an item that is on, and "---" is a divider.
    private static func lines(of menu: NSMenu) -> [String] {
        menu.items.map { item in
            if item.isSeparatorItem { return "---" }
            if item.isSectionHeader { return "# " + item.title }
            if item.submenu != nil { return item.title + " >" }
            return item.state == .on ? item.title + " (on)" : item.title
        }
    }

    /// The menu SwiftUI makes of StatusMenu. No Live Captions shortcut unless one is given.
    private func menu(translationOn: Bool, speakingOn: Bool, voiceModel: Bool = true, store: CaptionStore = CaptionStore(), shortcut: KeyCombination? = nil, projects: ProjectsRuntime? = nil) -> NSMenu {
        // Projects off, in preferences of its own that nothing writes, removed at the end.
        let offSuite = "io.github.db-ol.OrraTests.status-menu-off-\(UUID().uuidString)"
        let offDefaults = UserDefaults(suiteName: offSuite)!
        defer { offDefaults.removePersistentDomain(forName: offSuite) }
        let pushToTalk = PushToTalkController(capture: mic.capture, transcription: dictation.transcription, insert: inserter.insert, liveCaptionsShortcut: shortcut)
        pushToTalk.setTranslationKeyOn(translationOn)
        let speech = TranslationSpeech(
            engines: voiceModel ? .only(FakeSynthesizer()) : .none,
            playback: FakePlayback(),
            outputs: { [] },
            folders: { nil },
            settings: TranslationSpeech.Settings(isOn: speakingOn)
        )
        let view = StatusMenu(
            pushToTalk: pushToTalk,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in throw URLError(.notConnectedToInternet) }, freeSpace: { _ in nil }, sleep: { _ in })
            ),
            captions: MeetingCaptions(
                source: SystemAudioSource(start: { _ in }, stop: {}),
                engines: CaptionEngines(isSpeechReady: { true }, transcribe: { _, _ in "" }, canTranslate: { false }, target: { .chinese }, translate: { text, _ in text }),
                store: store
            ),
            openAtLogin: OpenAtLogin(readStatus: { .off }, register: { _ in }, openLoginItemsSettings: {}),
            inputs: AudioInputList { AudioInputList.Reading(inputs: [], defaultInput: nil, lidClosed: false) },
            clipboard: ClipboardWord(read: { nil }, isDictating: { false }, vocabulary: { [] }),
            updater: AppUpdater(),
            speech: speech,
            projects: projects ?? Self.projects(
                ProjectsSwitch(defaults: offDefaults, isVisible: false),
                storage: ProjectsStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("StatusMenuTests-off", isDirectory: true)),
                defaults: offDefaults
            ),
            showWelcome: {},
            reportProblem: {},
            showProjects: {}
        )
        let menu = NSHostingMenu(rootView: view)
        menu.update()
        return menu
    }
}
