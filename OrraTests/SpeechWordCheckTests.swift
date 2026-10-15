import Foundation
import Testing
@testable import Orra

/// The word check of a piece the voice model made, on what the speech model heard. The
/// pairs are from the voice benchmark of 2026-10-15 (public sentences and voices).
struct SpeechWordCheckTests {
    @Test func chineseIsComparedByCharacterAndEnglishByWord() {
        #expect(SpeechWordCheck.units(of: "我同意。") == ["我", "同", "意"])
        #expect(SpeechWordCheck.units(of: "Sorry, I was on mute.") == ["sorry", "i", "was", "on", "mute"])
        // Letters in a Chinese text, and what the speech model wrote in letters for it.
        #expect(SpeechWordCheck.units(of: "我们用 API 部署。") == ["我", "们", "用", "a", "p", "i", "部", "署"])
        #expect(SpeechWordCheck.units(of: "Watony.", characters: true) == ["w", "a", "t", "o", "n", "y"])
        // Chinese heard for an English text counts character by character.
        #expect(SpeechWordCheck.units(of: "嗯哼。", characters: false) == ["嗯", "哼"])
    }

    @Test func caseAndPunctuationDoNotCount() {
        #expect(SpeechWordCheck.passes(text: "Thanks everyone for joining, let's get started.", heard: "Thanks everyone for joining. Let's get started!"))
        #expect(SpeechWordCheck.wrongUnits(text: "Who is going to own the follow up?", heard: "who is going to own the follow-up").wrong == 0)
        #expect(SpeechWordCheck.wrongUnits(text: "好的，我们开始吧。", heard: "好的我们开始吧").wrong == 0)
    }

    /// OK may be heard as "Okay" or "O.K.", and letters spelled out join into a word.
    @Test func spellingsOfOneWordMatch() {
        #expect(SpeechWordCheck.wrongUnits(text: "OK.", heard: "Okay.").wrong == 0)
        #expect(SpeechWordCheck.wrongUnits(text: "OK.", heard: "O.K.").wrong == 0)
        #expect(SpeechWordCheck.wrongUnits(text: "We use the API.", heard: "We use the A P I.").wrong == 0)
    }

    /// A number can be read and written in many ways, so numbers do not count on either
    /// side.
    @Test func numbersDoNotCount() {
        #expect(SpeechWordCheck.units(of: "Call 5551234567.") == ["call"])
        #expect(SpeechWordCheck.passes(text: "Call 5551234567.", heard: "Call fifty-five fifty-one twelve three four five six seven."))
        #expect(SpeechWordCheck.passes(text: "The total is 1234567 dollars.", heard: "The total is 1,234,567 dollars."))
        #expect(SpeechWordCheck.passes(text: "电话是13812345678。", heard: "电话是幺三八幺二三四五六七八。"))
        #expect(SpeechWordCheck.passes(text: "我们用 API 部署 v2。", heard: "我们用API部署V二。"))
        // Nothing to compare: the check passes without the speech model.
        #expect(SpeechWordCheck.units(of: "13812345678。").isEmpty)
        #expect(SpeechWordCheck.passes(text: "2026.", heard: "Hello."))
    }

    /// The speech model may write a contraction in full, so a short sentence with one
    /// does not fail. It wrote "I am not sure" for "I'm not sure" in the benchmark.
    @Test func contractionsMatchTheirLongForms() {
        let pairs = [
            ("I'm not sure.", "I am not sure."),
            ("It's fine.", "It is fine."),
            ("We're ready.", "We are ready."),
            ("I can't make it.", "I cannot make it."),
            ("I don't know.", "I do not know."),
            ("Let's go.", "Let us go."),
            ("We’ll see.", "We will see."),
        ]
        for (text, heard) in pairs {
            #expect(SpeechWordCheck.wrongUnits(text: text, heard: heard).wrong == 0, "\(text)")
        }
        // A possessive keeps its one word.
        #expect(SpeechWordCheck.units(of: "John's plan.") == ["johns", "plan"])
    }

