import Foundation
import Testing
@testable import Orra

/// The files an email asks for, found by code rules in English, Chinese, Japanese and
/// Spanish: what counts as a request, what it asks for and the kinds it names, and what is
/// no request. The sentences are written for these tests.
struct FileRequestsTests {
    /// A sentence, what it asks for and the kinds it names.
    private typealias Case = (sentence: String, object: String, kinds: [DocumentKind])

    private static func found(_ text: String, subject: String = "") -> [FileRequest] {
        FileRequests.find(in: text, subject: subject)
    }

    private static func expectRequests(_ cases: [Case]) {
        for item in cases {
            let requests = found(item.sentence)
            #expect(requests.count == 1, "\(item.sentence)")
            guard let request = requests.first else { continue }
            #expect(request.object == item.object, "\(item.sentence)")
            #expect(request.documentKinds == item.kinds, "\(item.sentence)")
            // The sentence that asks, which is the whole text or its first sentence.
            #expect(!request.sentence.isEmpty && item.sentence.hasPrefix(request.sentence), "\(item.sentence)")
        }
    }

    private static func expectNone(_ sentences: [String]) {
        for sentence in sentences {
            #expect(found(sentence).isEmpty, "\(sentence)")
        }
    }

    // MARK: Requests in four languages

    @Test func requestsInEnglish() {
        Self.expectRequests([
            ("Please also send the floor plan and the lighting spec.", "the floor plan and the lighting spec", [.floorPlan, .specification]),
            ("Could you please send me the floor plan?", "the floor plan", [.floorPlan]),
            ("Can you share the budget with us?", "the budget", [.budget]),
            ("Would you mind sending the contract?", "the contract", [.contract]),
            ("I'd appreciate it if you could send over the quote.", "the quote", [.quote]),
            ("Kindly forward the signed contract to Kai.", "the signed contract", [.contract]),
            ("Please email me the invoice.", "the invoice", [.invoice]),
            ("Send me the schedule when you can.", "the schedule", [.schedule]),
            ("Hi Lin, send me the drawings for the lobby by Friday.", "the drawings", [.drawing]),
            ("We need the invoice by Friday.", "the invoice", [.invoice]),
            ("We'll need the updated renderings.", "the updated renderings", [.rendering]),
            ("Do you have the latest drawings?", "the latest drawings", [.drawing]),
            ("Please send the floor plan for the lobby.", "the floor plan", [.floorPlan]),
            ("Could you send me a copy of the contract?", "a copy of the contract", [.document, .contract]),
            ("Can you upload the photos from the site visit?", "the photos from the site visit", [.photo]),
            ("Please resend the slides from yesterday's meeting.", "the slides", [.slides]),
            ("Please let me know when you can send the meeting minutes.", "the meeting minutes", [.minutes]),
            ("I need you to send the CV.", "the CV", [.cv]),
            ("Could you send the contract over by Friday, please?", "the contract", [.contract]),
            ("There is no need to send the plan, but could you share the budget?", "the budget", [.budget]),
            ("Could you send me the drawings and specs for the lobby?", "the drawings and specs", [.drawing, .specification]),
            ("Could you send me the price list for 2026?", "the price list", [.quote]),
        ])
    }

