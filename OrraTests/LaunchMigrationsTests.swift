import Foundation
import Testing
@testable import Orra

/// Cleanup and translation with a stand in model that never loads and no network, for the
/// steps at launch. Translate into is `direction`, and the caption target is read from and
/// saved to `defaults` when given, as the app does with its own.
@MainActor
func launchCleanup(direction: TranslationDirection = .automatic, defaults: UserDefaults? = nil) -> TextCleanup {
    let temporary = TemporaryModelFolders()
    return TextCleanup(
        isOn: false,
        save: { _ in },
        translationDirection: direction,
        captionTarget: defaults.flatMap { CaptionTargetPreference.saved(in: $0) },
        saveCaptionTarget: { target in
            if let defaults { CaptionTargetPreference.save(target, to: defaults) }
        },
        models: ModelInstaller(
            manifest: temporary.manifest,
            folders: temporary.folders,
            environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in throw URLError(.notConnectedToInternet) }, freeSpace: { _ in nil }, sleep: { _ in })
        ),
        engine: CleanupEngine(load: { _ in }, unload: {}, complete: { $0 })
    )
}

/// The steps at launch that save what a user started with, so it stays when a later
/// version starts the setting another way. Each runs at every launch and leaves a saved
/// value alone.
@MainActor
struct LaunchMigrationsTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()

    private func controller(talkMode: TriggerMode, translationMode: TriggerMode = .newTranslationKeyMode, dictationLanguage: DictationLanguage, dictationLanguageFollows: Bool = false) -> PushToTalkController {
        PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert, talkMode: talkMode, translationMode: translationMode, dictationLanguage: dictationLanguage, dictationLanguageFollows: dictationLanguageFollows)
    }

    /// One launch, by default of a new user with no own language.
    private func launch(_ pushToTalk: PushToTalkController, cleanup: TextCleanup? = nil, setUpBefore: Bool = false, ownLanguage: DictationLanguage? = nil, in defaults: UserDefaults) {
        LaunchMigrations.run(pushToTalk, cleanup: cleanup ?? launchCleanup(), setUpBefore: setUpBefore, ownLanguage: ownLanguage, in: defaults)
    }

    /// A first launch has nothing saved, and saves the modes of both keys and the dictation
    /// language they started with.
    @Test func aFirstLaunchSavesWhatTheUserStartedWith() throws {
        try withTestDefaults("LaunchMigrations.first") { defaults in
            launch(controller(talkMode: .toggle, dictationLanguage: .japanese), in: defaults)
            #expect(TriggerModePreference.saved(for: .talk, in: defaults) == .toggle)
            #expect(TriggerModePreference.saved(for: .translation, in: defaults) == .toggle)
            #expect(DictationLanguagePreference.saved(in: defaults) == .japanese)
            #expect(!defaults.bool(forKey: DictationLanguagePreference.newUserKey))
            // A new user's caption target follows their own language until they pick one.
            #expect(CaptionTargetPreference.saved(in: defaults) == nil)
        }
        // A new user's dictation language follows the welcome window, and the first launch
        // notes it for the next launches.
        try withTestDefaults("LaunchMigrations.newUser") { defaults in
            launch(controller(talkMode: .toggle, dictationLanguage: .japanese, dictationLanguageFollows: true), in: defaults)
            #expect(DictationLanguagePreference.saved(in: defaults) == .japanese)
            #expect(defaults.bool(forKey: DictationLanguagePreference.newUserKey))
        }
    }

    /// An update for a user who turned Translation on before: the translation key loads in
    /// Hold, and the step keeps it there.
    @Test func anEarlierTranslationUserKeepsHold() throws {
        try withTestDefaults("LaunchMigrations.translation") { defaults in
            TranslationPreference.save(true, to: defaults)
            let translationMode = TriggerModePreference.load(for: .translation, setUpBefore: true, from: defaults)
            launch(controller(talkMode: .hold, translationMode: translationMode, dictationLanguage: .chinese), setUpBefore: true, in: defaults)
            #expect(TriggerModePreference.saved(for: .translation, in: defaults) == .hold)
        }
    }

    /// An update for a user who set Orra up before saves the caption target their captions
    /// translated into, once, and the captions take it at once. A pick after that stays.
    @Test func anEarlierUsersCaptionsKeepTheirLanguage() throws {
        try withTestDefaults("LaunchMigrations.captionTarget") { defaults in
            let pushToTalk = controller(talkMode: .hold, dictationLanguage: .chinese)
            let first = launchCleanup(direction: .english, defaults: defaults)
            #expect(first.pickedCaptionTarget == nil)
            launch(pushToTalk, cleanup: first, setUpBefore: true, ownLanguage: .chinese, in: defaults)
            #expect(CaptionTargetPreference.saved(in: defaults) == .english)
            #expect(first.captionTarget == .english)
            #expect(first.pickedCaptionTarget == .english)
            // The user picks Chinese in the caption window, and the next launch keeps it.
            first.setCaptionTarget(.chinese)
            let next = launchCleanup(direction: .english, defaults: defaults)
            launch(pushToTalk, cleanup: next, setUpBefore: true, ownLanguage: .chinese, in: defaults)
            #expect(CaptionTargetPreference.saved(in: defaults) == .chinese)
            #expect(next.captionTarget == .chinese)
        }
    }

    /// An update for a user whose Translate into was saved for another dictation language
    /// and acted as Automatic: it becomes Automatic once, before the caption target's step
    /// reads it, so captions get what they got. A target outside the pair picked after
    /// that stays.
    @Test func aChoiceForAnotherLanguageBecomesAutomatic() throws {
        try withTestDefaults("LaunchMigrations.translationTargets") { defaults in
            TranslationDirection.japanese.save(to: defaults)
            let pushToTalk = controller(talkMode: .hold, dictationLanguage: .chinese)
            let first = launchCleanup(direction: .japanese, defaults: defaults)
            launch(pushToTalk, cleanup: first, setUpBefore: true, ownLanguage: .chinese, in: defaults)
            #expect(first.translationDirection == .automatic)
            #expect(TranslationDirection.load(from: defaults) == .automatic)
            #expect(CaptionTargetPreference.saved(in: defaults) == .chinese)
            // The user picks Japanese, which now goes through English, and it stays.
            TranslationDirection.japanese.save(to: defaults)
            let next = launchCleanup(direction: .japanese, defaults: defaults)
            launch(pushToTalk, cleanup: next, setUpBefore: true, ownLanguage: .chinese, in: defaults)
            #expect(next.translationDirection == .japanese)
            #expect(TranslationDirection.load(from: defaults) == .japanese)
        }
    }

    /// A later launch, or an update, never replaces what is saved.
    @Test func aSavedValueStays() throws {
        try withTestDefaults("LaunchMigrations.saved") { defaults in
            TriggerModePreference.save(.doubleTap, for: .talk, to: defaults)
            TriggerModePreference.save(.hold, for: .translation, to: defaults)
            DictationLanguagePreference.save(.spanish, to: defaults)
            launch(controller(talkMode: .hold, translationMode: .toggle, dictationLanguage: .chinese), in: defaults)
            #expect(TriggerModePreference.saved(for: .talk, in: defaults) == .doubleTap)
            #expect(TriggerModePreference.saved(for: .translation, in: defaults) == .hold)
            #expect(DictationLanguagePreference.saved(in: defaults) == .spanish)
        }
        // A user who saved a language before is never noted as new.
        try withTestDefaults("LaunchMigrations.savedFollows") { defaults in
            DictationLanguagePreference.save(.spanish, to: defaults)
            launch(controller(talkMode: .hold, dictationLanguage: .spanish, dictationLanguageFollows: true), in: defaults)
            #expect(!defaults.bool(forKey: DictationLanguagePreference.newUserKey))
        }
    }

    /// Running twice, as two launches do, gives what running once gives.
    @Test func runningAgainChangesNothing() throws {
        try withTestDefaults("LaunchMigrations.twice") { defaults in
            launch(controller(talkMode: .hold, translationMode: .hold, dictationLanguage: .chinese), in: defaults)
            launch(controller(talkMode: .toggle, translationMode: .toggle, dictationLanguage: .japanese), in: defaults)
            #expect(TriggerModePreference.saved(for: .talk, in: defaults) == .hold)
            #expect(TriggerModePreference.saved(for: .translation, in: defaults) == .hold)
            #expect(DictationLanguagePreference.saved(in: defaults) == .chinese)
        }
    }
}
