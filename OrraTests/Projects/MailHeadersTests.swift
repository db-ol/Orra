import Foundation
import Testing
@testable import Orra

struct MailHeadersTests {
    private static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }

    private static let gb18030 = encoding(.GB_18030_2000)
    private static let big5 = encoding(.big5)

    /// An RFC 2047 word with the text in base64, in the charset given.
    private static func word(_ text: String, _ charset: String, _ encoding: String.Encoding) -> String {
        "=?\(charset)?B?\(text.data(using: encoding)!.base64EncodedString())?="
    }

    @Test func foldedLinesJoinAndTheBlockEndsAtTheFirstBlankLine() {
        let headers = MailHeaders(parsing: "Subject: Budget for\r\n the print run\r\n\tand paper\r\nX-Empty:\r\n\r\nTo: never@orchard.example\r\n")
        #expect(headers.fields.map(\.name) == ["Subject", "X-Empty"])
        #expect(headers["subject"] == "Budget for the print run\tand paper")
        #expect(headers.subject == "Budget for the print run and paper")
        #expect(headers["X-Empty"] == "")
        #expect(headers["To"] == nil)
    }

    @Test func linesThatAreNoFieldAreSkipped() {
        let headers = MailHeaders(parsing: "From mei@orchard.example Mon Oct 12 09:30:00 2026\nnot a field\nSub ject: x\nSubject : Kept\n continued\n")
        #expect(headers.fields == [MailHeaders.Field(name: "Subject", value: "Kept continued")])
    }

    @Test func valuesOfARepeatedFieldKeepTheirOrder() {
        let headers = MailHeaders(parsing: "Received: one\nreceived: two\nRECEIVED: three\n")
        #expect(headers.values("Received") == ["one", "two", "three"])
        #expect(headers["received"] == "one")
    }

    @Test func limitsCutFieldsAndValues() {
        let many = (1...10).map { "X-Field-\($0): value \($0)" }.joined(separator: "\n")
        let cut = MailHeaders(parsing: many, limits: MailHeaders.Limits(maximumFields: 4, maximumValueBytes: 64))
        #expect(cut.fields.count == 4)
        #expect(cut.isCut)
        let long = MailHeaders(parsing: "Subject: " + String(repeating: "a", count: 500), limits: MailHeaders.Limits(maximumFields: 10, maximumValueBytes: 64))
        #expect(long.subject?.count == 64)
        #expect(long.isCut)
    }

    @Test(arguments: [
        ("=?UTF-8?B?5Lmm5p6255qE5bC65a+4?=", "书架的尺寸"),
        ("=?utf-8?q?Caf=C3=A9_menu_for_Friday?=", "Café menu for Friday"),
        ("=?UTF-8?Q?Quarterly?= =?UTF-8?Q?_report?=", "Quarterly report"),
        ("Re: =?UTF-8?B?6aG555uu?= update", "Re: 项目 update"),
        ("=?UTF-8*en?Q?Hello?=", "Hello"),
        ("=?UTF-8?X?broken?= stays", "=?UTF-8?X?broken?= stays"),
        ("=?UTF-8?B?no end", "=?UTF-8?B?no end"),
        ("plain subject", "plain subject"),
        ("=?unknown-charset?Q?caf=C3=A9?=", "café"),
        ("=?UTF-8?Q?line=0Abreak?=", "line break"),
    ])
    func encodedWordsDecode(_ value: String, _ expected: String) {
        #expect(MailHeaders.decodedWords(value) == expected)
    }

    @Test func chineseCharsetsDecode() {
        // GB2312 labels often carry GBK characters, such as 镕, which GB2312 lacks.
        #expect(MailHeaders.decodedWords(Self.word("项目进度", "GB2312", Self.gb18030)) == "项目进度")
        #expect(MailHeaders.decodedWords(Self.word("镕铸工坊", "gb2312", Self.gb18030)) == "镕铸工坊")
        #expect(MailHeaders.decodedWords(Self.word("报价单", "GBK", Self.gb18030)) == "报价单")
        #expect(MailHeaders.decodedWords(Self.word("𠀀字", "GB18030", Self.gb18030)) == "𠀀字")
        #expect(MailHeaders.decodedWords(Self.word("請確認報價", "Big5", Self.big5)) == "請確認報價")
    }

    @Test func aCharacterSplitBetweenTwoWordsComesOutWhole() {
        let bytes = Array("工作室".utf8)
        let first = Data(bytes[0..<4]).base64EncodedString()
        let second = Data(bytes[4...]).base64EncodedString()
        #expect(MailHeaders.decodedWords("=?UTF-8?B?\(first)?=\r\n =?UTF-8?B?\(second)?=") == "工作室")
    }

    @Test func spaceBetweenAWordAndTextStays() {
        let encoded = Self.word("顾远", "UTF-8", .utf8)
        #expect(MailHeaders.decodedWords("Hi \(encoded) there") == "Hi 顾远 there")
        // Words in two charsets next to each other still join without the space.
        #expect(MailHeaders.decodedWords("\(encoded) \(Self.word("你好", "GBK", Self.gb18030))") == "顾远你好")
    }

    @Test func rawBytesInHeadersReadAsUTF8OrGB18030() {
        let utf8 = Array("Subject: 设计稿\r\n\r\n".utf8)
        #expect(MailHeaders(bytes: utf8[...]).subject == "设计稿")
        let gbk = Array("Subject: ".utf8) + [UInt8]("设计稿".data(using: Self.gb18030)!) + Array("\r\n".utf8)
        #expect(MailHeaders(bytes: gbk[...]).subject == "设计稿")
        let latin = Array("Subject: caf".utf8) + [0xE9]
        #expect(MailHeaders(bytes: latin[...]).subject == "café")
    }

    @Test func messageIDsLoseTheirAngleBrackets() {
        let headers = MailHeaders(parsing: """
            Message-ID: <20261012.abc123@orchard.example>
            In-Reply-To: <parent.1@orchard.example> (sent from the phone)
            References: <root.0@orchard.example>
             <parent.1@orchard.example>,<other@harbor.example>
            """)
        #expect(headers.messageID == "20261012.abc123@orchard.example")
        #expect(headers.inReplyTo == ["parent.1@orchard.example"])
        #expect(headers.references == ["root.0@orchard.example", "parent.1@orchard.example", "other@harbor.example"])
    }

    @Test func messageIDsWithoutBracketsAndBrokenOnes() {
        #expect(MailHeaders.messageIDs("root.0@orchard.example parent.1@orchard.example") == ["root.0@orchard.example", "parent.1@orchard.example"])
        #expect(MailHeaders.messageIDs("<> <a b@x.example> <ok@x.example>") == ["ok@x.example"])
        #expect(MailHeaders.messageIDs("(comment <not@an.id>) <real@x.example>") == ["real@x.example"])
        #expect(MailHeaders.messageIDs("<unclosed@x.example") == [])
        #expect(MailHeaders.messageIDs("no ids here") == [])
    }

    @Test func aLongReferencesListKeepsTheRootAndTheNewest() {
        let ids = (0..<300).map { "<m\($0)@orchard.example>" }.joined(separator: " ")
        let references = MailHeaders(parsing: "References: \(ids)").references
        #expect(references.count == 200)
        #expect(references.first == "m0@orchard.example")
        #expect(references.last == "m299@orchard.example")
        #expect(references[1] == "m101@orchard.example")
    }

    @Test func addressListsGiveNamesAndNormalizedAddresses() {
        let list = MailAddressHeader.list(
            #""Tan, Mei" <Mei.Tan@Orchard.example>, lu@orchard.example (Lu Wen), Team: a@x.example, B@X.example;, "#
                + #"=?UTF-8?B?6aG+6L+c?= <theo@studio.example>, not an address, <broken@>"#)
        #expect(list == [
            MailAddressHeader(name: "Tan, Mei", address: "mei.tan@orchard.example"),
            MailAddressHeader(name: "Lu Wen", address: "lu@orchard.example"),
            MailAddressHeader(name: "", address: "a@x.example"),
            MailAddressHeader(name: "", address: "b@x.example"),
            MailAddressHeader(name: "顾远", address: "theo@studio.example"),
        ])
    }

    /// A check that must see every address Mail may reply to counts the entries not read
    /// exactly: one left out, and one with a second address in angle brackets or text after
    /// the one. Empty entries and groups without members do not count.
    @Test func entriesNotReadExactlyAreCounted() {
        let mixed = MailAddressHeader.read(
            #""Tan, Mei" <Mei.Tan@Orchard.example>, lu@orchard.example (Lu Wen), Team: a@x.example, B@X.example;, "#
                + #"=?UTF-8?B?6aG+6L+c?= <theo@studio.example>, not an address, <broken@>"#)
        #expect(mixed.mailboxes.count == 5)
        #expect(mixed.unclear == 2)
        #expect(MailAddressHeader.read("Mei <mei@harbor.example> (Mei Tan), , undisclosed-recipients:;, lu@orchard.example,").unclear == 0)
        let unclear = [
            #""mallory x"@other.example"#, "mallory@[192.0.2.1]", "mallory@other.example.", "<>",
            "<mallory@other.example> <mei@harbor.example>", "<mei@harbor.example> mallory@other.example",
            #"<mei@harbor.example> "mallory@other.example""#, "<mei@harbor.example>: mallory@other.example",
        ]
        for value in unclear {
            #expect(MailAddressHeader.read("lu@orchard.example, " + value).unclear == 1, "\(value)")
        }
        let many = (0...1_000).map { "p\($0)@harbor.example" }.joined(separator: ", ")
        #expect(MailAddressHeader.read(many).mailboxes.count == 1_000)
        #expect(MailAddressHeader.read(many).unclear == 1)
        let headers = MailHeaders(parsing: "To: lu@orchard.example\r\nCc: lu@orchard.example\r\nCc: mallory@other.example.\r\n")
        #expect(headers.exactAddresses("To")?.map(\.address) == ["lu@orchard.example"])
        #expect(headers.exactAddresses("Cc") == nil)
        #expect(headers.exactAddresses("Reply-To") == [])
    }

    @Test func addressFieldsOfAMessage() {
        let headers = MailHeaders(parsing: """
            From: Noor Saleh <noor.saleh@harbor.example>
            To: theo@studio.example
            To: "Ravi  Kumar" <ravi@harbor.example>
            Cc: undisclosed-recipients:;
            Reply-To: <billing@harbor.example>
            """)
        #expect(headers.from == [MailAddressHeader(name: "Noor Saleh", address: "noor.saleh@harbor.example")])
        #expect(headers.to.map(\.address) == ["theo@studio.example", "ravi@harbor.example"])
        #expect(headers.to.last?.name == "Ravi Kumar")
        #expect(headers.cc.isEmpty)
        #expect(headers.replyTo.map(\.address) == ["billing@harbor.example"])
    }

    @Test(arguments: [
        ("Mon, 12 Oct 2026 09:30:00 +0800", "2026-10-12T01:30:00Z"),
        ("12 Oct 2026 09:30 +0800", "2026-10-12T01:30:00Z"),
        ("Mon, 12 Oct 2026 09:30:15 -0500 (CDT)", "2026-10-12T14:30:15Z"),
        ("Mon, 12 Oct 2026 01:30:00 GMT", "2026-10-12T01:30:00Z"),
        ("Mon, 12 Oct 2026 01:30:00", "2026-10-12T01:30:00Z"),
        ("Mon, 12 Oct 26 01:30:00 EST", "2026-10-12T06:30:00Z"),
        ("Tue, 29 Feb 2028 23:59:59 +0000", "2028-02-29T23:59:59Z"),
        ("Fri, 1 Jan 2027 00:00:00 +1400", "2026-12-31T10:00:00Z"),
        ("Oct 12 2026 09:30:00 +0000", "2026-10-12T09:30:00Z"),
    ])
    func datesRead(_ value: String, _ expected: String) throws {
        let date = try #require(MailHeaders.date(value))
        #expect(date == ISO8601DateFormatter().date(from: expected))
    }

    @Test(arguments: ["", "yesterday", "Mon, 32 Oct 2026 09:30:00 +0800", "Mon, 12 Foo 2026 09:30 +0800", "12 Oct 2026 25:00 +0800", "12 Oct 2026 09:30 +08"])
    func badDatesGiveNil(_ value: String) {
        #expect(MailHeaders.date(value) == nil)
    }

    @Test func theDateField() {
        #expect(MailHeaders(parsing: "Date: Mon, 12 Oct 2026 09:30:00 +0800").date == ISO8601DateFormatter().date(from: "2026-10-12T01:30:00Z"))
        #expect(MailHeaders(parsing: "Subject: x").date == nil)
    }

    @Test func charsetsFallBackWhenBytesDoNotFit() {
        let gbk = [UInt8]("报价".data(using: Self.gb18030)!)
        // Labeled UTF-8 but not UTF-8: the valid characters stay.
        #expect(MailHeaders.text(gbk + Array("ok".utf8), charset: "utf-8").hasSuffix("ok"))
        // Labeled Latin-1 but valid UTF-8: read as UTF-8.
        #expect(MailHeaders.text(Array("café".utf8), charset: "iso-8859-1") == "café")
        // No label: UTF-8, then GB18030.
        #expect(MailHeaders.text(gbk, charset: nil) == "报价")
        // Windows-1252 has no character for 0x81, so Latin-1 reads it.
        #expect(MailHeaders.text([0x41, 0x81], charset: "windows-1252") == "A\u{81}")
        #expect(MailHeaders.text([0x93, 0x41, 0x94], charset: "windows-1252") == "“A”")
    }

    @Test func base64AndQuotedPrintableAreLenient() {
        #expect(MailHeaders.base64(Array("aGVs\r\nbG8=".utf8)) == Array("hello".utf8))
        #expect(MailHeaders.base64(Array("aGVsbG8".utf8)) == Array("hello".utf8))
        #expect(MailHeaders.base64(Array("a*G!V sbG8=junk".utf8)) == Array("hello".utf8))
        #expect(MailHeaders.quotedPrintable(Array("caf=C3=A9 =\r\nau lait=3d=ZZ=".utf8)) == Array("café au lait==ZZ".utf8))
        #expect(MailHeaders.quotedPrintable(Array("a=  \nb".utf8)) == Array("ab".utf8))
    }
}
