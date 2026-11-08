import Foundation
import Synchronization
import Testing
@testable import Orra

/// A dictation with Polish on, through PushToTalkController with stand ins for the
/// microphone, the speech model and the cleanup model: the polish takes the place of the
/// cleanup, a polish that cannot be used leaves what Orra pastes without Polish, the
/// translation key ignores Polish, and Orra never learns from a polished paste.
@MainActor
struct PolishRoutingTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let workspace = FakeWorkspace()

    /// What the stand in cleanup model got and gives, read off the main actor.
    final class Model: Sendable {
        let polishAnswer: Mutex<String>
        let cleanupAnswer: Mutex<String>
        let polished = Mutex<[String]>([])
        let cleaned = Mutex<[String]>([])

        init(polish: String, cleanup: String = #"{"cleaned": ""}"#) {
            polishAnswer = Mutex(polish)
            cleanupAnswer = Mutex(cleanup)
        }

        /// The cleanup model with cleanup on or off and Polish in `style`, nil for off.
        @MainActor
        func closures(cleanupOn: Bool, style: PolishStyle?, ready: Bool = true) -> CleanupModel {
            CleanupModel(
                isOn: { cleanupOn },
                waitUntilLoaded: { cleanupOn && ready },
                complete: { [self] text in
                    cleaned.withLock { $0.append(text) }
                    return cleanupAnswer.withLock { $0 }
                },
                polishStyle: { style },
                waitUntilLoadedForPolish: { style != nil && ready },
                polish: { [self] text, style in
                    polished.withLock { $0.append("\(style.rawValue) \(text)") }
                    return polishAnswer.withLock { $0 }
                }
            )
        }
    }

    private func controller(cleanup: CleanupModel, translation: PushToTalkControllerTests.FakeTranslation? = nil) async -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            cleanup: cleanup,
            translation: translation?.model ?? .off,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            dictationLanguage: .chinese
        )
        if translation != nil {
            controller.setTranslationKeyOn(true)
        }
        await controller.loadModel()
        return controller
    }

    private func dictate(_ controller: PushToTalkController, with key: TalkKey? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let starts = mic.calls.filter { $0 == "start" }.count
        controller.handle(.pressed(isRepeat: false), key: key.map { .key($0) })
        try await waitUntil({ mic.calls.filter { $0 == "start" }.count > starts }, sourceLocation: sourceLocation)
        controller.handle(.released, key: key.map { .key($0) })
        try await waitUntil({ controller.state == .idle }, sourceLocation: sourceLocation)
    }

    private static let spoken = "呃，我觉得我觉得这个方案还是可以的，就是成本，成本稍微高了一点。"
    private static let ruled = "我觉得我觉得这个方案还是可以的，就是成本，成本稍微高了一点。"
    private static let polish = "我觉得这个方案还是可以的，就是成本稍微高了一点。"

    /// The polish runs after the rule steps, on their result, in place of the cleanup. It is
    /// pasted and kept for Copy Last Dictation, Paste Original Text pastes the text the
    /// rules left, and Orra never learns from the polished paste.
    @Test func polishTakesThePlaceOfTheCleanup() async throws {
        let model = Model(polish: #"{"polished": "\#(Self.polish)"}"#)
        let controller = await controller(cleanup: model.closures(cleanupOn: true, style: .concise))
        var reported: [String] = []
        var stopped: [String] = []
        controller.onPasted = { text, _, _, _ in reported.append(text) }
        controller.onPasteOriginal = { stopped.append($0) }
        speech.reply = Self.spoken
        try await dictate(controller)
        #expect(model.polished.withLock { $0 } == ["concise \(Self.ruled)"])
        #expect(model.cleaned.withLock { $0 }.isEmpty)
        #expect(inserter.inserted == [Self.polish])
        #expect(controller.lastTranscript == Self.polish)
        #expect(controller.originalText == Self.ruled)
        #expect(controller.notice == nil)
        #expect(reported.isEmpty)
        await controller.pasteOriginal()
        #expect(inserter.inserted == [Self.polish, Self.ruled])
        #expect(reported.isEmpty)
        #expect(stopped == [Self.polish])
    }

    /// Polish works with cleanup off too.
    @Test func polishWorksWithCleanupOff() async throws {
        let model = Model(polish: #"{"polished": "\#(Self.polish)"}"#)
        let controller = await controller(cleanup: model.closures(cleanupOn: false, style: .clear))
        speech.reply = Self.spoken
        try await dictate(controller)
        #expect(model.polished.withLock { $0 } == ["clear \(Self.ruled)"])
        #expect(inserter.inserted == [Self.polish])
        #expect(controller.originalText == Self.ruled)
    }

    /// A polish held back by the checks leaves the cleanup while cleanup is on, which
    /// Orra may learn from, as without Polish.
    @Test func aHeldBackPolishPastesTheCleanup() async throws {
        let model = Model(
            polish: #"{"polished": "好的，以下是修改后的方案：成本可以再降低。"}"#,
            cleanup: #"{"cleaned": "我觉得这个方案还是可以的，就是成本，成本稍微高了一点。"}"#
        )
        let controller = await controller(cleanup: model.closures(cleanupOn: true, style: .clear))
        var reported: [(String, String?)] = []
        controller.onPasted = { text, _, before, _ in reported.append((text, before)) }
        speech.reply = "呃，我觉得我觉得这个方案还是可以的，就是成本，那个，成本稍微高了一点。"
        try await dictate(controller)
        let ruled = "我觉得我觉得这个方案还是可以的，就是成本，那个，成本稍微高了一点。"
        #expect(model.polished.withLock { $0 } == ["clear \(ruled)"])
        #expect(model.cleaned.withLock { $0 } == [ruled])
        #expect(inserter.inserted == ["我觉得这个方案还是可以的，就是成本，成本稍微高了一点。"])
        #expect(controller.originalText == ruled)
        #expect(reported.map(\.0) == ["我觉得这个方案还是可以的，就是成本，成本稍微高了一点。"])
        #expect(reported.map(\.1) == [ruled])
        #expect(controller.problem == nil)
    }

    /// With cleanup off, a polish that cannot be used leaves the text after the rules,
    /// whatever went wrong: the checks, an answer that cannot be read or an error.
    @Test func aPolishThatCannotBeUsedPastesTheRuledTextWithCleanupOff() async throws {
        for answer in [#"{"polished": "Sure, here is a cheaper plan."}"#, #"{"polished": "我觉得"#, "not JSON"] {
            let model = Model(polish: answer)
            let controller = await controller(cleanup: model.closures(cleanupOn: false, style: .concise))
            speech.reply = Self.spoken
            try await dictate(controller)
            #expect(inserter.inserted.last == Self.ruled)
            #expect(controller.originalText == nil)
            #expect(model.cleaned.withLock { $0 }.isEmpty)
        }
    }

    /// Without the model ready, nothing is polished, and the cleanup step does not wait
    /// again.
    @Test func noPolishWhileTheModelIsNotReady() async throws {
        let model = Model(polish: #"{"polished": "x"}"#)
        let controller = await controller(cleanup: model.closures(cleanupOn: true, style: .clear, ready: false))
        speech.reply = Self.spoken
        try await dictate(controller)
        #expect(model.polished.withLock { $0 }.isEmpty)
        #expect(model.cleaned.withLock { $0 }.isEmpty)
        #expect(inserter.inserted == [Self.ruled])
    }

    /// Text too short to polish is pasted as the rules left it.
    @Test func shortTextIsNotPolished() async throws {
        let model = Model(polish: #"{"polished": "x"}"#)
        let controller = await controller(cleanup: model.closures(cleanupOn: false, style: .clear))
        speech.reply = "好的。"
        try await dictate(controller)
        #expect(model.polished.withLock { $0 }.isEmpty)
        #expect(inserter.inserted == ["好的。"])
    }

    /// A dictation too long to polish says so, and with cleanup on, the notice about
    /// polishing stands in for the one about cleanup.
    @Test func aLongDictationSaysItWasPastedWithoutPolishing() async throws {
        let model = Model(polish: #"{"polished": "x"}"#)
        let controller = await controller(cleanup: model.closures(cleanupOn: true, style: .clear))
        // Long enough for the text, which the speech model's guard cuts to what the
        // recording could hold.
        mic.recording = AudioRecording(samples: FakeMicrophone.tone(count: 100 * 16_000), sampleRate: 16_000)
        speech.reply = String(repeating: "呃我们明天下午开会讨论一下。", count: PolishStep.maximumLength / 10)
        try await dictate(controller)
        #expect(model.polished.withLock { $0 }.isEmpty)
        #expect(model.cleaned.withLock { $0 }.isEmpty)
        #expect((inserter.inserted.first?.count ?? 0) > PolishStep.maximumLength)
        // Formatted as the interface formats numbers, 1,000 in English.
        #expect(controller.notice == String(localized: "Dictations over \(PolishStep.maximumLength) characters are pasted without polishing."))
        #expect(controller.notice == "Dictations over 1,000 characters are pasted without polishing.")
    }

    /// The translation key ignores Polish: its dictation is translated, never polished.
    @Test func theTranslationKeyIgnoresPolish() async throws {
        let model = Model(polish: #"{"polished": "x"}"#)
        let translation = PushToTalkControllerTests.FakeTranslation()
        let controller = await controller(cleanup: model.closures(cleanupOn: false, style: .concise), translation: translation)
        speech.reply = "呃，我们下周一，哦不是，下周二开会。"
        try await dictate(controller, with: .rightOption)
        #expect(model.polished.withLock { $0 }.isEmpty)
        #expect(inserter.inserted == ["We have a meeting next Tuesday."])
        // The talk key still polishes.
        try await dictate(controller, with: .rightControl)
        #expect(model.polished.withLock { $0 }.count == 1)
    }

    /// A dictation of the translation key that is not translated, since it is too long or
    /// the model is not ready, is pasted as it would be without Polish, never polished.
    @Test func theTranslationKeyNeverPolishesAnUntranslatedDictation() async throws {
        let sentence = "我们下周二下午3点在3楼开会，大家记得带电脑。"
        let spoken = String(repeating: sentence, count: 15)
        #expect(spoken.count > TranslationStep.maximumLength)
        #expect(spoken.count <= PolishStep.maximumLength)
        let model = Model(polish: #"{"polished": "\#(String(repeating: sentence, count: 14))"}"#)
        let translation = PushToTalkControllerTests.FakeTranslation()
        let controller = await controller(cleanup: model.closures(cleanupOn: false, style: .concise), translation: translation)
        // Long enough for the text, which the speech model's guard cuts to what the
        // recording could hold, and short enough for one piece.
        mic.recording = AudioRecording(samples: FakeMicrophone.tone(count: 15 * 16_000), sampleRate: 16_000)
        speech.reply = spoken
        try await dictate(controller, with: .rightOption)
        #expect(translation.received.isEmpty)
        #expect(model.polished.withLock { $0 }.isEmpty)
        #expect(inserter.inserted == [spoken])
        #expect(controller.notice == String(localized: "Dictations over \(TranslationStep.maximumLength) characters are pasted without translation."))
        // The model not ready for translation.
        translation.ready = false
        mic.recording = AudioRecording(samples: FakeMicrophone.tone(count: 16_000), sampleRate: 16_000)
        speech.reply = sentence
        try await dictate(controller, with: .rightOption)
        #expect(model.polished.withLock { $0 }.isEmpty)
        #expect(inserter.inserted.last == sentence)
        #expect(controller.notice == String(localized: "The local model is not ready, so the text was pasted without translation."))
    }

    /// Japanese and Spanish text skip Polish, as they skip the cleanup model, while English
    /// of the same user is polished.
    @Test func onlyTextOfChineseAndEnglishIsPolished() async throws {
        let model = Model(polish: #"{"polished": "I think we should ship on Monday."}"#)
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            cleanup: model.closures(cleanupOn: false, style: .clear),
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            dictationLanguage: .spanish
        )
        await controller.loadModel()
        speech.reply = LanguageGuardTests.spanish
        try await dictate(controller)
        #expect(model.polished.withLock { $0 }.isEmpty)
        speech.reply = "So I I think we should ship it on Monday."
        try await dictate(controller)
        #expect(model.polished.withLock { $0 }.count == 1)
        #expect(inserter.inserted.last == "I think we should ship on Monday.")
    }

    /// A polished paste dates the vocabulary words of the text before the polish, as a
    /// translated paste dates those before the translation, so a word the polish left out
    /// still counts as used and stays among those the speech model gets.
    @Test func aPolishedPasteDatesTheWordsOfTheTextBeforeIt() async throws {
        let model = Model(polish: #"{"polished": "版本中秋前发出去，大家抓紧。"}"#)
        let pasteTime = Date(timeIntervalSince1970: 5_000)
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            cleanup: model.closures(cleanupOn: false, style: .concise),
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            vocabulary: vocabularyWords("中秋节", "发版", added: Date(timeIntervalSince1970: 1_000)),
            dictationLanguage: .chinese,
            now: { pasteTime }
        )
        await controller.loadModel()
        speech.reply = "这个版本中秋节之前要发出去，大家抓紧。"
        try await dictate(controller)
        #expect(inserter.inserted == ["版本中秋前发出去，大家抓紧。"])
        #expect(controller.vocabulary.map(\.lastUsed) == [pasteTime, nil])
    }

    /// A polish the model gave back as it was is the text the rules left: Orra may learn
    /// from it, and Paste Original Text has nothing to bring back.
    @Test func anUnchangedPolishIsNoRewrite() async throws {
        let model = Model(polish: #"{"polished": "明天下午3点开会。"}"#)
        let controller = await controller(cleanup: model.closures(cleanupOn: false, style: .concise))
        var reported: [String] = []
        controller.onPasted = { text, _, _, _ in reported.append(text) }
        speech.reply = "明天下午三点开会。"
        try await dictate(controller)
        #expect(inserter.inserted == ["明天下午3点开会。"])
        #expect(reported == ["明天下午3点开会。"])
        #expect(controller.originalText == nil)
    }
}
