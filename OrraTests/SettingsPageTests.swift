import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orra

/// The page of the settings window, its sheets, and how the window is turned to one.
/// Serialized, since the sheet asked for is shared.
@MainActor
@Suite(.serialized)
struct SettingsPageTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let temporary = TemporaryModelFolders()

    @Test func aSheetAskedForOpensOnceAndSettingsOpensThePage() {
        SettingsWindow.show(.vocabulary)
        #expect(SettingsWindow.takeOpeningSheet() == .vocabulary)
        // Settings… after that opens on the page alone.
        #expect(SettingsWindow.takeOpeningSheet() == nil)
    }

    @Test func changeTalkKeyOpensThePageAlone() {
        SettingsWindow.show(.advanced)
        // Change Talk Key… closes a sheet that is open, since the talk key is on the page.
        SettingsWindow.show()
        #expect(SettingsWindow.takeOpeningSheet() == nil)
    }

    @Test func anOpenWindowIsToldToShowTheSheet() {
        let received = Received()
        // Posted on the main thread, so the observer runs before show returns.
        let observer = NotificationCenter.default.addObserver(forName: SettingsWindow.showNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { received.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        SettingsWindow.show(.cleanup)
        #expect(received.count == 1)
        #expect(SettingsWindow.takeOpeningSheet() == .cleanup)
    }

    /// A sheet opens at its own height in a tall window, and no taller than the window in
    /// a short one, but never shorter than the form needs to scroll.
    @Test func aSheetFitsInTheWindow() {
        #expect(SettingsSheetLimits.height(560, limit: 700) == 560)
        #expect(SettingsSheetLimits.height(560, limit: 376) == 376)
        #expect(SettingsSheetLimits.height(560, limit: 100) == SettingsSheetLimits.minimumHeight)
        #expect(SettingsSheetLimits.height(560, limit: .infinity) == 560)
    }

    /// The line under Clean Up Text on the page: nothing while cleanup has its model
    /// ready, and where the model stands otherwise.
    @Test func theCleanupRowSaysWhereTheModelStands() {
        #expect(CleanupLabels.status(.installed(URL(fileURLWithPath: "/")), engine: .ready, total: 100) == nil)
        #expect(CleanupLabels.status(.installed(URL(fileURLWithPath: "/")), engine: .loading, total: 100) == "Loading the cleanup model…")
        #expect(CleanupLabels.status(.installed(URL(fileURLWithPath: "/")), engine: .failed, total: 100) == "The cleanup model could not be loaded")
        #expect(CleanupLabels.status(.missing(bytesPresent: 0), engine: .unloaded, total: 100) == "The cleanup model is not on this Mac yet. Until it is, Orra pastes the text without cleanup.")
        #expect(CleanupLabels.status(.downloading(bytes: 50, source: nil), engine: .unloaded, total: 100)?.hasPrefix("Downloading the cleanup model: 50%") == true)
    }

    @MainActor
    private final class Received {
        var count = 0
    }

    /// Renders the page and each sheet of the settings window to a PNG, for a look at the
    /// layout without running the app. Off unless ORRA_SETTINGS_SNAPSHOTS names a folder to
    /// write to, which the test command passes as TEST_RUNNER_ORRA_SETTINGS_SNAPSHOTS. CI
    /// never sets it. Run with -testLanguage zh-Hans for the Chinese text.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_SETTINGS_SNAPSHOTS"] != nil))
    func renderThePageAndEverySheet() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        try await render(nil, cleanupOn: false, name: "\(language)-0-general")
        try await render(nil, cleanupOn: true, name: "\(language)-0-general-cleanup-on")
        try await render(.cleanup, cleanupOn: false, name: "\(language)-1-cleanup-options")
        try await render(.cleanup, cleanupOn: true, name: "\(language)-1-cleanup-options-on")
        try await render(.vocabulary, cleanupOn: false, name: "\(language)-2-vocabulary")
        try await render(.advanced, cleanupOn: false, name: "\(language)-3-advanced")
        try await render(.about, cleanupOn: false, name: "\(language)-4-about")
    }

    private var folder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRA_SETTINGS_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
    }

    /// The page for a nil sheet, or the sheet alone at its own size, since a sheet does not
    /// draw outside a window on screen.
    private func render(_ sheet: SettingsSheet?, cleanupOn: Bool, name: String) async throws {
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
        // The window's first size, and each sheet at the size it opens at over that window.
        let page = NSSize(width: 600, height: 400)
        let limit = page.height - SettingsSheetLimits.margin
        let content: AnyView = if let sheet {
            AnyView(view.content(for: sheet).environment(\.settingsSheetHeightLimit, limit))
        } else {
            AnyView(view)
        }
        let size = switch sheet {
        case nil: page
        case .cleanup: NSSize(width: 540, height: SettingsSheetLimits.height(560, limit: limit))
        case .vocabulary: NSSize(width: 680, height: SettingsSheetLimits.height(600, limit: limit))
        case .advanced: NSSize(width: 600, height: SettingsSheetLimits.height(640, limit: limit))
        case .about: NSSize(width: 540, height: SettingsSheetLimits.height(380, limit: limit))
        }
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        // A window that is never ordered front, so the view appears without showing.
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
