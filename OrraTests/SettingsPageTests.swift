import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orra

/// The tabs of the settings window and how the window is turned to one. Serialized, since
/// the request is shared.
@MainActor
@Suite(.serialized)
struct SettingsPageTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let temporary = TemporaryModelFolders()

    /// Seven pages with General first. A build that hides Projects shows the six without it,
    /// and one that shows it has Projects after Vocabulary.
    @Test func theSidebarHasSevenPagesWithGeneralFirst() {
        #expect(SettingsTab.allCases == [.general, .dictation, .translation, .meeting, .vocabulary, .projects, .about])
        #expect(SettingsTab.visible(projectsVisible: false) == [.general, .dictation, .translation, .meeting, .vocabulary, .about])
        #expect(SettingsTab.visible(projectsVisible: true) == [.general, .dictation, .translation, .meeting, .vocabulary, .projects, .about])
        // Each page has its own icon in its own color.
        #expect(Set(SettingsTab.allCases.map(\.symbol)).count == SettingsTab.allCases.count)
        #expect(Set(SettingsTab.allCases.map(\.tint)).count == SettingsTab.allCases.count)
        #expect(SettingsTab.projects.symbol == "briefcase.fill")
        #expect(SettingsTab.projects.tint == .teal)
        #expect(SettingsTab.allCases.filter(\.isPreview) == [.projects])
    }

    /// The sidebar shows Projects only with a switch from a build that shows it. A request
    /// for Projects opens its page there, and General everywhere else. Every other page opens
    /// as asked either way.
    @Test func projectsOpensItsPageOnlyWhereItShows() throws {
        let suite = "io.github.db-ol.OrraTests.settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("SettingsPageTests-\(UUID().uuidString)", isDirectory: true))
        let shown = SettingsView.tabs(projects: ProjectsSwitch(defaults: defaults, isVisible: true, storage: storage))
        let hidden = SettingsView.tabs(projects: ProjectsSwitch(defaults: defaults, isVisible: false, storage: storage))
        let missing = SettingsView.tabs(projects: nil)
        #expect(shown == [.general, .dictation, .translation, .meeting, .vocabulary, .projects, .about])
        #expect(hidden == [.general, .dictation, .translation, .meeting, .vocabulary, .about])
        #expect(missing == hidden)
        SettingsWindow.show(.projects)
        let request = SettingsWindow.takeRequest()
        #expect(request == .init(tab: .projects, section: nil))
        #expect(request.tab.shown(in: shown) == .projects)
        #expect(request.tab.shown(in: hidden) == .general)
        #expect(request.tab.shown(in: missing) == .general)
        for tab in SettingsTab.allCases where tab != .projects {
            #expect(tab.shown(in: hidden) == tab)
            #expect(tab.shown(in: shown) == tab)
        }
    }

    /// The lines of the Projects page: where the cleanup model stands, what Projects keeps
    /// and for how long, and the privacy page in the interface language.
    @Test func theProjectsPageSaysWhereTheModelAndTheDataStand() {
        #expect(ProjectsSettings.retention == "Projects keeps the text of each email and its explanation for 90 days after reading it, and a draft for 30 days after its last change. It keeps the rest of an email, such as its sender and subject, until 180 days after it read the newest email of its thread. It removes old data only while it is on.")
        #expect(ProjectsSettings.modelStatus(.installed(URL(fileURLWithPath: "/"))) == "On this Mac")
        #expect(ProjectsSettings.modelStatus(.installed(URL(fileURLWithPath: "/")), engine: .ready) == "On this Mac")
        // A model on this Mac that could not be loaded says so.
        #expect(ProjectsSettings.modelStatus(.installed(URL(fileURLWithPath: "/")), engine: .failed) == "Could not be loaded")
        #expect(ProjectsSettings.modelStatus(.missing(bytesPresent: 0)) == "Not on this Mac yet")
        #expect(ProjectsSettings.modelStatus(.failed(.offline)) == "Not on this Mac yet")
        #expect(ProjectsSettings.modelStatus(.downloading(bytes: 5, source: nil)) == "Downloading…")
        #expect(ProjectsSettings.modelStatus(.checking) == "Checking…")
        #expect(ProjectsSettings.stored(nil) == "Checking…")
        #expect(ProjectsSettings.stored(0) == "Nothing")
        #expect(ProjectsSettings.stored(1_500_000) == "1.5 MB")
        let pages = ["en", "zh-Hans", "ja", "es-419", "fr"].map { ProjectsSettings.privacyPage(for: $0).absoluteString }
        #expect(pages == [
            "https://github.com/db-ol/Orra/blob/main/docs/privacy.md",
            "https://github.com/db-ol/Orra/blob/main/docs/privacy.zh-CN.md",
            "https://github.com/db-ol/Orra/blob/main/docs/privacy.ja.md",
            "https://github.com/db-ol/Orra/blob/main/docs/privacy.es.md",
            "https://github.com/db-ol/Orra/blob/main/docs/privacy.md",
        ])
    }

    /// How to Use Projects opens the Projects section of the user guide in the interface
    /// language, English for any other, at the anchors the site links to.
    @Test func howToUseProjectsOpensTheGuideAtProjects() {
        let guides = ["en", "zh-Hans", "ja", "es-419", "fr"].map { ProjectsSettings.userGuidePage(for: $0) }
        #expect(guides.map { $0.absoluteString.components(separatedBy: "#")[0] } == [
            "https://github.com/db-ol/Orra/blob/main/docs/user-guide.md",
            "https://github.com/db-ol/Orra/blob/main/docs/user-guide.zh-CN.md",
            "https://github.com/db-ol/Orra/blob/main/docs/user-guide.ja.md",
            "https://github.com/db-ol/Orra/blob/main/docs/user-guide.es.md",
            "https://github.com/db-ol/Orra/blob/main/docs/user-guide.md",
        ])
        #expect(guides.map { $0.fragment(percentEncoded: false) } == ["projects-preview", "项目预览版", "プロジェクトプレビュー", "proyectos-vista-previa", "projects-preview"])
        // Percent encoded, as a browser sends it.
        #expect(guides[1].absoluteString.hasSuffix("#%E9%A1%B9%E7%9B%AE%E9%A2%84%E8%A7%88%E7%89%88"))
    }

    @Test func aTabAskedForOpensOnceAndSettingsOpensGeneral() {
        SettingsWindow.show(.vocabulary)
        #expect(SettingsWindow.takeRequest() == .init(tab: .vocabulary, section: nil))
        // Settings… after that opens on General alone.
        #expect(SettingsWindow.takeRequest() == .init(tab: .general, section: nil))
        // As Set Up in Settings… in the welcome window asks for it.
        SettingsWindow.show(.meeting)
        #expect(SettingsWindow.takeRequest() == .init(tab: .meeting, section: nil))
        #expect(SettingsWindow.takeRequest() == .init(tab: .general, section: nil))
        SettingsWindow.show(.translation)
        #expect(SettingsWindow.takeRequest() == .init(tab: .translation, section: nil))
    }

    /// Change Talk Key… and Change Translation Key… in the menu, and Change… beside the
    /// translation key on the Translation page, open General scrolled to Keys, which sit
    /// below the fold of the window's first size. Once.
    @Test func changeTalkKeyOpensGeneralAtTheKeys() {
        SettingsWindow.show(.general, section: .keys)
        #expect(SettingsWindow.takeRequest() == .init(tab: .general, section: .keys))
        #expect(SettingsWindow.takeRequest() == .init(tab: .general, section: nil))
    }

    @Test func anOpenWindowIsToldToTurn() {
        let received = Received()
        // Posted on the main thread, so the observer runs before show returns.
        let observer = NotificationCenter.default.addObserver(forName: SettingsWindow.showNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { received.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        SettingsWindow.show(.dictation)
        #expect(received.count == 1)
        #expect(SettingsWindow.takeRequest() == .init(tab: .dictation, section: nil))
    }

    /// The row of double press for hands free shows in Keys only while a key it works on is
    /// in Hold: the talk key, or the translation key while Translation is on.
    @Test func theHandsFreeRowShowsOnlyWhileAKeyIsInHold() {
        let pushToTalk = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert, talkMode: .toggle, translationMode: .hold)
        #expect(!pushToTalk.handsFreeApplies)
        pushToTalk.setTranslationKeyOn(true)
        #expect(pushToTalk.handsFreeApplies)
        pushToTalk.setTriggerMode(.toggle, for: .translation)
        #expect(!pushToTalk.handsFreeApplies)
        pushToTalk.setTriggerMode(.hold, for: .talk)
        #expect(pushToTalk.handsFreeApplies)
        pushToTalk.setTriggerMode(.doubleTap, for: .talk)
        #expect(!pushToTalk.handsFreeApplies)
    }

    /// The status row under the switch of Clean Up Text: nothing while cleanup has its
    /// model ready, and where the model stands otherwise.
    @Test func theCleanupRowSaysWhereTheModelStands() {
        #expect(CleanupLabels.status(.installed(URL(fileURLWithPath: "/")), engine: .ready, total: 100, use: .cleanup) == nil)
        #expect(CleanupLabels.status(.installed(URL(fileURLWithPath: "/")), engine: .loading, total: 100, use: .cleanup) == "Loading the cleanup model…")
        #expect(CleanupLabels.status(.installed(URL(fileURLWithPath: "/")), engine: .failed, total: 100, use: .cleanup) == "The cleanup model could not be loaded")
        #expect(CleanupLabels.status(.missing(bytesPresent: 0), engine: .unloaded, total: 100, use: .cleanup) == "The cleanup model is not on this Mac yet. Until it is, Orra pastes the text without cleanup.")
        #expect(CleanupLabels.status(.downloading(bytes: 50, source: nil), engine: .unloaded, total: 100, use: .cleanup)?.hasPrefix("Downloading the cleanup model: 50%") == true)
    }

    /// The target picker on the Translation page shows each direction with its
    /// explanation, and the row under it says where the model stands in the words of
    /// translation.
    @Test func everyDirectionHasATitleAndAnExplanation() {
        #expect(TranslationDirection.choices(for: .chinese) == [.automatic, .english, .chinese])
        let details = TranslationDirection.choices(for: .chinese).map { "\($0.detail)" }
        #expect(Set(details).count == details.count)
        // Each dictation language has its choices, each with its own explanation, and the
        // Chinese ones are those there always were.
        var all: Set<String> = []
        for language in DictationLanguage.allCases {
            let choices = TranslationDirection.choices(for: language)
            #expect(choices == [.automatic, .english, language.translationDirection])
            for direction in choices {
                all.insert("\(direction.detail(for: language))")
            }
        }
        #expect(all.count == 7)
        #expect(TranslationDirection.choices(for: .chinese).map { "\($0.detail(for: .chinese))" } == details)
        #expect("\(TranslationDirection.japanese.title)" != "\(TranslationDirection.spanish.title)")
        #expect(CleanupLabels.lines(.missing(bytesPresent: 0), total: 100, use: .translation) == ["The local model is not on this Mac yet. Until it is, Orra pastes the text without translation."])
        #expect(CleanupLabels.loading(.translation) == "Loading the local model…")
        #expect(CleanupLabels.loading(.cleanup) == "Loading the cleanup model…")
        #expect(CleanupLabels.progress(bytes: 50, total: 100, use: .translation).hasPrefix("Downloading the local model: 50%"))
        #expect(CleanupLabels.status(.installed(URL(fileURLWithPath: "/")), engine: .loading, total: 100, use: .translation) == "Loading the local model…")
    }

    @MainActor
    private final class Received {
        var count = 0
    }

    /// Renders each tab of the settings window to a PNG, for a look at the layout without
    /// running the app. Off unless ORRA_SETTINGS_SNAPSHOTS names a folder to write to, which
    /// the test command passes as TEST_RUNNER_ORRA_SETTINGS_SNAPSHOTS. CI never sets it. Run
    /// with -testLanguage zh-Hans for the Chinese text.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_SETTINGS_SNAPSHOTS"] != nil))
    func renderEveryTab() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        try await render(.general, name: "\(language)-0-general")
        try await render(.general, scrollingTo: .keys, name: "\(language)-0-general-keys")
        try await render(.general, translationOn: true, swapped: true, scrollingTo: .keys, name: "\(language)-0-general-translation-swapped")
        try await render(.general, talkMode: .toggle, scrollingTo: .keys, name: "\(language)-0-general-keys-without-hold")
        // A talk key of ⌃ ⌥ inside ⌃ ⌥ ⌘ C, with the note under the Live Captions shortcut.
        try await render(.general, talkKey: .combination(KeyCombination(modifiers: [.control, .option])), talkMode: .toggle, scrollingTo: .keys, name: "\(language)-0-general-keys-shortcut-note")
        try await render(.general, translationOn: true, height: 1200, name: "\(language)-0-general-full-height")
        try await render(.dictation, name: "\(language)-1-dictation")
        try await render(.dictation, cleanupOn: true, height: 1000, name: "\(language)-1-dictation-cleanup-on")
        try await render(.dictation, dictating: .japanese, height: 1000, name: "\(language)-1-dictation-japanese")
        try await render(.translation, name: "\(language)-2-translation")
        try await render(.translation, translationOn: true, name: "\(language)-2-translation-on")
        try await render(.translation, translationOn: true, dictating: .spanish, name: "\(language)-2-translation-spanish")
        try await render(.translation, translationOn: true, translationMode: .hold, name: "\(language)-2-translation-hold")
        try await render(.meeting, meeting: true, name: "\(language)-3-meeting-interpretation")
        try await render(.meeting, translationOn: true, meeting: true, height: 1200, name: "\(language)-3-meeting-interpretation-full-height")
        try await render(.vocabulary, name: "\(language)-4-vocabulary")
        try await render(.projects, name: "\(language)-5-projects")
        try await render(.projects, cleanupInstalled: true, projectsData: 1_500_000, name: "\(language)-5-projects-with-data")
        try await render(.projects, physicalMemory: 8 << 30, name: "\(language)-5-projects-8-gb")
        try await render(.projects, projectsOn: true, mail: .notAsked, height: 1000, name: "\(language)-5-projects-on")
        try await render(.projects, cleanupInstalled: true, projectsOn: true, mail: .allowed, height: 1100, name: "\(language)-5-projects-mailboxes")
        try await render(.projects, cleanupInstalled: true, projectsOn: true, mail: .allowed, reading: true, height: 1100, name: "\(language)-5-projects-mailboxes-reading")
        try await render(.projects, cleanupInstalled: true, projectsOn: true, mail: .denied, height: 1000, name: "\(language)-5-projects-mail-denied")
        try await render(.about, name: "\(language)-6-about")
        try await render(.about, height: 900, name: "\(language)-6-about-full-height")
    }

    /// Renders Set Up Projects in each state the spec of the checklist names, at the window's
    /// first width and at its smallest, 680 points, each as tall as the page, and the first
    /// one also at the window's first size and its smallest, to see what shows without
    /// scrolling. Off unless ORRA_SETTINGS_SNAPSHOTS names a folder, as above.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_SETTINGS_SNAPSHOTS"] != nil))
    func renderTheProjectsSetup() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        // The smallest size of the window, see SettingsView.
        let narrow: CGFloat = 680
        let tall: CGFloat = 1_400
        try await render(.projects, physicalMemory: 48 << 30, width: narrow, height: 440, name: "\(language)-7-setup-0-off-680")
        for width in [SettingsWindow.defaultSize.width, narrow] {
            let suffix = "-\(Int(width))"
            // On, with the model not on this Mac and Mail closed.
            try await render(.projects, projectsOn: true, mail: .notAsked, mailRunning: false, width: width, height: tall, name: "\(language)-7-setup-1-closed\(suffix)")
            // The model downloads, Mail is open and macOS was not asked yet.
            try await render(.projects, projectsOn: true, mail: .notAsked, downloading: true, width: width, height: tall, name: "\(language)-7-setup-2-downloading\(suffix)")
            // Allowed, with nothing ticked, then with a mailbox ticked.
            try await render(.projects, cleanupInstalled: true, projectsOn: true, mail: .allowed, ticks: false, width: width, height: tall, name: "\(language)-7-setup-3-allowed-unticked\(suffix)")
            try await render(.projects, cleanupInstalled: true, projectsOn: true, mail: .allowed, width: width, height: tall, name: "\(language)-7-setup-4-allowed-ticked\(suffix)")
            try await render(.projects, cleanupInstalled: true, projectsOn: true, mail: .denied, width: width, height: tall, name: "\(language)-7-setup-5-denied\(suffix)")
            // After Start Reading Mail, with Mail open, then after a restart with Mail closed.
            try await render(.projects, cleanupInstalled: true, projectsOn: true, mail: .allowed, reading: true, width: width, height: tall, name: "\(language)-7-setup-6-confirmed\(suffix)")
            try await render(.projects, cleanupInstalled: true, projectsOn: true, mail: .allowed, reading: true, mailRunning: false, remembers: false, width: width, height: tall, name: "\(language)-7-setup-7-returning\(suffix)")
        }
        try await render(.projects, projectsOn: true, mail: .notAsked, mailRunning: false, name: "\(language)-7-setup-1-closed-first-size")
        try await render(.projects, projectsOn: true, mail: .notAsked, mailRunning: false, width: narrow, height: 440, name: "\(language)-7-setup-1-closed-smallest-size")
    }

    /// The mailboxes of the stand in Mail: the two of all accounts, two of an account, and
    /// one On My Mac.
    private nonisolated static let snapshotMailboxes: [MailMailbox] = {
        let account = MailEvents.Specifier.textID(MailEvents.Code.account, "2B7E-account", of: .application)
        let mailbox = { (name: String, container: MailEvents.Specifier, account: String?) in
            MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, name, of: container), name: name, account: account)
        }
        return [.inbox, .sent, mailbox("Clients", account, "Studio"), mailbox("Archive/2026", account, "Studio"), mailbox("orra-test", .application, nil)]
    }()

    /// Mail access over a stand in Mail that never sends an Apple Event: macOS last answered
    /// `permission`, and the listing follows it. Mail runs unless `running` is false, and the
    /// bridge remembers the answer unless `remembers` is false, as after a restart. `projects`
    /// link their mailboxes, and Mail no longer has those in `missing`.
    private static func mailAccess(answering permission: MailPermission, running: Bool = true, remembers: Bool = true, defaults: UserDefaults, projects: [Project] = [], missing: Set<String> = [], isOn: @escaping () -> Bool) -> ProjectsSettings.MailAccess {
        let bridge = MailBridge(
            isRunning: { running },
            permission: { _ in permission },
            lastPermission: { remembers ? permission : nil },
            accounts: { [] },
            mailboxes: {
                switch permission {
                case .allowed: return snapshotMailboxes
                case .denied: throw MailBridgeError.denied
                default: throw MailBridgeError.notAsked
                }
            },
            count: { _ in 0 },
            listing: { _, _ in [] },
            headers: { _ in "" },
            source: { _ in "" },
            attachments: { _ in [] },
            mailbox: { _ in throw MailBridgeError.notFound },
            selection: { [] },
            reply: { _, _ in nil },
            attach: { _, _ in }
        )
        return ProjectsSettings.MailAccess(bridge: bridge, choice: MailChoice(defaults: defaults, suggestsInboxAndSent: false), projects: { projects }, missingMailboxes: { missing }, isOn: isOn)
    }

    private var folder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRA_SETTINGS_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
    }

    /// A tab in the whole window, at the window's first size or `height`. With `meeting`,
    /// the Meeting Interpretation page has its parts, with captions that hear nothing and a
    /// voice model that is not downloaded. `dictating` is the dictation language picked,
    /// `talkKey`, `talkMode` and `translationMode` the talk key and the modes of the keys, and
    /// `section` the part the page scrolls to. The Projects page shows on a Mac with
    /// `physicalMemory`, with a cleanup model in place when `cleanupInstalled`, and with
    /// `projectsData` bytes kept, in folders of its own, and on with `projectsOn`. With
    /// `mail`, it shows Mail access as macOS last answered it, over a stand in Mail with a
    /// few made up mailboxes, one of them ticked and another linked to a project once access
    /// is allowed, unless `ticks` is false, and the choice confirmed with `reading`, where the
    /// project also links a mailbox that Mail no longer has. `mailRunning` and `remembers`
    /// say whether Mail runs and whether the bridge remembers the answer, see
    /// `mailAccess(answering:)`. With `downloading`, the cleanup model downloads from a
    /// stand in that never finishes. The window is `width` wide.
    private func render(_ tab: SettingsTab, cleanupOn: Bool = false, translationOn: Bool = false, swapped: Bool = false, meeting: Bool = false, dictating: DictationLanguage = .chinese, talkKey: Hotkey = .defaultKey, talkMode: TriggerMode = .hold, translationMode: TriggerMode = .newTranslationKeyMode, cleanupInstalled: Bool = false, physicalMemory: UInt64 = 48 << 30, projectsData: Int = 0, projectsOn: Bool = false, mail: MailPermission? = nil, reading: Bool = false, ticks: Bool = true, mailRunning: Bool = true, remembers: Bool = true, downloading: Bool = false, scrollingTo section: SettingsSection? = nil, width: CGFloat = SettingsWindow.defaultSize.width, height: CGFloat? = nil, name: String) async throws {
        // The real model's files in an empty folder, so the page shows its size and that
        // it is missing, or the files of the test model in place. A download gets half of
        // the first file and then waits until it is cancelled.
        let fetch = downloading
            ? FileFetch { _, _, _, size, _, progress in
                progress(size / 2)
                try await Task.sleep(for: .seconds(3_600))
            }
            : FileFetch { _, _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        let models = ModelInstaller(
            manifest: cleanupInstalled ? temporary.manifest : .qwen35Cleanup,
            folders: temporary.folders,
            environment: ModelDownload.Environment(fetch: fetch, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
        )
        if cleanupInstalled {
            try temporary.write(Array(TestModel.sizes.keys), to: temporary.installed)
        }
        await models.prepare()
        if downloading {
            models.download()
        }
        defer { models.cancel() }
        let projectsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsPageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectsRoot) }
        let storage = ProjectsStorage(root: projectsRoot)
        if projectsData > 0 {
            try storage.create()
            try Data(count: projectsData).write(to: storage.indexFolder.appendingPathComponent("projects.sqlite"))
        }
        let suite = "io.github.db-ol.OrraTests.settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let projects = ProjectsSwitch(defaults: defaults, isVisible: true, physicalMemory: physicalMemory, storage: storage)
        if projectsData > 0 || projectsOn {
            projects.turnOn()
        }
        let missing: Set<String> = reading ? ["/Harbor 2025"] : []
        let linked = mail == .allowed ? ProjectsRuntime.mailboxName(Self.snapshotMailboxes[3]).map { [Project(name: "Harbor lobby", mailboxes: [$0] + missing.sorted())] } ?? [] : []
        let projectsMail = mail.map { Self.mailAccess(answering: $0, running: mailRunning, remembers: remembers, defaults: defaults, projects: linked, missing: missing, isOn: { projects.isOn }) }
        if mail == .allowed, let projectsMail {
            await projectsMail.show()
            if ticks {
                projectsMail.choose(Self.snapshotMailboxes[2], true)
            }
            if reading {
                // As Start Reading Mail confirmed it, also before a restart with Mail closed.
                projectsMail.choice.confirm()
            }
        }
        let cleanup = TextCleanup(
            isOn: cleanupOn,
            save: { _ in },
            translationIsOn: translationOn,
            models: models,
            engine: CleanupEngine(load: { _ in }, unload: {}, complete: { $0 })
        )
        let pushToTalk = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKey: talkKey,
            talkMode: talkMode,
            translationMode: translationMode,
            // The default on a US layout, never registered, since the controller never starts.
            liveCaptionsShortcut: LiveCaptionsShortcut.defaultShortcut(keyCodeForC: 0x08),
            dictationLanguage: dictating
        )
        // As AppDelegate keeps them in step.
        cleanup.setDictationLanguage(dictating)
        for word in ["Orra", "Qwen3-ASR", "克劳德"] {
            pushToTalk.addToVocabulary(word)
        }
        if swapped {
            // As after picking right Control, the talk key, for the translation key.
            pushToTalk.chooseTranslationKey(.rightControl)
        }
        let input = AudioInput(id: 1, uid: "built-in", name: "MacBook Pro Microphone", isInternalMicrophone: true)
        let view = SettingsView(
            pushToTalk: pushToTalk,
            inputs: AudioInputList { AudioInputList.Reading(inputs: [input], defaultInput: input, lidClosed: false) },
            feedback: RecordingFeedback(preferences: .init(), inputLevel: { 0 }, present: { _ in }, play: { _ in }, save: { _ in }),
            openAtLogin: OpenAtLogin(readStatus: { .off }, register: { _ in }, openLoginItemsSettings: {}),
            models: models,
            cleanup: cleanup,
            learning: CorrectionLearning(isOn: false, store: CorrectionStore(), watcher: CorrectionWatcher(), saveSetting: { _ in }, saveStore: { _ in }, addToVocabulary: { _ in .added }, removeFromVocabulary: { _ in }),
            dockIcon: DockIcon(showsInDock: true, save: { _ in }, setPolicy: { _ in }, hasOpenWindow: { true }),
            updater: AppUpdater(),
            captions: meeting ? MeetingCaptions(
                source: SystemAudioSource(start: { _ in }, stop: {}),
                engines: CaptionEngines(isSpeechReady: { true }, transcribe: { _, _ in "" }, canTranslate: { false }, target: { .chinese }, translate: { text, _ in text })
            ) : nil,
            speech: meeting ? TranslationSpeech(engines: .only(FakeSynthesizer()), playback: FakePlayback(), outputs: { [] }, folders: { nil }) : nil,
            voiceModels: meeting ? VoiceModels(kind: .qwen3) { [temporary] manifest in
                ModelInstaller(manifest: manifest, folders: temporary.folders, environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in throw URLError(.notConnectedToInternet) }, freeSpace: { _ in nil }, sleep: { _ in }))
            } : nil,
            projects: projects,
            projectsMail: projectsMail,
            openProjectsWindow: {},
            editProject: { _ in },
            openMail: {}
        )
        // The window's first size, or as wide as asked.
        let size = NSSize(width: width, height: height ?? SettingsWindow.defaultSize.height)
        // The sidebar's list does not draw outside a window on screen, so its rows stand
        // next to the page in a plain column, at the sidebar's width.
        let content = HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.visible(projectsVisible: true)) { row in
                    SettingsTabLabel(tab: row)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(row == tab ? Color.secondary.opacity(0.2) : .clear))
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            view.page(for: tab, scrollingTo: .constant(section))
        }
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        // A window that is never ordered front, so the view appears without showing.
        let offscreen = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.contentView = hosting
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        offscreen.close()
    }
}
