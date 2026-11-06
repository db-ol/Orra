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

    /// Latin lines break at spaces, each within 42 characters, and share the text of a
    /// segment evenly, rather than filling the first lines and leaving a word or two for
    /// the last one.
    @Test func latinLinesBreakAtSpacesAndShareTheText() {
        let text = "We will look at the budget for next quarter and then talk about the hiring plan for the design team."
        let lines = FileTranscript.lines(of: text)
        #expect(lines == [
            "We will look at the budget",
            "for next quarter and then",
            "talk about the hiring",
            "plan for the design team.",
        ])
        #expect(lines.allSatisfy { $0.count <= 42 })
        #expect(lines.joined(separator: " ") == text)
        // The two lines of a subtitle are about as wide as each other.
        #expect(FileTranscript.lines(of: "We spent a little less than planned on travel.") == ["We spent a little less", "than planned on travel."])
        #expect(FileTranscript.lines(of: "Gastamos un poco menos de lo previsto en viajes.") == ["Gastamos un poco menos", "de lo previsto en viajes."])
        // A line breaks before a word such as “the”, not after it.
        #expect(FileTranscript.lines(of: "Yes, and we can also ship the new build on Friday morning.") == ["Yes, and we can also ship", "the new build on Friday morning."])
    }

    @Test func aLatinLineEndsAtACommaNearItsMiddle() {
        let lines = FileTranscript.lines(of: "If the numbers hold up this week, we can ship the new build on Friday.")
        #expect(lines == ["If the numbers hold up this week,", "we can ship the new build on Friday."])
        // A comma near the start does not leave a line of one word.
        #expect(FileTranscript.lines(of: "Yes, we can ship the new build on Friday then.") == ["Yes, we can ship the new", "build on Friday then."])
    }

    @Test func aWordWiderThanALineKeepsALineOfItsOwn() {
        let word = String(repeating: "a", count: 50)
        #expect(FileTranscript.lines(of: "see \(word) now") == ["see", word, "now"])
    }

    @Test func chineseLinesHoldAboutEighteenCharactersAndNeverStartWithPunctuation() {
        let text = "我们下周一上午开会讨论预算，然后再确定设计团队的人选和时间安排，最后定下招聘计划。"
        let lines = FileTranscript.lines(of: text)
        // Each line ends at a comma. The second holds 18 characters with its comma.
        #expect(lines == ["我们下周一上午开会讨论预算，", "然后再确定设计团队的人选和时间安排，", "最后定下招聘计划。"])
        #expect(lines.allSatisfy { $0.count <= 18 })
        // Without punctuation the lines share the text evenly.
        let plain = FileTranscript.lines(of: String(repeating: "字", count: 40)).map(\.count)
        #expect(plain.reduce(0, +) == 40)
        #expect(plain.allSatisfy { $0 <= 18 })
        #expect((plain.max() ?? 0) - (plain.min() ?? 0) <= 2)
    }

    /// A Chinese segment of 37 characters, as the speech model wrote one, makes two
    /// subtitles of about 18, not one of 36 and one of a single character, and each shows
    /// for longer than a second.
    @Test func aChineseSegmentLeavesNoCharacterAlone() throws {
        let text = "杜瓦尔已婚，有两个已经成年的孩子，他并没有给故事的讲述者米勒留下太大印象。"
        let subtitles = FileTranscript.subtitles(of: segment(1, 537.22, 544.82, text))
        try #require(subtitles.count == 2)
        #expect(subtitles.flatMap(\.lines).joined() == text)
        #expect(subtitles.allSatisfy { $0.lines.joined().count >= 12 })
        #expect(subtitles.allSatisfy { $0.end - $0.start > 1 })
        #expect(subtitles.flatMap(\.lines).contains { $0.contains("印象") })
    }

    /// Chinese and Japanese lines break between words, as CFStringTokenizer finds them,
    /// never inside one, and a number stays with the character after it. Japanese keeps
    /// the particles and endings in hiragana with the word before them.
    @Test func chineseAndJapaneseLinesKeepTheirWordsWhole() {
        let cases = [
            ("桥下垂直净空15米。该项目于2011年8月完工，但直到2017年3月才开始通车。", ["完工", "15米", "2011年"]),
            ("科学家们可以得出结论：暗物质对其他暗物质的影响方式与普通物质相同。", ["物质"]),
            ("它的长下颚上布满了七十多颗剃刀般锋利的牙齿，上颚上还有一排。这意味着任何与它相遇的东西都无路可逃。", ["剃刀", "锋利", "牙齿", "相遇", "无路可逃"]),
        ]
        for (text, words) in cases {
            let lines = FileTranscript.lines(of: text)
            #expect(lines.joined() == text)
            #expect(lines.allSatisfy { FileTranscript.width(of: $0) <= FileTranscript.lineWidth })
            for word in words {
                let parts = text.components(separatedBy: word).count - 1
                #expect(lines.reduce(0) { $0 + $1.components(separatedBy: word).count - 1 } == parts, "\(word) broken in \(lines)")
            }
        }
        let japanese = FileTranscript.lines(of: "ちょっとコーヒーを飲みに行きませんか、それとも会議室で打ち合わせを続けましょうか。")
        #expect(japanese.dropFirst().allSatisfy { !"をにでかんませ".contains($0.first!) })
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
        #expect(FileTranscript.lines(of: "我们今天讨论预算和招聘计划。Orra会把会议记录发给大家。") == ["我们今天讨论预算和招聘计划。", "Orra会把会议记录发给大家。"])
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

    @Test func subtitlesOfSeveralSegmentsAreNumberedInOrder() throws {
        let long = String(repeating: "这是一个很长的句子，", count: 6)
        let srt = FileTranscript.contents(of: [segment(1, 0, 15, long), segment(2, 16, 18, "好的。")], as: .subtitles)
        let blocks = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let numbers = blocks.map { $0.split(separator: "\n").first.map(String.init) }
        #expect(numbers == (1...blocks.count).map(String.init))
        // The 60 characters of the long segment fit in two subtitles of two lines, which
        // split it at its middle comma, and the short segment makes a third.
        try #require(blocks.count == 3)
        #expect(blocks[0].split(separator: "\n").dropFirst(2).joined() == String(repeating: "这是一个很长的句子，", count: 3))
        #expect(blocks.allSatisfy { $0.split(separator: "\n").count <= 4 })
        #expect(blocks.last?.hasSuffix("好的。\n") == true || blocks.last?.hasSuffix("好的。") == true)
    }

    /// No subtitle shows for less than a second: one that its share of a segment would
    /// make shorter takes time from the others of the segment, and the subtitle of a short
    /// segment stays up into the pause after it, never past the start of the next one.
    @Test func noSubtitleShowsForLessThanASecond() throws {
        let segments = [
            segment(1, 40.98, 44.72, "Many people don't think about them as dinosaurs because they have feathers and can fly."),
            segment(2, 46.0, 46.5, "Yes."),
            segment(3, 50.0, 50.4, "Right."),
            segment(4, 50.7, 53.0, "Then let's look at the release schedule."),
        ]
        let subtitles = FileTranscript.subtitleList(of: segments)
        try #require(subtitles.count >= 5)
        let yes = try #require(subtitles.first { $0.lines == ["Yes."] })
        #expect(yes.start == 46.0 && abs(yes.end - 47.0) < 1e-9)
        let right = try #require(subtitles.first { $0.lines == ["Right."] })
        #expect(right.start == 50.0 && right.end == 50.7)
        #expect(subtitles.allSatisfy { $0.end - $0.start >= 1 - 1e-9 || $0.lines == ["Right."] })
        for (subtitle, next) in zip(subtitles, subtitles.dropFirst()) {
            #expect(subtitle.end <= next.start + 1e-9)
        }
    }

    /// The time of a segment goes to its subtitles in proportion to their text, with at
    /// least a second each when the segment has that much for all of them.
    @Test func aShortSubtitleTakesTimeFromTheOthersOfItsSegment() {
        let shares = FileTranscript.shares(of: 4, by: [10, 1, 10])
        #expect(abs(shares[1] - 1) < 1e-9)
        #expect(abs(shares[0] - 1.5) < 1e-9 && abs(shares[2] - 1.5) < 1e-9)
        #expect(FileTranscript.shares(of: 6, by: [1, 2]) == [2, 4])
        // A segment too short for a second each shares its time in proportion.
        let short = FileTranscript.shares(of: 2, by: [10, 1, 10])
        #expect(abs(short[1] - 2.0 / 21) < 1e-9)
        #expect(abs(short.reduce(0, +) - 2) < 1e-9)
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
