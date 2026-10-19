import Foundation
import Testing
@testable import Orra

/// The steps at launch that save what a user started with, so it stays when a later
/// version starts the setting another way. Each runs at every launch and leaves a saved
/// value alone.
@MainActor
struct LaunchMigrationsTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()

    private func controller(talkMode: TriggerMode, dictationLanguage: DictationLanguage) -> PushToTalkController {
        PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert, talkMode: talkMode, dictationLanguage: dictationLanguage)
    }

    /// A first launch has nothing saved, and saves the talk key's mode and the dictation
    /// language it started with.
    @Test func aFirstLaunchSavesWhatTheUserStartedWith() throws {
        try withTestDefaults("LaunchMigrations.first") { defaults in
            LaunchMigrations.run(controller(talkMode: .toggle, dictationLanguage: .japanese), in: defaults)
            #expect(TriggerModePreference.saved(for: .talk, in: defaults) == .toggle)
            #expect(DictationLanguagePreference.saved(in: defaults) == .japanese)
            // The translation key's mode is saved only when the user picks one.
            #expect(TriggerModePreference.saved(for: .translation, in: defaults) == nil)
        }
    }

    /// A later launch, or an update, never replaces what is saved.
    @Test func aSavedValueStays() throws {
        try withTestDefaults("LaunchMigrations.saved") { defaults in
            TriggerModePreference.save(.doubleTap, for: .talk, to: defaults)
            DictationLanguagePreference.save(.spanish, to: defaults)
            LaunchMigrations.run(controller(talkMode: .hold, dictationLanguage: .chinese), in: defaults)
            #expect(TriggerModePreference.saved(for: .talk, in: defaults) == .doubleTap)
            #expect(DictationLanguagePreference.saved(in: defaults) == .spanish)
        }
    }

    /// Running twice, as two launches do, gives what running once gives.
    @Test func runningAgainChangesNothing() throws {
        try withTestDefaults("LaunchMigrations.twice") { defaults in
            LaunchMigrations.run(controller(talkMode: .hold, dictationLanguage: .chinese), in: defaults)
            LaunchMigrations.run(controller(talkMode: .toggle, dictationLanguage: .japanese), in: defaults)
            #expect(TriggerModePreference.saved(for: .talk, in: defaults) == .hold)
            #expect(DictationLanguagePreference.saved(in: defaults) == .chinese)
        }
    }
}
