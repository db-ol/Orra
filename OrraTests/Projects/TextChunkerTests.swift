import Foundation
import Testing
@testable import Orra

/// Where TextChunker cuts a file's text, what each chunk repeats and what it keeps.
struct TextChunkerTests {
    @Test func aShortPageIsOneChunk() {
        let chunks = chunk(["Kickoff notes.\n\nThe venue is booked.\n"])
        #expect(chunks == [TextChunker.Chunk(file: Self.file, page: nil, modified: Self.modified, heading: nil, text: "Kickoff notes.\n\nThe venue is booked.")])
    }

    @Test func chunksStayWithinTheirSizeAndPage() {
        let first = (1...40).map { "Sentence \($0) of page one is about the print run and the paper stock." }
        let second = (1...40).map { "Sentence \($0) of page two is about the delivery and the invoice." }
        let pages = [first, second].map { sentences in
            stride(from: 0, to: sentences.count, by: 5).map { sentences[$0..<$0 + 5].joined(separator: " ") }.joined(separator: "\n\n")
        }
        let chunks = chunk(pages, numbered: true)
        #expect(chunks.allSatisfy { $0.text.count <= 800 })
        #expect(Set(chunks.map(\.page)) == [1, 2])
        #expect(chunks.filter { $0.page == 1 }.allSatisfy { !$0.text.contains("page two") })
        #expect(chunks.filter { $0.page == 2 }.allSatisfy { !$0.text.contains("page one") })
        for sentence in first + second {
            #expect(chunks.contains { $0.text.contains(sentence) }, "\(sentence)")
        }
    }

    /// One long paragraph: each chunk starts with about the last 15% of the one before,
    /// from a sentence start, and ends at a sentence end.
    @Test func chunksOfASectionOverlapAndEndAtSentences() {
        let paragraph = (1...60).map { "Item \($0) of the offer covers the printing and the binding." }.joined(separator: " ")
        let chunks = chunk([paragraph])
        #expect(chunks.count > 3)
        for (before, after) in zip(chunks, chunks.dropFirst()) {
            let repeated = after.text.components(separatedBy: "\n\n")[0]
            #expect(before.text.hasSuffix(repeated))
            #expect((40...120).contains(repeated.count), "\(repeated.count)")
            #expect(repeated.hasPrefix("Item "))
            #expect(before.text.hasSuffix("binding."))
        }
    }

    @Test func chineseTextIsCutAtSentenceEnds() {
        let numbers = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        let paragraph = (0..<120).map { "第\(numbers[$0 % 10])批台历的纸张、印刷和装订安排已经确认。" }.joined()
        let chunks = chunk([paragraph])
        #expect(chunks.count > 3)
        #expect(chunks.allSatisfy { $0.text.count <= 800 })
        for (before, after) in zip(chunks, chunks.dropFirst()) {
            #expect(before.text.hasSuffix("。"))
            let repeated = after.text.components(separatedBy: "\n\n")[0]
            #expect(before.text.hasSuffix(repeated))
            #expect(repeated.hasPrefix("第"))
            #expect(!repeated.isEmpty && repeated.count <= 120)
        }
    }

    /// Text with no place to cut is cut at the limit, and nothing is lost.
    @Test func textWithoutBreaksIsCutAtTheLimit() {
        let text = String(repeating: "台历印刷装订纸张交货", count: 200)
        let chunks = chunk([text])
        #expect(chunks.allSatisfy { $0.text.count <= 800 })
        let rest = chunks.dropFirst().map { $0.text.components(separatedBy: "\n\n")[1] }
        #expect(chunks[0].text + rest.joined() == text)
    }

    /// A heading starts a new chunk, which repeats nothing from the section before, and
    /// the heading stays until the next one, also on the next page.
    @Test func headingsStartChunksAndCarryOver() {
        let payment = (1...6).map { "Payment line \($0) explains when the deposit and the balance are due." }.joined(separator: " ")
        let delivery = "Delivery is in November, to the studio."
        let pages = ["# Payment\n\n\(payment)\n\n## Delivery\n\n\(delivery)", "The courier calls a day before."]
        let chunks = chunk(pages, numbered: true)
        #expect(chunks.map(\.heading) == ["Payment", "Delivery", "Delivery"])
        #expect(chunks.map(\.page) == [1, 1, 2])
        #expect(chunks[1].text == "## Delivery\n\n\(delivery)")
        #expect(chunks[2].text == "The courier calls a day before.")
    }