    @Test func requestsInChinese() {
        Self.expectRequests([
            ("请把平面图发给我。", "平面图", [.floorPlan]),
            ("请把最新的平面图发给我。", "平面图", [.floorPlan]),
            ("麻烦发一下最新的施工图", "施工图", [.drawing]),
            ("能否提供报价单？", "报价单", [.quote]),
            ("请将合同扫描件发送至我的邮箱", "合同扫描件", [.contract, .scan]),
            ("也请发一下平面图", "平面图", [.floorPlan]),
            ("我们需要最新的平面图", "平面图", [.floorPlan]),
            ("你们有没有最新的平面图？", "平面图", [.floorPlan]),
            ("请发我一份报价单和合同", "报价单和合同", [.quote, .contract]),
            ("麻烦把报价单和发票发给我", "报价单和发票", [.quote, .invoice]),
            ("方便的话把效果图传给我们", "效果图", [.rendering]),
            ("记得把会议纪要发给大家", "会议纪要", [.minutes]),
            ("请提供贵司的营业执照", "营业执照", [.certificate]),
            ("请把平面图的电子版发给我", "平面图的电子版", [.floorPlan, .document]),
            ("麻烦您有空的时候发一下平面图给我", "平面图", [.floorPlan]),
            ("需要你们提供平面图", "平面图", [.floorPlan]),
            ("我们需要你提供最新的平面图和报价单。", "平面图和报价单", [.floorPlan, .quote]),
            ("请把“平面图”发给我。", "平面图", [.floorPlan]),
            ("请问能否把施工图纸和效果图发给我们？", "施工图纸和效果图", [.drawing, .rendering]),
            ("你有最新的课件吗？", "课件", [.slides]),
            ("请把简历发到我的邮箱。", "简历", [.cv]),
        ])
    }

    @Test func requestsInJapanese() {
        Self.expectRequests([
            ("平面図を送っていただけますか。", "平面図", [.floorPlan]),
            ("見積書もお送りいただけますでしょうか", "見積書", [.quote]),
            ("最新の図面を共有してください", "図面", [.drawing]),
            ("資料をご送付ください", "資料", [.document]),
            ("図面が必要です", "図面", [.drawing]),
            ("平面図をいただけますか", "平面図", [.floorPlan]),
            ("お手数ですが、最新の平面図を送ってください。", "平面図", [.floorPlan]),
            ("契約書のご提供をお願いいたします", "契約書", [.contract]),
            ("写真と見積書を送ってください", "写真と見積書", [.photo, .quote]),
            ("議事録を共有していただけませんか。", "議事録", [.minutes]),
            ("また、請求書を至急送ってください。", "請求書", [.invoice]),
            ("履歴書を添付してください。", "履歴書", [.cv]),
            ("仕様書が必要です。", "仕様書", [.specification]),
            ("スライドもお送りいただけますか", "スライド", [.slides]),
            ("報告書のご送付をお願いします", "報告書", [.report]),
            ("先日の打ち合わせの議事録を送ってください", "議事録", [.minutes]),
            ("パースをご共有いただけますか", "パース", [.rendering]),
            ("工程表を送付してください", "工程表", [.schedule]),
            ("申請書を転送してください", "申請書", [.form]),
            ("カタログを送っていただけますでしょうか", "カタログ", [.catalog]),
        ])
    }

    @Test func requestsInSpanish() {
        Self.expectRequests([
            ("¿Me puedes enviar el plano?", "el plano", [.floorPlan, .drawing]),
            ("Hola, ¿me puedes enviar el plano de la planta baja antes del viernes? Gracias.", "el plano", [.floorPlan, .drawing]),
            ("Por favor, envíame la cotización.", "la cotización", [.quote]),
            ("Por favor, enviame la cotizacion.", "la cotizacion", [.quote]),
            ("¿Podrías compartirnos el presupuesto actualizado?", "el presupuesto actualizado", [.quote, .budget]),
            ("Necesito el contrato firmado.", "el contrato firmado", [.contract]),
            ("Mándame las fotos de la obra, por favor.", "las fotos de la obra", [.photo]),
            ("¿No me podrías enviar el plano?", "el plano", [.floorPlan, .drawing]),
            ("Te agradecería que me enviaras la factura.", "la factura", [.invoice]),
            ("Envíame una copia de la factura.", "una copia de la factura", [.document, .invoice]),
            ("Por favor adjunta el informe de ventas.", "el informe", [.report]),
            ("Necesitamos las especificaciones técnicas.", "las especificaciones técnicas", [.specification]),
            ("¿Puedes mandarme el cronograma?", "el cronograma", [.schedule]),
            ("¿Podrías pasarme el acta de la reunión?", "el acta", [.minutes]),
            ("¿Me podrías facilitar el certificado?", "el certificado", [.certificate]),
            ("Favor de enviar los planos antes del lunes.", "los planos", [.floorPlan, .drawing]),
            ("Compártenos la presentación, por favor.", "la presentación", [.slides]),
            ("¿Puede remitirnos el catálogo?", "el catálogo", [.catalog]),
            ("Necesito que me envíes tu currículum.", "tu currículum", [.cv]),
            ("Adjunta la planilla, por favor.", "la planilla", [.spreadsheet]),
            ("¿Puedes enviarme la hoja de cálculo?", "la hoja de cálculo", [.spreadsheet]),
        ])
    }

