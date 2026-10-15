import Testing
@testable import Orra

/// How a translation is cut into the pieces the voice speaks.
struct SpeechChunksTests {
    @Test func aShortSentenceIsOnePiece() {
        #expect(SpeechChunks.split("We have a meeting next Tuesday.") == ["We have a meeting next Tuesday."])
        #expect(SpeechChunks.split("我们下周二开会。") == ["我们下周二开会。"])
        #expect(SpeechChunks.split("  ") == [])
        #expect(SpeechChunks.split("") == [])
    }

    @Test func sentencesBecomePiecesInOrder() {
        #expect(SpeechChunks.split("We have a meeting next Tuesday. Could you send the numbers before then? Thanks a lot!") == [
            "We have a meeting next Tuesday.",
            "Could you send the numbers before then?",
            "Thanks a lot!",
        ])
        #expect(SpeechChunks.split("我们下周二开会。请在开会之前把数据发给我！谢谢大家的配合。") == [
            "我们下周二开会。",
            "请在开会之前把数据发给我！",
            "谢谢大家的配合。",
        ])
    }

    /// A period inside a number or a closing quote stays with its sentence.
    @Test func numbersAndQuotesStayWhole() {
        #expect(SpeechChunks.split("The price went up 3.5 percent this year. That is a lot.") == [
            "The price went up 3.5 percent this year.",
            "That is a lot.",
        ])
        #expect(SpeechChunks.split("他说：“我们明天见。”然后就走了。") == ["他说：“我们明天见。”", "然后就走了。"])
        #expect(SpeechChunks.split("She said \"see you tomorrow.\" Then she left.") == ["She said \"see you tomorrow.\"", "Then she left."])
    }

    /// The period of an abbreviation or a title does not end the sentence.
    @Test func abbreviationsDoNotEndASentence() {
        #expect(SpeechChunks.split("The meeting is at 3:30 p.m. on Tuesday. Bring the slides.") == [
            "The meeting is at 3:30 p.m. on Tuesday.",
            "Bring the slides.",
        ])
        #expect(SpeechChunks.split("Please ask Dr. Smith about the numbers, e.g. the budget for next year.") == [
            "Please ask Dr. Smith about the numbers, e.g. the budget for next year.",
        ])
        #expect(SpeechChunks.split("He said \"Mr. Wang is here.\" Then he left the room.") == [
            "He said \"Mr. Wang is here.\"",
            "Then he left the room.",
        ])
        #expect(SpeechChunks.split("We shipped version 2.0. Then we waited.") == ["We shipped version 2.0.", "Then we waited."])
    }

    /// A short sentence joins the next one, and a short end the one before it.
    @Test func shortPiecesJoinTheirNeighbours() {
        #expect(SpeechChunks.split("OK. We can start the meeting now.") == ["OK. We can start the meeting now."])
        #expect(SpeechChunks.split("好的。我们现在开始开会吧。") == ["好的。我们现在开始开会吧。"])
        #expect(SpeechChunks.split("We can start the meeting now. OK.") == ["We can start the meeting now. OK."])
    }

    /// A long sentence is cut at its commas, and without commas at a space or, in Chinese,
    /// at the limit. No piece is longer than the limit, and nothing is lost.
    @Test func longSentencesAreCut() {
        let english = "When we talked about the release last week, everyone agreed that the new settings page should ship first, the voice work should wait for the benchmark, and the website should follow after that."
        let pieces = SpeechChunks.split(english)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= SpeechChunks.maximumLength })
        #expect(pieces.joined(separator: " ") == english)
        #expect(pieces.first == "When we talked about the release last week,")

        let words = Array(repeating: "word", count: 40).joined(separator: " ") + "."
        let cut = SpeechChunks.split(words)
        #expect(cut.allSatisfy { $0.count <= SpeechChunks.maximumLength })
        #expect(cut.joined(separator: " ") == words)

        let chinese = String(repeating: "我们", count: 70) + "。"
        let han = SpeechChunks.split(chinese)
        #expect(han.allSatisfy { $0.count <= SpeechChunks.maximumLength })
        #expect(han.joined() == chinese)
    }

    /// A long sentence is not cut at the comma of a number or the colon of a time.
    @Test func longSentencesKeepNumbersWhole() {
        let english = "The budget grew from 1,000 to 2,500 dollars in the first quarter, and the team now expects 4,000 by the meeting at 3:30 next Tuesday afternoon."
        let pieces = SpeechChunks.split(english)
        #expect(pieces == [
            "The budget grew from 1,000 to 2,500 dollars in the first quarter,",
            "and the team now expects 4,000 by the meeting at 3:30 next Tuesday afternoon.",
        ])
        #expect(pieces.joined(separator: " ") == english)

        // Chinese written with Latin commas is still cut at them.
        let chinese = "团队现在预计到下周二下午开会的时候会达到四千左右,然后我们会讨论下一步的计划,包括新的设置页面和语音功能的发布时间,以及网站的更新和下一个版本的测试安排,还有用户反馈的整理工作。"
        #expect(SpeechChunks.split(chinese) == [
            "团队现在预计到下周二下午开会的时候会达到四千左右,",
            "然后我们会讨论下一步的计划,",
            "包括新的设置页面和语音功能的发布时间,",
            "以及网站的更新和下一个版本的测试安排,",
            "还有用户反馈的整理工作。",
        ])
    }
}