    /// A heading after a short start joins the chunk, which keeps the heading above its
    /// first line.
    @Test func aHeadingAfterAShortStartJoinsTheChunk() {
        let chunks = chunk(["Draft for review.\n\n二、付款方式\n\n首付百分之三十。"])
        #expect(chunks.count == 1)
        #expect(chunks[0].heading == nil)
        #expect(chunk(["二、付款方式\n\n首付百分之三十。"])[0].heading == "二、付款方式")
    }

    /// docx, rtf, odt and PDF text often has no blank line between paragraphs, so a heading
    /// is found on any line.
    @Test func findsHeadingsBetweenSingleLineBreaks() {
        let intro = (1...4).map { "Intro sentence \($0) says the calendar is printed in Ningbo for the studio." }
        let payment = (1...8).map { "付款第\($0)条说明定金和尾款的时间安排已经确认，发票随货寄出。" }
        let delivery = (1...4).map { "Delivery sentence \($0) says the courier brings the boxes in November." }
        let text = (["Calendar print brief"] + intro + ["二、付款方式"] + payment + ["3. Delivery"] + delivery).joined(separator: "\n")
        let chunks = chunk([text])
        #expect(chunks.map(\.heading) == [nil, "二、付款方式", "3. Delivery"])
        #expect(chunks[1].text.hasPrefix("二、付款方式\n付款第1条"))
        #expect(chunks[2].text.hasPrefix("3. Delivery\nDelivery sentence 1"))
    }

    @Test func recognizesHeadings() {
        let headings: [(String, String)] = [
            ("# 付款", "付款"), ("## Delivery plan", "Delivery plan"), ("二、付款方式", "二、付款方式"),
            ("第三条 交货", "第三条 交货"), ("1. Payment terms", "1. Payment terms"), ("1.2 Scope", "1.2 Scope"),
            ("3) Fees", "3) Fees"), ("（一）付款", "（一）付款"), ("Payment terms:", "Payment terms"), ("付款方式：", "付款方式"),
            ("Scope:\nThe studio designs the calendar.", "Scope"),
            // A Markdown heading of 120 characters.
            ("# " + String(repeating: "a", count: 118), String(repeating: "a", count: 118)),
        ]
        for (paragraph, heading) in headings {
            #expect(TextChunker.heading(in: paragraph) == heading, "\(paragraph)")
        }
        // A letter with 100 accents is one character of 201 bytes.
        let heavy = "a" + String(repeating: "\u{301}", count: 100)
        let notHeadings = [
            "1. Pay the deposit by Friday.", "The venue is booked.", "2026年10月18日", "#hashtag", "",
            "3.5 percent", "第一批台历已经发货，请查收", String(repeating: "Long title ", count: 5),
            // Too long, or too many bytes, for a heading every chunk under it repeats.
            "# " + String(repeating: "word ", count: 100), "# " + String(repeating: heavy, count: 3),
            "Payment " + String(repeating: heavy, count: 3) + ":",
        ]
        for paragraph in notHeadings {
            #expect(TextChunker.heading(in: paragraph) == nil, "\(paragraph)")
        }
    }

    /// A Markdown heading line far longer than a heading stays text, so the chunks under it
    /// do not each repeat it and keep all of its words once.
    @Test func aVeryLongHeadingLineStaysText() {
        let page = "# " + String(repeating: "budget invoice ", count: 20_000)
        let chunks = chunk([page])
        #expect(chunks.count > 100)
        #expect(chunks.allSatisfy { $0.heading == nil && $0.text.count <= 800 })
        #expect(chunks.first?.text.hasPrefix("# budget invoice") == true)
        #expect(chunks.reduce(0) { $0 + $1.text.components(separatedBy: "invoice").count - 1 } >= 20_000)
    }

    // MARK: Helpers

    private static let file = URL(fileURLWithPath: "/Projects/Calendar/notes.md")
    private static let modified = Date(timeIntervalSince1970: 1_760_000_000)

    /// The chunks of pages, numbered from 1 when `numbered`, as a PDF's are.
    private func chunk(_ pages: [String], numbered: Bool = false) -> [TextChunker.Chunk] {
        let result = FileTextResult(
            pages: pages.enumerated().map { FileTextResult.Page(number: numbered ? $0.offset + 1 : nil, text: $0.element) },
            hiddenRuns: 0, modified: Self.modified, isCut: false)
        let chunks = TextChunker().chunks(of: result, file: Self.file)
        #expect(chunks.allSatisfy { $0.file == Self.file && $0.modified == Self.modified })
        return chunks
    }
}