    // MARK: No requests

    @Test func theSendersOwnAttachmentsAndPromisesAreNoRequests() {
        Self.expectNone([
            "Please find attached the floor plan.",
            "Attached is the floor plan.",
            "I've attached the floor plan.",
            "I will send the floor plan tomorrow.",
            "Please note that I'm sending the floor plan today.",
            "Please let me know if I should send the floor plan.",
            "随信附上平面图，请查收。",
            "现附上报价单，供您参考。",
            "我会把平面图发给你",
            "我也发了平面图",
            "我们这边也可以提供报价单",
            "平面图也发给你了",
            "図面を添付いたします",
            "平面図をお送りします",
            "Te adjunto el plano.",
            "Adjunto el plano.",
            "Va adjunta la factura.",
            "Te envío el plano mañana.",
            "Por favor, confirma que envié el contrato.",
            "Por favor, confirma que mandé el contrato.",
        ])
        // The sender's own attachment counts in its own clause only.
        #expect(Self.found("我已附上合同，请发一下平面图。").first?.documentKinds == [.floorPlan])
    }

    @Test func negationsAreNoRequests() {
        Self.expectNone([
            "Please don't send the floor plan yet.",
            "No need to send the floor plan, I have it.",
            "Please do not forward the contract.",
            "不用发平面图了",
            "请不要把平面图发给别人",
            "资料暂时不用发。",
            "資料を送らないでください",
            "No me envíes el plano todavía.",
            "No hace falta que me envíes el plano.",
        ])
    }

    @Test func questionsAboutWhatArrivedAndOtherAsksAreNoRequests() {
        Self.expectNone([
            "Did you get the floor plan I sent?",
            "Please send it to me.",
            "We need to send the floor plan.",
            "Do you have time to meet?",
            "Could you confirm the date?",
            "Please send me your thoughts.",
            "Please send the plan.",
            "平面图收到了吗？",
            "我们需要讨论一下平面图",
            "请把发票开给我们公司",
            "先日お送りいただいた図面を確認しました",
            "お時間をいただけますか",
            "¿Recibiste el plano?",
            "Gracias por enviarme el plano.",
        ])
    }

    @Test func aRequestForCommentsOnADocumentIsNoRequest() {
        Self.expectNone([
            "Please send me your comments on the floor plan.",
            "Could you send me your feedback about the contract?",
            "请把对平面图的意见发给我",
            "¿Puedes enviarme tus comentarios sobre el plano?",
        ])
        // The head of what is asked for decides: the plan for the lobby is still the plan.
        #expect(Self.found("Send me the floor plan for the lobby.").first?.documentKinds == [.floorPlan])
        #expect(Self.found("请把最新的平面图发给我").first?.documentKinds == [.floorPlan])
    }

    // MARK: What a request holds

