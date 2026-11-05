import Foundation
import Testing
@testable import Orra

/// What Transcribe File writes: the text alone, the SubRip subtitles with their numbers,
/// times and lines, and the names the save panel offers.
struct FileTranscriptTests {
    private func segment(_ id: Int, _ start: Double, _ end: Double, _ text: String) -> FileTranscriptSegment {
        FileTranscriptSegment(id: id, start: start, end: end, text: text)
    }

    @Test func theTextHasOneParagraphForEachSegmentAndNoTimes() {
        let segments = [
            segment(1, 0.2, 3.4, "Hello everyone."),
            segment(2, 4.0, 7.5, "今天我们看一下预算。"),
            segment(3, 8.0, 9.0, ""),
            segment(4, 9.5, 12.0, "Thanks."),
        ]
        #expect(FileTranscript.text(of: segments) == "Hello everyone.\n今天我们看一下预算。\nThanks.")
        #expect(FileTranscript.contents(of: segments, as: .text) == "Hello everyone.\n今天我们看一下预算。\nThanks.\n")
        #expect(FileTranscript.text(of: []) == "")
        #expect(FileTranscript.contents(of: [], as: .text) == "")
    }

    @Test func subtitlesAreNumberedWithTheirTimes() {
        let segments = [
            segment(1, 0.2, 3.4, "Hello everyone."),
            segment(2, 3_725.0456, 3_727.9, "Thanks."),
        ]
        let expected = """
        1
        00:00:00,200 --> 00:00:03,400
        Hello everyone.

        2
        01:02:05,046 --> 01:02:07,900
        Thanks.

        """
        #expect(FileTranscript.contents(of: segments, as: .subtitles) == expected)
    }

    @Test func timestampsRoundToTheMillisecond() {
        #expect(FileTranscript.timestamp(0) == "00:00:00,000")
        #expect(FileTranscript.timestamp(59.9996) == "00:01:00,000")
        #expect(FileTranscript.timestamp(61.0004) == "00:01:01,000")
        #expect(FileTranscript.timestamp(3_599.999) == "00:59:59,999")
        #expect(FileTranscript.timestamp(36_000.5) == "10:00:00,500")
        #expect(FileTranscript.timestamp(-0.2) == "00:00:00,000")
    }

