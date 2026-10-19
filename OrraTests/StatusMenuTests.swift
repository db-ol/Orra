import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orra

/// The menu bar menu, read from the menu SwiftUI makes of StatusMenu: Live Captions under
/// a Meeting Interpretation heading, when the copy items and Speak Translations to Others
/// show, and what the Talk Key submenu holds.
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

    /// The menu SwiftUI makes of StatusMenu.
    private func menu(translationOn: Bool, speakingOn: Bool, voiceModel: Bool = true, store: CaptionStore = CaptionStore()) -> NSMenu {
        let pushToTalk = PushToTalkController(capture: mic.capture, transcription: dictation.transcription, insert: inserter.insert)
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
                engines: CaptionEngines(isSpeechReady: { true }, transcribe: { _, _ in "" }, canTranslate: { false }, direction: { .automatic }, translate: { text, _ in text }),
                store: store
            ),
            openAtLogin: OpenAtLogin(readStatus: { .off }, register: { _ in }, openLoginItemsSettings: {}),
            inputs: AudioInputList { AudioInputList.Reading(inputs: [], defaultInput: nil, lidClosed: false) },
            clipboard: ClipboardWord(read: { nil }, isDictating: { false }, vocabulary: { [] }),
            updater: AppUpdater(),
            speech: speech,
            showWelcome: {},
            reportProblem: {}
        )
        let menu = NSHostingMenu(rootView: view)
        menu.update()
        return menu
    }
}
