import Foundation
import Synchronization
import Testing
@testable import Orra

/// The translation step with a stand in model: every way the model can fail pastes the
/// text without translation, never nothing.
struct TranslationStepTests {
    private static func answer(_ text: String) -> @Sendable (String, TranslationTarget) async throws -> String {
        { _, _ in text }
    }

    private static let source = "呃，我们下周一，哦不是，下周二开会。"
    private static let good = #"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday."}"#

    @Test func aTranslationThatPassesTheChecksIsUsed() async {
        let result = await TranslationStep.run(Self.source, into: .english, cleansUp: true, complete: Self.answer(Self.good))
        #expect(result.text == "We have a meeting next Tuesday.")
        #expect(result.outcome == .translated)
        #expect(result.isTranslation)
        // Paste Original Text brings back the dictation as cleanup would have left it.
        #expect(result.untranslated == "我们下周二开会。")
    }

    /// With cleanup off, the text without translation is the text the step got.
    @Test func withoutCleanupTheUntranslatedTextIsTheRuledText() async {
        let result = await TranslationStep.run(Self.source, into: .english, cleansUp: false, complete: Self.answer(Self.good))
        #expect(result.text == "We have a meeting next Tuesday.")
        #expect(result.untranslated == Self.source)
    }

    @Test func theModelGetsTheTextAndTheTarget() async {
        let received = Mutex<[String]>([])
        _ = await TranslationStep.run("Lunch at noon.", into: .chinese, cleansUp: true, complete: { text, target in
            received.withLock { $0.append("\(target.rawValue) \(text)") }
            return #"{"cleaned": "Lunch at noon.", "translation": "中午吃午饭。"}"#
        })
        #expect(received.withLock { $0 } == ["zh Lunch at noon."])
    }

    /// A held back translation pastes the model's cleanup when cleanup is on, and the text
    /// the step got otherwise.
    @Test func aTranslationThatFailsACheckIsHeldBack() async {
        let answer = #"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday at 3."}"#
        let cleaned = await TranslationStep.run(Self.source, into: .english, cleansUp: true, complete: Self.answer(answer))
        #expect(cleaned.text == "我们下周二开会。")
        #expect(cleaned.untranslated == "我们下周二开会。")
        #expect(cleaned.outcome == .heldBack(.newNumber(["3"])))
        #expect(!cleaned.isTranslation)
        let ruled = await TranslationStep.run(Self.source, into: .english, cleansUp: false, complete: Self.answer(answer))
        #expect(ruled.text == Self.source)
        #expect(ruled.outcome == .heldBack(.newNumber(["3"])))
    }

    /// A cleanup that the cleanup checks hold back, here one that was translated too, is
    /// not pasted either.
    @Test func aCleanupThatFailsItsChecksIsNotUsed() async {
        let answer = #"{"cleaned": "We have a meeting next Tuesday.", "translation": "We have a meeting next Tuesday at 3."}"#
        let result = await TranslationStep.run(Self.source, into: .english, cleansUp: true, complete: Self.answer(answer))
        #expect(result.text == Self.source)
        #expect(result.untranslated == Self.source)
        let empty = #"{"cleaned": "", "translation": "We have a meeting next Tuesday."}"#
        let translated = await TranslationStep.run(Self.source, into: .english, cleansUp: true, complete: Self.answer(empty))
        #expect(translated.text == "We have a meeting next Tuesday.")
        #expect(translated.untranslated == Self.source)
    }

