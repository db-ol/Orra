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
/// before the verb in the same clause, and the head of what it asks for names a kind of
/// document or a file name. The sender's own attachments and promises, a question about
/// what arrived, and a request for comments on a document are no request. Every pattern is
/// bounded, so a hostile text cannot make it slow. Its limit is wording it does not know.
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
        for item in asked where !objects.contains(item.object) {
            let itemKinds = self.kinds(in: item.object)
            let itemNames = self.fileNames(in: item.object)
            if item.needsWhich, !itemKinds.contains(where: { !$0.isGeneric }), itemNames.isEmpty {
                continue
            }
            guard !itemKinds.isEmpty || !itemNames.isEmpty else { continue }
            objects.append(item.object)
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
        let object = items.joined(separator: ", ")
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

    /// please, could you, would you mind and their like, then within 40 characters a verb
    /// of sending, with the gap before the verb and the verb.
    private static let englishAsk = latin(#"\b(?:please|pls|plz|kindly|could you|can you|would you|will you|would you mind|could u|can u|(?:i|we)(?:['’]d| would) appreciate (?:it )?if you could|(?:i|we)(?:['’]d| would) be grateful if you could|would it be possible (?:for you )?to|(?:i|we) (?:also |still |really )?need you to|(?:i|we)(?:['’]d| would) like you to|(?:i|we) want you to)\b([^.!?;]{0,40}?)\b(send|resend|re-send|forward|share|attach|provide|upload|email|e-mail|sending|resending|forwarding|sharing|attaching|providing|uploading|emailing)\b"#)
    /// Send me or send us at the start of a sentence, after a greeting.
    private static let englishSendMe = latin(#"^(?:(?:hi|hello|hey|dear|good (?:morning|afternoon|evening))\b[^,!]{0,40}[,!]\s*)?(?:and |also |just |so |ok,? |okay,? )?(send|forward|email|e-mail|share)\s+(?:me|us)\b"#)
    /// We need or I need, with a kind as the object.
    private static let englishNeed = latin(#"\b(?:i|we)(?:['’]d|['’]ll| would| will| also| still| really| urgently| now| just| only){0,3}\s+(need)\b(?!\s+(?:to|you|your help|a reply|an answer|more time)\b)"#)
    /// Do you have, with a kind as the object and a question mark.
    private static let englishHave = latin(#"\bdo you (?:still |happen to |by any chance )?(have)\b"#)
    private static let englishNegation = latin(#"\b(?:don['’]?t|do not|didn['’]?t|did not|no need to|not necessary|unnecessary|needn['’]t|need not|never|not|no longer|won['’]t|without)\b"#)
    private static let englishPronoun = latin(#"\b(i|we|you|u|they|he|she)\b"#)
    /// Words before what is asked for that are none of it, as in "send me over the plan".
    private static let englishLead = latin(#"^(?:\s*\b(?:me|us|over|along|across|back|through|again|also|please|kindly|to me|to us|over to (?:me|us)|across to (?:me|us))\b)*\s*(?:the following(?: files?| documents?| items?)?\s*:|these\s*:|following\s*:)?"#)
    /// Where what is asked for ends.
    private static let englishCut = latin(#"\s+(?:on|about|regarding|re|for|by|to|with|from|in|within|before|after|when|whenever|if|as soon as|asap|so that|so|because|since|once|until|till|today|tomorrow|tonight|this week|next week|at|via|through|back|over|along|across|again|and (?:let|tell|confirm|please|could|can|also|then|i|we)|but|thanks|thank you)\b|[,;:()\[\]]|\s[-–—]\s"#)
    /// The cut words after which "a copy of the contract" and "una copia de la factura" go on.
    private static let prepositions: Set<String> = ["on", "about", "for", "by", "to", "with", "from", "in", "sobre", "para", "por", "con", "de", "del", "en", "a", "al"]
    private static let englishKeepGoing: Set<String> = ["copy", "copies", "version", "versions", "scan", "scans", "pdf", "pdfs", "photo", "photos", "picture", "pictures", "image", "images"]

    private static func english(_ sentence: String) -> [Asked] {
        var asked: [Asked] = []
        func add(_ match: NSTextCheckingResult, verb: Range<String.Index>, objectFrom start: String.Index, needsWhich: Bool) {
            guard !negated(sentence, before: verb.lowerBound, negation: englishNegation) else { return }
            let object = latinObject(after: start, in: sentence, lead: englishLead, cut: englishCut, keepGoing: englishKeepGoing)
            asked.append(Asked(position: match.range.location, object: object, needsWhich: needsWhich))
        }
        for match in matches(englishAsk, sentence) {
            guard let gap = Range(match.range(at: 1), in: sentence), let verb = Range(match.range(at: 2), in: sentence) else { continue }
            // The sender as the one who sends, as in "please let me know if I should send".
            if let pronoun = lastMatch(englishPronoun, in: String(sentence[gap]))?.lowercased(), pronoun == "i" || pronoun == "we" {
                continue
            }
            add(match, verb: verb, objectFrom: verb.upperBound, needsWhich: false)
        }
        for match in matches(englishSendMe, sentence) {
            guard let whole = Range(match.range, in: sentence), let verb = Range(match.range(at: 1), in: sentence) else { continue }
            add(match, verb: verb, objectFrom: whole.upperBound, needsWhich: false)
        }
        for match in matches(englishNeed, sentence) {
            guard let verb = Range(match.range(at: 1), in: sentence) else { continue }
            add(match, verb: verb, objectFrom: verb.upperBound, needsWhich: true)
        }
        if sentence.hasSuffix("?") {
            for match in matches(englishHave, sentence) {
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
    private static let spanishAsk = latin(#"\b(?:por favor|porfa|porfavor|favor de|puedes|podr[ií]as|puede|podr[ií]a|pueden|podr[ií]an|me puedes|me podr[ií]as|nos puedes|nos podr[ií]as|me puede|me podr[ií]a|nos puede|nos podr[ií]a|te agradecer[ií]a que|le agradecer[ií]a que|les agradecer[ií]a que|agradecer[ií]a que|necesito que|necesitamos que|ser[ií]a posible que|me har[ií]as el favor de|hazme el favor de)\b([^.!?;]{0,40}?)\b("# + spanishVerbs + #")\b"#)
    /// The imperatives with me or nos anywhere, and a bare imperative at the start of a
    /// clause, as in "adjunta el plano", not as in "va adjunta la factura".
    private static let spanishImperative = latin(#"\b((?:env[ií]a|m[aá]nda|comp[aá]rte|p[aá]sa|reenv[ií]a|fac[ií]l[ií]ta|adj[uú]nta|rem[ií]te)(?:me|nos)(?:lo|la|los|las)?)\b|(?:^|[,;:¿¡]\s*)((?:adj[uú]nta|env[ií]a|m[aá]nda|comp[aá]rte))\b"#)
    private static let spanishNeed = latin(#"\b(necesito|necesitamos|necesitar[ií]a|necesitar[ií]amos|me hace falta|nos hace falta)\b(?!\s+que\b)"#)
    /// No before the verb, but not the polite no of "¿no me podrías enviar…?".
    private static let spanishNegation = latin(#"\b(?:no(?!\s+(?:me\s+|nos\s+|te\s+|le\s+)?(?:puedes|podr[ií]as|puede|podr[ií]a|pueden|podr[ií]an)\b)|nunca|jam[aá]s|tampoco|sin)\b"#)
    private static let spanishLead = latin(#"^(?:\s*\b(?:me|nos|te|le|les|tambi[eé]n|por favor|porfa|de nuevo|otra vez|nuevamente|ahora|ya)\b)*\s*(?:(?:lo|los|las) siguientes?(?: archivos| documentos)?\s*:)?"#)
    private static let spanishCut = latin(#"\s+(?:sobre|para|por|con|de|del|a|al|antes|despu[eé]s|cuando|si|hoy|ma[nñ]ana|lo antes posible|en|porque|ya que|y (?:me|nos|te|le|av[ií]same|conf[ií]rmame)|pero|gracias)\b|[,;:()\[\]]|\s[-–—]\s"#)
    private static let spanishKeepGoing: Set<String> = ["copia", "copias", "versión", "version", "versiones", "foto", "fotos", "escaneo", "escaneos", "pdf", "imagen", "imágenes", "imagenes"]

    private static func spanish(_ sentence: String) -> [Asked] {
        var asked: [Asked] = []
        func add(_ match: NSTextCheckingResult, verb: Range<String.Index>, needsWhich: Bool) {
            guard !negated(sentence, before: verb.lowerBound, negation: spanishNegation) else { return }
            let object = latinObject(after: verb.upperBound, in: sentence, lead: spanishLead, cut: spanishCut, keepGoing: spanishKeepGoing)
            asked.append(Asked(position: match.range.location, object: object, needsWhich: needsWhich))
        }
        for match in matches(spanishAsk, sentence) {
            guard let verb = Range(match.range(at: 2), in: sentence) else { continue }
            add(match, verb: verb, needsWhich: false)
        }
        for match in matches(spanishImperative, sentence) {
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let verb = Range(match.range(at: group), in: sentence) else { continue }
            add(match, verb: verb, needsWhich: false)
        }
        for match in matches(spanishNeed, sentence) {
            guard let verb = Range(match.range(at: 1), in: sentence) else { continue }
            add(match, verb: verb, needsWhich: true)
        }
        return asked
    }

    // MARK: Chinese

    /// The words that make a request, before the verb: 请, 麻烦, 能否, 也 and their like.
    private static let chineseFrames = #"请|麻烦|劳烦|烦请|能否|可否|能不能|可不可以|可以|方便时|方便的话|记得|顺便|也|再|帮忙|帮我们|帮我|务必|还请|需要(?:你|您)们?|希望(?:你|您)们?(?:能)?|想请(?:你|您)?"#
    /// The verbs of sending. A verb of one character stands only before 给, 我, 一下 and the
    /// like, so 发票 or 发现 is no verb.
    private static let chineseVerbs = #"发送|发给|发过来|发一下|发一份|发个|发到|传给|传过来|传一下|传一份|传到|寄给|寄过来|寄一下|寄一份|寄到|分享|提供|附上|转发|共享|发(?=我|吧|呗|来|回|$|[,.!?;。，！？；\s])|传(?=我|吧|来|$|[,.!?;。，！？；\s])|寄(?=我|吧|来|$|[,.!?;。，！？；\s])"#
    /// A character of a clause: no punctuation that ends one, but the dot of a file name.
    private static let chineseClause = #"(?:[^,.!?;:。，！？；：、\n]|\.(?=[A-Za-z0-9]))"#
    /// 把 or 将 with the object before the verb, as in 请把平面图发给我.
    private static let chineseBa = regex("(" + chineseFrames + ")(" + chineseClause + "{0,10}?)(?:把|将)(" + chineseClause + "{1,30}?)(" + chineseVerbs + ")")
    /// The object after the verb, as in 麻烦发一下平面图.
    private static let chineseAsk = regex("(" + chineseFrames + ")(" + chineseClause + "{0,10}?)(" + chineseVerbs + ")(" + chineseClause + "{1,30})")
    /// 我们需要 or 我需要 with a kind, not with a verb as in 我们需要讨论平面图.
    private static let chineseNeed = regex("(?:我们|我司|本公司|我这边|我们这边|我)(?:这边|还|也|现在|目前|急|很)?(?:需要|要)(?!(?:你|您|讨论|确认|看|了解|修改|调整|知道|开会|安排|沟通|商量|审核|核对|更新|准备|提交|签|做|画|改|出|跟|和|与|去|来|再|重新|尽快|先))(" + chineseClause + "{1,30})")
    /// 有没有 with a kind, and 你有…吗 as a question.
    private static let chineseHave = regex("有没有(" + chineseClause + "{1,30}?)(?:吗|$|[?？])|(?:你|您)们?(?:这边|那边)?有(" + chineseClause + "{1,30}?)吗")
    private static let chineseNegation = regex(#"不用|不必|无需|无须|别|不要|不需要|没必要"#)
    /// The sender's own attachment or a step already done, which no request holds.
    private static let chineseOwn = regex(#"请查收|供参考|供您参考|请参阅|请参考|见附件|如附件|随信附|随邮件附|随函附|现附上|已附上|已发送|已经发|已发|附件(?:是|为)"#)
    /// The sender as the one who sends, right before a word of request: 我也, 我们这边也可以,
    /// but not 帮我 or 给我.
    private static let chineseFirstPerson = regex(#"(?:^|[^帮给替为让])(?:我们|我|本人)(?:这边|那边)?(?:也|还|再|就|都|会|将|可以|能|马上|稍后|今天|明天|先|随后)*$"#)
    private static let chineseObjectEnd = regex(#"给|到|至|过来|吧|吗|呢|哦|啊|谢谢|哈|呗|好吗|可以吗"#)

    private static func chinese(_ sentence: String) -> [Asked] {
        guard sentence.contains(where: \.isHan) else { return [] }
        var asked: [Asked] = []
        // The sender's own attachment or a step done counts in its own clause only, so
        // 我已附上合同，请发一下平面图 still asks for the plan.
        func own(_ match: NSTextCheckingResult) -> Bool {
            guard let range = Range(match.range, in: sentence) else { return true }
            let boundaries = ",;:，；：。!?！？"
            let start = sentence[..<range.lowerBound].lastIndex(where: { boundaries.contains($0) }).map { sentence.index(after: $0) } ?? sentence.startIndex
            let end = sentence[range.upperBound...].firstIndex(where: { boundaries.contains($0) }) ?? sentence.endIndex
            return ContentChecks.matches([chineseOwn], String(sentence[start..<end]))
        }
        for (pattern, objectGroup, verbGroup) in [(chineseBa, 3, 4), (chineseAsk, 4, 3)] {
            for match in matches(pattern, sentence) {
                guard !own(match),
                      let frame = Range(match.range(at: 1), in: sentence),
                      let verb = Range(match.range(at: verbGroup), in: sentence),
                      let object = Range(match.range(at: objectGroup), in: sentence) else { continue }
                // 我们需要你提供 asks the reader, whoever stands before it.
                let asksTheReader = sentence[frame].contains("你") || sentence[frame].contains("您")
                if !asksTheReader, ContentChecks.matches([chineseFirstPerson], String(sentence[..<frame.lowerBound])) { continue }
                // 附上了 or 发过 tell what was done.
                if sentence[verb.upperBound...].hasPrefix("了") || sentence[verb.upperBound...].hasPrefix("过") { continue }
                guard !negated(sentence, before: verb.lowerBound, negation: chineseNegation) else { continue }
                var text = String(sentence[object])
                if objectGroup > verbGroup, let end = chineseObjectEnd.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(end.range, in: text) {
                    text = String(text[..<range.lowerBound])
                }
                asked.append(Asked(position: match.range.location, object: hanObject(text), needsWhich: false))
            }
        }
        for pattern in [chineseNeed, chineseHave] {
            for match in matches(pattern, sentence) {
                let group = (1..<match.numberOfRanges).first { match.range(at: $0).location != NSNotFound } ?? 1
                guard !own(match), let object = Range(match.range(at: group), in: sentence) else { continue }
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
    /// The object before を or も, a verb of sending, and a polite request.
    private static let japaneseAsk = regex("(" + japaneseClause + "{1,30}?)(?:を|も)(?:至急|早めに|早急に|改めて|再度|もう一度|今一度|一度|すぐに|先に)?(?:送って|送付して|共有して|添付して|送信して|転送して|お送り|ご送付|ご共有|ご提供|ご送信|ご転送)(?:して|を)?(?:" + japaneseEndings + ")")
    /// The object before の and a noun of sending, as in 契約書のご提供をお願いいたします.
    private static let japaneseNoun = regex("(" + japaneseClause + "{1,30}?)の(?:ご送付|ご提供|ご共有|ご送信|ご転送|お送り)を(?:お願いします|お願いいたします|お願い致します|お願いできますか|お願いできますでしょうか|お願い申し上げます)")
    /// The object before を with いただけますか alone.
    private static let japaneseGive = regex("(" + japaneseClause + "{1,30}?)を(?:いただけますか|いただけませんか|いただけますでしょうか|頂けますか|頂けませんか|ください|下さい|もらえますか|いただきたい|頂きたい)")
    /// A kind before が必要です.
    private static let japaneseNeed = regex("(" + japaneseClause + "{1,30}?)が(?:必要です|必要になります|必要となります|必要でして|必要でございます|必要なのですが|必要なので|ほしいです|欲しいです)")
    private static let japaneseLead = regex(#"^(?:また|あと|それと|それから|さらに|念のため|ついでに|恐れ入りますが|お手数ですが|お手数をおかけしますが|すみませんが|申し訳ありませんが|至急)+"#)

    private static func japanese(_ sentence: String) -> [Asked] {
        guard sentence.contains(where: { $0.isHan || $0.isKana }) else { return [] }
        var asked: [Asked] = []
        for (pattern, needsWhich) in [(japaneseAsk, false), (japaneseNoun, false), (japaneseGive, false), (japaneseNeed, true)] {
            for match in matches(pattern, sentence) {
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
        var rest = String(sentence[start...])
        if let match = lead.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)), let range = Range(match.range, in: rest) {
            rest = String(rest[range.upperBound...])
        }
        // A word of the glossary stays whole, as "hoja de cálculo" or "price list".
        let phrases = phraseTerms.flatMap { term in ranges(of: term, in: rest) }
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

    /// Where a term stands in a text as whole words, ignoring case and accents.
    private static func ranges(of term: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isLetter ?? false), !(after?.isLetter ?? false) {
                found.append(range)
            }
            start = range.upperBound
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
    /// head names only a plain file, as 平面图的电子版, the whole object counts.
    private static func hanObject(_ text: String) -> String {
        var object = unquoted(text)
        for _ in 0..<3 {
            let stripped = removing(hanTrail, from: removing(hanLead, from: object))
            if stripped == object { break }
            object = trimmed(stripped)
        }
        guard let last = object.lastIndex(where: { $0 == "的" || $0 == "の" }) else { return object }
        let head = unquoted(String(object[object.index(after: last)...]))
        let headKinds = kinds(in: head)
        let namesOnlyAFile = !headKinds.isEmpty && headKinds.allSatisfy(\.isGeneric)
        return namesOnlyAFile && kinds(in: object).contains(where: { !$0.isGeneric }) ? object : head
    }

    private static let hanLead = regex(#"^(?:一下|一份|一个|一张|个|下|给我们|给我|过来|我们|我|你们的|您的|贵司的|贵方的|以下的?|下面的?|如下的?)"#)
    private static let hanTrail = regex(#"(?:吧|吗|呢|啊|哦|哈|呗|一下|也|过来|给我们|给我|好吗|可以吗|谢谢|嗎)$"#)

    /// The kinds a text names, each once, in the order the text names them.
    static func kinds(in text: String) -> [DocumentKind] {
        let folded = matchingText(text)
        var found: [(position: Int, kind: DocumentKind)] = []
        for (kind, terms) in matchingTerms {
            let first = terms.compactMap { position(of: $0, in: folded) }.min()
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
        "about", "attached", "enclosed", "signed", "back",
        "el", "la", "los", "las", "un", "una", "unos", "unas", "del", "al", "de", "tu", "tus", "su", "sus", "mi", "mis",
        "nuestro", "nuestra", "nuestros", "nuestras", "este", "esta", "estos", "estas", "ese", "esa", "esos", "esas",
        "ultimo", "ultima", "nuevo", "nueva", "actualizado", "actualizada", "final", "y", "o", "tambien", "version",
        "para", "por", "con", "en", "a", "sobre",
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

    /// Where a term first stands in a text, as a whole word when it is Latin, and anywhere
    /// when it is Chinese or Japanese, which write no spaces.
    private static func position(of term: String, in text: String) -> Int? {
        var start = text.startIndex
        while let range = text.range(of: term, range: start..<text.endIndex) {
            let latin = term.first.map { !$0.isHan && !$0.isKana } ?? true
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let isWord: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
            if !latin || (!isWord(before) && !isWord(after)) {
                return text.distance(from: text.startIndex, to: range.lowerBound)
            }
            start = text.index(after: range.lowerBound)
        }
        return nil
    }

    /// Whether a negation stands in the clause before the verb.
    private static func negated(_ sentence: String, before verb: String.Index, negation: NSRegularExpression) -> Bool {
        var clause = sentence[..<verb]
        if let boundary = clause.lastIndex(where: { ",;:，；：、".contains($0) }) {
            clause = clause[clause.index(after: boundary)...]
        }
        if let but = clause.range(of: " but ", options: [.caseInsensitive, .backwards]) {
            clause = clause[but.upperBound...]
        }
        if let pero = clause.range(of: " pero ", options: [.caseInsensitive, .backwards]) {
            clause = clause[pero.upperBound...]
        }
        let text = String(clause)
        return negation.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

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
