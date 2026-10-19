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

    private func controller(talkMode: TriggerMode, translationMode: TriggerMode = .newTranslationKeyMode, dictationLanguage: DictationLanguage) -> PushToTalkController {
        PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert, talkMode: talkMode, translationMode: translationMode, dictationLanguage: dictationLanguage)
    }

    /// A first launch has nothing saved, and saves the modes of both keys and the dictation
    /// language they started with.
    @Test func aFirstLaunchSavesWhatTheUserStartedWith() throws {
        try withTestDefaults("LaunchMigrations.first") { defaults in
            LaunchMigrations.run(controller(talkMode: .toggle, dictationLanguage: .japanese), in: defaults)
            #expect(TriggerModePreference.saved(for: .talk, in: defaults) == .toggle)
            #expect(TriggerModePreference.saved(for: .translation, in: defaults) == .toggle)
            #expect(DictationLanguagePreference.saved(in: defaults) == .japanese)
        }
    }

    /// An update for a user who turned Translation on before: the translation key loads in
    /// Hold, and the step keeps it there.
    @Test func anEarlierTranslationUserKeepsHold() throws {
        try withTestDefaults("LaunchMigrations.translation") { defaults in
            TranslationPreference.save(true, to: defaults)
            let translationMode = TriggerModePreference.load(for: .translation, setUpBefore: true, from: defaults)
            LaunchMigrations.run(controller(talkMode: .hold, translationMode: translationMode, dictationLanguage: .chinese), in: defaults)
            #expect(TriggerModePreference.saved(for: .translation, in: defaults) == .hold)
        }
    }

    /// A later launch, or an update, never replaces what is saved.
    @Test func aSavedValueStays() throws {
        try withTestDefaults("LaunchMigrations.saved") { defaults in
            TriggerModePreference.save(.doubleTap, for: .talk, to: defaults)
            TriggerModePreference.save(.hold, for: .translation, to: defaults)
            DictationLanguagePreference.save(.spanish, to: defaults)
            LaunchMigrations.run(controller(talkMode: .hold, translationMode: .toggle, dictationLanguage: .chinese), in: defaults)
            #expect(TriggerModePreference.saved(for: .talk, in: defaults) == .doubleTap)
            #expect(TriggerModePreference.saved(for: .translation, in: defaults) == .hold)
            #expect(DictationLanguagePreference.saved(in: defaults) == .spanish)
        }
    }

    /// Running twice, as two launches do, gives what running once gives.
    @Test func runningAgainChangesNothing() throws {
        try withTestDefaults("LaunchMigrations.twice") { defaults in
            LaunchMigrations.run(controller(talkMode: .hold, translationMode: .hold, dictationLanguage: .chinese), in: defaults)
            LaunchMigrations.run(controller(talkMode: .toggle, translationMode: .toggle, dictationLanguage: .japanese), in: defaults)
            #expect(TriggerModePreference.saved(for: .talk, in: defaults) == .hold)
            #expect(TriggerModePreference.saved(for: .translation, in: defaults) == .hold)
            #expect(DictationLanguagePreference.saved(in: defaults) == .chinese)
        }
    }
}