    @Test func anEmptySegmentGivesNoSubtitleAndAOneWordSegmentGivesOneLine() {
        let segments = [
            segment(1, 1, 2, ""),
            segment(2, 3, 4, "   "),
            segment(3, 5, 6, "Yes."),
            segment(4, 7, 8, "好。"),
        ]
        let subtitles = FileTranscript.subtitleList(of: segments)
        #expect(subtitles == [
            FileTranscript.Subtitle(start: 5, end: 6, lines: ["Yes."]),
            FileTranscript.Subtitle(start: 7, end: 8, lines: ["好。"]),
        ])
        #expect(FileTranscript.contents(of: segments, as: .subtitles).hasPrefix("1\n00:00:05,000 --> 00:00:06,000\nYes.\n\n2\n"))
        #expect(FileTranscript.contents(of: [], as: .subtitles) == "")
    }

    @Test func latinLinesBreakAtSpacesWithinFortyTwoCharacters() {
        let text = "We will look at the budget for next quarter and then talk about the hiring plan for the design team."
        let lines = FileTranscript.lines(of: text)
        #expect(lines == [
            "We will look at the budget for next",
            "quarter and then talk about the hiring",
            "plan for the design team.",
        ])
        #expect(lines.allSatisfy { $0.count <= 42 })
        #expect(lines.joined(separator: " ") == text)
    }

    @Test func aLatinLineEndsAtACommaInItsSecondHalf() {
        let lines = FileTranscript.lines(of: "If the numbers hold up this week, we can ship the new build on Friday.")
        #expect(lines == ["If the numbers hold up this week,", "we can ship the new build on Friday."])
        // A comma in the first half of the line does not end it.
        #expect(FileTranscript.lines(of: "Yes, and we can also ship the new build on Friday morning.") == [
            "Yes, and we can also ship the new build on",
            "Friday morning.",
        ])
    }

    @Test func aWordWiderThanALineKeepsALineOfItsOwn() {
        let word = String(repeating: "a", count: 50)
        #expect(FileTranscript.lines(of: "see \(word) now") == ["see", word, "now"])
    }

    @Test func chineseLinesHoldAboutEighteenCharactersAndNeverStartWithPunctuation() {
        let text = "我们下周一上午开会讨论预算，然后再确定设计团队的人选和时间安排，最后定下招聘计划。"
        let lines = FileTranscript.lines(of: text)
        // Each comma closes a line, since it falls in the line's second half. The second
        // line holds 18 characters with its comma.
        #expect(lines == ["我们下周一上午开会讨论预算，", "然后再确定设计团队的人选和时间安排，", "最后定下招聘计划。"])
        #expect(lines.allSatisfy { $0.count <= 18 })
        // Without a comma a line holds 18 characters, and the 19th starts the next.
        let plain = String(repeating: "字", count: 40)
        #expect(FileTranscript.lines(of: plain).map(\.count) == [18, 18, 4])
    }

    @Test func aClosingMarkStaysWithTheCharacterBeforeIt() {
        // The 18th character is followed by 。, which may not start the next line, so the
        // character goes along with it.
        let text = String(repeating: "好", count: 17) + "了。" + "明天见。"
        let lines = FileTranscript.lines(of: text)
        #expect(lines.allSatisfy { FileTranscript.width(of: $0) <= FileTranscript.lineWidth })
        #expect(lines.joined() == text)
        #expect(lines.dropFirst().allSatisfy { $0.first != "。" })
    }

    @Test func japaneseKeepsSmallKanaAndTheLongMarkOffTheStartOfALine() {
        let text = "ちょっとコーヒーを飲みに行きませんか、それとも会議室で打ち合わせを続けましょうか。"
        let lines = FileTranscript.lines(of: text)
        #expect(lines.joined() == text)
        #expect(lines.allSatisfy { FileTranscript.width(of: $0) <= FileTranscript.lineWidth })
        #expect(lines.dropFirst().allSatisfy { !"ーっゃゅょ、。".contains($0.first!) })
    }

    @Test func mixedChineseAndEnglishKeepTheirSpaces() {
        let text = "我们用 Orra 把会议录音转成文字，然后发给 design team 看一下。"
        #expect(FileTranscript.lines(of: text) == ["我们用 Orra 把会议录音转成文字，", "然后发给 design team 看一下。"])
        // A Latin word next to Chinese without a space may start a line too.
        #expect(FileTranscript.lines(of: "这是一个关于预算和招聘计划的会议我用Orra记录") == ["这是一个关于预算和招聘计划的会议我用", "Orra记录"])
    }

    /// A segment that needs more than two lines becomes several subtitles in a row, each
    /// of at most two lines, which share its time in proportion to their text.
    @Test func aLongSegmentBecomesSeveralSubtitlesThatShareItsTime() throws {
        let text = "We will look at the budget for next quarter and then talk about the hiring plan for the design team, and after that we can take questions."
        let subtitles = FileTranscript.subtitles(of: segment(1, 10, 22, text))
        try #require(subtitles.count == 2)
        #expect(subtitles.allSatisfy { $0.lines.count <= 2 })
        #expect(subtitles.first?.start == 10)
        #expect(subtitles.last?.end == 22)
        #expect(subtitles[0].end == subtitles[1].start)
        let first = subtitles[0].lines.reduce(0) { $0 + FileTranscript.width(of: $1) }
        let second = subtitles[1].lines.reduce(0) { $0 + FileTranscript.width(of: $1) }
        #expect(abs((subtitles[0].end - 10) / 12 - first / (first + second)) < 0.0001)
        #expect(subtitles.flatMap(\.lines).joined(separator: " ") == text)
    }

    @Test func subtitlesOfSeveralSegmentsAreNumberedInOrder() {
        let long = String(repeating: "这是一个很长的句子，", count: 6)
        let srt = FileTranscript.contents(of: [segment(1, 0, 15, long), segment(2, 16, 18, "好的。")], as: .subtitles)
        let blocks = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let numbers = blocks.map { $0.split(separator: "\n").first.map(String.init) }
        #expect(numbers == (1...blocks.count).map(String.init))
        // Each line of the long segment ends at one of its commas, so its six lines make
        // three subtitles, and the short segment a fourth.
        #expect(blocks.count == 4)
        #expect(blocks.allSatisfy { $0.split(separator: "\n").count <= 4 })
        #expect(blocks.last?.hasSuffix("好的。\n") == true || blocks.last?.hasSuffix("好的。") == true)
    }

    @Test func theSavePanelOffersTheFilesNameWithTheNewExtension() {
        #expect(FileTranscript.suggestedName(for: "Interview.m4a", as: .text) == "Interview.txt")
        #expect(FileTranscript.suggestedName(for: "Interview.m4a", as: .subtitles) == "Interview.srt")
        #expect(FileTranscript.suggestedName(for: "talk.final.mov", as: .subtitles) == "talk.final.srt")
        #expect(FileTranscript.suggestedName(for: "会议录音 11月5日.mp3", as: .text) == "会议录音 11月5日.txt")
        #expect(FileTranscript.suggestedName(for: "Recording", as: .text) == "Recording.txt")
        #expect(FileTranscript.suggestedName(for: ".m4a", as: .text) == "Transcript.txt")
        #expect(FileTranscript.suggestedName(for: "..hidden.wav", as: .subtitles) == "hidden.srt")
    }
}
