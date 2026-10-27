import Foundation

/// A file an email asks the user to send, as FileRequests finds it in the sender's own
/// words. Saved with the explanation, so every field reads leniently: a field missing, of
/// another shape or from a later Orra reads as empty, and the explanation still reads.
nonisolated struct FileRequest: Sendable, Equatable, Codable {
    /// The sentence that asks, as the email writes it, at most 200 characters.
    var sentence: String
    /// What it asks for, at most 80 characters, such as "the floor plan and the lighting
    /// spec" or 平面图.
    var object: String
    /// The kinds of document it names, as raw values of DocumentKind, in the order of the
    /// object. A kind of a later Orra stays, and `documentKinds` leaves it out.
    var kinds: [String]
    /// The file names it gives whole, such as floor-plan-v3.pdf.
    var fileNames: [String]

    init(sentence: String, object: String, kinds: [String], fileNames: [String]) {
        self.sentence = sentence
        self.object = object
        self.kinds = kinds
        self.fileNames = fileNames
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sentence = (try? container.decodeIfPresent(String.self, forKey: .sentence)) ?? ""
        object = (try? container.decodeIfPresent(String.self, forKey: .object)) ?? ""
        kinds = (try? container.decodeIfPresent([String].self, forKey: .kinds)) ?? []
        fileNames = (try? container.decodeIfPresent([String].self, forKey: .fileNames)) ?? []
    }

    /// The kinds this Orra knows, in order.
    var documentKinds: [DocumentKind] {
        kinds.compactMap(DocumentKind.init(rawValue:))
    }

    /// Whether the request says which file it wants: by a kind other than a plain file, by
    /// a file name, or by words of its own besides those. "Send me the file" does not.
    var saysWhichFile: Bool {
        let terms = FileRequests.searchTerms(for: self)
        return !terms.words.isEmpty || !terms.terms.isEmpty || !terms.fileNames.isEmpty
    }
}

/// A kind of document an email may ask for, with the words for it in English, Chinese,
/// Japanese and Spanish, lowercase as SortingText.matchingForm gives them. A word may stand
/// for two kinds, as plano does for a floor plan and a drawing, and presupuesto for a quote
/// and a budget. `document` is any file, which says that a file is asked for but not which.
nonisolated enum DocumentKind: String, CaseIterable, Sendable {
    case floorPlan, drawing, rendering, quote, invoice, contract, schedule, budget, report, minutes
    case slides, spreadsheet, photo, specification, cv, document, scan, proposal, certificate, form
    case paper, transcript, letter, courseMaterial, catalog, designFile, data

    /// The words for a kind in each language.
    nonisolated struct Terms: Sendable, Equatable {
        var english: [String]
        var chinese: [String]
        var japanese: [String]
        var spanish: [String]

        /// Every word, in the order of the languages.
        var all: [String] {
            var seen: Set<String> = []
            return (english + chinese + japanese + spanish).filter { seen.insert($0).inserted }
        }
    }

    /// Whether the kind says only that a file is asked for, not which one.
    var isGeneric: Bool {
        self == .document
    }

    /// The extensions of the files a kind of document is, lowercased, for a kind that is a
    /// kind of file, such as a photo, a drawing, a scan, slides or a spreadsheet, and nil for
    /// a kind any document may be, such as a quote or a contract. A file of another type that
    /// a word for such a kind names, such as photo-shoot-brief.md, is about the kind and is
    /// rarely what was asked for, see RequestedFiles.
    var fileTypes: Set<String>? {
        switch self {
        case .photo: Self.images.union(["dng"])
        case .rendering: Self.images.union(["pdf", "psd", "ai", "fig", "sketch", "svg"])
        case .floorPlan, .drawing: Self.images.union(["pdf", "dwg", "dxf", "svg", "skp", "rvt", "ai"])
        case .scan: Self.images.union(["pdf"])
        case .slides: ["ppt", "pptx", "key", "pdf", "odp"]
        case .spreadsheet: ["xls", "xlsx", "numbers", "csv", "ods", "tsv"]
        case .designFile: Self.images.union(["ai", "psd", "indd", "fig", "sketch", "svg", "eps", "xd", "pdf"])
        default: nil
        }
    }

    private static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"]

    var terms: Terms {
        switch self {
        case .floorPlan:
            Terms(english: ["floor plan", "floor plans", "floorplan", "floorplans", "layout plan", "layout plans"],
                  chinese: ["平面图", "平面布置图", "户型图", "平面圖", "平面佈置圖"],
                  japanese: ["平面図", "間取り図", "間取図", "フロアプラン"],
                  spanish: ["plano", "planos", "plano de planta", "planos de planta", "distribución"])
        case .drawing:
            Terms(english: ["drawing", "drawings", "blueprint", "blueprints", "cad", "dwg", "elevation", "elevations", "shop drawings"],
                  chinese: ["图纸", "施工图", "设计图", "立面图", "剖面图", "图则", "圖紙", "施工圖", "設計圖", "圖則"],
                  japanese: ["図面", "設計図", "施工図", "立面図", "断面図"],
                  spanish: ["plano", "planos", "dibujo", "dibujos", "alzado", "alzados"])
        case .rendering:
            Terms(english: ["rendering", "renderings", "render", "renders", "mockup", "mockups", "mock-up", "visualization", "visualisation"],
                  chinese: ["效果图", "渲染图", "透视图", "效果圖"],
                  japanese: ["パース", "完成予想図", "レンダリング", "イメージ図"],
                  spanish: ["render", "renders", "renderizado", "renderizados", "maqueta", "maquetas"])
        case .quote:
            Terms(english: ["quote", "quotes", "quotation", "quotations", "estimate", "estimates", "price list", "price quote"],
                  chinese: ["报价", "报价单", "估价单", "报价表", "价目表", "報價", "報價單"],
                  japanese: ["見積書", "見積もり", "見積り", "見積", "お見積り", "お見積もり", "価格表"],
                  spanish: ["cotización", "cotizaciones", "presupuesto", "presupuestos", "lista de precios"])
        case .invoice:
            Terms(english: ["invoice", "invoices", "receipt", "receipts"],
                  chinese: ["发票", "收据", "账单", "發票", "收據"],
                  japanese: ["請求書", "領収書", "インボイス"],
                  spanish: ["factura", "facturas", "recibo", "recibos"])
        case .contract:
            Terms(english: ["contract", "contracts", "agreement", "agreements", "nda"],
                  chinese: ["合同", "协议", "协议书", "合约", "合約", "協議"],
                  japanese: ["契約書", "合意書", "覚書"],
                  spanish: ["contrato", "contratos", "acuerdo", "acuerdos", "convenio"])
        case .schedule:
            Terms(english: ["schedule", "schedules", "timeline", "timelines", "timetable", "gantt chart"],
                  chinese: ["进度表", "时间表", "日程表", "排期", "排期表", "進度表", "時間表"],
                  japanese: ["スケジュール", "工程表", "日程表", "予定表"],
                  spanish: ["cronograma", "cronogramas", "calendario", "programación"])
        case .budget:
            Terms(english: ["budget", "budgets", "cost breakdown", "cost sheet", "cost plan"],
                  chinese: ["预算", "预算表", "成本表", "預算"],
                  japanese: ["予算書", "内訳書", "予算表"],
                  spanish: ["presupuesto", "presupuestos", "desglose", "desglose de costos"])
        case .report:
            Terms(english: ["report", "reports"],
                  chinese: ["报告", "报告书", "報告"],
                  japanese: ["報告書", "レポート"],
                  spanish: ["informe", "informes", "reporte", "reportes"])
        case .minutes:
            Terms(english: ["minutes", "meeting notes", "meeting minutes"],
                  chinese: ["会议纪要", "会议记录", "纪要", "會議紀要", "會議記錄"],
                  japanese: ["議事録", "会議録"],
                  spanish: ["acta", "actas", "minuta", "minutas"])
        case .slides:
            Terms(english: ["slides", "slide deck", "deck", "presentation", "presentations", "ppt", "pptx", "powerpoint", "keynote"],
                  chinese: ["课件", "幻灯片", "演示文稿", "ppt", "汇报材料"],
                  japanese: ["スライド", "プレゼン資料", "プレゼンテーション", "パワーポイント", "パワポ"],
                  spanish: ["diapositivas", "presentación", "presentaciones"])
        case .spreadsheet:
            Terms(english: ["spreadsheet", "spreadsheets", "excel", "excel file", "workbook", "xlsx", "xls"],
                  chinese: ["表格", "excel", "电子表格", "excel表"],
                  japanese: ["エクセル", "一覧表", "スプレッドシート"],
                  spanish: ["hoja de cálculo", "hojas de cálculo", "planilla", "planillas", "excel"])
        case .photo:
            Terms(english: ["photo", "photos", "picture", "pictures", "image", "images", "screenshot", "screenshots", "pic", "pics"],
                  chinese: ["照片", "图片", "截图", "相片", "圖片", "截圖"],
                  japanese: ["写真", "画像", "スクリーンショット", "スクショ"],
                  spanish: ["foto", "fotos", "imagen", "imágenes", "captura", "capturas", "fotografía", "fotografías"])
        case .specification:
            Terms(english: ["spec", "specs", "specification", "specifications", "datasheet", "data sheet", "spec sheet"],
                  chinese: ["规格书", "说明书", "参数表", "规格", "技术规格", "規格書"],
                  japanese: ["仕様書", "データシート", "仕様"],
                  spanish: ["especificaciones", "especificación", "ficha técnica", "fichas técnicas"])
        case .cv:
            Terms(english: ["cv", "resume", "résumé", "curriculum vitae"],
                  chinese: ["简历", "履历", "簡歷"],
                  japanese: ["履歴書", "職務経歴書"],
                  spanish: ["currículum", "curriculum", "cv", "hoja de vida", "currículo"])
        case .document:
            Terms(english: ["file", "files", "document", "documents", "attachment", "attachments", "copy", "copies", "pdf", "materials"],
                  chinese: ["文件", "资料", "材料", "文档", "附件", "档案", "电子版", "原件", "复印件", "副本", "文檔", "資料"],
                  japanese: ["資料", "ファイル", "書類", "データ一式", "原本", "コピー"],
                  spanish: ["archivo", "archivos", "documento", "documentos", "material", "materiales", "copia", "copias"])
        case .scan:
            Terms(english: ["scan", "scans", "scanned copy", "scanned copies"],
                  chinese: ["扫描件", "扫描版", "掃描件"],
                  japanese: ["スキャン", "スキャンデータ"],
                  spanish: ["escaneo", "escaneos", "escaneado", "copia escaneada"])
        case .proposal:
            Terms(english: ["proposal", "proposals"],
                  chinese: ["方案", "提案", "建议书", "企划书", "策划案"],
                  japanese: ["提案書", "企画書"],
                  spanish: ["propuesta", "propuestas"])
        case .certificate:
            Terms(english: ["certificate", "certificates", "license", "licence", "permit", "permits", "certification"],
                  chinese: ["证书", "证明", "执照", "营业执照", "许可证", "證書"],
                  japanese: ["証明書", "許可証", "免許証"],
                  spanish: ["certificado", "certificados", "licencia", "permiso", "constancia"])
        case .form:
            Terms(english: ["form", "forms", "application form", "questionnaire"],
                  chinese: ["申请表", "登记表", "报名表", "问卷", "表单"],
                  japanese: ["申請書", "申込書", "用紙", "アンケート"],
                  spanish: ["formulario", "formularios", "solicitud", "cuestionario"])
        case .paper:
            Terms(english: ["paper", "papers", "manuscript", "article", "thesis"],
                  chinese: ["论文", "文章", "稿件", "手稿", "論文"],
                  japanese: ["論文", "原稿"],
                  spanish: ["artículo", "artículos", "manuscrito", "tesis", "ponencia"])
        case .transcript:
            Terms(english: ["transcript", "transcripts", "grade report"],
                  chinese: ["成绩单", "成績單"],
                  japanese: ["成績証明書", "成績表"],
                  spanish: ["certificado de notas", "expediente académico", "boletín de notas"])
        case .letter:
            Terms(english: ["letter", "letters", "cover letter", "recommendation letter", "reference letter"],
                  chinese: ["推荐信", "推薦信", "证明信", "邀请函", "介绍信", "求职信"],
                  japanese: ["推薦状", "推薦書", "紹介状", "招待状"],
                  spanish: ["carta", "cartas", "carta de recomendación", "carta de presentación"])
        case .courseMaterial:
            Terms(english: ["syllabus", "lecture notes", "handout", "handouts", "course materials", "reading list"],
                  chinese: ["讲义", "课程资料", "教学大纲", "课程大纲", "講義"],
                  japanese: ["講義資料", "シラバス", "配布資料"],
                  spanish: ["temario", "apuntes", "material del curso", "programa del curso"])
        case .catalog:
            Terms(english: ["catalog", "catalogue", "catalogs", "catalogues", "brochure", "brochures", "lookbook"],
                  chinese: ["目录", "产品目录", "画册", "宣传册", "目錄"],
                  japanese: ["カタログ", "パンフレット", "製品カタログ"],
                  spanish: ["catálogo", "catálogos", "folleto", "folletos"])
        case .designFile:
            Terms(english: ["design file", "design files", "source file", "source files", "artwork", "psd", "indd", "figma", "logo"],
                  chinese: ["设计稿", "源文件", "设计文件", "原稿"],
                  japanese: ["デザインデータ", "デザインファイル", "入稿データ", "ロゴデータ"],
                  spanish: ["archivo de diseño", "archivos de diseño", "archivos fuente", "logotipo", "logo"])
        case .data:
            Terms(english: ["data", "dataset", "datasets", "raw data", "csv"],
                  chinese: ["数据", "原始数据", "数据集", "數據"],
                  japanese: ["データ", "生データ", "データセット"],
                  spanish: ["datos", "conjunto de datos", "base de datos"])
        }
    }
}