    /// The words that go with a number count with it, so a percentage, a time or an
    /// ordinal in digits matches it read out.
    @Test func wordsThatGoWithANumberDoNotCount() {
        let pairs = [
            ("Revenue grew 10% to 20%.", "Revenue grew ten percent to twenty percent."),
            ("It went up 1.5 points.", "It went up one point five points."),
            ("Let's meet at 2 o'clock.", "Let's meet at two."),
            ("Let's meet at 2:30.", "Let's meet at half past two."),
            ("The demo is on the 3rd.", "The demo is on the third."),
            ("It costs $5.", "It costs five dollars."),
            ("收入增长了10%。", "收入增长了百分之十。"),
            ("下午2:30开会。", "下午两点半开会。"),
            ("已经完成了1/3。", "已经完成了三分之一。"),
            ("预算是1.5万。", "预算是一点五万。"),
        ]
        for (text, heard) in pairs {
            #expect(SpeechWordCheck.wrongUnits(text: text, heard: heard).wrong == 0, "\(text)")
        }
        // Only after a number: 点 in 重点 and "point" in "a good point" count.
        #expect(SpeechWordCheck.units(of: "重点。") == ["重", "点"])
        #expect(SpeechWordCheck.units(of: "A good point.") == ["a", "good", "point"])
    }

    /// The speech model may write Chinese in traditional characters.
    @Test func traditionalCharactersMatchSimplifiedOnes() {
        #expect(SpeechWordCheck.wrongUnits(text: "会后我会把会议纪要发给大家。", heard: "會後我會把會議紀要發給大家。").wrong == 0)
    }

    /// What the speech model gets wrong on good clips passes: a word or a character in
    /// four.
    @Test func smallSlipsPass() {
        let slips = [
            ("感谢大家参加，我们开始每周的进度同步吧。", "感谢大家参加，开始每周的禁毒同步吧。"),
            ("周末的服务器迁移进行得很顺利。", "周末服务器迁移进行的很顺利。"),
            ("我先跟设计团队确认一下，明天再回复你。", "我先跟设计团确认一下，明天再付你。"),
            ("The new build fixed the crash, but the login page is still slow.", "The new build fixed crash, but the login page still slow."),
            ("I'm not sure that estimate is realistic for such a small team.", "I am not sure that estimate is realistic for such a small team."),
            ("The total is 1234567 dollars.", "The total is twelve, three, four million, five hundred and sixty-seven dollars."),
            // One wrong unit never fails a piece.
            ("好的。", "好。"),
        ]
        for (text, heard) in slips {
            #expect(SpeechWordCheck.passes(text: text, heard: heard), "\(text)")
        }
    }

    /// Other words, words left out, another language or nothing at all fail.
    @Test func otherWordsFail() {
        let misses = [
            ("我同意。", "Watony."),
            ("好的，我们开始吧。", "How the woman came here."),
            ("谢谢大家。", "Спасибо, Даша."),
            ("谢谢大家。", "是是，大家。"),
            ("好。", "Hold."),
            ("我们另外约个时间，专门过一下细节吧。", "我門靈活用個時間，做下門各式嘗試嘅吧。"),
            ("我们还在等法务部门审核这份协议。", "我们还在等。"),
            ("Thank you all, that's everything for today. See you next week.", "Thank you all. That's everything for today."),
            ("Thank you.", "嗯哼。"),
            ("Sounds good to me.", ""),
        ]
        for (text, heard) in misses {
            #expect(!SpeechWordCheck.passes(text: text, heard: heard), "\(text)")
        }
    }

    /// A known limit: one wrong character of a short text passes, even when it turns the
    /// meaning around.
    @Test func oneWrongCharacterOfAShortTextPasses() {
        #expect(SpeechWordCheck.wrongUnits(text: "我同意。", heard: "不同意。") == (1, 3))
        #expect(SpeechWordCheck.passes(text: "我同意。", heard: "不同意。"))
    }

    @Test func theLimitIsAShareOfTheText() {
        // 3 of 10 words wrong passes, 4 of 10 fails.
        let ten = "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
        #expect(SpeechWordCheck.passes(text: ten, heard: "xa xb xc delta echo foxtrot golf hotel india juliet"))
        #expect(!SpeechWordCheck.passes(text: ten, heard: "xa xb xc xd echo foxtrot golf hotel india juliet"))
    }

    @Test func errorsGiveTheShareOfWrongUnits() {
        let errors = SpeechWordCheck.errors(text: "我们明天开会讨论预算。", heard: "我们明天开看看看看看")
        #expect(errors == SpeechWordCheck.Errors(wrong: 5, length: 10))
        #expect(errors.share == 0.5)
        #expect(!errors.passes)
        #expect(SpeechWordCheck.errors(text: "2026.", heard: "Hello.").share == 0)
        #expect(SpeechWordCheck.errors(text: "2026.", heard: "Hello.").passes)
    }
}
