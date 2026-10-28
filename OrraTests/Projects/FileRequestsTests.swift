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
            ("Please don't forget to send the floor plan.", "the floor plan", [.floorPlan]),
            ("Don't forget to send me the drawings.", "the drawings", [.drawing]),
            ("Please do not hesitate to send me the floor plan.", "the floor plan", [.floorPlan]),
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
            ("请发平面图给我。", "平面图", [.floorPlan]),
            ("可以发平面图给我吗？", "平面图", [.floorPlan]),
            ("麻烦发平面图过来。", "平面图", [.floorPlan]),
            ("请把平面图的最新版发给我。", "平面图的最新版", [.floorPlan]),
            ("请别忘了把平面图发给我。", "平面图", [.floorPlan]),
            ("不要忘记发报价单给我。", "报价单", [.quote]),
            ("请勿忘记把平面图发给我。", "平面图", [.floorPlan]),
        ])
    }

    /// What is asked for may stand before the frame, as in 厨电规格麻烦发我一下, a signed paper
    /// may be asked back, a clause that starts with 并 asks after a clause that asks, each
    /// thing of a list keeps its own head, and a long file name fits after 把.
    @Test func moreRequestsInChinese() {
        Self.expectRequests([
            ("厨电规格麻烦发我一下，开孔要用。", "厨电规格", [.specification]),
            ("最新的排期表麻烦再发我一份", "排期表", [.schedule]),
            ("厨房的立面图麻烦发我一份", "立面图", [.drawing]),
            ("报价单麻烦发我邮箱", "报价单", [.quote]),
            ("盖章后回传扫描件即可", "扫描件", [.scan]),
            ("合同签字后寄回即可", "合同", [.contract]),
            ("请帮我直接回复同意，并把装修合同和您的身份证照片发过来。", "装修合同和身份证照片", [.contract, .photo]),
            ("请把报价单和您的营业执照发给我", "报价单和营业执照", [.quote, .certificate]),
            ("麻烦把合同再发我一下", "合同", [.contract]),
            ("方便的话把你们文件夹里的报价单和合同都发我参考一下", "报价单和合同", [.quote, .contract]),
        ])
        #expect(Self.found("麻烦把 proof-feedback-2026-10-14.md 再发我一下").first?.fileNames == ["proof-feedback-2026-10-14.md"])
        Self.expectNone([
            "平面图我已经发给你了，麻烦查收。",
            "合同麻烦发一下意见",
            "我们盖章后回传给您。",
            "盖章后已回传。",
            "合并后发给我。",
            "他并把平面图发给了我。",
            "请把对平面图的意见和建议发给我",
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
            ("平面図の最新版を送っていただけますか。", "平面図の最新版", [.floorPlan]),
            ("図面を送るのを忘れないでください。", "図面", [.drawing]),
            ("平面図をいただきたい。", "平面図", [.floorPlan]),
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
            ("No olvides enviarme el plano.", "el plano", [.floorPlan, .drawing]),
            ("No te olvides de enviarme la factura.", "la factura", [.invoice]),
        ])
    }

    // MARK: The constructions of each language

    /// Each construction with the texts that ask with it: the request's object and the kinds
    /// it names, document for a phrase that names no kind. The sentence that asks may come
    /// after others, and what a pronoun points to may stand in the sentence before.
    private static func expectConstruction(_ construction: String, _ cases: [Case]) {
        #expect(cases.count >= 2, "\(construction)")
        for item in cases {
            let requests = found(item.sentence)
            #expect(requests.count == 1, "\(construction): \(item.sentence)")
            guard let request = requests.first else { continue }
            #expect(request.object == item.object, "\(construction): \(item.sentence)")
            #expect(request.documentKinds == item.kinds, "\(construction): \(item.sentence)")
            #expect(request.saysWhichFile, "\(construction): \(item.sentence)")
        }
    }

    @Test func englishAsksForADocumentInEachConstruction() {
        Self.expectConstruction("a verb of sending and a phrase that names no kind, searched by its words", [
            ("Could you send me the speaker bio you wrote for the panel?", "the speaker bio", [.document]),
            ("Would you mind forwarding the venue checklist to Mei?", "the venue checklist", [.document]),
            ("Please send the plan.", "the plan", [.document]),
        ])
        Self.expectConstruction("a request in passing, near the end of a text about something else", [
            ("Thanks again for lunch. By the way, could you also send me the seating chart from Friday?", "the seating chart", [.document]),
            ("The movers come at nine. If you could forward the packing list as well, that would help.", "the packing list", [.document]),
        ])
        Self.expectConstruction("a pronoun under a condition: if you have X, could you send it", [
            ("If you have the moodboard for the bakery, please share it with me.", "the moodboard", [.document]),
            ("If you have the signed waiver handy, please send it over.", "the signed waiver", [.document]),
            ("If you kept that waiver from the venue, please send it over.", "that waiver", [.document]),
        ])
        Self.expectConstruction("a pronoun or a plain file that points to the sentence before", [
            ("We are still missing the packing list for the second shipment. Could you send it today?", "the packing list", [.document]),
            ("You mentioned a style guide for the menus. Can you share it with us?", "a style guide", [.document]),
            ("I lost the scan of the permit. Could you send me a copy?", "the scan of the permit", [.scan, .certificate]),
            ("We still don't have your headshot. Could you send one today?", "your headshot", [.document]),
            ("The auditors asked for the maintenance log. Do you have it? If so, please share it with me.", "the maintenance log", [.document]),
            ("Please sign the attached agreement and send it back to me.", "the attached agreement", [.contract]),
        ])
        Self.expectConstruction("a wish to see or to have a document", [
            ("I'd love to see the draft floor plan before Monday.", "the draft floor plan", [.floorPlan]),
            ("Our client would like to see the renderings first.", "the renderings", [.rendering]),
            ("Could I take a look at the signed contract?", "the signed contract", [.contract]),
            ("I look forward to receiving the revised quote.", "the revised quote", [.quote]),
            ("I'd love a copy of the seating plan.", "a copy of the seating plan", [.document]),
        ])
        Self.expectConstruction("show me, get me or ask for a document", [
            ("Could you show me the latest renderings?", "the latest renderings", [.rendering]),
            ("Can you get me a copy of the permit?", "a copy of the permit", [.document, .certificate]),
            ("I'd like to ask you for the signed lease.", "the signed lease", [.contract]),
        ])
        Self.expectConstruction("a need, what is missing, and whether there is one", [
            ("We are missing the brochure for the fair.", "the brochure", [.catalog]),
            ("The signed consent form is still missing.", "The signed consent form", [.form]),
            ("Is there a floor plan of the second floor?", "a floor plan of the second floor", [.floorPlan]),
            ("Do you have the vendor list?", "the vendor list", [.document]),
        ])
        Self.expectConstruction("have you got X?", [
            ("Have you got the minutes from Tuesday's meeting?", "the minutes", [.minutes]),
            ("Have you got a scan of the permit?", "a scan of the permit", [.scan, .certificate]),
        ])
        Self.expectConstruction("mind sending X?, the short form of would you mind", [
            ("Mind sending over the seating plan?", "the seating plan", [.document]),
            ("Hi Ana, mind resending the invoice?", "the invoice", [.invoice]),
        ])
        Self.expectConstruction("drop X into a thread or a chat, which must name a document", [
            ("Can you drop the quote in our shared chat?", "the quote", [.quote]),
            ("Could you drop the signed lease into this email thread?", "the signed lease", [.contract]),
        ])
        Self.expectConstruction("a pronoun that points to a file named before what the reader did to it", [
            ("The quote you sent last week has the wrong date. Could you resend it?", "The quote", [.quote]),
            ("Thanks for the itinerary you drafted. Could you forward it to Kai as well?", "the itinerary", [.document]),
        ])
    }

    @Test func chineseAsksForADocumentInEachConstruction() {
        Self.expectConstruction("请, 麻烦 … 发 and a phrase that names no kind, searched by its words", [
            ("麻烦发一下上周的会议安排", "上周的会议安排", [.document]),
            ("请发一下展位布置说明给我", "展位布置说明", [.document]),
        ])
        Self.expectConstruction("你把 X 发我, with no word that asks", [
            ("你把装修合同也转给我们。", "装修合同", [.contract]),
            ("你把面试题目发给我", "面试题目", [.document]),
        ])
        Self.expectConstruction("把 X 发我 at the start of a clause", [
            ("把展会的照片发我一下吧", "照片", [.photo]),
            ("好的，把样书的封面文件发过来", "封面文件", [.document]),
        ])
        Self.expectConstruction("X 发我一份, the document before the verb", [
            ("合同扫描件发我一份就行", "合同扫描件", [.contract, .scan]),
            ("那张效果图发我看看", "那张效果图", [.rendering]),
            ("你的演示稿能不能今晚发给我？", "演示稿", [.document]),
            ("另外，报价单方便发我一份吗？", "报价单", [.quote]),
        ])
        Self.expectConstruction("发我一份 X, 发 X 给我 and 给我发 X", [
            ("发我一份最新的报价单", "报价单", [.quote]),
            ("发一下排练流程给我", "排练流程", [.document]),
            ("给我发一份产品手册", "产品手册", [.document]),
        ])
        Self.expectConstruction("a need, asking for a document by its name, and whether the reader has one", [
            ("我们还缺一份营业执照复印件", "营业执照复印件", [.certificate, .document]),
            ("我这边需要你们的报价单", "报价单", [.quote]),
            ("想跟你要一份装修合同", "装修合同", [.contract]),
            ("你们手上有装箱清单吗？", "装箱清单", [.document]),
            ("有没有上周的签到表？", "上周的签到表", [.document]),
        ])
        Self.expectConstruction("a wish to see or to receive a document", [
            ("我想先看看你们的设计稿", "设计稿", [.designFile]),
            ("客户希望尽快收到合同", "合同", [.contract]),
            ("能给我看一下平面图吗", "平面图", [.floorPlan]),
        ])
        Self.expectConstruction("nothing named after the verb, which points to the document named before", [
            ("上次说的那份报价单，麻烦再发我一份。", "那份报价单", [.quote]),
            ("门店的照片拍好了吗？拍好了麻烦发我几张。", "照片", [.photo]),
            ("如果你手上有活动的海报，麻烦发我一份。", "活动的海报", [.document]),
            ("上次的会议安排，麻烦发我一下。", "上次的会议安排", [.document]),
            ("上周你提到过一份施工须知，麻烦发我一份。", "施工须知", [.document]),
        ])
        Self.expectConstruction("方便的时候 and 有时间的话 before what asks", [
            ("方便的时候把施工合同传给我就行。", "施工合同", [.contract]),
            ("有时间的话发一下平面图给我。", "平面图", [.floorPlan]),
        ])
        Self.expectConstruction("把 X 给我看看, which must name a document", [
            ("能不能把效果图先给我看看？", "效果图", [.rendering]),
            ("你把合同给我们过目一下。", "合同", [.contract]),
        ])
        Self.expectConstruction("给我一份 X, 能给我 X 吗", [
            ("能给我一份最新的价目表吗？", "价目表", [.quote]),
            ("给我们一张现场的照片吧。", "照片", [.photo]),
        ])
        Self.expectConstruction("一版 after the verb, which points to the document named before", [
            ("合同定稿后，麻烦传一版给我们。", "合同", [.contract]),
            ("报价改好以后，发一版给我看看。", "报价", [.quote]),
        ])
    }

    @Test func japaneseAsksForADocumentInEachConstruction() {
        Self.expectConstruction("X を送っていただけますか and a phrase that names no kind, or a count before the verb", [
            ("展示会の案内文を送っていただけますか", "展示会の案内文", [.document]),
            ("会場の写真を2枚お送りいただけますか", "写真", [.photo]),
        ])
        Self.expectConstruction("X も and X は before the verb, and いただけますと幸いです", [
            ("見積書もあわせてお送りいただけますと幸いです。", "見積書", [.quote]),
            ("工程表は共有していただけますか", "工程表", [.schedule]),
            ("見積書については改めてお送りいただけますか", "見積書", [.quote]),
        ])
        Self.expectConstruction("no object before the verb, after Xがあれば or a phrase before the comma", [
            ("もし議事録がお手元にあれば、お送りいただけますか。", "議事録", [.minutes]),
            ("先日の打ち合わせのまとめ、お手数ですが共有していただけないでしょうか。", "先日の打ち合わせのまとめ", [.document]),
            ("昨日お話しした見積書ですが、ご送付いただけると助かります。", "見積書", [.quote]),
        ])
        Self.expectConstruction("X のご共有をお願い and X 送付のお願い", [
            ("納品書のご共有をお願いできますでしょうか", "納品書", [.document]),
            ("設計図面ご送付のお願い", "設計図面", [.drawing]),
        ])
        Self.expectConstruction("X を頂戴できますか and X をお願いできますか, with a copy", [
            ("契約書の写しを1通頂戴できますか", "契約書の写し", [.contract, .document]),
            ("請求書の控えをお願いできますか", "請求書の控え", [.invoice, .document]),
        ])
        Self.expectConstruction("what is missing", [
            ("契約書の原本が見当たりません", "契約書の原本", [.contract, .document]),
            ("仕様書が足りません", "仕様書", [.specification]),
        ])
        Self.expectConstruction("a wish to see a document", [
            ("完成予想図を拝見できれば幸いです", "完成予想図", [.rendering]),
            ("パンフレットを見せていただけますか", "パンフレット", [.catalog]),
            ("前回の議事録を拝見できますでしょうか。", "議事録", [.minutes]),
        ])
        Self.expectConstruction("ぜひ拝見したいです after a phrase that names a document before the comma", [
            ("先週お話しした企画書、ぜひ拝見したいです。", "企画書", [.proposal]),
            ("例の契約書、一度拝見させていただけますか。", "契約書", [.contract]),
        ])
        Self.expectConstruction("X は or X も before a verb of giving", [
            ("請求書は紙でもいただけますか。", "請求書", [.invoice]),
            ("議事録もメールでいただけますでしょうか。", "議事録", [.minutes]),
        ])
        Self.expectConstruction("もう一度 or もしよろしければ before a verb with nothing named", [
            ("先月の請求書ですが、もう一度お送りいただけますか。", "請求書", [.invoice]),
            ("工程表の件ですが、もしよろしければ共有していただけますか。", "工程表", [.schedule]),
        ])
        Self.expectConstruction("再送 and X のもの, which points to the document named before", [
            ("先週の見積書を再送していただけますか。", "見積書", [.quote]),
            ("前回の図面、最新のものを再送していただけますか。", "図面", [.drawing]),
        ])
        Self.expectConstruction("X のデータ, the file of a kind", [
            ("パンフレットのデータを送っていただけますか。", "パンフレット", [.catalog]),
            ("図面のデータを共有してください。", "図面", [.drawing]),
        ])
    }

    @Test func spanishAsksForADocumentInEachConstruction() {
        Self.expectConstruction("¿podrías?, te agradecería que … enviar and a phrase that names no kind, with what follows de", [
            ("¿Podrías enviarme la lista de invitados?", "la lista de invitados", [.document]),
            ("Te agradecería que me mandaras el guion de la charla.", "el guion de la charla", [.document]),
            ("¿Serías tan amable de enviarme el presupuesto final?", "el presupuesto final", [.quote, .budget]),
        ])
        Self.expectConstruction("lo or la that point to the document named before", [
            ("Perdí el acta firmada. ¿Me la puedes reenviar?", "el acta firmada", [.minutes]),
            ("Si todavía tienes el folleto del evento, ¿me lo mandas?", "el folleto", [.catalog]),
            ("Mencionaste una guía de estilo para los menús. ¿Me la puedes compartir?", "una guía de estilo", [.document]),
            ("Te adjunto el contrato. Fírmalo y envíamelo de vuelta, por favor.", "el contrato", [.contract]),
        ])
        Self.expectConstruction("an imperative and a question in the present", [
            ("Pásame la agenda del taller, porfa.", "la agenda del taller", [.document]),
            ("Compártenos el borrador cuando lo tengas.", "el borrador", [.document]),
            ("¿Me envías el plano actualizado?", "el plano actualizado", [.floorPlan, .drawing]),
            ("¿Nos mandas las fotos del evento?", "las fotos del evento", [.photo]),
        ])
        Self.expectConstruction("a wish to see or to have a document, and asking for one", [
            ("Me gustaría ver el contrato antes de firmar.", "el contrato", [.contract]),
            ("¿Puedo ver los planos de la cocina?", "los planos", [.floorPlan, .drawing]),
            ("Me gustaría una copia del contrato.", "una copia del contrato", [.document, .contract]),
            ("Quería pedirte el contrato firmado, para archivarlo.", "el contrato firmado", [.contract]),
        ])
        Self.expectConstruction("what is missing, and whether the reader has one", [
            ("Nos faltan las fotos del almacén.", "las fotos del almacén", [.photo]),
            ("¿Tienes el catálogo en PDF?", "el catálogo", [.catalog]),
            ("¿Tienes todavía a mano el acta de la reunión?", "el acta", [.minutes]),
        ])
        Self.expectConstruction("an imperative that carries lo or la, with conmigo, which points to the document named before", [
            ("Las facturas de marzo ya están listas, compártelas conmigo cuando puedas.", "Las facturas", [.invoice]),
            ("Si encuentras el contrato de arrendamiento, mándalo el lunes.", "el contrato", [.contract]),
        ])
        Self.expectConstruction("the words after de name the kind when what is asked for names none", [
            ("¿Me pasas la versión final del presupuesto?", "la versión final del presupuesto", [.quote, .budget]),
            ("¿Podrías enviarme el resumen del informe anual?", "el resumen del informe anual", [.report]),
        ])
    }

    /// Colloquial Spanish names the document again after a verb that carries lo or la, as in
    /// "mándamelo el archivo", which asks for it. What names no document after such a verb,
    /// as bien in "pásala bien", asks for nothing, also when a word for a kind comes later
    /// with no word that ends the phrase before it, as after durante, mientras or entre.
    @Test func aVerbThatCarriesLoOrLaTakesTheDocumentNamedAgain() throws {
        Self.expectConstruction("a verb that carries lo or la, and the document named again by its kind or its file name", [
            ("Oye, pásamelo el presupuesto cuando lo tengas.", "el presupuesto", [.quote, .budget]),
            ("¿Puedes mandármela la hoja de cálculo de gastos?", "la hoja de cálculo", [.spreadsheet]),
            ("Reenvíamelas las capturas del error, porfa.", "las capturas", [.photo]),
            ("Envíamela la versión final de la propuesta.", "la versión final de la propuesta", [.proposal]),
            ("Pásamelo rev-0412.pdf, porfa.", "rev-0412.pdf", [.document]),
        ])
        let plain = try #require(Self.found("Cuando termines, mándamelo el archivo.").first)
        #expect(plain.object == "el archivo")
        #expect(plain.documentKinds == [.document])
        #expect(!plain.saysWhichFile)
        Self.expectNone([
            "¡Pásalo bomba este finde!",
            "Pásala súper con tu gente.",
            "Pásala bien en la presentación de mañana.",
            "Pásalo bien durante la feria del catálogo.",
            "¡Pásala bien mientras yo reviso los planos!",
            "Pásalo genial durante las fotos de grupo.",
            "¡Pásalo bomba entre tanta factura!",
            "Pásala súper durante tu presentación en Lima.",
        ])
    }

    /// Lo or la with a word after the verb that says how or when to send it, a participle, a
    /// quantifier or an adverb, points to the document named before, as a verb with nothing
    /// after it does, and asks for nothing when none is named. A wish of a good time, and a
    /// phrase after lo or la that names no document, ask for nothing.
    @Test func loOrLaWithAWordForHowOrWhenPointsBack() {
        Self.expectConstruction("lo or la and a participle, a quantifier or an adverb, with the document named before", [
            ("El contrato de alquiler ya está corregido. Envíamelo firmado, por favor.", "El contrato", [.contract]),
            ("Las fotos de la boda ya están editadas. Pásamelas todas.", "Las fotos de la boda", [.photo]),
            ("Revisé el presupuesto de pintura. Mándamelo cuanto antes.", "el presupuesto", [.quote, .budget]),
            ("La factura del hotel tenía un error. ¿Me la reenvías corregida?", "La factura", [.invoice]),
            ("Ya está listo el informe de auditoría. Envíamelo lo más pronto posible.", "el informe", [.report]),
        ])
        Self.expectNone([
            "Envíamelo firmado, por favor.",
            "¿Me lo mandas cuanto antes?",
            "Gracias por el cronograma. ¡Pásala bien!",
            "Ya firmé el contrato. ¡Pásalo de maravilla en Cancún!",
            "Ya tengo el plano. Mándamela la dirección del local.",
        ])
    }

    // MARK: What never counts

    @Test func commentsAndFeedbackAreNoFile() {
        Self.expectNone([
            "Could you send me your thoughts on the logo by Friday?",
            "Please share your feedback about the second draft.",
            "请把你对方案的意见发给我",
            "资料的修改建议麻烦发我一下",
            "パンフレットについてのコメントを送ってください",
            "¿Nos mandas tus observaciones sobre el folleto?",
        ])
    }

    /// A question as what is asked for asks for an answer, also when its words name a
    /// document, as "how the tenants felt about the new layout" does.
    @Test func aQuestionAsWhatIsAskedForIsNoFile() {
        Self.expectNone([
            "Could you share how the tenants felt about the new layout?",
            "Please send me how many chairs you still need.",
            "Could you forward whether the hall is free on Sunday?",
            "¿Me puedes compartir cómo prefieres organizar la visita?",
            "麻烦发一下怎么去仓库。",
        ])
    }

    /// Numbers and values, as a price, a size, a total, a count, an account or a member number,
    /// and the details of a form, are no file.
    @Test func numbersAndValuesAreNoFile() {
        Self.expectNone([
            "Please send over your hourly rates.",
            "Can you email me the total for the catering?",
            "Please send me your jacket size.",
            "Could you send me your PayPal so I can pay you back?",
            "Envíame tu talla de camiseta, por favor.",
            "¿Podrías mandarme el precio de las sillas?",
            "请把你的会员号发给我。",
            "能不能把订单号发我？",
            "请把报名人数发我一下。",
            "ご希望のサイズをお送りください。",
            "参加人数を送っていただけますか。",
        ])
    }

    /// The details a form asks for, listed under a colon, are no file, and a list of written
    /// things is.
    @Test func aListOfDetailsIsNoFile() {
        Self.expectNone([
            "To book your place, please send us the following:\n- your full name\n- your company\n- your arrival date",
            "参会前请把以下信息发给我们：\n1. 姓名\n2. 单位\n3. 手机号",
            "申込のため、以下をお送りください：\n・お名前\n・会社名\n・電話番号",
        ])
        Self.expectConstruction("a list of written things under a colon", [
            ("Before the fair, please send the following:\n- the booth layout\n- the staff list", "the booth layout, the staff list", [.document]),
            ("请把以下内容发给我：\n1. 装箱清单\n2. 签到表", "装箱清单, 签到表", [.document]),
        ])
    }

    /// What 把 takes ends at a verb that handles it before it is sent, so comments that are to
    /// be summed up stay comments, and a paper to scan or stamp stays the paper.
    @Test func whatIsHandledBeforeItIsSentIsWhatIsAskedFor() {
        Self.expectNone([
            "麻烦把大家的意见汇总一下发给我。",
            "请把修改建议整理后发我们。",
        ])
        Self.expectConstruction("把 X, a verb that handles it, then a verb of sending", [
            ("请把签好字的协议扫描一下发给我。", "协议", [.contract]),
            ("麻烦把报价单盖章后寄回给我们。", "报价单", [.quote]),
        ])
    }

    /// 发回, 传回 and 寄回 send back to whom follows, so a paper to sign and send back names
    /// no file of its own.
    @Test func sendingBackNamesNoFileOfItsOwn() {
        Self.expectNone([
            "请签好字后发回给我们。",
            "麻烦盖章后寄回给我。",
            "确认无误后请传回给我们。",
        ])
        Self.expectRequests([
            ("请把租赁合同发回给我们。", "租赁合同", [.contract]),
        ])
    }

    /// Leave to pass a file on to others gives a permission and asks the reader for no file,
    /// and the same words toward the writer, or a question, still ask.
    @Test func leaveToPassAFileOnIsNoRequest() {
        Self.expectNone([
            "Feel free to forward the brochure to your neighbours.",
            "Feel free to share the recording with Priya and the rest of the class.",
            "Puedes reenviar el programa a tus compañeros si quieres.",
        ])
        Self.expectRequests([
            ("Feel free to send me the floor plan whenever it's ready.", "the floor plan", [.floorPlan]),
            ("¿Puedes compartir el plano con Marta?", "el plano", [.floorPlan, .drawing]),
        ])
    }

    /// The constructions that also take what is no file ask for nothing with it: a line or a
    /// price to drop, a hand or a home to show, time or an answer to give, a check or a reading
    /// to do, a place to see.
    @Test func constructionsThatAlsoTakeWhatIsNoFile() {
        Self.expectNone([
            "Could you drop me a line when you land?",
            "Could you drop the price a little?",
            "把手给我看看。",
            "能不能把新家给我们看看？",
            "お時間はいただけますか。",
            "ご返事はいただけますか。",
            "契約書はご確認いただけますか。",
            "企画書は読んでいただけますか。",
            "新しいオフィス、ぜひ拝見したいです。",
            "¡Pásala bien en tus vacaciones!",
        ])
    }

    /// A pronoun that points to a file named only as a file asks for a file but does not say
    /// which, and the words after what the reader did to it, as "this morning", are none of it.
    @Test func aFileNamedOnlyAsAFileSaysNotWhichOne() throws {
        let english = try #require(Self.found("The document you shared this morning is blank. Can you share it again?").first)
        #expect(english.object == "The document")
        #expect(english.documentKinds == [.document])
        #expect(!english.saysWhichFile)
        let japanese = try #require(Self.found("送っていただいたファイルが開けません。もう一度送っていただけますか。").first)
        #expect(japanese.object == "ファイル")
        #expect(japanese.documentKinds == [.document])
        #expect(!japanese.saysWhichFile)
    }

    @Test func availabilityIsNoFile() {
        Self.expectNone([
            "Could you send me your availability for next week?",
            "Please share a few times that work for you.",
            "麻烦发一下你方便的时间",
            "ご都合のよい日時をお送りください",
            "Envíame tu disponibilidad para el jueves.",
        ])
    }

    @Test func anAddressIsNoFile() {
        Self.expectNone([
            "Can you send me your mailing address?",
            "请把收货地址发我",
            "ご住所を送っていただけますか",
            "¿Me puedes mandar tu dirección?",
        ])
    }

    @Test func bankAndTaxDetailsAreNoFile() {
        Self.expectNone([
            "Please send us your bank details and tax ID.",
            "Could you provide your VAT number?",
            "请提供一下开票信息和银行账户",
            "振込先の口座情報を送ってください",
            "Por favor, envíame tus datos bancarios.",
        ])
    }

    @Test func aPortalToUploadToAsksForNoFile() {
        Self.expectNone([
            "Please upload the receipts to the expense portal.",
            "Could you submit the slides through the conference platform?",
            "The call for talks is open. Submit your proposal at talks.example/cfp.",
            "请把发票上传到报销系统",
            "ポータルに請求書をアップロードしてください",
            "Por favor, envía las facturas a través del portal.",
        ])
    }

    @Test func aFormOnlineAsksForNoFile() {
        Self.expectNone([
            "Could you complete the web form and submit it today?",
            "Please send the online form back by Friday.",
            "Por favor, completa el formulario en línea y envíalo hoy.",
        ])
    }

    @Test func aQuoteStillToPrepareIsNoFile() {
        Self.expectNone([
            "Could you send us a quote for 300 mugs?",
            "Please send me an estimate for the repair.",
            "¿Puedes enviarnos una cotización para 200 piezas?",
            "お見積りをお願いします",
        ])
    }

    /// The sender sends, attaches or promises the file, also when a pronoun of a later
    /// sentence points to the file the sender attached.
    @Test func whatTheSenderSendsAttachesOrPromisesIsNoRequest() {
        Self.expectNone([
            "I'll send you the floor plan tonight.",
            "Attached is the revised schedule.",
            "I've attached the floor plan. Could you share it with your team?",
            "Here is the revised budget. Please forward it to Kai.",
            "Te adjunto el plano. ¿Lo puedes compartir con tu equipo?",
            "附件是平面图。麻烦转发给团队。",
            "見積書を添付いたします。社内で共有していただけますか。",
            "我把报价单发给你了",
            "合同我明天发您",
            "資料を添付いたします",
            "明日図面をお送りします",
            "Te envío el contrato mañana.",
            "Adjunto la factura.",
        ])
    }

    /// Information, the email itself, a person, money, and what a newsletter asks readers to
    /// pass on are no file.
    @Test func otherThingsThatAreNoFile() {
        Self.expectNone([
            "Could you send me more details about the venue?",
            "Please send me an update when you can.",
            "Please forward this email to anyone who might be interested.",
            "Could you send someone to fix the heater?",
            "Our autumn catalog is out! Share it with anyone who loves tea.",
            "请把定金转给我们",
            "麻烦发一下产品信息",
            "这封邮件麻烦转发给设计团队，谢谢。",
            "このメッセージを、営業チームに転送していただけますか。",
            "Comparte este boletín con tus amigos.",
        ])
    }

    /// A pronoun or a verb with no object asks for nothing when no document is named before
    /// it, and a wish to see what is no file asks for nothing.
    @Test func aPointerWithNothingNamedAndAWishForNoFileAreNoRequests() {
        Self.expectNone([
            "Could you send it to me?",
            "Thanks for the call. Could you forward it to Kai?",
            "麻烦发我一下",
            "お送りいただけますか",
            "¿Me lo puedes enviar?",
            "I'd love to see you at the dinner.",
            "Me gustaría ver la oficina.",
            "我想看看你们的新办公室",
        ])
    }

    /// A file that came, as in 你发给我的平面图, is no request.
    @Test func aFileThatCameIsNoRequest() {
        Self.expectNone([
            "你上次发给我的平面图有问题",
            "先日お送りいただいた資料、ありがとうございました。",
            "Thanks so much for the floor plan you sent yesterday.",
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
            // Attachments that the sender brings after 也 or 再, or with a clause that only
            // says so after them, and the participle adjunta.
            "另外再附上一份报价单，请查收。",
            "另外也附上报价单，供参考。",
            "再附上合同扫描件，请查收。",
            "随信也附上平面图。",
            "这里也附上平面图。",
            "Adjunta encontrarás la factura.",
            "Adjunta te envío la factura.",
            "Adjunta va la cotización.",
        ])
        // The sender's own attachment counts in its own clause only.
        #expect(Self.found("我已附上合同，请发一下平面图。").first?.documentKinds == [.floorPlan])
        // A word that asks makes 也附上 a request, and one in what is attached does not.
        #expect(Self.found("也请附上平面图。").first?.documentKinds == [.floorPlan])
        #expect(Self.found("也把需要的平面图附上。").isEmpty)
    }

    /// The sender offers to send, with me or us before the verb, a first person between the
    /// frame and the verb, or que te envíe.
    @Test func theSendersOffersAreNoRequests() {
        Self.expectNone([
            "Would you like me to send the floor plan?",
            "Please let me know if you need me to send the floor plan.",
            "Please let us know if you would like us to send the drawings.",
            "Can you confirm you still need me to send the contract?",
            "Can you remind me to send the floor plan?",
            "请等我把平面图发给你。",
            "请问需要我把合同发给你吗？",
            "请问我可以把平面图发给你吗？",
            "请确认后我再把平面图发给你。",
            "Por favor, avísame si necesitas que te envíe el plano.",
            "Por favor, dime si quieres que te mande el plano.",
        ])
        // Help me, and que le envíes with a verb of tú, still ask the reader.
        #expect(Self.found("请帮我把平面图发给他。").first?.documentKinds == [.floorPlan])
        #expect(Self.found("Necesito que le envíes el plano a Juan.").first?.object == "el plano")
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
            // One negation for a list of verbs, 请勿 and ni.
            "Please do not copy, print or forward the attachments.",
            "If you are not the intended recipient, please do not copy, distribute or forward this email or its attachments.",
            "Please do not use, copy or share the attached contract.",
            "本邮件及其附件含有保密信息，请勿转发附件。",
            "请勿把合同发给别人。",
            "麻烦勿转发合同。",
            "Por favor no copie, use ni reenvíe este documento.",
        ])
        // A negation in an if clause between the frame and the verb negates nothing.
        #expect(Self.found("Please, if you don't mind, send the floor plan.").first?.documentKinds == [.floorPlan])
    }

    /// A notice of confidentiality under the sender's words, which forbids sending, asks for
    /// nothing.
    @Test func aNoticeOfConfidentialityAsksForNothing() {
        Self.expectNone([
            "Hi Lin,\n\nThanks for the update. The samples look good and we can go ahead on Friday.\n\nBest regards,\nMei\n\nCONFIDENTIALITY NOTICE: This email and any attachments are confidential. If you are not the intended recipient, please do not copy, distribute or forward this email or its attachments.",
            "王经理您好：\n\n样品已收到，我们周五开工。\n\n谢谢！\n李明\n\n本邮件及其附件含有保密信息，请勿转发附件。",
            "Hola Lin:\n\nGracias, el viernes empezamos.\n\nSaludos,\nAna\n\nAVISO: Este mensaje y sus anexos son confidenciales. Si usted no es el destinatario, por favor no copie, use ni reenvíe este documento.",
        ])
    }

    /// 有没有 or 你有…吗 before a verb asks whether the reader did something to a document,
    /// not for it. A kind that starts like such a verb, as 发票 or 画册, is still asked for.
    @Test func aQuestionAboutWhatTheReaderDidIsNoRequest() {
        Self.expectNone([
            "你有没有看过平面图？",
            "你们有没有确认平面图？",
            "有没有更新平面图？",
            "您有看过合同吗？",
            "你有没有修改平面图？",
            "你有没有收到平面图？",
        ])
        #expect(Self.found("有没有发票？").first?.documentKinds == [.invoice])
        #expect(Self.found("你们有画册吗？").first?.documentKinds == [.catalog])
    }

    @Test func questionsAboutWhatArrivedAndOtherAsksAreNoRequests() {
        Self.expectNone([
            "Did you get the floor plan I sent?",
            "Please send it to me.",
            "We need to send the floor plan.",
            "Do you have time to meet?",
            "Could you confirm the date?",
            "Please send me your thoughts.",
            "平面图收到了吗？",
            "我们需要讨论一下平面图",
            "请把发票开给我们公司",
            "请开发票。",
            "我们发现平面图有问题。",
            "请发表意见。",
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
        // A lead that names no file, as "the files below" or 下列文件, still reads the list.
        #expect(Self.found("Please send the files below:\n- floor plan\n- lighting spec").first?.documentKinds == [.floorPlan, .specification])
        #expect(Self.found("Please send the documents listed below:\n- floor plan\n- lighting spec").first?.documentKinds == [.floorPlan, .specification])
        #expect(Self.found("请把下列文件发给我：\n1. 平面图\n2. 报价单").first?.documentKinds == [.floorPlan, .quote])
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

    /// Every sentence of the part read repeats a frame, which once made each match read the
    /// rest of its sentence, for seconds an email. Each text ends well within a second.
    @Test(.timeLimit(.minutes(1)))
    func aFrameInEverySentenceEndsQuickly() {
        func sentences(_ unit: String, length: Int, count: Int, end: String) -> String {
            let body = String(String(repeating: unit, count: length / unit.count + 1).prefix(length - 1))
            return String(repeating: body + end, count: count)
        }
        let texts = [
            sentences("we need we need ", length: 133, count: 60, end: ". "),
            sentences("we need the floor plan and ", length: 400, count: 20, end: ". "),
            sentences("please send please send ", length: 400, count: 20, end: ". "),
            sentences("necesito necesito ", length: 400, count: 20, end: ". "),
            sentences("por favor envía por favor envía ", length: 400, count: 20, end: ". "),
            sentences("我们需要我们需要", length: 400, count: 20, end: "。"),
            sentences("请发送请发送", length: 400, count: 20, end: "。"),
            sentences("请把把把把把把把把把把", length: 400, count: 20, end: "。"),
            sentences("有没有你们有", length: 400, count: 20, end: "。"),
            sentences("資料をください資料をください", length: 400, count: 20, end: "。"),
            sentences("をもをも送って", length: 400, count: 20, end: "。"),
            sentences("合同也发我一份合同也发我", length: 400, count: 20, end: "，"),
            sentences("お送りいただけますかお送り", length: 400, count: 20, end: "、"),
            sentences("If you have the plan, could you send it", length: 400, count: 20, end: ". "),
            sentences("¿me lo mandas? me la podrías ", length: 400, count: 20, end: ". "),
            sentences("資料をください資料をください", length: 400, count: 20, end: "、"),
            sentences("資料はいただけますか資料は", length: 400, count: 20, end: "。"),
            sentences("请把合同把方案给我看看", length: 400, count: 20, end: "。"),
            sentences("ファイルが開けませんファイルが", length: 400, count: 20, end: "。"),
            sentences("feel free to share it with Kai ", length: 400, count: 20, end: ". "),
        ]
        for text in texts {
            let started = ContinuousClock.now
            #expect(Self.found(text, subject: String(text.prefix(FileRequests.sentenceLength))).count <= FileRequests.mostRequests)
            #expect(ContinuousClock.now - started < .seconds(1), "\(text.prefix(30))")
        }
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

    /// A kind that is a kind of file names its types, lowercased and without a dot, and a
    /// kind any document may be names none.
    @Test func kindsOfFilesNameTheirTypes() {
        #expect(DocumentKind.photo.fileTypes?.isSuperset(of: ["jpg", "png", "heic"]) == true)
        #expect(DocumentKind.drawing.fileTypes?.isSuperset(of: ["dwg", "pdf"]) == true)
        #expect(DocumentKind.spreadsheet.fileTypes?.contains("xlsx") == true)
        for kind in [DocumentKind.quote, .contract, .invoice, .document] {
            #expect(kind.fileTypes == nil, "\(kind)")
        }
        for kind in DocumentKind.allCases {
            for type in kind.fileTypes ?? [] {
                #expect(type == type.lowercased() && !type.contains(".") && !type.isEmpty, "\(kind) \(type)")
            }
        }
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