/// Finds the files an email asks the user to send, such as "Please also send the floor
/// plan.", 请把平面图发给我。, 平面図を送っていただけますか。 or "¿Me puedes enviar el
/// plano?", with code rules in English, Chinese, Japanese and Spanish, no model.
///
/// It reads the subject, unless it is that of a reply or a forward, and the first
/// `readLength` characters of the sender's own words, cut into sentences as DraftCheck cuts
/// them, at most `mostSentences` of `sentenceLength` characters each. A sentence asks for a
/// file when a request frame of one of the four languages matches it, no negation stands
/// before the verb in the same clause or, for a list of verbs as in a notice of
/// confidentiality, between the frame and the verb, and the head of what it asks for names a
/// kind of document or a file name. The sender's own attachments, promises and offers, a
/// question about what arrived or what the reader did to a document, and a request for
/// comments on a document are no request. Every pattern is bounded, a sentence reads at most
/// `mostFrames` matches of each, and what one asks for is read only as far as it is kept, so
/// a hostile text cannot make it slow. Its limit is wording it does not know.
///
/// Pure: it reads only the text it is given, and logs nothing.
nonisolated enum FileRequests {
    /// How much of the sender's words is read.
    static let readLength = 8_000
    static let mostSentences = 60
    static let sentenceLength = 400
    /// The most requests an email gives, in the order of its text.
    static let mostRequests = 3
    static let sentenceKept = 200
    static let objectKept = 80
    /// The most matches of one pattern read in a sentence, so a sentence that repeats a frame
    /// costs no more than a few.
    static let mostFrames = 4

    /// The files the email asks for, at most `mostRequests`, in the order of the text.
    /// `words` are the sender's own words, without quoted history, forwarded messages, the
    /// signature, hidden text or lines to an assistant.
    static func find(in words: String, subject: String) -> [FileRequest] {
        var sentences: [String] = []
        let subject = bounded(subject, to: sentenceLength)
        if !isReplyOrForward(subject) {
            sentences.append(subject)
        }
        // An item of a list is a sentence of its own, so "1. 平面图" keeps its number.
        let text = unwrapped(bounded(words, to: readLength))
        for line in text.split(separator: "\n") {
            let line = String(line)
            let parts = listItem(line) != nil ? [line[...]] : DraftCheck.sentenceRanges(in: line).map { line[$0] }
            for part in parts where sentences.count < mostSentences {
                sentences.append(String(part.prefix(sentenceLength)))
            }
        }
        var requests: [FileRequest] = []
        var index = 0
        while index < sentences.count, requests.count < mostRequests {
            let sentence = sentences[index]
            index += 1
            let asked = self.asked(in: sentence)
            var found = request(in: sentence, asked: asked)
            // A sentence that ends in a colon with a list under it, as "Please send the
            // following:", asks for the items of the list, once a frame of it passed its
            // checks, so "Please do not send the following:" asks for nothing.
            if found?.saysWhichFile != true, sentence.hasSuffix(":") || sentence.hasSuffix("："), !asked.isEmpty {
                var items: [String] = []
                while index < sentences.count, items.count < 8, let item = listItem(sentences[index]) {
                    items.append(item)
                    index += 1
                }
                if let listed = listRequest(sentence, items: items) {
                    found = listed
                }
            }
            guard let found, !requests.contains(where: { covers($0, found) }) else { continue }
            requests.append(found)
        }
        return requests
    }

    /// What a request is searched with: its object's own words, without stop words and
    /// without the words for a plain file, the words of each kind it names in all four
    /// languages, and the file names it gives.
    static func searchTerms(for request: FileRequest) -> (words: String, terms: [String], fileNames: [String]) {
        var terms: [String] = []
        for kind in request.documentKinds where !kind.isGeneric {
            for term in kind.terms.all where !terms.contains(term) {
                terms.append(term)
            }
        }
        return (ownWords(request.object), terms, request.fileNames)
    }

    // MARK: A sentence

    /// What one frame found: where it starts in the sentence, what it asks for, and whether
    /// that must name a kind other than a plain file, as "we need" and "do you have" must.
    private struct Asked {
        var position: Int
        var object: String
        var needsWhich: Bool
    }

    /// What the frames of a sentence ask for, each frame that passed its checks, in the order
    /// of the sentence.
    private static func asked(in original: String) -> [Asked] {
        let sentence = plain(original)
        guard !sentence.isEmpty else { return [] }
        return (english(sentence) + spanish(sentence) + chinese(sentence) + japanese(sentence)).sorted { $0.position < $1.position }
    }

    /// The request of one sentence, nil when it asks for no file.
    private static func request(in original: String, asked: [Asked]) -> FileRequest? {
        var objects: [String] = []
        var kinds: [DocumentKind] = []
        var fileNames: [String] = []
        for item in asked {
            // What is kept of the object is what names its kinds.
            let object = clipped(item.object, to: objectKept)
            guard !objects.contains(object) else { continue }
            let itemKinds = self.kinds(in: object)
            let itemNames = self.fileNames(in: object)
            if item.needsWhich, !itemKinds.contains(where: { !$0.isGeneric }), itemNames.isEmpty {
                continue
            }
            guard !itemKinds.isEmpty || !itemNames.isEmpty else { continue }
            objects.append(object)
            kinds += itemKinds.filter { !kinds.contains($0) }
            fileNames += itemNames.filter { !fileNames.contains($0) }
        }
        guard !objects.isEmpty else { return nil }
        return FileRequest(
            sentence: String(trimmed(original).prefix(sentenceKept)),
            object: clipped(objects.joined(separator: ", "), to: objectKept),
            kinds: kinds.map(\.rawValue),
            fileNames: fileNames
        )
    }

    /// The request of a sentence that ends in a colon, with the items of the list under it
    /// as what it asks for.
    private static func listRequest(_ original: String, items: [String]) -> FileRequest? {
        let object = items.map { clipped($0, to: objectKept) }.joined(separator: ", ")
        let kinds = self.kinds(in: object)
        let names = fileNames(in: object)
        guard !items.isEmpty, !kinds.isEmpty || !names.isEmpty else { return nil }
        return FileRequest(
            sentence: String(trimmed(original).prefix(sentenceKept)),
            object: clipped(object, to: objectKept),
            kinds: kinds.map(\.rawValue),
            fileNames: names
        )
    }

    /// The text of a list item, without its bullet or number, nil for a line that is none.
    private static func listItem(_ sentence: String) -> String? {
        let line = plain(sentence)
        guard let match = listMarker.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else { return nil }
        let item = trimmed(String(line[range.upperBound...]))
        return item.isEmpty ? nil : item
    }

    /// Whether an earlier request already asks for all a new one does, as when the subject
    /// and the text ask for the same file.
    private static func covers(_ earlier: FileRequest, _ later: FileRequest) -> Bool {
        let first = searchTerms(for: earlier)
        let second = searchTerms(for: later)
        let firstWords = Set(first.words.split(separator: " "))
        return Set(later.kinds).isSubset(of: earlier.kinds)
            && Set(later.fileNames.map { $0.lowercased() }).isSubset(of: earlier.fileNames.map { $0.lowercased() })
            && Set(second.words.split(separator: " ")).isSubset(of: firstWords)
    }

    // MARK: English

    /// please, could you, would you mind, don't forget to and their like, then within 40
    /// characters a verb of sending, with the gap before the verb and the verb.
    private static let englishAsk = latin(#"\b(?:please|pls|plz|kindly|could you|can you|would you|will you|would you mind|could u|can u|don['’]?t forget to|do not forget to|(?:i|we)(?:['’]d| would) appreciate (?:it )?if you could|(?:i|we)(?:['’]d| would) be grateful if you could|would it be possible (?:for you )?to|(?:i|we) (?:also |still |really )?need you to|(?:i|we)(?:['’]d| would) like you to|(?:i|we) want you to)\b([^.!?;]{0,40}?)\b(send|resend|re-send|forward|share|attach|provide|upload|email|e-mail|sending|resending|forwarding|sharing|attaching|providing|uploading|emailing)\b"#)
    /// Send me or send us at the start of a sentence, after a greeting.
    private static let englishSendMe = latin(#"^(?:(?:hi|hello|hey|dear|good (?:morning|afternoon|evening))\b[^,!]{0,40}[,!]\s*)?(?:and |also |just |so |ok,? |okay,? )?(send|forward|email|e-mail|share)\s+(?:me|us)\b"#)
    /// We need or I need, with a kind as the object.
    private static let englishNeed = latin(#"\b(?:i|we)(?:['’]d|['’]ll| would| will| also| still| really| urgently| now| just| only){0,3}\s+(need)\b(?!\s+(?:to|you|your help|a reply|an answer|more time)\b)"#)
    /// Do you have, with a kind as the object and a question mark.
    private static let englishHave = latin(#"\bdo you (?:still |happen to |by any chance )?(have)\b"#)
    private static let englishNegation = latin(#"\b(?:don['’]?t|do not|didn['’]?t|did not|no need to|not necessary|unnecessary|needn['’]t|need not|never|not|no longer|won['’]t|without)\b"#)
    /// Who sends: a subject, or me or us before to, as in "would you like me to send".
    private static let englishPronoun = latin(#"\b(i|we|you|u|they|he|she|me(?=\s+to\b)|us(?=\s+to\b))\b"#)
    /// The pronouns that make the sender the one who sends.
    private static let englishSender: Set<String> = ["i", "we", "me", "us"]
    /// Words before what is asked for that are none of it, as in "send me over the plan".
    private static let englishLead = latin(#"^(?:\s*\b(?:me|us|over|along|across|back|through|again|also|please|kindly|to me|to us|over to (?:me|us)|across to (?:me|us))\b)*\s*(?:the following(?: files?| documents?| items?)?\s*:|these\s*:|following\s*:)?"#)
    /// Where what is asked for ends.
    private static let englishCut = latin(#"\s+(?:on|about|regarding|re|for|by|to|with|from|in|within|before|after|when|whenever|if|as soon as|asap|so that|so|because|since|once|until|till|today|tomorrow|tonight|this week|next week|at|via|through|back|over|along|across|again|and (?:let|tell|confirm|please|could|can|also|then|i|we)|but|thanks|thank you)\b|[,;:()\[\]]|\s[-–—]\s"#)
    /// The cut words after which "a copy of the contract" and "una copia de la factura" go on.
    private static let prepositions: Set<String> = ["on", "about", "for", "by", "to", "with", "from", "in", "sobre", "para", "por", "con", "de", "del", "en", "a", "al"]
    private static let englishKeepGoing: Set<String> = ["copy", "copies", "version", "versions", "scan", "scans", "pdf", "pdfs", "photo", "photos", "picture", "pictures", "image", "images"]

    private static func english(_ sentence: String) -> [Asked] {
        var asked: [Asked] = []
        func add(_ match: NSTextCheckingResult, verb: Range<String.Index>, objectFrom start: String.Index, frame: String.Index? = nil, needsWhich: Bool) {
            guard !negated(sentence, from: frame, before: verb.lowerBound, negation: englishNegation) else { return }
            let object = latinObject(after: start, in: sentence, lead: englishLead, cut: englishCut, keepGoing: englishKeepGoing)
            asked.append(Asked(position: match.range.location, object: object, needsWhich: needsWhich))
        }
        for match in frames(englishAsk, sentence) {
            guard let whole = Range(match.range, in: sentence),
                  let gap = Range(match.range(at: 1), in: sentence),
                  let verb = Range(match.range(at: 2), in: sentence) else { continue }
            // The sender as the one who sends, as in "please let me know if I should send" or
            // "would you like me to send".
            if let pronoun = lastMatch(englishPronoun, in: String(sentence[gap]))?.lowercased(), englishSender.contains(pronoun) {
                continue
            }
            add(match, verb: verb, objectFrom: verb.upperBound, frame: whole.lowerBound, needsWhich: false)
        }
        for match in frames(englishSendMe, sentence) {
            guard let whole = Range(match.range, in: sentence), let verb = Range(match.range(at: 1), in: sentence) else { continue }
            add(match, verb: verb, objectFrom: whole.upperBound, needsWhich: false)
        }
        for match in frames(englishNeed, sentence) {
            guard let verb = Range(match.range(at: 1), in: sentence) else { continue }
            add(match, verb: verb, objectFrom: verb.upperBound, needsWhich: true)
        }
        if sentence.hasSuffix("?") {
            for match in frames(englishHave, sentence) {
                guard let verb = Range(match.range(at: 1), in: sentence) else { continue }
                add(match, verb: verb, objectFrom: verb.upperBound, needsWhich: true)
            }
        }
        return asked
    }

    // MARK: Spanish

    /// The verbs of sending, in the infinitive, the imperative and the subjunctive, with me
    /// or nos and lo or la, accented or not. Never the first person, as in te envío, adjunto
    /// or envié, which the sender says of their own attachment or of what they sent.
    private static let spanishVerbs = #"(?:re)?env[ií](?:[aá]r|[aá]|e|es|en|[aá]ras?|[aá]ran|[aá]ses?)(?:me|nos|te|le|les)?(?:lo|la|los|las)?|m[aá]nd(?:[aá]r|[aá]|e|es|en|[aá]ras?|[aá]ran)(?:me|nos|te|le|les)?(?:lo|la|los|las)?|comp[aá]rt(?:[ií]r|[aá]|e|as|an|en|[ií]eras?|[ií]eran)(?:me|nos|te|le|les)?(?:lo|la|los|las)?|adj[uú]nt(?:[aá]r|[aá]|e|es|en|[aá]ras?)(?:me|nos|te|le|les)?(?:lo|la|los|las)?|p[aá]s(?:[aá]r|[aá]|e|es|en|[aá]ras?)(?:me|nos|te|le|les)?(?:lo|la|los|las)?|fac[ií]l[ií]t(?:[aá]r|[aá]|e|es|[aá]ras?)(?:me|nos|te|le|les)?(?:lo|la|los|las)?|proporci[oó]n(?:[aá]r|[aá]|e|es|[aá]ras?)(?:me|nos|te|le|les)?(?:lo|la|los|las)?|rem[ií]t(?:[ií]r|[aá]|e|as|[ií]eras?)(?:me|nos|te|le|les)?(?:lo|la|los|las)?"#
    private static let spanishAsk = latin(#"\b(?:por favor|porfa|porfavor|favor de|puedes|podr[ií]as|puede|podr[ií]a|pueden|podr[ií]an|me puedes|me podr[ií]as|nos puedes|nos podr[ií]as|me puede|me podr[ií]a|nos puede|nos podr[ií]a|te agradecer[ií]a que|le agradecer[ií]a que|les agradecer[ií]a que|agradecer[ií]a que|necesito que|necesitamos que|ser[ií]a posible que|me har[ií]as el favor de|hazme el favor de|no olvides|no te olvides de|no se olvide de|no olvide|recuerda|recuerde)\b([^.!?;]{0,40}?)\b("# + spanishVerbs + #")\b"#)
    /// The imperatives with me or nos anywhere, and a bare imperative at the start of a
    /// clause, as in "adjunta el plano", not as in "va adjunta la factura", and not the
    /// participle that brings the sender's own file, as in "adjunta encontrarás la factura",
    /// "adjunta te envío" or "adjunta va".
    private static let spanishImperative = latin(#"\b((?:env[ií]a|m[aá]nda|comp[aá]rte|p[aá]sa|reenv[ií]a|fac[ií]l[ií]ta|adj[uú]nta|rem[ií]te)(?:me|nos)(?:lo|la|los|las)?)\b|(?:^|[,;:¿¡]\s*)((?:adj[uú]nta|env[ií]a|m[aá]nda|comp[aá]rte))\b(?!\s+(?:encontrar[aáeé]?\w*|hallar[aáeé]?\w*|ver[aá]s|va|van|est[aá]n?|tienes?|te|le|les|os|se|me|nos|env[ií]o|remito|mando|adjunto)\b)"#)
    private static let spanishNeed = latin(#"\b(necesito|necesitamos|necesitar[ií]a|necesitar[ií]amos|me hace falta|nos hace falta)\b(?!\s+que\b)"#)
    /// No before the verb, but not the polite no of "¿no me podrías enviar…?", and ni, as in
    /// "no copie, use ni reenvíe".
    private static let spanishNegation = latin(#"\b(?:no(?!\s+(?:me\s+|nos\s+|te\s+|le\s+)?(?:puedes|podr[ií]as|puede|podr[ií]a|pueden|podr[ií]an)\b)|ni|nunca|jam[aá]s|tampoco|sin)\b"#)
    /// The sender as the one who sends, right before the verb, as in "si necesitas que te
    /// envíe el plano".
    private static let spanishSender = latin(#"\bque\s+(?:yo\s+)?(?:te|le|les|os)\s+$|\bque\s+yo\s+$"#)
    private static let spanishLead = latin(#"^(?:\s*\b(?:me|nos|te|le|les|tambi[eé]n|por favor|porfa|de nuevo|otra vez|nuevamente|ahora|ya)\b)*\s*(?:(?:lo|los|las) siguientes?(?: archivos| documentos)?\s*:)?"#)
    private static let spanishCut = latin(#"\s+(?:sobre|para|por|con|de|del|a|al|antes|despu[eé]s|cuando|si|hoy|ma[nñ]ana|lo antes posible|en|porque|ya que|y (?:me|nos|te|le|av[ií]same|conf[ií]rmame)|pero|gracias)\b|[,;:()\[\]]|\s[-–—]\s"#)
    private static let spanishKeepGoing: Set<String> = ["copia", "copias", "versión", "version", "versiones", "foto", "fotos", "escaneo", "escaneos", "pdf", "imagen", "imágenes", "imagenes"]

    private static func spanish(_ sentence: String) -> [Asked] {
        var asked: [Asked] = []
        func add(_ match: NSTextCheckingResult, verb: Range<String.Index>, frame: String.Index? = nil, needsWhich: Bool) {
            guard !negated(sentence, from: frame, before: verb.lowerBound, negation: spanishNegation) else { return }
            let object = latinObject(after: verb.upperBound, in: sentence, lead: spanishLead, cut: spanishCut, keepGoing: spanishKeepGoing)
            asked.append(Asked(position: match.range.location, object: object, needsWhich: needsWhich))
        }
        for match in frames(spanishAsk, sentence) {
            guard let whole = Range(match.range, in: sentence), let verb = Range(match.range(at: 2), in: sentence) else { continue }
            // "que te envíe" with a verb not of tú: the sender sends to the reader.
            if !sentence[verb].lowercased().hasSuffix("s"), ContentChecks.matches([spanishSender], String(sentence[whole.lowerBound..<verb.lowerBound])) {
                continue
            }
            add(match, verb: verb, frame: whole.lowerBound, needsWhich: false)
        }
        for match in frames(spanishImperative, sentence) {
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let verb = Range(match.range(at: group), in: sentence) else { continue }
            add(match, verb: verb, needsWhich: false)
        }
        for match in frames(spanishNeed, sentence) {
            guard let verb = Range(match.range(at: 1), in: sentence) else { continue }
            add(match, verb: verb, needsWhich: true)
        }
        return asked
    }

    // MARK: Chinese

    /// The words that make a request, before the verb: 请, 麻烦, 能否, 也 and their like, the
    /// steps before sending back a signed paper, as in 盖章后回传, and 并 that starts a clause
    /// after one that asks, as in 请回复同意，并把合同发过来.
    private static let chineseFrames = #"(?:签字|签名|签章|盖章|签署|签好|盖好|签完|盖完)(?:字|章)?(?:并|后|之后|以后)|(?<=[,;，；]\s{0,1})并且?|请|麻烦|劳烦|烦请|能否|可否|能不能|可不可以|可以|方便时|方便的话|记得|顺便|也|再|帮忙|帮我们|帮我|务必|还请|需要(?:你|您)们?|希望(?:你|您)们?(?:能)?|想请(?:你|您)?|别忘了?|别忘记了?|不要忘了?|不要忘记了?|千万别忘了?|千万不要忘了?|可别忘了?"#
    /// The verbs of sending. A verb of one character stands only before 给, 我, 一下 and the
    /// like, or right before a word of the glossary, as in 请发平面图给我, so 发票 or 发现 is
    /// no verb.
    private static let chineseVerbs = #"回传|传回|发回|寄回|发送|发给|发过来|发一下|发一份|发个|发到|传给|传过来|传一下|传一份|传到|寄给|寄过来|寄一下|寄一份|寄到|分享|提供|附上|转发|共享|发(?=我|吧|呗|来|回|$|[,.!?;。，！？；\s])|传(?=我|吧|来|$|[,.!?;。，！？；\s])|寄(?=我|吧|来|$|[,.!?;。，！？；\s])|(?:发|传|寄)(?=(?:(?:最新|最终|新|完整|正式|修改后|更新后|那|这)(?:版|个|份|些)?的?)?(?:"# + hanTerms + "))"
    /// The words of the glossary in Chinese characters, longest first, as a pattern.
    private static let hanTerms: String = {
        var seen: Set<String> = []
        return DocumentKind.allCases.flatMap { $0.terms.chinese + $0.terms.japanese }
            .filter { $0.contains(where: \.isHan) && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
    }()
    /// A verb of sending anywhere, which the patterns of 把 and of the object after the verb
    /// need, so a sentence without one costs them nothing.
    private static let chineseVerb = regex(chineseVerbs)
    /// A character of a clause: no punctuation that ends one, but the dot of a file name.
    private static let chineseClause = #"(?:[^,.!?;:。，！？；：、\n]|\.(?=[A-Za-z0-9]))"#
    /// 把 or 将 with the object before the verb, as in 请把平面图发给我, long enough for a file
    /// name, as in 麻烦把 proof-feedback-2026-10-14.md 再发我一下.
    private static let chineseBa = regex("(" + chineseFrames + ")(" + chineseClause + "{0,10}?)(?:把|将)(" + chineseClause + "{1,60}?)(" + chineseVerbs + ")")
    /// The object after the verb, as in 麻烦发一下平面图.
    private static let chineseAsk = regex("(" + chineseFrames + ")(" + chineseClause + "{0,10}?)(" + chineseVerbs + ")(" + chineseClause + "{1,30})")
    /// 我们需要 or 我需要 with a kind, not with a verb as in 我们需要讨论平面图.
    private static let chineseNeed = regex("(?:我们|我司|本公司|我这边|我们这边|我)(?:这边|还|也|现在|目前|急|很)?(?:需要|要)(?!(?:你|您|讨论|确认|看|了解|修改|调整|知道|开会|安排|沟通|商量|审核|核对|更新|准备|提交|签|做|画|改|出|跟|和|与|去|来|再|重新|尽快|先))(" + chineseClause + "{1,30})")
    /// 有没有 with a kind, and 你有…吗 as a question.
    private static let chineseHave = regex("有没有(" + chineseClause + "{1,30}?)(?:吗|$|[?？])|(?:你|您)们?(?:这边|那边)?有(" + chineseClause + "{1,30}?)吗")
    /// A verb at the start of what 有没有 or 你有…吗 asks about, which asks whether the reader
    /// did something to a document, as in 你有没有看过平面图, not for the document.
    private static let chineseHaveVerb = regex(#"^(?:看|查看|查阅|阅读|读|确认|核对|核实|检查|审核|审阅|审批|批准|批过|签|盖章|更新|修改|修订|调整|改|收到|收好|拿到|下载|上传|保存|打印|提交|提供|准备|完成|处理|做|画过|画了|画好|找到|找过|用过|用了|使用|参考|考虑|讨论|联系|通知|安排|整理|发过|发了|发给|发送|发出|传过|传了|传给|寄过|寄了|寄出|转发|分享|共享|附上)"#)
    /// A negation before the verb: 不用, 别, 请勿 and their like. Not 不能 or 不可, which stand
    /// in the frames 能不能 and 可不可以.
    private static let chineseNegation = regex(#"不用|不必|无需|无须|别|不要|不需要|没必要|勿|禁止|严禁|不得(?!不)"#)
    /// The sender's own attachment or a step already done, which no request holds.
    private static let chineseOwn = regex(#"请查收|供参考|供您参考|请参阅|请参考|见附件|如附件|随信附|随邮件附|随函附|现附上|已附上|已发送|已经发|已发|已(?:经)?(?:回传|传回|寄回)|附件(?:是|为)"#)
    /// A clause that only says the clause before it brings the sender's own file, as in
    /// 另外再附上一份报价单，请查收。
    private static let chineseOwnClause = regex(#"^\s*(?:(?:请|敬请|烦请|请您|请你)(?:查收|查阅|参阅|参考)|仅?供(?:您|你)?参考)\s*$"#)
    /// A word that asks, which 也 and 再 before 附上 lack: 也附上平面图 brings the sender's own
    /// plan, 也请附上平面图 asks for one.
    private static let chineseAsking = regex(#"请|麻烦|劳烦|能否|可否|能不能|可不可以|可以|方便|记得|帮|务必|需要|希望|忘"#)
    /// The sender as the one who sends, right before a word of request: 我也, 我们这边也可以,
    /// but not 帮我 or 给我.
    private static let chineseFirstPerson = regex(#"(?:^|[^帮给替为让])(?:我们|我|本人)(?:这边|那边)?(?:也|还|再|就|都|会|将|可以|能|马上|稍后|今天|明天|先|随后)*$"#)
    private static let chineseObjectEnd = regex(#"给|到|至|过来|吧|吗|呢|哦|啊|谢谢|哈|呗|好吗|可以吗"#)

    private static func chinese(_ sentence: String) -> [Asked] {
        guard sentence.contains(where: \.isHan) else { return [] }
        var asked: [Asked] = []
        // The sender's own attachment or a step done counts in its own clause, so 我已附上
        // 合同，请发一下平面图 still asks for the plan, and through the clause right after it
        // when that clause only says so, as in 再附上合同扫描件，请查收。
        func own(_ match: NSTextCheckingResult) -> Bool {
            guard let range = Range(match.range, in: sentence) else { return true }
            let boundaries = ",;:，；：。!?！？"
            let start = sentence[..<range.lowerBound].lastIndex(where: { boundaries.contains($0) }).map { sentence.index(after: $0) } ?? sentence.startIndex
            let end = sentence[range.upperBound...].firstIndex(where: { boundaries.contains($0) }) ?? sentence.endIndex
            if ContentChecks.matches([chineseOwn], String(sentence[start..<end])) {
                return true
            }
            guard end < sentence.endIndex else { return false }
            let next = sentence.index(after: end)
            let nextEnd = sentence[next...].firstIndex(where: { boundaries.contains($0) }) ?? sentence.endIndex
            return ContentChecks.matches([chineseOwnClause], String(sentence[next..<nextEnd]))
        }
        // The patterns run only when the words they need stand in the sentence.
        let sends = ContentChecks.matches([chineseVerb], sentence)
        for (pattern, objectGroup, verbGroup) in [(chineseBa, 3, 4), (chineseAsk, 4, 3)] where sends {
            for match in frames(pattern, sentence) {
                guard !own(match),
                      let frame = Range(match.range(at: 1), in: sentence),
                      let gap = Range(match.range(at: 2), in: sentence),
                      let verb = Range(match.range(at: verbGroup), in: sentence),
                      let object = Range(match.range(at: objectGroup), in: sentence) else { continue }
                // 我们需要你提供 asks the reader, whoever stands before it. The sender as the
                // one who sends, before the frame or between it and the verb, as in 请等我把
                // 平面图发给你 or 请问需要我把合同发给你吗, asks nothing.
                let asksTheReader = sentence[frame].contains("你") || sentence[frame].contains("您")
                if !asksTheReader, ContentChecks.matches([chineseFirstPerson], String(sentence[..<frame.lowerBound])) { continue }
                if ContentChecks.matches([chineseFirstPerson], String(sentence[gap])) { continue }
                // 并 joins a request only to a clause that asks, so 合并后发给我 asks nothing.
                if sentence[frame].hasPrefix("并"), !ContentChecks.matches([chineseAsking], String(sentence[..<frame.lowerBound])) { continue }
                // 也附上 or 再附上 without a word that asks, in the frame or right after it,
                // brings the sender's own file.
                if sentence[verb].hasPrefix("附"), !ContentChecks.matches([chineseAsking], String(sentence[frame.lowerBound..<gap.upperBound])) { continue }
                // 附上了 or 发过 tell what was done.
                if sentence[verb.upperBound...].hasPrefix("了") || sentence[verb.upperBound...].hasPrefix("过") { continue }
                guard !negated(sentence, before: verb.lowerBound, negation: chineseNegation) else { continue }
                var text = String(sentence[object])
                if objectGroup > verbGroup, let end = chineseObjectEnd.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(end.range, in: text) {
                    text = String(text[..<range.lowerBound])
                }
                var asking = hanObject(text)
                // What is asked for stands before the frame, as in 厨电规格麻烦发我一下, when the
                // verb has only me, 一下 or 一份 after it: the clause before the frame, at most
                // as long as an object after a verb.
                if objectGroup > verbGroup, asking.isEmpty {
                    let boundaries = ",;:，；：。!?！？、"
                    let start = sentence[..<frame.lowerBound].lastIndex(where: { boundaries.contains($0) }).map { sentence.index(after: $0) } ?? sentence.startIndex
                    asking = hanObject(String(sentence[start..<frame.lowerBound].suffix(30)))
                }
                asked.append(Asked(position: match.range.location, object: asking, needsWhich: false))
            }
        }
        for pattern in [chineseNeed, chineseHave] where sentence.contains(pattern === chineseNeed ? "要" : "有") {
            for match in frames(pattern, sentence) {
                let group = (1..<match.numberOfRanges).first { match.range(at: $0).location != NSNotFound } ?? 1
                guard !own(match), let object = Range(match.range(at: group), in: sentence) else { continue }
                if pattern === chineseHave, ContentChecks.matches([chineseHaveVerb], String(sentence[object])) { continue }
                guard !negated(sentence, before: object.lowerBound, negation: chineseNegation) else { continue }
                var text = String(sentence[object])
                if let end = chineseObjectEnd.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(end.range, in: text) {
                    text = String(text[..<range.lowerBound])
                }
                asked.append(Asked(position: match.range.location, object: hanObject(text), needsWhich: true))
            }
        }
        return asked
    }

    // MARK: Japanese

    private static let japaneseClause = #"(?:[^,.!?;:。、，！？；：\n]|\.(?=[A-Za-z0-9]))"#
    private static let japaneseEndings = #"ください|下さい|くださいませ|いただけますか|いただけませんか|いただけますでしょうか|いただけないでしょうか|頂けますか|頂けませんか|頂けますでしょうか|もらえますか|もらえませんか|お願いします|お願いいたします|お願い致します|お願いできますか|いただければ|頂ければ|いただけると|頂けると|いただきたく|いただきたいです|頂きたく|願います|ほしいです|欲しいです"#
    /// A polite request anywhere, which the first three patterns need: an ending of
    /// `japaneseEndings`, of the noun pattern (お願い…) or of the give pattern (いただきたい).
    private static let japaneseEnding = regex(japaneseEndings + "|お願い|いただきたい|頂きたい")
    /// A verb of sending anywhere, which the first two patterns need.
    private static let japaneseSend = regex(#"送って|送付して|共有して|添付して|送信して|転送して|お送り|ご送付|ご共有|ご提供|ご送信|ご転送"#)
    /// The object before を or も, a verb of sending, and a polite request.
    private static let japaneseAsk = regex("(" + japaneseClause + "{1,30}?)(?:を|も)(?:至急|早めに|早急に|改めて|再度|もう一度|今一度|一度|すぐに|先に)?(?:送って|送付して|共有して|添付して|送信して|転送して|お送り|ご送付|ご共有|ご提供|ご送信|ご転送)(?:して|を)?(?:" + japaneseEndings + ")")
    /// The object before の and a noun of sending, as in 契約書のご提供をお願いいたします.
    private static let japaneseNoun = regex("(" + japaneseClause + "{1,30}?)の(?:ご送付|ご提供|ご共有|ご送信|ご転送|お送り)を(?:お願いします|お願いいたします|お願い致します|お願いできますか|お願いできますでしょうか|お願い申し上げます)")
    /// The object before を with いただけますか alone.
    private static let japaneseGive = regex("(" + japaneseClause + "{1,30}?)を(?:いただけますか|いただけませんか|いただけますでしょうか|頂けますか|頂けませんか|ください|下さい|もらえますか|いただきたい|頂きたい)")
    /// A kind before が必要です.
    private static let japaneseNeed = regex("(" + japaneseClause + "{1,30}?)が(?:必要です|必要になります|必要となります|必要でして|必要でございます|必要なのですが|必要なので|ほしいです|欲しいです)")
    /// The object before を, a verb of sending and 忘れないでください, don't forget to send.
    private static let japaneseForget = regex("(" + japaneseClause + "{1,30}?)を(?:送る|送付する|共有する|添付する|お送りする|転送する)の(?:を)?忘れないで(?:ください|下さい|くださいね|ね)?")
    private static let japaneseLead = regex(#"^(?:また|あと|それと|それから|さらに|念のため|ついでに|恐れ入りますが|お手数ですが|お手数をおかけしますが|すみませんが|申し訳ありませんが|至急)+"#)

    private static func japanese(_ sentence: String) -> [Asked] {
        // Every pattern needs kana, which Chinese has none of.
        guard sentence.contains(where: \.isKana) else { return [] }
        var asked: [Asked] = []
        // The patterns run only when the words they need stand in the sentence: the first
        // three end in a polite request, and the first two hold a verb of sending.
        let asks = ContentChecks.matches([japaneseEnding], sentence)
        let sends = asks && ContentChecks.matches([japaneseSend], sentence)
        let needs: [(NSRegularExpression, Bool, Bool)] = [
            (japaneseAsk, false, sends), (japaneseNoun, false, sends), (japaneseGive, false, asks),
            (japaneseForget, false, sentence.contains("忘れないで")), (japaneseNeed, true, sentence.contains("が")),
        ]
        for (pattern, needsWhich, mayMatch) in needs where mayMatch {
            for match in frames(pattern, sentence) {
                guard let object = Range(match.range(at: 1), in: sentence) else { continue }
                var text = String(sentence[object])
                if let lead = japaneseLead.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(lead.range, in: text) {
                    text = String(text[range.upperBound...])
                }
                asked.append(Asked(position: match.range.location, object: hanObject(text), needsWhich: needsWhich))
            }
        }
        return asked
    }

    // MARK: What is asked for

    /// What a Latin request asks for: the text after its verb, without the words before the
    /// object, up to the end of the clause or a word that starts something else, as in "the
    /// floor plan for the lobby", where "for the lobby" goes. After copy, version, scan and
    /// their like the object goes on, as in "una copia de la factura".
    private static func latinObject(after start: String.Index, in sentence: String, lead: NSRegularExpression, cut: NSRegularExpression, keepGoing: Set<String>) -> String {
        var rest = String(sentence[start...].prefix(objectKept * 3))
        if let match = lead.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)), let range = Range(match.range, in: rest) {
            rest = String(rest[range.upperBound...].prefix(objectKept * 2))
        }
        // A word of the glossary stays whole, as "hoja de cálculo" or "price list".
        let searched = rest as NSString
        let phrases = phraseTerms.flatMap { term in ranges(of: term, in: rest, searched) }
        var end = rest.endIndex
        for match in matches(cut, rest) {
            guard let range = Range(match.range, in: rest) else { continue }
            if phrases.contains(where: { $0.lowerBound < range.lowerBound && range.lowerBound < $0.upperBound }) {
                continue
            }
            let before = rest[..<range.lowerBound].split(whereSeparator: { !$0.isLetter && !$0.isNumber }).last.map { $0.lowercased() }
            let word = rest[range].trimmingCharacters(in: .whitespaces).lowercased()
            if let before, keepGoing.contains(before), prepositions.contains(word) {
                continue
            }
            end = range.lowerBound
            break
        }
        return unquoted(String(rest[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: ".!?¿¡")))
    }

    /// The words of the glossary that hold a space, which no cut may split.
    private static let phraseTerms: [String] = {
        var seen: Set<String> = []
        return DocumentKind.allCases.flatMap(\.terms.all).filter { $0.contains(" ") && seen.insert($0).inserted }
    }()

    /// Where a term stands in a text as whole words, ignoring case and accents. `searched` is
    /// the text as an NSString, made once for all the terms.
    private static func ranges(of term: String, in text: String, _ searched: NSString) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var start = 0
        while start < searched.length {
            let match = searched.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: searched.length - start))
            guard match.location != NSNotFound else { break }
            start = match.location + max(match.length, 1)
            guard let range = Range(match, in: text) else { continue }
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isLetter ?? false), !(after?.isLetter ?? false) {
                found.append(range)
            }
        }
        return found
    }

    /// What is asked for without the white space around it and without double quotes, as in
    /// "the file "report.pdf"".
    private static func unquoted(_ text: String) -> String {
        let quotes = CharacterSet(charactersIn: "\"“”«»「」『』")
        let inner = String(String.UnicodeScalarView(text.unicodeScalars.filter { !quotes.contains($0) }))
        return trimmed(inner).trimmingCharacters(in: CharacterSet(charactersIn: "'‘’").union(.whitespaces))
    }

    /// What a Chinese or Japanese request asks for: the text after the last 的 or の, which
    /// heads it, so 对平面图的意见 asks for comments and 最新的平面图 for the plan. When that
    /// head names only a plain file, as 平面图的电子版, or only a version or a format, as
    /// 平面图的最新版 or 平面図のPDF, the whole object counts. In a list of things, as in
    /// 合同和您的身份证照片, each keeps its own head when the head of the whole would leave a
    /// kind out.
    private static func hanObject(_ text: String) -> String {
        var object = unquoted(text)
        for _ in 0..<3 {
            let stripped = removing(hanTrail, from: removing(hanLead, from: object))
            if stripped == object { break }
            object = trimmed(stripped)
        }
        let whole = hanHead(object)
        let lost = Set(kinds(in: object).filter { !$0.isGeneric }).subtracting(kinds(in: whole))
        let separators = matches(hanConjunction, object).compactMap { Range($0.range, in: object) }
        guard !lost.isEmpty, !separators.isEmpty else { return whole }
        var parts: [String] = []
        var start = object.startIndex
        for separator in separators {
            parts.append(hanHead(trimmed(String(object[start..<separator.lowerBound]))) + String(object[separator]))
            start = separator.upperBound
        }
        parts.append(hanHead(trimmed(String(object[start...]))))
        return trimmed(parts.joined())
    }

    /// The words that join the things of a list asked for.
    private static let hanConjunction = regex(#"以及|还有|和|与|及|跟|、|と"#)

    /// The text after the last 的 or の of what is asked for, or the whole of it, see
    /// `hanObject(_:)`.
    private static func hanHead(_ object: String) -> String {
        guard let last = object.lastIndex(where: { $0 == "的" || $0 == "の" }) else { return object }
        let head = unquoted(String(object[object.index(after: last)...]))
        let headKinds = kinds(in: head)
        let namesOnlyAFile = !headKinds.isEmpty && headKinds.allSatisfy(\.isGeneric)
        let namesOnlyAVersion = headKinds.isEmpty && ContentChecks.matches([hanVersion], head)
        return (namesOnlyAFile || namesOnlyAVersion) && kinds(in: object).contains(where: { !$0.isGeneric }) ? object : head
    }

    /// A version or a format of a file, without a kind of its own: 最新版, 修改稿, 定稿, PDF版,
    /// 最終版, データ and their like.
    private static let hanVersion = latin(#"^(?:(?:最新|最终|最終|最后|最後|新|旧|修改|修订|修正|改訂|更新|正式|完整|当前|現行|初|定|终|終|草|原)(?:版本|版|稿|バージョン)?|版本|バージョン|(?:pdf|cad|dwg|word|excel|jpe?g|png|tiff?|zip|ppt|pptx|xlsx?|docx?)(?:版|格式|形式|ファイル|档|文件)?)$"#)

    private static let hanLead = regex(#"^(?:一下|一份|一个|一张|个|以下的?|下面的?|下列的?|如下的?|上述的?|以上的?|下|给我们|给我|过来|我的邮箱|我邮箱|这个邮箱|邮箱|我们|我|你们的|您的|贵司的|贵方的|另外|还有|对了|顺便|此外|然后)"#)
    private static let hanTrail = regex(#"(?:吧|吗|呢|啊|哦|哈|呗|一下|也|过来|给我们|给我|好吗|可以吗|谢谢|嗎|即可|就行|就好|就可以)$"#)

    /// The kinds a text names, each once, in the order the text names them.
    static func kinds(in text: String) -> [DocumentKind] {
        let folded = matchingText(text)
        let searched = folded as NSString
        var found: [(position: Int, kind: DocumentKind)] = []
        for (kind, terms) in matchingTerms {
            let first = terms.compactMap { position(of: $0, in: folded, searched) }.min()
            if let first {
                found.append((first, kind))
            }
        }
        return found.sorted { $0.position < $1.position }.map(\.kind)
    }

    /// The words of every kind as the kinds are matched.
    private static let matchingTerms: [(DocumentKind, [String])] = DocumentKind.allCases.map { kind in
        (kind, kind.terms.all.map(matchingText))
    }

    /// The file names a text gives whole: a run of letters, digits, spaces, dots, hyphens
    /// and underscores that ends in an extension of a document, an image, an archive or a
    /// design, without the words before the name, such as "the".
    static func fileNames(in text: String) -> [String] {
        var names: [String] = []
        for match in matches(fileName, text) {
            guard let range = Range(match.range, in: text) else { continue }
            var name = trimmed(String(text[range]))
            while let space = name.firstIndex(of: " "), stopWords.contains(name[..<space].lowercased()) || fileNameLead.contains(name[..<space].lowercased()) {
                name = trimmed(String(name[name.index(after: space)...]))
            }
            if !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    private static let fileName = latin(#"(?<![\p{L}\p{N}._-])[\p{L}\p{N}][\p{L}\p{N} ._-]{0,78}?\.(?:pdf|docx?|xlsx?|pptx?|key|pages|numbers|dwg|dxf|png|jpe?g|heic|tiff?|zip|txt|md|rtf|odt|csv|ai|psd|indd|skp|rvt|sketch|fig)(?![\p{L}\p{N}])"#)

    /// The object's own words for the search: lowercase, without stop words and without the
    /// words of a plain file, as one line.
    private static func ownWords(_ object: String) -> String {
        var text = matchingText(object)
        for name in fileNames(in: object) {
            text = text.replacingOccurrences(of: matchingText(name), with: " ")
        }
        let generic = DocumentKind.document.terms.all.map(matchingText)
        var words: [String] = []
        for token in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var word = String(token)
            if word.contains(where: \.isHan) || word.contains(where: \.isKana) {
                for stop in hanStopWords + generic where word.contains(stop) && stop.contains(where: { $0.isHan || $0.isKana }) {
                    word = word.replacingOccurrences(of: stop, with: " ")
                }
                words += word.split(separator: " ").map(String.init)
                continue
            }
            guard !stopWords.contains(word), !generic.contains(word) else { continue }
            words.append(word)
        }
        var seen: Set<String> = []
        return words.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: " ")
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "your", "our", "my", "his", "her", "their", "its", "this", "that", "these", "those", "me", "us", "you",
        "it", "them", "latest", "last", "new", "newest", "updated", "final", "current", "recent", "most", "version", "versions",
        "of", "and", "or", "also", "please", "both", "all", "any", "some", "from", "for", "to", "in", "on", "at", "with", "by",
        "about", "attached", "enclosed", "signed", "back", "below", "above", "listed", "following", "mentioned",
        "el", "la", "los", "las", "un", "una", "unos", "unas", "del", "al", "de", "tu", "tus", "su", "sus", "mi", "mis",
        "nuestro", "nuestra", "nuestros", "nuestras", "este", "esta", "estos", "estas", "ese", "esa", "esos", "esas",
        "ultimo", "ultima", "nuevo", "nueva", "actualizado", "actualizada", "final", "y", "o", "tambien", "version",
        "para", "por", "con", "en", "a", "sobre", "siguiente", "siguientes", "abajo", "indicados", "listados",
    ]
    /// Words before a file name that are none of it, as in "the attached file report.pdf".
    private static let fileNameLead: Set<String> = ["attached", "enclosed", "file", "files", "document", "documents", "archivo", "documento", "adjunto"]
    private static let hanStopWords = ["一下", "一份", "一个", "那个", "这个", "那份", "这份", "最新版", "最新", "新版", "最终版", "你们", "您", "你", "贵司", "和", "与", "及", "的", "例の", "先日", "前回", "最新の", "と", "の"]

    // MARK: Helpers

    /// A text in the form the patterns read: compatibility forms made plain, format
    /// characters dropped, white space made single spaces. The case stays, so what is asked
    /// for keeps the email's own words.
    private static func plain(_ text: String) -> String {
        SortingText.withoutFormatCharacters(text.precomposedStringWithCompatibilityMapping)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first scalars of a text, so no work reads past the limit, whatever the text
    /// holds, long runs of combining marks included.
    private static func bounded(_ text: String, to length: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(length)))
    }

    /// The text cut to a length, at the end of a word where the text has spaces.
    private static func clipped(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        var cut = String(text.prefix(length))
        let next = text[text.index(text.startIndex, offsetBy: length)]
        if next.isLetter || next.isNumber, let space = cut.lastIndex(of: " ") {
            cut = String(cut[..<space])
        }
        return trimmed(cut)
    }

    /// A text as the kinds are matched: lowercase, the accents of Latin letters gone, and
    /// hyphens and underscores read as spaces, so "Floor-Plan" names a floor plan and
    /// "cotizacion" a quote. Kana keep their marks, so デ stays デ.
    private static func matchingText(_ text: String) -> String {
        var folded = ""
        for character in SortingText.matchingForm(text) {
            if character == "-" || character == "_" {
                folded.append(" ")
            } else if let scalar = character.unicodeScalars.first, (0x00C0...0x024F).contains(scalar.value) {
                folded += String(character).folding(options: [.diacriticInsensitive], locale: nil)
            } else {
                folded.append(character)
            }
        }
        return folded
    }

    /// Where a term first stands in a text, in UTF-16 units, as a whole word when it is
    /// Latin, and anywhere when it is Chinese or Japanese, which write no spaces. `searched`
    /// is the text as an NSString, made once for all the terms, since a search of a Swift
    /// string makes one for each term. Both are in the matching form, so a literal search
    /// finds what a search of their characters would.
    private static func position(of term: String, in text: String, _ searched: NSString) -> Int? {
        let latin = term.first.map { !$0.isHan && !$0.isKana } ?? true
        var start = 0
        while start < searched.length {
            let found = searched.range(of: term, options: .literal, range: NSRange(location: start, length: searched.length - start))
            guard found.location != NSNotFound else { return nil }
            guard latin else { return found.location }
            if let range = Range(found, in: text) {
                let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                let isWord: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
                if !isWord(before), !isWord(after) {
                    return found.location
                }
            }
            start = found.location + 1
        }
        return nil
    }

    /// Whether a negation stands in the clause before the verb, or, given where the frame
    /// that asks starts, anywhere between the frame and the verb, as in "please do not copy,
    /// print or forward", where one negation stands for a list of verbs. An if clause between
    /// them counts for none, as in "please, if you don't mind, send", and nor does what
    /// stands before but or pero.
    private static func negated(_ sentence: String, from frame: String.Index? = nil, before verb: String.Index, negation: NSRegularExpression) -> Bool {
        var clause = sentence[..<verb]
        if let boundary = clause.lastIndex(where: { ",;:，；：、".contains($0) }) {
            clause = clause[clause.index(after: boundary)...]
        }
        if hasNegation(afterBut(clause), negation) {
            return true
        }
        guard let frame, frame < verb else { return false }
        return hasNegation(removing(conditionalClause, from: String(afterBut(sentence[frame..<verb]))), negation)
    }

    /// The text after its last but or pero.
    private static func afterBut(_ text: Substring) -> Substring {
        var text = text
        if let but = text.range(of: " but ", options: [.caseInsensitive, .backwards]) {
            text = text[but.upperBound...]
        }
        if let pero = text.range(of: " pero ", options: [.caseInsensitive, .backwards]) {
            text = text[pero.upperBound...]
        }
        return text
    }

    /// Whether a text holds a negation, other than one that asks all the same.
    private static func hasNegation(_ text: some StringProtocol, _ negation: NSRegularExpression) -> Bool {
        let text = removing(askingNegations, from: String(text))
        return negation.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Negations that ask all the same: "don't forget to", "do not hesitate to", "no
    /// olvides", 别忘了 and their like.
    private static let askingNegations = latin(#"\b(?:don['’]?t|do not) (?:forget|hesitate)\b|\bno (?:te |se |os )?olvid(?:es|e|éis|eis|en)\b|(?:千万|可)?(?:别|不要|勿)忘(?:记|了)*"#)

    /// An if clause, up to the comma that ends it.
    private static let conditionalClause = latin(#"\b(?:if|si)\b[^,;:]*(?:[,;:]|$)"#)

    /// Whether the subject is that of a reply or a forward, which repeats words the user or
    /// someone else wrote.
    private static func isReplyOrForward(_ subject: String) -> Bool {
        ContentChecks.matches([replyPrefix], plain(subject))
    }

    private static let replyPrefix = latin(#"^\s*(?:re|aw|sv|rv|fw|fwd|wg|tr|回复|答复|回覆|转发|轉寄|转寄|返信|転送)\s*[:：]"#)

    /// Hard wrapped lines joined again: a line break inside a sentence becomes a space, or
    /// nothing between two Chinese or Japanese characters. A blank line, a sentence that
    /// ends and an item of a list keep their break.
    private static func unwrapped(_ text: String) -> String {
        var result = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let last = result.last, last != "\n" else {
                result += line.isEmpty && !result.isEmpty ? "\n" : line
                continue
            }
            if line.isEmpty || ".!?:。！？：…;；".contains(last) || listItem(line) != nil {
                result += "\n" + line
            } else if (last.isHan || last.isKana), let first = line.first, first.isHan || first.isKana {
                result += line
            } else {
                result += " " + line
            }
        }
        return result
    }

    private static let listMarker = regex(#"^\s*(?:[-*•·・●▪◦]|\(?\d{1,2}[.)、．]|[a-z][.)])\s+|^\s*[•·・●▪◦]"#)

    private static func removing(_ pattern: NSRegularExpression, from text: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The first matches of a frame in a sentence, at most `mostFrames`. The search stops
    /// there, so a sentence that repeats a frame costs no more than a few.
    private static func frames(_ pattern: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        var found: [NSTextCheckingResult] = []
        pattern.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if let match {
                found.append(match)
            }
            if found.count >= mostFrames {
                stop.pointee = true
            }
        }
        return found
    }

    /// The text of the last match of a pattern.
    private static func lastMatch(_ pattern: NSRegularExpression, in text: String) -> String? {
        guard let match = matches(pattern, text).last, let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static func latin(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }
}

nonisolated extension Character {
    /// Hiragana or katakana, the half width forms included.
    fileprivate var isKana: Bool {
        unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9F).contains($0.value) || $0.value == 0x30FC }
    }
}