    @Test func aFileNameInTheRequestIsKept() throws {
        let english = try #require(Self.found("Could you send floor-plan-v3.pdf?").first)
        #expect(english.fileNames == ["floor-plan-v3.pdf"])
        let spaced = try #require(Self.found("Could you send me the Harbor lobby floor plan v3.pdf and quote-2026.xlsx?").first)
        #expect(spaced.fileNames == ["Harbor lobby floor plan v3.pdf", "quote-2026.xlsx"])
        let attached = try #require(Self.found("Please send the attached file report.pdf back to me.").first)
        #expect(attached.fileNames == ["report.pdf"])
        let quoted = try #require(Self.found("Please send \"report.pdf\".").first)
        #expect(quoted.fileNames == ["report.pdf"])
        let named = try #require(Self.found("Please send the file \"report.pdf\".").first)
        #expect(named.object == "the file report.pdf")
        #expect(named.fileNames == ["report.pdf"])
        let chinese = try #require(Self.found("请把平面图草图.png发给我").first)
        #expect(chinese.fileNames == ["平面图草图.png"])
        #expect(FileRequests.searchTerms(for: chinese).fileNames == ["平面图草图.png"])
    }

    @Test func aRequestThatNamesOnlyAFileSaysNotWhichOne() throws {
        let plain = try #require(Self.found("Please send me the file.").first)
        #expect(plain.documentKinds == [.document])
        #expect(!plain.saysWhichFile)
        #expect(try #require(Self.found("请发一下资料。").first).saysWhichFile == false)
        #expect(try #require(Self.found("資料をご送付ください").first).saysWhichFile == false)
        #expect(try #require(Self.found("Please send me the Harbor documents.").first).saysWhichFile)
        #expect(try #require(Self.found("Please send the floor plan.").first).saysWhichFile)
    }

    @Test func atMostThreeRequestsWithTheirLengths() {
        let text = "Please send the floor plan. Could you also share the budget? And can you send the photos? Please email the invoice. Please send the contract."
        let requests = Self.found(text)
        #expect(requests.map(\.documentKinds) == [[.floorPlan], [.budget], [.photo]])

        let long = "Could you please send me " + String(repeating: "the very long and winding floor plan ", count: 20) + "?"
        let request = Self.found(long).first
        #expect((request?.sentence.count ?? 0) <= FileRequests.sentenceKept)
        #expect((request?.object.count ?? 0) <= FileRequests.objectKept)
        #expect(request?.documentKinds == [.floorPlan])
    }

    /// The same file asked for twice, as in the subject and the text, is one request.
    @Test func theSameRequestTwiceIsOne() {
        #expect(Self.found("Please send the floor plan. Also, please send the floor plan.").count == 1)
        #expect(Self.found("Could you send me the floor plan?", subject: "Please send the floor plan").count == 1)
    }

    /// A subject asks too, unless it is that of a reply or a forward, which repeats words
    /// someone wrote before.
    @Test func theSubjectOfAReplyOrAForwardIsNotRead() {
        #expect(Self.found("", subject: "Please send the floor plan").first?.documentKinds == [.floorPlan])
        for subject in ["Re: Please send the floor plan", "RE: RE: Please send the floor plan", "Fwd: Please send the floor plan", "回复：请把平面图发给我", "返信: 平面図を送ってください"] {
            #expect(Self.found("Here it is.", subject: subject).isEmpty, "\(subject)")
        }
    }

    /// A sentence that ends in a colon asks for the items of the list under it, once a frame
    /// of it passed its checks.
    @Test func aListUnderAColonIsWhatIsAskedFor() {
        #expect(Self.found("Please do not send the following:\n- contract").isEmpty)
        #expect(Self.found("以下の資料を添付します：\n・契約書").isEmpty)
        #expect(Self.found("Please send the following:\n- floor plan\n- lighting spec\n- the budget for phase 2").first?.documentKinds == [.floorPlan, .specification, .budget])
        #expect(Self.found("请发送以下文件：\n1. 平面图\n2. 报价单").first?.documentKinds == [.floorPlan, .quote])
        #expect(Self.found("以下の資料を送ってください：\n・平面図\n・見積書").first?.documentKinds == [.floorPlan, .quote])
    }

