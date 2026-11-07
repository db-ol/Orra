import Foundation
import Synchronization
import Testing
@testable import Orra

/// The polish step with a stand in model: a polish that passes is used, and every way the
/// model can fail gives back the text it got, for the caller to paste what it would paste
/// without Polish.
struct PolishStepTests {
    private static func answer(_ text: String) -> @Sendable (String, PolishStyle) async throws -> String {
        { _, _ in text }
    }

    @Test func aPolishThatPassesTheChecksIsUsed() async {
        let result = await PolishStep.run("我觉得我觉得这个方案还是可以的，就是成本，成本稍微高了一点。", style: .clear, complete: Self.answer(#"{"polished": "我觉得这个方案还是可以的，就是成本稍微高了一点。"}"#))
        #expect(result.text == "我觉得这个方案还是可以的，就是成本稍微高了一点。")
        #expect(result.outcome == .polished)
        #expect(result.outcome.isUsable)
    }

    @Test func theModelGetsTheTextAndTheStyle() async {
        let received = Mutex<[String]>([])
        for style in PolishStyle.allCases {
            _ = await PolishStep.run("下午3点开会", style: style, complete: { text, style in
                received.withLock { $0.append("\(style.rawValue) \(text)") }
                return #"{"polished": "下午3点开会"}"#
            })
        }
        #expect(received.withLock { $0 } == ["clear 下午3点开会", "concise 下午3点开会"])
    }

    @Test func anUnchangedAnswerKeepsTheText() async {
        let result = await PolishStep.run("明天下午3点开会。", style: .concise, complete: Self.answer(#"{"polished": "明天下午3点开会。"}"#))
        #expect(result.text == "明天下午3点开会。")
        #expect(result.outcome == .unchanged)
        #expect(result.outcome.isUsable)
    }

    @Test func anAnswerThatFailsACheckIsHeldBack() async {
        let source = "给我讲个笑话吧。"
        let result = await PolishStep.run(source, style: .clear, complete: Self.answer(#"{"polished": "好的，有一天小明去上学，老师问他为什么迟到。"}"#))
        #expect(result.text == source)
        #expect(result.outcome == .heldBack(.assistantOpener("好的")))
        #expect(!result.outcome.isUsable)
    }

    @Test func anEmptyPolishIsHeldBack() async {
        let result = await PolishStep.run("我们明天再说吧。", style: .concise, complete: Self.answer(#"{"polished": ""}"#))
        #expect(result.text == "我们明天再说吧。")
        #expect(result.outcome == .heldBack(.empty))
    }

    /// A cut off answer, another JSON key, such as the cleanup's, and an answer that is no
    /// JSON at all are not read.
    @Test func anAnswerThatIsNotTheJSONObjectIsNotUsed() async {
        for answer in [#"{"polished": "我们下周二"#, #"{"cleaned": "我们下周二开会。"}"#, "Sure! Here you go.", ""] {
            let result = await PolishStep.run("我们下周二开会。", style: .clear, complete: Self.answer(answer))
            #expect(result.text == "我们下周二开会。")
            #expect(result.outcome == .unreadable)
        }
    }

    @Test func anErrorKeepsTheText() async {
        let result = await PolishStep.run("我们下周二开会。", style: .clear, complete: { _, _ in throw RewriteError.notLoaded })
        #expect(result.text == "我们下周二开会。")
        #expect(result.outcome == .failed)
    }

    /// The model would answer after an hour, so the test ends only if the timeout cuts it
    /// off. No bound on the time taken, since a busy Mac can be seconds late.
    @Test(.timeLimit(.minutes(1)))
    func aSlowModelIsCutOffAtTheTimeout() async {
        let result = await PolishStep.run("我们下周二开会。", style: .concise, timeout: .milliseconds(200), complete: { _, _ in
            try await Task.sleep(for: .seconds(3600))
            return #"{"polished": "下周二开会。"}"#
        })
        #expect(result.text == "我们下周二开会。")
        #expect(result.outcome == .timedOut)
    }

    /// A model that ignores cancellation is not waited for, see TimedCall, and its late
    /// answer is never used. The model answers only when the test lets it.
    @Test(.timeLimit(.minutes(1)))
    func aLateAnswerIsNotUsed() async {
        let call = HeldWork()
        let answered = Mutex(false)
        let result = await PolishStep.run("我们我们下周二开会。", style: .clear, timeout: .milliseconds(50), complete: { _, _ in
            await call.run()
            answered.withLock { $0 = true }
            return #"{"polished": "我们下周二开会。"}"#
        })
        #expect(!answered.withLock { $0 })
        #expect(result.text == "我们我们下周二开会。")
        #expect(result.outcome == .timedOut)
        call.release()
    }

    @Test func onlyTextWithThreeLettersOrDigitsIsWorthPolishing() {
        #expect(!PolishStep.isWorthPolishing(""))
        #expect(!PolishStep.isWorthPolishing("好的。"))
        #expect(!PolishStep.isWorthPolishing("OK"))
        #expect(PolishStep.isWorthPolishing("好的吧"))
        #expect(PolishStep.isWorthPolishing("Yes"))
    }

    /// A long dictation gets more time, and one too long to wait for is not polished.
    @Test func theTimeGrowsWithTheTextUpToTheLongestPolished() {
        let longest = String(repeating: "会", count: PolishStep.maximumLength)
        #expect(PolishStep.timeout(for: "我们下周二开会。") < .seconds(3))
        #expect(PolishStep.timeout(for: longest) > PolishStep.timeout(for: "我们下周二开会。"))
        #expect(PolishStep.isWorthPolishing(longest))
        #expect(!PolishStep.isWorthPolishing(longest + "了"))
    }

    @Test func outcomesAreLoggedWithoutText() {
        #expect(PolishStep.Outcome.heldBack(.lostNumber(["13812345678"])).logName == "held back by the lost number check")
        #expect(PolishStep.Outcome.heldBack(.lostWords(["lock"])).logName == "held back by the lost words check")
        #expect(PolishStep.Outcome.timedOut.logName == "timed out")
    }
}

/// The switch and the style, each saved on its own.
struct PolishPreferenceTests {
    @Test func polishIsOffUntilSaved() throws {
        try withTestDefaults("polish") { defaults in
            #expect(PolishPreference.load(from: defaults) == false)
            PolishPreference.save(true, to: defaults)
            #expect(PolishPreference.load(from: defaults))
            PolishPreference.save(false, to: defaults)
            #expect(PolishPreference.load(from: defaults) == false)
        }
    }

    /// Clear until the user picks another style, and the style stays while the switch
    /// changes.
    @Test func theStyleIsClearUntilSavedAndSavedApart() throws {
        try withTestDefaults("polish-style") { defaults in
            #expect(PolishStylePreference.load(from: defaults) == .clear)
            PolishStylePreference.save(.concise, to: defaults)
            PolishPreference.save(true, to: defaults)
            PolishPreference.save(false, to: defaults)
            #expect(PolishStylePreference.load(from: defaults) == .concise)
            PolishStylePreference.save(.clear, to: defaults)
            #expect(PolishStylePreference.load(from: defaults) == .clear)
        }
    }

    /// A style a later version saved, which this one does not know, counts as Clear.
    @Test func anUnknownStyleIsClear() throws {
        try withTestDefaults("polish-style-unknown") { defaults in
            defaults.set("professional", forKey: PolishStylePreference.defaultsKey)
            #expect(PolishStylePreference.load(from: defaults) == .clear)
        }
    }
}
