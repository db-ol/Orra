import Testing
@testable import Orra

struct TranscriptGuardTests {
    @Test func normalTextIsUnchanged() {
        let text = "这个 PR 先 merge 一下，然后跑一下 test。"
        #expect(TranscriptGuard.clean(text, audioSeconds: 4) == text)
    }

    @Test func shortRepeatsAreKept() {
        #expect(TranscriptGuard.clean("对对对，好好好。", audioSeconds: 2) == "对对对，好好好。")
        #expect(TranscriptGuard.clean("哈哈哈哈哈哈哈", audioSeconds: 2) == "哈哈哈哈哈哈哈")
    }

    @Test(arguments: ["我的手机号是13800000000。", "验证码是000000。", "客服电话4008888888", "颜色是#000000", "一三八零零零零零零零零"])
    func numbersAreNeverCut(_ text: String) {
        #expect(TranscriptGuard.clean(text, audioSeconds: 4) == text)
    }

    @Test func aLoopIsCutBackToTwoCopies() {
        let looped = "三，" + String(repeating: "非常", count: 300)
        #expect(TranscriptGuard.clean(looped, audioSeconds: 2) == "三，非常非常")
    }

    @Test func aRepeatedEnglishPhraseIsCut() {
        let looped = String(repeating: "thank you ", count: 20)
        #expect(TranscriptGuard.clean(looped, audioSeconds: 3) == "thank you thank you")
    }

    @Test func textLongerThanTheAudioCouldHoldIsCut() {
        // 500 different characters, so only the length rule applies.
        let long = String((0..<500).map { Character(UnicodeScalar(0x4E00 + $0)!) })
        let cleaned = TranscriptGuard.clean(long, audioSeconds: 1)
        #expect(cleaned.count == 60)
        #expect(long.hasPrefix(cleaned))
    }

    @Test func emptyAndWhitespaceTextBecomesEmpty() {
        #expect(TranscriptGuard.clean("", audioSeconds: 1).isEmpty)
        #expect(TranscriptGuard.clean("  \n", audioSeconds: 1).isEmpty)
    }
}