    /// A sentence hard wrapped in a plain text email reads as one.
    @Test func hardWrappedLinesAreJoined() {
        let text = "Hi Lin,\n\nCould you please send me the floor\nplan before Friday?\n\nThanks,\nMei"
        #expect(Self.found(text).first?.object == "the floor plan")
        #expect(Self.found("请把最新的平面\n图发给我。").first?.documentKinds == [.floorPlan])
    }

    /// Nested frames, frames without an end and a text far longer than the part read end
    /// quickly. A slow pattern would hang, and the time limit stops it.
    @Test(.timeLimit(.minutes(1)))
    func aHostileTextEndsInTime() {
        let texts = [
            String(repeating: "please could you please could you send send me me the the ", count: 1_200),
            String(repeating: "请请把把把麻烦也再发发给给", count: 5_000),
            String(repeating: "をもをも送って送ってください", count: 5_000),
            String(repeating: "por favor puedes enviarme enviarme de de de ", count: 1_500),
            String(repeating: "floor plan.pdf ", count: 5_000),
            String(repeating: "Please send the following:\n", count: 3_000),
            "a" + String(repeating: "\u{0301}", count: 200_000) + " Please send the floor plan.",
        ]
        let started = ContinuousClock.now
        for text in texts {
            #expect(Self.found(text, subject: String(text.prefix(5_000))).count <= FileRequests.mostRequests)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    // MARK: Kinds and search terms

    @Test func everyKindHasTermsInFourLanguages() {
        for kind in DocumentKind.allCases {
            let terms = kind.terms
            #expect(!terms.english.isEmpty, "\(kind)")
            #expect(!terms.chinese.isEmpty, "\(kind)")
            #expect(!terms.japanese.isEmpty, "\(kind)")
            #expect(!terms.spanish.isEmpty, "\(kind)")
            for term in terms.all {
                #expect(term == SortingText.matchingForm(term), "\(kind): \(term)")
            }
        }
        #expect(DocumentKind.allCases.count == 27)
        #expect(DocumentKind.allCases.filter(\.isGeneric) == [.document])
    }

    @Test func searchTermsHoldEveryLanguageOfTheKind() throws {
        let request = try #require(Self.found("Please send the latest floor plan for the lobby.").first)
        let terms = FileRequests.searchTerms(for: request)
        #expect(terms.words == "floor plan")
        for term in ["floor plan", "平面图", "平面図", "plano"] {
            #expect(terms.terms.contains(term), "\(term)")
        }
        #expect(!terms.terms.contains("file"))
        // A plain file adds no terms, which would match every file.
        let copy = try #require(Self.found("Could you send me a copy of the contract?").first)
        let copyTerms = FileRequests.searchTerms(for: copy)
        #expect(copyTerms.words == "contract")
        #expect(copyTerms.terms.contains("合同"))
        #expect(!copyTerms.terms.contains("copy"))
    }

    // MARK: Saved requests

    /// A request saved by a later Orra, with a kind this one does not know or a field of
    /// another shape, still reads, so its explanation is never dropped.
    @Test func aSavedRequestWithAnUnknownKindOrABrokenFieldStillReads() throws {
        let saved = #"{"sentence":"Please send the hologram and the floor plan.","object":"the hologram and the floor plan","kinds":["hologram","floorPlan"],"fileNames":[],"confidence":0.9}"#
        let request = try JSONDecoder().decode(FileRequest.self, from: Data(saved.utf8))
        #expect(request.kinds == ["hologram", "floorPlan"])
        #expect(request.documentKinds == [.floorPlan])

        let broken = #"{"sentence":5,"kinds":"floorPlan","fileNames":[1,2]}"#
        let read = try JSONDecoder().decode(FileRequest.self, from: Data(broken.utf8))
        #expect(read == FileRequest(sentence: "", object: "", kinds: [], fileNames: []))

        let original = FileRequest(sentence: "请把平面图发给我。", object: "平面图", kinds: ["floorPlan"], fileNames: ["平面图草图.png"])
        #expect(try JSONDecoder().decode(FileRequest.self, from: JSONEncoder().encode(original)) == original)
    }
}
