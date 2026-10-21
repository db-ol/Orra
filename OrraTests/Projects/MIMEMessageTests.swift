import Foundation
import Testing
@testable import Orra

struct MIMEMessageTests {
    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// A source with CRLF line breaks, as mail travels.
    private static func source(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    @Test func aPlainMessageWithoutMIMEHeaders() {
        let message = MIMEMessage(source: Self.source([
            "From: Mei Tan <mei.tan@orchard.example>",
            "Subject: Proofs",
            "Message-ID: <proofs.1@orchard.example>",
            "",
            "The proofs are ready.",
            "See you Friday.",
        ]))
        #expect(message.headers.subject == "Proofs")
        #expect(message.headers.messageID == "proofs.1@orchard.example")
        #expect(message.bodies == [MIMEMessage.Body(format: .plain, text: "The proofs are ready.\nSee you Friday.")])
        #expect(message.attachments.isEmpty)
        #expect(!message.isCut)
    }

    @Test func quotedPrintableAndBase64BodiesDecodeInTheirCharsets() {
        let qp = MIMEMessage(source: Self.source([
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "Caf=C3=A9 au lait at the studio, a long line that wraps =",
            "here.",
        ]))
        #expect(qp.bodies.map(\.text) == ["Café au lait at the studio, a long line that wraps here."])

        let text = "顾总，样书已经装箱，周五发出。镕"
        let gbk = MIMEMessage(source: Self.source([
            "Content-Type: text/plain; charset=gb2312",
            "Content-Transfer-Encoding: base64",
            "",
            Self.base64Lines(text.data(using: Self.gb18030)!),
        ]))
        #expect(gbk.bodies.map(\.text) == [text])
    }

    @Test func eightBitBodiesKeepTheirCharset() {
        let header = Array("Content-Type: text/plain; charset=GBK\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
        let message = MIMEMessage(source: Data(header + [UInt8]("定金周三到账".data(using: Self.gb18030)!)))
        #expect(message.bodies.map(\.text) == ["定金周三到账"])
    }

    @Test func aTextSourceReadsAsBytesOrAsDecodedText() {
        // Characters that all fit in a byte are the source's bytes, so the GBK body decodes.
        let gbkBytes = [UInt8]("定金".data(using: Self.gb18030)!)
        let latin = "Content-Type: text/plain; charset=gbk\r\n\r\n" + String(String.UnicodeScalarView(gbkBytes.map { Unicode.Scalar($0) }))
        #expect(MIMEMessage(source: latin).bodies.map(\.text) == ["定金"])
        // A source that Mail decoded already reads its 8 bit part as UTF-8, whatever the label.
        let decoded = "Content-Type: text/plain; charset=gbk\r\nContent-Transfer-Encoding: 8bit\r\n\r\n定金周三到账"
        #expect(MIMEMessage(source: decoded).bodies.map(\.text) == ["定金周三到账"])
        // A base64 part still decodes in its charset.
        let encoded = "Content-Type: text/plain; charset=gbk\r\nContent-Transfer-Encoding: base64\r\nX-Note: 已解码\r\n\r\n"
            + "定金".data(using: Self.gb18030)!.base64EncodedString()
        #expect(MIMEMessage(source: encoded).bodies.map(\.text) == ["定金"])
    }

    @Test func alternativeKeepsTheLastPartWithText() {
        let htmlLast = MIMEMessage(source: Self.source([
            "Content-Type: multipart/alternative; boundary=\"b1\"",
            "",
            "--b1",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Plain version",
            "--b1",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<p>Rich version</p>",
            "--b1--",
            "",
        ]))
        #expect(htmlLast.bodies == [MIMEMessage.Body(format: .markup, text: "<p>Rich version</p>")])

        let plainLast = MIMEMessage(source: Self.source([
            "Content-Type: multipart/alternative; boundary=b2",
            "",
            "preamble that no one reads",
            "--b2",
            "Content-Type: text/html",
            "",
            "<p>Rich</p>",
            "--b2",
            "Content-Type: text/plain",
            "",
            "Plain",
            "--b2--",
            "epilogue",
        ]))
        #expect(plainLast.bodies == [MIMEMessage.Body(format: .plain, text: "Plain")])
    }

    @Test func mixedGivesTextInOrderAndListsAttachments() {
        let message = MIMEMessage(source: Self.source([
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "--outer",
            "Content-Type: multipart/alternative; boundary=\"inner\"",
            "",
            "--inner",
            "Content-Type: text/plain",
            "",
            "First",
            "--inner",
            "Content-Type: multipart/related; boundary=\"rel\"",
            "",
            "--rel",
            "Content-Type: text/html",
            "",
            "<p>First</p><img src=\"cid:logo\">",
            "--rel",
            "Content-Type: image/png; name=logo.png",
            "Content-ID: <logo>",
            "Content-Transfer-Encoding: base64",
            "",
            "iVBORw0KGgo=",
            "--rel--",
            "--inner--",
            "--outer",
            "Content-Type: application/pdf; name=\"quote.pdf\"",
            "Content-Disposition: attachment; filename*=UTF-8''%E6%8A%A5%E4%BB%B7%E5%8D%95.pdf",
            "Content-Transfer-Encoding: base64",
            "",
            "JVBERi0xLjQK",
            "--outer",
            "Content-Type: text/plain",
            "",
            "Second",
            "--outer",
            "Content-Type: TEXT/PLAIN; name=\"notes.txt\"",
            "",
            "an attached text file",
            "--outer",
            "Content-Type: message/rfc822",
            "Content-Disposition: attachment; filename=\"=?UTF-8?B?5Y6f6YKu5Lu2?=.eml\"",
            "",
            "Subject: inner",
            "",
            "inner text",
            "--outer--",
        ]))
        #expect(message.bodies == [
            MIMEMessage.Body(format: .markup, text: "<p>First</p><img src=\"cid:logo\">"),
            MIMEMessage.Body(format: .plain, text: "Second"),
        ])
        #expect(message.attachments == [
            MIMEMessage.Attachment(name: "logo.png", mimeType: "image/png", isInline: true),
            MIMEMessage.Attachment(name: "报价单.pdf", mimeType: "application/pdf", isInline: false),
            MIMEMessage.Attachment(name: "notes.txt", mimeType: "text/plain", isInline: false),
            MIMEMessage.Attachment(name: "原邮件.eml", mimeType: "message/rfc822", isInline: false),
        ])
    }

    @Test func signedMailGivesItsTextAndNoSignature() {
        let message = MIMEMessage(source: Self.source([
            "Content-Type: multipart/signed; protocol=\"application/pkcs7-signature\"; boundary=s",
            "",
            "--s",
            "Content-Type: text/plain",
            "",
            "Signed text",
            "--s",
            "Content-Type: application/pkcs7-signature; name=smime.p7s",
            "Content-Disposition: attachment; filename=smime.p7s",
            "",
            "MIAGCSqGSIb3DQEHAqCAMIACAQEx",
            "--s--",
        ]))
        #expect(message.bodies.map(\.text) == ["Signed text"])
        #expect(message.attachments.isEmpty)
    }

    @Test func encryptedMailGivesNothing() {
        let message = MIMEMessage(source: Self.source([
            "Content-Type: multipart/encrypted; boundary=e",
            "",
            "--e",
            "Content-Type: application/pgp-encrypted",
            "",
            "Version: 1",
            "--e--",
        ]))
        #expect(message.bodies.isEmpty)
        #expect(message.attachments.isEmpty)
    }

    @Test func brokenStructureReadsAsFarAsItCan() {
        // No closing delimiter: the last part runs to the end.
        let unclosed = MIMEMessage(source: Self.source([
            "Content-Type: multipart/mixed; boundary=u",
            "",
            "--u",
            "",
            "Part one",
            "--u",
            "Content-Type: text/plain",
            "",
            "Part two",
        ]))
        #expect(unclosed.bodies.map(\.text) == ["Part one", "Part two"])

        // A multipart that cannot be split gives no text, since its parts as plain text
        // would show markup and hidden text that Mail never shows.
        let missing = MIMEMessage(source: Self.source([
            "Content-Type: multipart/mixed; boundary=never",
            "",
            "Just text",
        ]))
        #expect(missing.bodies.isEmpty)
        #expect(missing.isCut)
        let noBoundary = MIMEMessage(source: Self.source(["Content-Type: multipart/mixed", "", "Text"]))
        #expect(noBoundary.bodies.isEmpty)
        #expect(noBoundary.isCut)

        // A line that only starts like a delimiter is text.
        let lookalike = MIMEMessage(source: Self.source([
            "Content-Type: multipart/mixed; boundary=ab",
            "",
            "--ab",
            "",
            "--abc is not a delimiter",
            "--ab--",
        ]))
        #expect(lookalike.bodies.map(\.text) == ["--abc is not a delimiter"])

        // No blank line after the headers.
        let headersOnly = MIMEMessage(source: Self.source(["Subject: only headers"]))
        #expect(headersOnly.headers.subject == "only headers")
        #expect(headersOnly.bodies.map(\.text) == [""])
    }

    @Test func aPartWithoutHeadersIsPlainText() {
        let message = MIMEMessage(source: Self.source([
            "Content-Type: multipart/mixed; boundary=p",
            "",
            "--p",
            "no headers here, just text",
            "--p--",
        ]))
        #expect(message.bodies.map(\.text) == ["no headers here, just text"])
    }

    @Test func anMboxFromLineIsSkipped() {
        let message = MIMEMessage(source: Self.source([
            "From mei.tan@orchard.example Mon Oct 12 09:30:00 2026",
            "Subject: From an export",
            "",
            "Body",
        ]))
        #expect(message.headers.subject == "From an export")
        #expect(message.bodies.map(\.text) == ["Body"])
    }

    @Test func flowedTextJoinsItsSoftBreaks() {
        let message = MIMEMessage(source: Self.source([
            "Content-Type: text/plain; charset=utf-8; format=flowed; delsp=no",
            "",
            "This line goes on ",
            "in the next one.",
            " From here, stuffed.",
            "> quoted and ",
            "> joined",
            "-- ",
            "Mei",
        ]))
        #expect(message.bodies.map(\.text) == ["This line goes on in the next one.\nFrom here, stuffed.\n> quoted and joined\n-- \nMei"])
        let delsp = MIMEMessage(source: Self.source([
            "Content-Type: text/plain; format=flowed; delsp=yes",
            "",
            "工作 ",
            "室",
        ]))
        #expect(delsp.bodies.map(\.text) == ["工作室"])
    }

    @Test func limitsCutTheWork() {
        let parts = (1...10).flatMap { ["--m", "Content-Type: text/plain", "", "Part \($0)"] }
        let many = Self.source(["Content-Type: multipart/mixed; boundary=m", ""] + parts + ["--m--"])
        let fewParts = MIMEMessage(source: many, limits: MIMEMessage.Limits(maximumParts: 3))
        #expect(fewParts.bodies.map(\.text) == ["Part 1", "Part 2", "Part 3"])
        #expect(fewParts.isCut)

        var nested = ["Content-Type: multipart/mixed; boundary=d0", ""]
        for depth in 1...6 {
            nested += ["--d\(depth - 1)", "Content-Type: multipart/mixed; boundary=d\(depth)", ""]
        }
        nested += ["--d6", "", "Deep text"]
        let shallow = MIMEMessage(source: Self.source(nested), limits: MIMEMessage.Limits(maximumDepth: 3))
        #expect(shallow.bodies.isEmpty)
        #expect(shallow.isCut)
        #expect(MIMEMessage(source: Self.source(nested)).bodies.map(\.text) == ["Deep text"])

        let long = Self.source(["Content-Type: text/plain; charset=utf-8", "", String(repeating: "工", count: 100)])
        let shortText = MIMEMessage(source: long, limits: MIMEMessage.Limits(maximumTextBytes: 31))
        #expect(shortText.bodies.map(\.text) == [String(repeating: "工", count: 10)])
        #expect(shortText.isCut)

        let shortSource = MIMEMessage(source: long, limits: MIMEMessage.Limits(maximumSourceBytes: 48))
        #expect(shortSource.isCut)
        #expect(shortSource.bodies.first.map { $0.text.count < 100 } == true)

        let fewSteps = MIMEMessage(source: many, limits: MIMEMessage.Limits(maximumSteps: 20))
        #expect(fewSteps.isCut)
        #expect(fewSteps.steps <= 20 + many.count)
    }

    /// An alternative that a limit cut or left unread may be the one Mail shows, so no
    /// earlier alternative stands in for it, whatever the limit. A sender could otherwise
    /// show one text in Mail and give the model another.
    @Test func anAlternativeCutAtALimitGivesNoEarlierOne() throws {
        let source = Self.source([
            "Content-Type: multipart/alternative; boundary=b",
            "",
            "--b",
            "Content-Type: text/plain",
            "",
            "Plain only words",
            "--b",
            "Content-Type: text/html",
            "",
            "<p>Rich</p>",
            "--b--",
            "",
        ])
        let whole = MIMEMessage(source: source)
        #expect(whole.bodies == [MIMEMessage.Body(format: .markup, text: "<p>Rich</p>")])
        #expect(!whole.isCut)

        let inPlain = try #require(source.range(of: Data("only".utf8))).lowerBound
        let cut = [
            // The plain part spends the whole text budget.
            MIMEMessage.Limits(maximumTextBytes: 16),
            MIMEMessage.Limits(maximumParts: 1),
            MIMEMessage.Limits(maximumSteps: whole.steps - 1),
            // The source ends in the plain part.
            MIMEMessage.Limits(maximumSourceBytes: inPlain),
        ]
        for limits in cut {
            let message = MIMEMessage(source: source, limits: limits)
            #expect(message.bodies.isEmpty, "\(limits)")
            #expect(message.isCut, "\(limits)")
        }

        let nested = Self.source([
            "Content-Type: multipart/alternative; boundary=b",
            "",
            "--b",
            "Content-Type: text/plain",
            "",
            "Plain only words",
            "--b",
            "Content-Type: multipart/mixed; boundary=m1",
            "",
            "--m1",
            "Content-Type: multipart/mixed; boundary=m2",
            "",
            "--m2",
            "Content-Type: text/html",
            "",
            "<p>Rich</p>",
            "--m2--",
            "--m1--",
            "--b--",
            "",
        ])
        #expect(MIMEMessage(source: nested).bodies == [MIMEMessage.Body(format: .markup, text: "<p>Rich</p>")])
        let shallow = MIMEMessage(source: nested, limits: MIMEMessage.Limits(maximumDepth: 2))
        #expect(shallow.bodies.isEmpty)
        #expect(shallow.isCut)

        // A cut plain part is still the one shown when no later alternative has text.
        let image = Self.source([
            "Content-Type: multipart/alternative; boundary=b",
            "",
            "--b",
            "Content-Type: text/plain",
            "",
            "Plain only words",
            "--b",
            "Content-Type: image/png",
            "",
            "iVBORw0KGgo=",
            "--b--",
            "",
        ])
        let cutPlain = MIMEMessage(source: image, limits: MIMEMessage.Limits(maximumTextBytes: 10))
        #expect(cutPlain.bodies == [MIMEMessage.Body(format: .plain, text: "Plain only")])
        #expect(cutPlain.isCut)
    }

    @Test func stepsGrowWithTheSize() {
        let lines = (1...200).map { "Line \($0) of the letter." }
        let small = MIMEMessage(source: Self.source(["Subject: s", ""] + lines.prefix(20)))
        let large = MIMEMessage(source: Self.source(["Subject: s", ""] + lines))
        #expect(small.steps > 0)
        #expect(large.steps > small.steps)
        #expect(large.steps <= 4 * Self.source(["Subject: s", ""] + lines).count)
    }

    @Test func parsingOffTheMainActorGivesTheSameMessage() async {
        let source = Self.source(["Subject: async", "", "Body"])
        #expect(await MIMEMessage.parsed("Subject: async\r\n\r\nBody") == MIMEMessage(source: source))
    }

    @Test func aTextSourceOfLatinCharactersReadsAsTheyCame() {
        // Mail may give an 8 bit UTF-8 message as the characters it decoded. They all fit in
        // a byte, but are not the source's bytes, so they read as they came.
        let decoded = "Subject: Réunion à 10h\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\nCafé à 10h, Größe ok."
        let message = MIMEMessage(source: decoded)
        #expect(message.headers.subject == "Réunion à 10h")
        #expect(message.bodies.map(\.text) == ["Café à 10h, Größe ok."])
    }

    @Test(arguments: [
        // An encoded word is a valid boundary, and stays as it is.
        "Content-Type: multipart/alternative; boundary=\"=?utf-8?q?x?=\"",
        // A comment may stand in the field.
        "Content-Type: multipart/alternative (generated); boundary=\"b1\"",
        "Content-Type: multipart/alternative; boundary=\"b1\"; boundary=\"b2\"",
    ])
    func multipartFieldsReadAsMailReadsThem(_ field: String) {
        let boundary = field.contains("=?utf-8") ? "=?utf-8?q?x?=" : "b1"
        let message = MIMEMessage(source: Self.source([
            field,
            "",
            "--\(boundary)",
            "Content-Type: text/plain",
            "",
            "Plain version",
            "--\(boundary)",
            "Content-Type: text/html",
            "",
            "<p>Rich</p><div style=\"display:none\">secret line</div>",
            "--\(boundary)--",
        ]))
        #expect(message.bodies == [MIMEMessage.Body(format: .markup, text: "<p>Rich</p><div style=\"display:none\">secret line</div>")])
        #expect(VisibleText(message).text == "Rich")
    }

    @Test func onlyTheShownAlternativeListsItsAttachments() {
        let message = MIMEMessage(source: Self.source([
            "Content-Type: multipart/alternative; boundary=a",
            "",
            "--a",
            "Content-Type: multipart/related; boundary=r",
            "",
            "--r",
            "Content-Type: text/html",
            "",
            "<p>Rich</p>",
            "--r",
            "Content-Type: image/png; name=hero.png",
            "",
            "iVBORw0KGgo=",
            "--r--",
            "--a",
            "Content-Type: text/plain",
            "",
            "Plain",
            "--a",
            "Content-Type: text/x-amp-html",
            "",
            "<p>amp</p>",
            "--a--",
        ]))
        #expect(message.bodies.map(\.text) == ["Plain"])
        #expect(message.attachments.isEmpty)
    }

    @Test func headerValuesReadParametersOfEveryForm() {
        let value = MIMEMessage.HeaderValue(#"Attachment ; filename*0*=utf-8''%E6%8A%A5; filename*1="价单.pdf"; size=12; x="a;b\"c""#)
        #expect(value.value == "attachment")
        #expect(value.parameters["filename"] == "报价单.pdf")
        #expect(value.parameters["size"] == "12")
        #expect(value.parameters["x"] == #"a;b"c"#)
        #expect(MIMEMessage.HeaderValue("text/plain").parameters.isEmpty)
        // Comments go, the first of a name counts, and only file names decode encoded words.
        let type = MIMEMessage.HeaderValue(#"Text / HTML (generated (nested)); charset="=?x?q?y?="; name="=?UTF-8?B?5Y6f?=.txt"; name=other; note="(kept)""#)
        #expect(type.value == "text/html")
        #expect(type.parameters["charset"] == "=?x?q?y?=")
        #expect(type.parameters["name"] == "原.txt")
        #expect(type.parameters["note"] == "(kept)")
    }
}
