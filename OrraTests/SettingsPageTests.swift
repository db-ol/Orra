import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orra

/// The pages of the settings window and how the window is turned to one. Serialized, since
/// the page asked for is shared.
@MainActor
@Suite(.serialized)
struct SettingsPageTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let temporary = TemporaryModelFolders()

    @Test func theSidebarListsThePagesInOrder() {
        #expect(SettingsPage.allCases == [.general, .dictation, .cleanup, .vocabulary, .about])
    }

    @Test func everyPageHasItsOwnIconAndColor() {
        let symbols = SettingsPage.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
        let tints = SettingsPage.allCases.map(\.tint)
        #expect(Set(tints.map(\.description)).count == tints.count)
    }

    @Test func changeTalkKeyOpensDictationAndSettingsOpensGeneral() {
        SettingsWindow.show(.dictation)
        #expect(SettingsWindow.takeOpeningPage() == .dictation)
        // Settings… after that opens on General again.
        #expect(SettingsWindow.takeOpeningPage() == .general)
    }

    @Test func anOpenWindowIsToldToTurnToThePage() {
        let received = Received()
        // Posted on the main thread, so the observer runs before show returns.
        let observer = NotificationCenter.default.addObserver(forName: SettingsWindow.showPageNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { received.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        SettingsWindow.show(.cleanup)
        #expect(received.count == 1)
        #expect(SettingsWindow.takeOpeningPage() == .cleanup)
    }

    @MainActor
    private final class Received {
        var count = 0
    }

    /// Renders each page of the settings window to a PNG, for a look at the layout without
    /// running the app. Off unless ORRA_SETTINGS_SNAPSHOTS names a folder to write to, which
    /// the test command passes as TEST_RUNNER_ORRA_SETTINGS_SNAPSHOTS. CI never sets it. Run
    /// with -testLanguage zh-Hans for the Chinese pages.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_SETTINGS_SNAPSHOTS"] != nil))
    func renderEveryPage() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        for page in SettingsPage.allCases {
            try await render(page, cleanupOn: false, name: "\(language)-\(SettingsPage.allCases.firstIndex(of: page)!)-\(page.rawValue)")
        }
        try await render(.cleanup, cleanupOn: true, name: "\(language)-2-cleanup-on")
    }

    private var folder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRA_SETTINGS_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
    }

    private func render(_ page: SettingsPage, cleanupOn: Bool, name: String) async throws {
        // The real model's files in an empty folder, so the page shows its size and that
        // it is missing.
        let models = ModelInstaller(
            manifest: .qwen35Cleanup,
            folders: temporary.folders,
            environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in throw URLError(.notConnectedToInternet) }, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
        )
        await models.prepare()
        let cleanup = TextCleanup(
            isOn: cleanupOn,
            save: { _ in },
            models: models,
            engine: CleanupEngine(load: { _ in }, unload: {}, complete: { $0 })
        )
        let pushToTalk = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert)
        for word in ["Orra", "Qwen3-ASR", "克劳德"] {
            pushToTalk.addToVocabulary(word)
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
            updater: AppUpdater()
        )
        // The page alone, since the sidebar's list does not draw outside a window on screen.
        let size = NSSize(width: 590, height: 1000)
        let hosting = NSHostingView(rootView: view.detail(for: page).frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        // A window that is never ordered front, so the page appears without showing.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        window.close()
    }
}