    @Test func anEmptyTranslationIsHeldBack() async {
        let result = await TranslationStep.run("我们下周二开会。", into: .english, cleansUp: false, complete: Self.answer(#"{"cleaned": "我们下周二开会。", "translation": ""}"#))
        #expect(result.text == "我们下周二开会。")
        #expect(result.outcome == .heldBack(.empty))
    }

    @Test func anUnchangedAnswerKeepsTheText() async {
        let result = await TranslationStep.run("我们下周二开会。", into: .chinese, cleansUp: true, complete: Self.answer(#"{"cleaned": "我们下周二开会。", "translation": "我们下周二开会。"}"#))
        #expect(result.text == "我们下周二开会。")
        #expect(result.outcome == .unchanged)
        #expect(!result.isTranslation)
    }

    @Test func anAnswerThatIsNotTheJSONObjectIsNotUsed() async {
        for answer in [#"{"cleaned": "我们下周二开会。", "translation": "We have"#, #"{"cleaned": "我们下周二开会。"}"#, "Sure! Here you go.", ""] {
            let result = await TranslationStep.run(Self.source, into: .english, cleansUp: true, complete: Self.answer(answer))
            #expect(result.text == Self.source)
            #expect(result.untranslated == Self.source)
            #expect(result.outcome == .unreadable)
        }
    }

    @Test func anErrorKeepsTheText() async {
        let result = await TranslationStep.run(Self.source, into: .english, cleansUp: true, complete: { _, _ in throw RewriteError.notLoaded })
        #expect(result.text == Self.source)
        #expect(result.outcome == .failed)
    }

    /// The model would answer after an hour, so the test ends only if the timeout cuts it
    /// off. No bound on the time taken, since a busy Mac can be seconds late.
    @Test(.timeLimit(.minutes(1)))
    func aSlowModelIsCutOffAtTheTimeout() async {
        let result = await TranslationStep.run(Self.source, into: .english, cleansUp: true, timeout: .milliseconds(200), complete: { _, _ in
            try await Task.sleep(for: .seconds(3600))
            return Self.good
        })
        #expect(result.text == Self.source)
        #expect(result.outcome == .timedOut)
    }

    /// A model that ignores cancellation is not waited for. The step pastes the text without
    /// translation at the timeout while the model still runs, see TimedCall, and the answer
    /// that comes later is never used. The model answers only when the test lets it, so the
    /// test does not depend on how long a busy Mac takes to run the timer.
    @Test(.timeLimit(.minutes(1)))
    func aLateAnswerIsNotUsed() async {
        let call = HeldWork()
        let answered = Mutex(false)
        let result = await TranslationStep.run(Self.source, into: .english, cleansUp: true, timeout: .milliseconds(50), complete: { _, _ in
            await call.run()
            answered.withLock { $0 = true }
            return Self.good
        })
        #expect(!answered.withLock { $0 })
        #expect(result.text == Self.source)
        #expect(result.untranslated == Self.source)
        #expect(result.outcome == .timedOut)
        call.release()
    }

    /// Any Han character or Latin letter is worth translating, even a word, but digits and
    /// punctuation alone are not.
    @Test func shortTextIsTranslatedWhenItHasADirection() {
        #expect(TranslationStep.isWorthTranslating("OK"))
        #expect(TranslationStep.isWorthTranslating("好"))
        #expect(!TranslationStep.isWorthTranslating(""))
        #expect(!TranslationStep.isWorthTranslating("123"))
        #expect(!TranslationStep.isWorthTranslating("3:30，！"))
    }

    /// A long dictation gets more time, and one too long to wait for is not translated.
    @Test func theTimeGrowsWithTheTextUpToTheLongestTranslated() {
        let longest = String(repeating: "会", count: TranslationStep.maximumLength)
        #expect(TranslationStep.timeout(for: "我们下周二开会。") == .milliseconds(3240))
        #expect(TranslationStep.timeout(for: longest) == .seconds(12))
        #expect(TranslationStep.isWorthTranslating(longest))
        #expect(!TranslationStep.isWorthTranslating(longest + "了"))
    }

    @Test func outcomesAreLoggedWithoutText() {
        #expect(TranslationStep.Outcome.heldBack(.acronymLost(["GMV"])).logName == "held back by the acronym check")
        #expect(TranslationStep.Outcome.heldBack(.newNumber(["13812345678"])).logName == "held back by the new number check")
        #expect(TranslationStep.Outcome.timedOut.logName == "timed out")
    }
}
