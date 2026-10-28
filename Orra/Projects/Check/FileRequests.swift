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

    /// Where the kind stands among all kinds, which orders two kinds a text names at the same
    /// place, as plano does a floor plan and a drawing.
    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
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
            Terms(english: ["contract", "contracts", "agreement", "agreements", "nda", "lease", "leases"],
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
                  japanese: ["資料", "ファイル", "書類", "データ一式", "原本", "コピー", "写し", "控え"],
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
                  japanese: ["デザインデータ", "デザインファイル", "入稿データ", "ロゴデータ", "ロゴ"],
                  spanish: ["archivo de diseño", "archivos de diseño", "archivos fuente", "logotipo", "logo"])
        case .data:
            Terms(english: ["data", "dataset", "datasets", "raw data", "csv"],
                  chinese: ["数据", "原始数据", "数据集", "數據"],
                  japanese: ["データ", "生データ", "データセット"],
                  spanish: ["datos", "conjunto de datos", "base de datos"])
        }
    }
}

/// Finds the files an email asks the user to send, such as "Could you send me the floor
/// plan?", 合同你也发我一份吧, 平面図を送っていただけますか。 or "¿Me lo podrías enviar?",
/// with code rules in English, Chinese, Japanese and Spanish, no model.
///
/// Each language has a list of constructions, the ways it asks someone to send, share,
/// forward or attach a document or to let the writer see one, written from the language and
/// not from any set of mails: the words that ask with a verb of sending (could you send, 请发,
/// お送りいただけますか, ¿podrías enviar?), the verb with what it asks for where the language
/// puts it (把 X 发我, X 也发我一份, X を送っていただけ, mándame X), a request in passing or
/// under a condition (if you have it, could you send it), a wish to see or have a document
/// (I'd love to see, 想看看, 拝見できれば, me gustaría ver), a need (we need, 我们还缺, が必要です,
/// nos falta) and a question whether the reader has one (do you have, 有没有, ¿tienes?).
///
/// What a construction asks for is read up to where its phrase ends. A word for a kind of
/// document sets the kind, a file name is kept whole, and a phrase with neither, such as "the
/// seating chart", asks for a document by its own words, which the search looks for by name
/// and content. The constructions of verbs that also take time, help or a visit (need, have,
/// see, give, provide) count only what names a document or a written thing such as a list.
/// "It", "them", lo, それ, 这个 or no object at all, as in 麻烦再发我一份, point to the
/// document named last before them, in the same sentence or in the sentence before, and ask
/// for nothing when none is named. So does lo or la with a word after it that says how or
/// when, as in "envíamelo firmado" or "¿me la mandas cuanto antes?".
///
/// Never a request: what is no file (comments, feedback, availability, an address, bank or
/// tax details, information, money, goods, a link, the email itself, a question such as "how
/// the client reacted", a number or a value such as a price or a size, and the details a form
/// asks for), a portal to upload to or a form to fill in online, a quote or an invoice still
/// to prepare ("send us a quote for 500 units"), a negation before the verb, leave to pass a
/// file on to others ("feel free to share it with your team"), the sender's own attachments,
/// offers and promises (I'll send you, attached, 我发给你, 添付します, te envío), a question
/// about what arrived or what the reader did to a document, a file that came, as in
/// 你发给我的平面图, and a wish of a good time, as in "¡pásalo bien!".
///
/// It reads the subject, unless it is that of a reply or a forward, and the first
/// `readLength` characters of the sender's own words, cut into sentences as DraftCheck cuts
/// them, at most `mostSentences` of `sentenceLength` characters each. Every pattern is
/// bounded, a construction of Chinese or Japanese runs only when the words it needs stand in
/// the sentence, and a sentence reads at most `mostFrames` matches of each pattern, so a
/// hostile text cannot make it slow. Its limit is wording it does not know.
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
    /// The most pronouns and plain files of a sentence that look for the document named
    /// before them, and how far back in their sentence they look, in characters.
    static let mostPointers = 4
    static let antecedentReach = 160

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
            // The sentence before, where a pronoun or a verb without an object may find the
            // document it means.
            let sentenceBefore = index > 0 ? sentences[index - 1] : nil
            let sentenceBeforeThat = index > 1 ? sentences[index - 2] : nil
            index += 1
            let asked = self.asked(in: sentence)
            var found = request(in: sentence, asked: asked, sentenceBefore: sentenceBefore, sentenceBeforeThat: sentenceBeforeThat)
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

    private enum Language {
        case english, spanish, chinese, japanese
    }

    /// What one construction found in a sentence.
    private struct Asked {
        /// Where the construction starts in the sentence, in UTF-16 units.
        var position: Int
        /// What it asks for, in Chinese and Japanese its head, see `hanObject(_:)`.
        var object: String
        /// What it asks for as a whole, which names the document when its head names no
        /// kind, as 展示会の案内文 does beside its head 案内文.
        var phrase: String
        /// The text of the sentence before the verb, or before what is asked for when that
        /// comes first, where a pronoun may find its document.
        var before: String
        var language: Language
        /// What it asks for must name a document, see `Construction.mustNameADocument`.
        var mustNameADocument: Bool
        /// It asks for "it", lo, それ or 这个, or for nothing named, as in 麻烦再发我一份, and so
        /// points to a document named before it, see `antecedent(before:namedBefore:ownCounts:)`.
        var pointsBack: Bool
    }

    /// What the constructions of a sentence ask for, in the order of the sentence.
    private static func asked(in original: String) -> [Asked] {
        let sentence = plain(original)
        guard !sentence.isEmpty else { return [] }
        return (english(sentence) + spanish(sentence) + chinese(sentence) + japanese(sentence)).sorted { $0.position < $1.position }
    }

    /// The request of one sentence, nil when it asks for no file. `sentenceBefore` and
    /// `sentenceBeforeThat` are the two sentences before it, where a pronoun may find its
    /// document.
    private static func request(in original: String, asked: [Asked], sentenceBefore: String?, sentenceBeforeThat: String?) -> FileRequest? {
        var objects: [String] = []
        var kinds: [DocumentKind] = []
        var fileNames: [String] = []
        // A sentence that ends in a colon leaves what it does not name to the list under it.
        let leadsAList = original.hasSuffix(":") || original.hasSuffix("：")
        // A sentence that asks to sign a paper and send it back may point to the one the
        // sender attached.
        let signs = ContentChecks.matches([signedAndSentBack], plain(original))
        // The document the sentence before names, read once for every pointer of the sentence,
        // or, when that sentence only points back itself, as "Do you have it?" does, the one
        // the sentence before it names.
        var named: Antecedent??
        func namedBefore() -> Antecedent? {
            if let named { return named }
            var found = sentenceBefore.flatMap { lastDocument(in: plain($0), ownCounts: signs) }
            if found == nil, let sentenceBefore, let earlier = sentenceBeforeThat, ContentChecks.matches(pointerWords, plain(sentenceBefore)) {
                found = lastDocument(in: plain(earlier), ownCounts: signs)
            }
            named = .some(found)
            return found
        }
        var searches = 0
        for item in asked {
            guard let found = askedFor(item, namedBefore: namedBefore, signs: signs, searches: &searches, leadsAList: leadsAList), !objects.contains(found.object) else { continue }
            objects.append(found.object)
            kinds += found.kinds.filter { !kinds.contains($0) }
            fileNames += found.fileNames.filter { !fileNames.contains($0) }
        }
        guard !objects.isEmpty else { return nil }
        return FileRequest(
            sentence: String(trimmed(original).prefix(sentenceKept)),
            object: clipped(objects.joined(separator: ", "), to: objectKept),
            kinds: kinds.map(\.rawValue),
            fileNames: fileNames
        )
    }

    /// What one construction asks for, with the kinds and file names it names, nil when that
    /// is no file. A pronoun, or a plain file such as "a copy", takes the document named
    /// before it. A phrase that names no kind and no file name asks for a document by its
    /// own words, unless its construction must name a document.
    private static func askedFor(_ item: Asked, namedBefore: () -> Antecedent?, signs: Bool, searches: inout Int, leadsAList: Bool) -> (object: String, kinds: [DocumentKind], fileNames: [String])? {
        var object = clipped(item.object, to: objectKept)
        var phrase = clipped(item.phrase, to: objectKept)
        var language = item.language
        if leadsAList, item.pointsBack || object.isEmpty {
            return nil
        }
        var kinds = self.kinds(in: object)
        var names = self.fileNames(in: object)
        let plainFile = !kinds.isEmpty && kinds.allSatisfy(\.isGeneric) && names.isEmpty && ownWords(phrase).isEmpty
        if item.pointsBack || plainFile, searches < mostPointers {
            searches += 1
            let found = antecedent(before: item.before, namedBefore: namedBefore, ownCounts: signs).map { found in
                (object: clipped(found.object, to: objectKept), phrase: clipped(found.phrase, to: objectKept), language: found.language)
            }
            // A construction that must name a document takes only a document named by a kind
            // or a file name, and a plain file keeps itself otherwise.
            if let found, !item.mustNameADocument || !self.kinds(in: found.object).isEmpty || !self.fileNames(in: found.object).isEmpty {
                object = found.object
                phrase = found.phrase
                language = found.language
                kinds = self.kinds(in: object)
                names = self.fileNames(in: object)
            } else if item.pointsBack {
                return nil
            }
        } else if item.pointsBack {
            return nil
        }
        guard !object.isEmpty, !isNoFile(object, language), !isToPrepare(object) else { return nil }
        if kinds.isEmpty, names.isEmpty {
            guard !item.mustNameADocument || namesAWrittenThing(object, language), !ownWords(phrase).isEmpty, !isNoFile(phrase, language) else { return nil }
            // In Spanish the words after de may name the kind, as in "el borrador del
            // contrato", which English keeps in what is asked for, as "the draft of the
            // contract" does.
            let phraseKinds = language == .spanish ? self.kinds(in: phrase) : []
            return (phrase, phraseKinds.isEmpty ? [.document] : phraseKinds, [])
        }
        return (object, kinds, names)
    }

    /// Whether a phrase that names no kind still names a written thing by its head, as "the
    /// vendor list", "your notes", 装箱清单, 讲稿, 一覧 or "el borrador" do, which the
    /// constructions that must name a document take as a document asked for by its words.
    private static func namesAWrittenThing(_ object: String, _ language: Language) -> Bool {
        let folded = matchingText(object)
        guard !folded.isEmpty else { return false }
        if folded.contains(where: { $0.isHan || $0.isKana }) {
            return ContentChecks.matches([hanWrittenThing], trimmed(folded))
        }
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let last = words.last else { return false }
        switch language {
        case .spanish:
            guard let head = words.first(where: { !spanishDeterminers.contains($0) }) else { return false }
            return spanishWrittenThings.contains(head)
        default:
            var head = last
            if let of = words.firstIndex(of: "of"), of > 0, !englishCounts.contains(words[of - 1]) {
                head = words[of - 1]
            }
            return englishWrittenThings.contains(head)
        }
    }

    private static let englishWrittenThings: Set<String> = [
        "list", "lists", "sheet", "sheets", "chart", "charts", "notes", "draft", "drafts", "summary", "agenda", "checklist",
        "checklists", "log", "logs", "records", "diagram", "diagrams", "layout", "sketch", "sketches", "outline", "handbook",
        "manual", "guidelines", "guide", "guides", "brief", "template", "templates", "map", "maps",
    ]
    private static let spanishWrittenThings: Set<String> = [
        "lista", "listas", "notas", "borrador", "borradores", "resumen", "agenda", "esquema", "bosquejo", "registro", "registros",
        "diagrama", "manual", "plantilla", "mapa", "croquis", "hoja",
    ]
    /// The ends of a Chinese or Japanese head that name a written thing: 清单, 签到表, 讲稿, 手册,
    /// 记录, 一覧, リスト, 書 and their like, but not 代表 or 手表.
    private static let hanWrittenThing = regex(#"(?:(?<!简|买)单|(?<!代|发|外|手|电|仪|钟|水)表|稿|(?<!注)册|记录|笔记|日志|明细|模板|草图|地图|指南|须知|细则|一覧|リスト|書|録|原稿|下書き|明細|テンプレート|マニュアル|まとめ)$"#)

    /// The request of a sentence that ends in a colon, with the items of the list under it
    /// as what it asks for. Items that name no kind ask for documents by their own words when
    /// one of them names a written thing, as "the guest list" or 签到表 does, so a list of a
    /// name, a city and a size, as on a form to sign up, asks for none.
    private static func listRequest(_ original: String, items: [String]) -> FileRequest? {
        let object = items.map { clipped($0, to: objectKept) }.joined(separator: ", ")
        var kinds = self.kinds(in: object)
        let names = fileNames(in: object)
        if kinds.isEmpty, names.isEmpty, items.contains(where: { item in
            let language: Language = item.contains(where: { $0.isHan || $0.isKana }) ? (item.contains(where: \.isKana) ? .japanese : .chinese) : latinLanguage(item)
            let head = language == .chinese || language == .japanese ? hanObject(item) : item
            return !ownWords(item).isEmpty && !isNoFile(head, language) && namesAWrittenThing(head, language)
        }) {
            kinds = [.document]
        }
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

    // MARK: Constructions

    /// A way a language asks the reader for a document, as one pattern with named groups:
    /// `verb`, `frame` for the words that ask where they stand apart from the verb, `gap`
    /// between the two, and `object` where what is asked for stands in the pattern, as in
    /// 把 X 发 or X を送って. Without `object`, what is asked for is read after the verb.
    private struct Construction: Sendable {
        /// The construction in words, such as "could you send X" or 把 X 发我, for whoever
        /// reads the list.
        let reads: String
        let pattern: NSRegularExpression
        /// What is asked for must name a document: a kind, a file name, a word for a file such
        /// as copy, 资料 or 書類, or a written thing such as a list, 清单 or 一覧, see
        /// `namesAWrittenThing(_:_:)`. So it must for the verbs that also take time, help or a
        /// visit: need, have, see, give and provide, and for a topic before its verb, which may
        /// also be its subject. After a verb of sending, a phrase that names no kind asks for a
        /// document by its own words.
        let mustNameADocument: Bool
        /// The sentence must end in a question mark, as "do you have X?" must.
        let question: Bool
        /// An imperative at the start of a clause, which the sender's own "I'll" before it
        /// makes the sender's, as in "I'll check it and send the plan".
        let imperative: Bool
        /// The verb must send toward the writer, as 发我, 发给我 or 发过来 do, or end the
        /// clause as a request, as 发一下吧 does, since a clause that starts with 把 and no
        /// subject may also tell what someone did.
        let towardTheWriter: Bool
        /// Patterns the sentence must match first, so most sentences cost the construction
        /// nothing.
        let gates: [NSRegularExpression]
        let hasFrame: Bool
        let hasGap: Bool
        let hasObject: Bool

        init(
            _ reads: String, _ pattern: NSRegularExpression, mustNameADocument: Bool = false, question: Bool = false,
            imperative: Bool = false, towardTheWriter: Bool = false, gates: [NSRegularExpression] = []
        ) {
            self.reads = reads
            self.pattern = pattern
            self.mustNameADocument = mustNameADocument
            self.question = question
            self.imperative = imperative
            self.towardTheWriter = towardTheWriter
            self.gates = gates
            hasFrame = pattern.pattern.contains("(?<frame>")
            hasGap = pattern.pattern.contains("(?<gap>")
            hasObject = pattern.pattern.contains("(?<object>")
        }

        /// Whether the construction may match the sentence at all.
        func mayMatch(_ sentence: String) -> Bool {
            if question, !(sentence.hasSuffix("?") || sentence.hasSuffix("？")) {
                return false
            }
            return gates.allSatisfy { ContentChecks.matches([$0], sentence) }
        }

        /// Where a named group of a match stands, nil when the pattern has no such group or
        /// the group took no part in the match.
        func range(_ name: String, in match: NSTextCheckingResult, of sentence: String) -> Range<String.Index>? {
            switch name {
            case "frame": guard hasFrame else { return nil }
            case "gap": guard hasGap else { return nil }
            case "object": guard hasObject else { return nil }
            default: break
            }
            let found = match.range(withName: name)
            guard found.location != NSNotFound else { return nil }
            return Range(found, in: sentence)
        }
    }

    // MARK: English

    /// The words that ask: please, could you, would you mind, if you could, I'd appreciate it
    /// if you could, don't forget to and their like.
    private static let englishAsks = #"please|pls|plz|kindly|(?:could|can|would|will|might) (?:you|u)|(?:would|do) you mind|(?:if|whether) (?:you|u) (?:could|can|would|might)|you could|would it be possible (?:for you )?to|is it possible (?:for you )?to|any chance (?:you could|you can|of you)|(?:i|we)(?:['’]d| would)? (?:really |greatly |very much |so much )?appreciate (?:it )?if you (?:could|can|would)|(?:i|we)(?:['’]d| would) be (?:very |most |really |so )?(?:grateful|thankful|obliged|glad|happy) if you (?:could|can|would)|(?:i|we) (?:also |still |really )?need you to|(?:i|we)(?:['’]d| would) (?:like|love) you to|(?:i|we) want you to|don['’]?t forget to|do not forget to|remember to|make sure (?:to|you)|be sure to|feel free to|do not hesitate to|don['’]?t hesitate to|thanks? (?:you )?in advance for"#
    /// The verbs of sending a file.
    private static let englishSends = #"send|resend|re-send|forward|share|reshare|attach|email|e-mail|upload|submit|pass along|pass on|include|sending|resending|re-sending|forwarding|sharing|resharing|attaching|emailing|e-mailing|uploading|submitting|passing along|passing on|including"#
    /// The verbs that give or show, which also take a call, a hand or a tour.
    private static let englishGives = #"provide|providing|(?:give|giving|get|getting|show|showing|lend|lending) (?:me|us)|let (?:me|us) (?:have|see)"#
    /// The verbs of a wish to have or to see.
    private static let englishSees = #"see|seeing|view|viewing|have|having|get|getting|receive|receiving|read|reading|look at|looking at|take a look at|taking a look at|have a look at|having a look at|go through|going through|glance at|peek at"#

    /// The ways English asks the reader for a document.
    private static let englishConstructions: [Construction] = [
        Construction(
            "please, could you, would you mind, if you could, I'd appreciate it if you could … send, forward, share or attach X",
            latin(#"\b(?<frame>"# + englishAsks + #")\b(?<gap>[^.!?;]{0,40}?)\b(?<verb>"# + englishSends + #")\b"#)),
        Construction(
            "could you provide, give, get or show me X",
            latin(#"\b(?<frame>"# + englishAsks + #")\b(?<gap>[^.!?;]{0,40}?)\b(?<verb>"# + englishGives + #")\b"#),
            mustNameADocument: true),
        Construction(
            "could you drop X into the thread, a verb that also drops a line or a price",
            latin(#"\b(?<frame>"# + englishAsks + #")\b(?<gap>[^.!?;]{0,40}?)\b(?<verb>drop|dropping)\b"#),
            mustNameADocument: true),
        Construction(
            "mind sending X?, the short form of would you mind, at the start of a clause",
            latin(#"(?:^|[,;:]\s*)(?<frame>mind)\s+(?<verb>sending|resending|forwarding|sharing|emailing|e-mailing|attaching|passing along|passing on)\b"#),
            question: true),
        Construction(
            "send me X, forward X, share X, at the start of a clause, not upload or submit X, which calls for a portal",
            latin(#"(?:^|[,;:]\s*)(?:(?:hi|hello|hey|dear|good (?:morning|afternoon|evening))\b[^,!]{0,40}[,!]\s*)?(?:(?:and|also|just|so|ok|okay|then|oh|ps|p\.s\.)[,:]?\s+){0,2}(?<verb>send|resend|forward|email|e-mail|share|attach|pass along|pass on)\s+(?=(?:me|us|over|along|across|back|through|again|the|your|that|this|these|those|it|them|a|an|any|all|both|copies|one|some)\b)"#),
            imperative: true),
        Construction(
            "I'd love to see X, can I have X, she'd like to read X, I look forward to receiving X",
            latin(#"\b(?<frame>(?:i|we|she|he|they)(?:['’]d|['’]ll| would| will| really| also| still| just){0,2} (?:love|like|want|wish|hope|need)s? to|(?!(?:you|u)\b)[\p{L}]+(?:['’]d| would)(?: really| also| just)? (?:love|like) to|(?:i|we)(?:['’]m|['’]re| am| are) (?:keen|eager|hoping|looking|waiting) to|(?:can|could|may|might) (?:i|we)(?: please)?|it (?:would|will|might)(?: be)? (?:\w+ )?(?:help|helpful|great|useful|good|nice|ideal) to|(?:i|we) look forward to|(?:i|we)(?:['’]m|['’]re| am| are) looking forward to|looking forward to)\s+(?<verb>"# + englishSees + #")\b"#),
            mustNameADocument: true),
        Construction(
            "I'd love a copy of X, we'd like the X",
            latin(#"\b(?<frame>(?:i|we)(?:['’]d| would)(?: really| also)?) (?<verb>love|like|appreciate)\s+(?=(?:a|an|the|your|any|some|copies|both)\b)"#),
            mustNameADocument: true),
        Construction(
            "I'd like to ask you for X, may I ask for X",
            latin(#"\b(?<frame>(?:i|we)(?:['’]d| would)? (?:like to |want to |wanted to )?|(?:can|could|may|might) (?:i|we) )(?<verb>ask (?:you )?for)\b"#),
            mustNameADocument: true),
        Construction(
            "we need X, we'll need X",
            latin(#"\b(?:i|we)(?:['’]d|['’]ll| would| will| also| still| really| urgently| now| just| only){0,3}\s+(?<verb>need|require)\b(?!\s+(?:to|you|your help|a reply|an answer|more time)\b)"#),
            mustNameADocument: true),
        Construction(
            "we are missing X, we lack X",
            latin(#"\b(?:i|we)(?:['’]re|['’]m| are| am)?(?: still| also)? (?<verb>missing|lacking|lack)\b"#),
            mustNameADocument: true),
        Construction(
            "X is missing, X is still needed",
            latin(#"(?<object>\b(?:the|your|a|an|our)\s[^,.!?;:]{1,60}?)\s+(?<verb>(?:is|are) (?:still |also )?(?:missing|needed|required))\b"#),
            mustNameADocument: true),
        Construction(
            "do you have X?",
            latin(#"\bdo (?:you|u)(?: still| also| happen to| by any chance){0,2} (?<verb>have)\b"#),
            mustNameADocument: true, question: true),
        Construction(
            "have you got X?",
            latin(#"\bhave (?:you|u) (?<verb>got)\b"#),
            mustNameADocument: true, question: true),
        Construction(
            "is there X?",
            latin(#"\b(?<verb>is there|are there)\b"#),
            mustNameADocument: true, question: true),
    ]

    private static let englishNegation = latin(#"\b(?:don['’]?t|do not|didn['’]?t|did not|no need to|not necessary|unnecessary|needn['’]t|need not|never|not|no longer|won['’]t|without|can['’]?t|cannot|couldn['’]?t|wouldn['’]?t|shouldn['’]?t)\b"#)
    /// Who sends: a subject, or me or us before to, as in "would you like me to send".
    private static let englishPronoun = latin(#"\b(i|we|you|u|they|he|she|me(?=\s+to\b)|us(?=\s+to\b))\b"#)
    /// The pronouns that make the sender the one who sends.
    private static let englishSender: Set<String> = ["i", "we", "me", "us"]
    /// A permission between the words that ask and the verb, as in "allows you to".
    private static let englishAllowed = latin(#"\b(?:allow|allows|allowed|let|lets|permit|permits|permitted|authori[sz]e|authori[sz]es)\s+(?:you|u)\b"#)
    /// The sender's own future before an imperative, as in "I'll check it and send the plan".
    private static let englishSendersOwn = latin(#"\b(?:i|we)(?:['’]ll| will| shall|['’]m going to| am going to|['’]re going to| are going to)\b"#)
    /// Words before what is asked for that are none of it, as in "send me over the plan", and
    /// him or her before what is asked for, as in "send him the plan".
    private static let englishLead = latin(#"^(?:\s*\b(?:me|us|over|along|across|back|through|again|also|please|kindly|to me|to us|over to (?:me|us)|across to (?:me|us)|(?:him|her|them)(?=\s+(?:the|a|an|your|our|that|this|these|those|any|all|both|copies|one)\b))\b)*\s*(?:the following(?: files?| documents?| items?)?\s*:|these\s*:|following\s*:)?"#)
    /// Where what is asked for ends, also before a clause that says more about it, as in
    /// "the plan that we discussed" or "the plan you sent".
    private static let englishCut = latin(#"\s+(?:on|onto|about|regarding|re|for|by|to|with|from|in|into|within|before|after|when|whenever|if|as soon as|asap|so that|so|because|since|once|until|till|today|tomorrow|tonight|this week|next week|(?:yesterday|earlier|last (?:week|month|time|night)|this morning)(?!['’])|at|via|through|back|over|along|across|again|too|as well|either|please|as|is|are|was|were|has|have|had|will|won['’]?t|doesn['’]?t|does not|didn['’]?t|did not|can['’]?t|cannot|isn['’]?t|aren['’]?t|wasn['’]?t|handy|ready|available|on hand|at hand|first(?=\s*[.!?]?\s*$)|that|which|who|whom|whose|where|you|we|i|they|he|she|and (?:let|tell|confirm|please|could|can|also|then|i|we|send|forward|share|sign|return|email|attach|upload|submit)|but|thanks|thank you)\b|[,;:()\[\]]|\s[-–—]\s"#)
    /// The cut words after which "a copy of the contract" and "una copia de la factura" go on.
    private static let prepositions: Set<String> = ["on", "about", "for", "by", "to", "with", "from", "in", "sobre", "para", "por", "con", "de", "del", "en", "a", "al"]
    private static let englishKeepGoing: Set<String> = ["copy", "copies", "version", "versions", "scan", "scans", "pdf", "pdfs", "photo", "photos", "picture", "pictures", "image", "images"]
    /// What asks for the document named before it.
    private static let englishPointer = latin(#"^(?:it|them|that|this|these|those|one|ones|the one|the ones|the same|that one|this one|those ones|it all|them all|all of them|all of it|both|both of them)$"#)

    private static func english(_ sentence: String) -> [Asked] {
        var asked: [Asked] = []
        for construction in englishConstructions where construction.mayMatch(sentence) {
            for match in frames(construction.pattern, sentence) {
                guard let whole = Range(match.range, in: sentence), let verb = construction.range("verb", in: match, of: sentence) else { continue }
                let frame = construction.range("frame", in: match, of: sentence)
                // The sender as the one who sends, between the words that ask and the verb, as
                // in "please let me know if I should send" or "would you like me to send".
                if let frame, frame.upperBound < verb.lowerBound,
                   let pronoun = lastMatch(englishPronoun, in: String(sentence[frame.upperBound..<verb.lowerBound]))?.lowercased(),
                   englishSender.contains(pronoun) {
                    continue
                }
                if construction.imperative, ContentChecks.matches([englishSendersOwn], String(sentence[..<verb.lowerBound])) {
                    continue
                }
                // What the reader may do, as in "can you confirm the client allows you to show
                // screenshots", asks for no file.
                if let frame, frame.upperBound < verb.lowerBound, ContentChecks.matches([englishAllowed], String(sentence[frame.upperBound..<verb.lowerBound])) {
                    continue
                }
                guard !negated(sentence, from: frame?.lowerBound, before: verb.lowerBound, negation: englishNegation),
                      !ContentChecks.matches([portal], clause(of: whole, verb: verb, in: sentence)) else { continue }
                // Passing something on to anyone at all, as in "share it with your friends" or
                // "forward this to a friend", asks the reader for no file.
                if ContentChecks.matches([englishAnyone], String(sentence[verb.upperBound...])) {
                    continue
                }
                // Leave to pass a file on to others, as in "feel free to share the slides with
                // your students", gives a permission and asks the reader for no file.
                if let frame, ContentChecks.matches([englishPermission], String(sentence[frame])),
                   ContentChecks.matches([englishToOthers], String(sentence[verb.upperBound...])) {
                    continue
                }
                // "include me" or "attach us" asks for no file.
                if ["include", "including", "attach", "attaching", "upload", "uploading", "submit", "submitting"].contains(sentence[verb].lowercased()),
                   ContentChecks.matches([objectIsAPerson], String(sentence[verb.upperBound...])) {
                    continue
                }
                let object = construction.range("object", in: match, of: sentence).map { trimmed(String(sentence[$0])) }
                    ?? latinObject(after: verb.upperBound, in: sentence, lead: englishLead, cut: englishCut, keepGoing: englishKeepGoing)
                let pointsBack = ContentChecks.matches([englishPointer], object) || (object.isEmpty && !construction.mustNameADocument)
                // What a pronoun may point to stands before the verb, also between the words
                // that ask and the verb, as in "please sign the attached form and send it back".
                let before = construction.range("object", in: match, of: sentence)?.lowerBound ?? verb.lowerBound
                asked.append(Asked(
                    position: match.range.location, object: object, phrase: object, before: String(sentence[..<before]),
                    language: .english, mustNameADocument: construction.mustNameADocument, pointsBack: pointsBack))
            }
        }
        return asked
    }

    private static let objectIsAPerson = latin(#"^\s*(?:me|us|him|her)\b"#)
    /// Anyone at all as whom something goes to, as in a newsletter.
    private static let englishAnyone = latin(#"\b(?:with|to)\s+(?:anyone|anybody|everyone|everybody|a friend|friends|your friends|your network|your colleagues|others|other people|people you know)\b"#)
    /// The words that ask which also give leave, as in "feel free to share it".
    private static let englishPermission = latin(#"^(?:feel free to|do not hesitate to|don['’]?t hesitate to)$"#)
    /// Someone other than the writer whom a file would go to, in the clause after the verb:
    /// with or to and a name, or a determiner or a pronoun of others, as in "with your
    /// students", "to the parents" or "with Kai", but not "with me" or "with our team".
    private static let englishToOthers = regex(#"^[^.!?;]*?(?i:\b(?:with|to)\s+)(?!(?i:me|us|myself|ourselves|our)\b)(?:(?i:your|the|his|her|their|any|all|other|others|everyone|anyone|anybody|everybody|people|whoever|them|him)\b|[A-Z])"#)

    // MARK: Spanish

    /// The words that ask: por favor, ¿podrías?, te agradecería que, necesito que, no
    /// olvides, si puedes and their like.
    private static let spanishAsks = #"por favor|porfa|porfavor|favor de|ser[ií]as? tan amable de|tendr[ií]as? la amabilidad de|puedes|podr[ií]as|puede|podr[ií]a|pueden|podr[ií]an|pod[eé]s|(?:te |le |les )?agradecer[ií]a(?: mucho)? (?:que|si)|necesito que|necesitamos que|necesitar[ií]a que|ser[ií]a posible que|es posible que|me har[ií]as el favor de|hazme el favor de|me haces el favor de|no olvides|no te olvides de|no se olvide de|no olvide|recuerda|recuerde|(?:te|le|les) importar[ií]a|(?:te|le|les) molestar[ií]a|si puedes|si pudieras|si puede|si pudiera|cuando puedas|cuando pueda|(?:te|le|les) pido que|quisiera pedirte que|quisiera pedirle que|te encargo|(?:me|nos) gustar[ií]a que|(?:me|nos) encantar[ií]a que|ser[ií]a (?:\w+ )?(?:genial|ideal|perfecto|bueno|[uú]til|estupendo|de gran ayuda) (?:si|que)|estar[ií]a bien que|gracias de antemano por|gracias por adelantado por"#
    /// The verbs of sending, in the infinitive, the imperative and the subjunctive, with me
    /// or nos and lo or la, accented or not. Never the first person, as in te envío, adjunto
    /// or envié, which the sender says of their own attachment or of what they sent.
    private static let spanishSends = #"(?:re)?env[ií](?:[aá]r|[aá]|e|es|en|[aá]ras?|[aá]ran|[aá]ses?)(?:me|nos|te|le|les|se)?(?:lo|la|los|las)?|m[aá]nd(?:[aá]r|[aá]|e|es|en|[aá]ras?|[aá]ran)(?:me|nos|te|le|les|se)?(?:lo|la|los|las)?|comp[aá]rt(?:[ií]r|[aá]|e|as|an|en|[ií]eras?|[ií]eran)(?:me|nos|te|le|les|se)?(?:lo|la|los|las)?|adj[uú]nt(?:[aá]r|[aá]|e|es|en|[aá]ras?)(?:me|nos|te|le|les|se)?(?:lo|la|los|las)?|p[aá]s(?:[aá]r|[aá]|e|es|en|[aá]ras?)(?:me|nos|te|le|les|se)?(?:lo|la|los|las)?|rem[ií]t(?:[ií]r|[aá]|e|as|[ií]eras?)(?:me|nos|te|le|les|se)?(?:lo|la|los|las)?|hac(?:[eé]r|e|es)(?:me|nos|le|les|se)?(?:lo|la|los|las)?\s+llegar|h[aá]g(?:as|a|an)(?:me|nos|le|les|se)?(?:lo|la|los|las)?\s+llegar|hicier(?:as|a|an)\s+llegar|h[aá]z(?:me|nos)(?:lo|la|los|las)?\s+llegar"#
    /// The verbs that give or show, which also take help or a visit, accented or not, as in
    /// dámelo, mostrármelo or enséñame.
    private static let spanishGives = #"fac[ií]l[ií]t(?:[aá]r|[aá]|e|es|[aá]ras?)(?:me|nos|te|le|les|se)?(?:lo|la|los|las)?|proporci[oó]n(?:[aá]r|[aá]|e|es|[aá]ras?)(?:me|nos|te|le|les|se)?(?:lo|la|los|las)?|d(?:[aá]r|[eé]s?|[aá])(?:me|nos)(?:lo|la|los|las)?|mostr(?:[aá]r|[eé]s?)(?:me|nos)(?:lo|la|los|las)?|mu[eé]str(?:a|e|as)(?:me|nos)(?:lo|la|los|las)?|ens[eé][nñ](?:[aá]r|a|e|es)(?:me|nos)(?:lo|la|los|las)?"#

    /// The ways Spanish asks the reader for a document.
    private static let spanishConstructions: [Construction] = [
        Construction(
            "por favor, ¿podrías?, te agradecería que, no olvides … enviar, mandar, compartir, adjuntar o hacer llegar X",
            latin(#"\b(?<frame>"# + spanishAsks + #")\b(?<gap>[^.!?;]{0,40}?)\b(?<verb>"# + spanishSends + #")\b"#)),
        Construction(
            "¿podrías facilitarme, darme o mostrarme X?",
            latin(#"\b(?<frame>"# + spanishAsks + #")\b(?<gap>[^.!?;]{0,40}?)\b(?<verb>"# + spanishGives + #")\b"#),
            mustNameADocument: true),
        Construction(
            "envíame X, mándamelo, compártenos X, hazme llegar X, házmelo llegar",
            latin(#"\b(?<verb>(?:env[ií]a|m[aá]nda|comp[aá]rte|p[aá]sa|reenv[ií]a|adj[uú]nta|rem[ií]te)(?:me|nos)(?:lo|la|los|las)?|h[aá]z(?:me|nos)(?:lo|la|los|las)?\s+llegar)\b"#)),
        Construction(
            "envíeme X, mándemelo, compártannos X, hágame llegar X, the same verbs as usted and ustedes say them",
            latin(#"\b(?<verb>(?:env[ií]e|m[aá]nde|comp[aá]rta|p[aá]se|reenv[ií]e|adj[uú]nte|rem[ií]ta)n?(?:me|nos)(?:lo|la|los|las)?|h[aá]gan?(?:me|nos)(?:lo|la|los|las)?\s+llegar)\b"#)),
        Construction(
            "adjunta X, envía X, at the start of a clause, not the participle of the sender's own file, as in adjunta encontrarás la factura",
            latin(#"(?:^|[,;:¿¡]\s*)(?<verb>adj[uú]nta|env[ií]a|m[aá]nda|comp[aá]rte)\b(?!\s+(?:encontrar[aáeé]?\w*|hallar[aáeé]?\w*|ver[aá]s|va|van|est[aá]n?|tienes?|te|le|les|os|se|me|nos|env[ií]o|remito|mando|adjunto)\b)"#)),
        Construction(
            "envíalo, compártelas conmigo, at the start of a clause, which point to the document named before",
            latin(#"(?:^|[,;:¿¡]\s*)(?<verb>(?:env[ií]a|m[aá]nda|comp[aá]rte|p[aá]sa|reenv[ií]a|adj[uú]nta|rem[ií]te)(?:lo|la|los|las))\b"#)),
        Construction(
            "¿me envías X?, ¿me lo mandas?, ¿me enviarías X?",
            latin(#"(?:^|[¿,;:]\s*)(?:(?:y|tambi[eé]n|oye|oiga|entonces)\s+)?(?<frame>me|nos)\s+(?:(?:lo|la|los|las)\s+)?(?<verb>env[ií]as|mandas|pasas|compartes|reenv[ií]as|adjuntas|remites|haces llegar|env[ií]ar[ií]as|mandar[ií]as|pasar[ií]as|compartir[ií]as|reenviar[ií]as)\b"#)),
        Construction(
            "me gustaría ver X, quisiera recibir X, ¿puedo ver X?",
            latin(#"\b(?<frame>(?:me|nos|le|les) gustar[ií]a|(?:me|nos|le|les) encantar[ií]a|quisiera|quisi[eé]ramos|quiero|queremos|quiere|quieren|querr[ií]a|deseo|deseamos|desear[ií]a|puedo|podemos|espero|esperamos)\s+(?<verb>ver|tener|recibir|leer|echar(?:le)? un vistazo a(?:l)?|dar(?:le)? un vistazo a(?:l)?|mirar|obtener|contar con)\b"#),
            mustNameADocument: true),
        Construction(
            "me gustaría una copia de X",
            latin(#"\b(?<frame>(?:me|nos) gustar[ií]a|(?:me|nos) encantar[ií]a|quisiera|quisi[eé]ramos)\s+(?<verb>)(?=(?:una?|el|la|los|las|tu|tus|su|sus)\s)"#),
            mustNameADocument: true),
        Construction(
            "quería pedirte X, te pido X",
            latin(#"\b(?<frame>(?:te |le |les )?quer[ií]a pedir(?:te|le|les)?|quisiera pedir(?:te|le|les)|(?:te|le|les) pido|(?:te|le|les) quer[ií]a pedir)\s+(?<verb>)(?=(?:una?|el|la|los|las|tu|tus|su|sus)\s)"#),
            mustNameADocument: true),
        Construction(
            "necesito X, nos falta X",
            latin(#"\b(?<verb>necesito|necesitamos|necesitar[ií]a|necesitar[ií]amos|me hace falta|nos hace falta|me falta|nos falta|me faltan|nos faltan|requerimos|requiero)\b(?!\s+que\b)"#),
            mustNameADocument: true),
        Construction(
            "¿tienes X?",
            latin(#"(?:^|¿)\s*(?<verb>tienes|tiene|tienen|tendr[aá]s|tendr[ií]as|tendr[ií]a|cuentas con|cuenta con|hay|habr[aá])\b"#),
            mustNameADocument: true, question: true),
    ]

    /// No before the verb, but not the polite no of "¿no me podrías enviar…?", and ni, as in
    /// "no copie, use ni reenvíe".
    private static let spanishNegation = latin(#"\b(?:no(?!\s+(?:me\s+|nos\s+|te\s+|le\s+)?(?:puedes|podr[ií]as|puede|podr[ií]a|pueden|podr[ií]an)\b)|ni|nunca|jam[aá]s|tampoco|sin)\b"#)
    /// The sender as the one who sends, right before the verb, as in "si necesitas que te
    /// envíe el plano".
    private static let spanishSender = latin(#"\bque\s+(?:yo\s+)?(?:te|le|les|os)\s+$|\bque\s+yo\s+$"#)
    /// Words before what is asked for that are none of it, as in "¿tienes a mano las fotos?"
    /// or "compártelas conmigo".
    private static let spanishLead = latin(#"^(?:\s*\b(?:me|nos|te|le|les|tambi[eé]n|por favor|porfa|de nuevo|otra vez|nuevamente|ahora|ya|todav[ií]a|a[uú]n|a mano|a la mano|por ah[ií]|conmigo|con nosotros|con nosotras|a m[ií]|a nosotros|a nosotras)(?![\p{L}]))*\s*(?:(?:lo|los|las) siguientes?(?: archivos| documentos)?\s*:)?"#)
    private static let spanishCut = latin(#"\s+(?:sobre|para|por|con|de|del|a|al|antes|despu[eé]s|cuando|si|hoy|ma[nñ]ana|(?:el|este|el pr[oó]ximo) (?:lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bado|domingo)|esta semana|la (?:pr[oó]xima )?semana(?: que viene)?|este mes|lo antes posible|en|porque|ya que|que|tambi[eé]n|por favor|es|est[aá]|est[aá]n|son|fue|ya|y (?:me|nos|te|le|av[ií]same|conf[ií]rmame|env[ií]\w*|m[aá]nd\w*|f[ií]rm\w*|devu[eé]lv\w*|reenv[ií]\w*|comp[aá]rt\w*)|pero|gracias)\b|[,;:()\[\]]|\s[-–—]\s"#)
    /// Where what is asked for ends when its head names no kind, so the words after de stay,
    /// as in "la lista de invitados".
    private static let spanishCutAfterDe = latin(#"\s+(?:sobre|para|por|con|a|al|antes|despu[eé]s|cuando|si|hoy|ma[nñ]ana|(?:el|este|el pr[oó]ximo) (?:lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bado|domingo)|esta semana|la (?:pr[oó]xima )?semana(?: que viene)?|este mes|lo antes posible|en|porque|ya que|que|tambi[eé]n|por favor|es|est[aá]|est[aá]n|son|fue|ya|y (?:me|nos|te|le|av[ií]same|conf[ií]rmame|env[ií]\w*|m[aá]nd\w*|f[ií]rm\w*|devu[eé]lv\w*|reenv[ií]\w*|comp[aá]rt\w*)|pero|gracias)\b|[,;:()\[\]]|\s[-–—]\s"#)

    /// What a Spanish construction asks for after its verb, and the phrase a search reads:
    /// the same, or with the words after de when the head names no kind or file name, as
    /// "la lista de invitados" beside "la lista".
    private static func spanishObject(after start: String.Index, in sentence: String) -> (object: String, phrase: String) {
        let object = latinObject(after: start, in: sentence, lead: spanishLead, cut: spanishCut, keepGoing: spanishKeepGoing)
        guard kinds(in: object).isEmpty, fileNames(in: object).isEmpty else { return (object, object) }
        return (object, latinObject(after: start, in: sentence, lead: spanishLead, cut: spanishCutAfterDe, keepGoing: spanishKeepGoing))
    }

    /// Whether what follows a verb that carries lo or la names the document that lo or la
    /// stands for: a file name at its start, as in "pásamelo rev-0412.pdf", or a phrase that
    /// starts with an article, a possessive or a demonstrative and names a kind or a file
    /// name, also in the words after de, as "la factura" in "¿podrías enviármela la factura?"
    /// or "el borrador del contrato". A word for a kind further on names nothing, as in
    /// "pásalo bien durante la presentación".
    private static func namesTheDocumentAgain(_ object: String, phrase: String) -> Bool {
        if let name = fileNames(in: object).first, object.hasPrefix(name) {
            return true
        }
        guard isSpanishNounPhrase(object) else { return false }
        return !kinds(in: object).isEmpty || !fileNames(in: object).isEmpty || !kinds(in: phrase).isEmpty || !fileNames(in: phrase).isEmpty
    }

    /// Whether a Spanish phrase starts with an article, a possessive or a demonstrative, or
    /// with todo or ambos before one, as "la dirección", "tus notas" or "todas las fotos" do,
    /// and so names a thing, unlike firmado, todas or cuanto antes, which say how or when.
    private static func isSpanishNounPhrase(_ text: String) -> Bool {
        let words = matchingText(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).map(String.init)
        guard let first = words.first else { return false }
        if spanishArticles.contains(first) {
            return true
        }
        return ["todo", "toda", "todos", "todas", "ambos", "ambas"].contains(first) && words.count == 2 && spanishArticles.contains(words[1])
    }

    private static let spanishArticles: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "tu", "tus", "su", "sus", "mi", "mis", "nuestro", "nuestra", "nuestros",
        "nuestras", "este", "esta", "estos", "estas", "ese", "esa", "esos", "esas", "aquel", "aquella", "aquellos", "aquellas",
    ]
    /// Pasar with lo or la and a word for a good time after it, "to have a good time", as in
    /// "¡pásalo bien!", "pásala de maravilla" or "que lo pases genial", which asks for
    /// nothing. Pásamelo, with me or nos, is no such phrase.
    private static let spanishGoodTimeVerb = latin(#"^p[aá]s(?:[aá]r|[aá]|e|es|en|[aá]ras?)(?:te|se)?(?:lo|la|los|las)?$"#)
    private static let spanishGoodTime = latin(#"^\s*(?:(?:muy|tan|re|s[uú]per|bien)\s+)?(?:bien|mal|genial|s[uú]per|bomba|incre[ií]ble|fenomenal|estupend\w*|maravillos\w*|de maravilla|de lujo|en grande|a lo grande|fatal|de miedo|de pel[ií]cula|ch[eé]vere|padr[ií]simo|padre|bac[aá]n|chido|regio|lindo|rico|bonito|excelente|tranquil[oa]|como nunca|a tope)(?![\p{L}\p{N}])"#)

    private static let spanishKeepGoing: Set<String> = ["copia", "copias", "versión", "version", "versiones", "foto", "fotos", "escaneo", "escaneos", "pdf", "imagen", "imágenes", "imagenes"]
    /// Lo, la, los or las on the verb or right before it, which point back, as in
    /// mándamelo or ¿me lo podrías enviar?
    private static let spanishCliticOnVerb = latin(#"(?:lo|la|los|las)(?:\s+llegar)?$"#)
    private static let spanishCliticBefore = latin(#"(?:^|[\s¿¡,])(?:(?:me|nos|te|se|le|les)\s+)?(?:lo|la|los|las)\s*$|(?:^|[\s¿¡,])(?:lo|la|los|las)\s+(?:puedes|podr[ií]as|puede|podr[ií]a|pueden|podr[ií]an|pod[eé]s)\b"#)
    private static let spanishAnyone = latin(#"\b(?:con|a)\s+(?:todos|todo el mundo|cualquiera|tus amigos|sus amigos|un amigo|una amiga|tus colegas|quien quieras)\b"#)
    /// The words that ask which outside a question give leave, as "puedes compartirlo" does.
    private static let spanishPermission = latin(#"^(?:puedes|puede|pueden|pod[eé]s)$"#)
    /// Someone other than the writer whom a file would go to, in the clause after the verb:
    /// con or a and a name, or a determiner or a pronoun of others, as in "con tus clientes" or
    /// "a Marta", but not "a mí" or "con nosotros".
    private static let spanishToOthers = regex(#"^[^.!?;]*?(?i:\b(?:con|a)\s+)(?!(?i:m[ií]|mis|nosotros|nosotras|nuestro|nuestra|nuestros|nuestras)\b)(?:(?i:tus?|sus?|los|las|el|la|todos|todas|quien|quienes|cualquiera|otros|otras)\b|[A-ZÁÉÍÓÚÑ])"#)
    private static let spanishPointer = latin(#"^(?:eso|esto|esos|estos|esa|esas|ese|este|ello|lo mismo|el mismo|la misma|los mismos|las mismas)$"#)

    private static func spanish(_ sentence: String) -> [Asked] {
        var asked: [Asked] = []
        for construction in spanishConstructions where construction.mayMatch(sentence) {
            for match in frames(construction.pattern, sentence) {
                guard let whole = Range(match.range, in: sentence), let verb = construction.range("verb", in: match, of: sentence) else { continue }
                let frame = construction.range("frame", in: match, of: sentence)
                // "que te envíe" with a verb not of tú: the sender sends to the reader.
                if frame != nil, !sentence[verb].lowercased().hasSuffix("s"),
                   ContentChecks.matches([spanishSender], String(sentence[whole.lowerBound..<verb.lowerBound])) {
                    continue
                }
                // Passing something on to anyone at all, as in "compártelo con tus amigos".
                if ContentChecks.matches([spanishAnyone], String(sentence[verb.upperBound...])) {
                    continue
                }
                // Leave to pass a file on to others, as "puedes compartir el folleto con tus
                // clientes" says outside a question, gives a permission and asks for no file.
                if let frame, ContentChecks.matches([spanishPermission], String(sentence[frame])),
                   !sentence[..<frame.lowerBound].contains("¿"), !sentence.hasSuffix("?"),
                   ContentChecks.matches([spanishToOthers], String(sentence[verb.upperBound...])) {
                    continue
                }
                guard !negated(sentence, from: frame?.lowerBound, before: verb.lowerBound, negation: spanishNegation),
                      !ContentChecks.matches([portal], clause(of: whole, verb: verb, in: sentence)) else { continue }
                var (object, phrase) = spanishObject(after: verb.upperBound, in: sentence)
                // Lo or la on the verb, before the words that ask or between them and the verb.
                let cliticOnVerb = ContentChecks.matches([spanishCliticOnVerb], String(sentence[verb]))
                let clitic = cliticOnVerb
                    || ContentChecks.matches([spanishCliticBefore], String(sentence[..<(frame?.lowerBound ?? verb.lowerBound)].suffix(12)))
                    || ContentChecks.matches([spanishCliticBefore], String(sentence[(frame?.lowerBound ?? verb.lowerBound)..<verb.lowerBound]))
                // "¡Pásalo bien!" wishes a good time and asks for nothing.
                if clitic, ContentChecks.matches([spanishGoodTimeVerb], String(sentence[verb])),
                   ContentChecks.matches([spanishGoodTime], String(sentence[verb.upperBound...])) {
                    continue
                }
                if clitic, !object.isEmpty, !ContentChecks.matches([spanishPointer], object), !namesTheDocumentAgain(object, phrase: phrase) {
                    if !isSpanishNounPhrase(object) {
                        // What says how or when to send it, as firmado, todas, pronto or cuanto
                        // antes, leaves lo or la to point to the document named before.
                        object = ""
                        phrase = ""
                    } else if cliticOnVerb {
                        // A phrase after a verb that carries lo or la says what lo or la
                        // stands for, so one that names no document asks for none, as "la
                        // dirección" in "mándamela la dirección". It names the document again
                        // in colloquial Spanish, as in "mándamelo el archivo".
                        continue
                    }
                }
                let pointsBack = ContentChecks.matches([spanishPointer], object)
                    || (object.isEmpty && (clitic || !construction.mustNameADocument))
                asked.append(Asked(
                    position: match.range.location, object: object, phrase: phrase, before: String(sentence[..<verb.lowerBound]),
                    language: .spanish, mustNameADocument: construction.mustNameADocument, pointsBack: pointsBack))
            }
        }
        return asked
    }

    // MARK: Chinese

    /// The words that make a request, before the verb: 请, 麻烦, 能否, 方便的话, 也 and their
    /// like, 你能 or 您可以, the steps before sending back a signed paper, as in 盖章后回传, and
    /// 并 that starts a clause after one that asks, as in 请回复同意，并把合同发过来.
    private static let chineseFrames = #"(?:签字|签名|签章|盖章|签署|签好|盖好|签完|盖完)(?:字|章)?(?:并|后|之后|以后)|(?<=[,;，；]\s{0,1})并且?|请|麻烦|劳烦|烦请|能否|可否|能不能|可不可以|可以|是否可以|是否能|方便(?:的)?时(?:候)?|方便的话|(?<!没)有(?:空|时间)(?:的话|时|的时候)?|如果可以(?:的话)?|如果方便(?:的话)?|要是方便(?:的话)?|记得|顺便|顺手|顺带|也|再|帮忙|帮我们|帮我|务必|还请|劳驾|辛苦(?:你|您)了?|拜托(?:你|您)?|抽空|得空|尽快|赶紧|需要(?:你|您)们?|希望(?:你|您)们?(?:能)?|想请(?:你|您)?|(?:你|您)们?(?:这边|那边)?(?:能不能|能|可以|可不可以|方便)|别忘了?|别忘记了?|不要忘了?|不要忘记了?|千万别忘了?|千万不要忘了?|可别忘了?"#
    /// The verbs of sending. A verb of one character stands only before 给, 我, 一下 and the
    /// like, or right before a word of the glossary, as in 请发平面图给我, so 发票 or 发现 is
    /// no verb.
    private static let chineseSends = #"回传|传回|发回|寄回|发送|发给|发过来|发过去|发一下|发一份|发个|发到|传给|传过来|传过去|传一下|传一份|传到|寄给|寄过来|寄一下|寄一份|寄到|分享|附上|转发|共享|转给|转过来|转一下|抄送(?:给)?|交给|上传|转(?=我)|发(?=我|吧|呗|来|回|$|[,.!?;。，！？；\s])|传(?=我|吧|来|$|[,.!?;。，！？；\s])|寄(?=我|吧|来|$|[,.!?;。，！？；\s])|(?:发|传|寄)(?=(?:(?:最新|最终|新|完整|正式|修改后|更新后|那|这)(?:版|个|份|些)?的?)?(?:"# + hanTerms + "))"
    /// The words of the glossary in Chinese characters, longest first, as a pattern.
    private static let hanTerms: String = {
        var seen: Set<String> = []
        return DocumentKind.allCases.flatMap { $0.terms.chinese + $0.terms.japanese }
            .filter { $0.contains(where: \.isHan) && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
    }()
    /// A verb of sending anywhere, which the constructions of sending need, so a sentence
    /// without one costs them nothing.
    private static let chineseSend = regex(chineseSends)
    /// A verb of sending of one character, which 发 X 给我 and X 发我一下 need.
    private static let chineseSendCharacter = regex(#"发|传|寄|转|分享|共享"#)
    /// A verb of sending that stands before what it sends, as in 发排练流程给我, and not the
    /// first character of a word such as 发票, 发现, 传真 or 寄存, nor of 发回, 传回 or 寄回,
    /// after which comes whom it goes back to, not what.
    private static let chineseBareSend = #"(?:发(?!票|现|布|生|展|言|表|明|起|出|货|动|挥|放|行|育|达|烧|热|音|射|酵|型|量|觉|愁|呆|火|疯|抖|胖|财|奋|掘|源|件|给|到|过|了|送|回)|传(?!统|说|达|播|真|染|承|奇|闻|授|唤|递|输|给|到|过|了|回)|寄(?!存|托|生|宿|养|居|给|到|过|了|回)|转发|分享|共享)"#
    /// A character of a clause: no punctuation that ends one, but the dot of a file name.
    private static let chineseClause = #"(?:[^,.!?;:。，！？；：、\n]|\.(?=[A-Za-z0-9]))"#
    /// A character of a topic before its verb, as in 合同也发我一份: one of a clause, but not
    /// 把 or 将, whose constructions read their own object.
    private static let chineseTopic = #"(?:[^,.!?;:。，！？；：、\n把将]|\.(?=[A-Za-z0-9]))"#
    /// The start of a clause, where a request without a word that asks may start.
    private static let chineseClauseStart = #"(?:^|(?<=[,，;；:：。!！?？、]))\s*"#
    /// What may stand between the subject and the verb of a request: 也, 再, 能, 方便, 帮忙,
    /// 尽快, 明天 and their like.
    private static let chineseAdverbs = "(?:也|再|就|先|都|还|能不能|能|可不可以|可以|方便|有空|帮忙|帮我|尽快|赶紧|直接|顺便|" + chineseWhen + "){0,4}"
    /// When the reader is asked to send it: 今晚, 明天, 下周 and their like.
    private static let chineseWhen = #"今天|今晚|明天|明早|后天|这周|本周|下周|周末|回头|到时候|稍后|晚点|早点|尽早|待会|一会儿|有(?:空|时间)(?:的话|时|的时候)|方便(?:的)?时(?:候)?|方便的话"#

    /// The ways Chinese asks the reader for a document.
    private static let chineseConstructions: [Construction] = [
        Construction(
            "请, 麻烦, 能否, 方便的话, 也 … 发, 传, 转发, 附上 X, or nothing named, as in 麻烦再发我一份",
            regex("(?<frame>" + chineseFrames + ")(?<gap>" + chineseTopic + "{0,10}?)(?<verb>" + chineseSends + ")(?<object>" + chineseClause + "{0,30})"),
            gates: [chineseSend]),
        Construction(
            "请发 X 给我, 麻烦传 X 过来",
            regex("(?<frame>" + chineseFrames + ")(?<gap>" + chineseClause + "{0,10}?)(?<verb>" + chineseBareSend + ")(?<object>" + chineseClause + "{1,30}?)(?=给(?:我|我们|他|她|他们|她们|大家|客户|对方|同事)|过来|过去)"),
            gates: [chineseSendCharacter]),
        Construction(
            "请把 X 发给我, 麻烦将 X 转发",
            regex("(?<frame>" + chineseFrames + ")(?<gap>" + chineseClause + "{0,10}?)(?:把|将)(?<object>" + chineseClause + "{1,60}?)(?<verb>" + chineseSends + "|提供)"),
            gates: [regex(chineseSends + "|提供")]),
        Construction(
            "请提供 X",
            regex("(?<frame>" + chineseFrames + ")(?<gap>" + chineseClause + "{0,10}?)(?<verb>提供)(?<object>" + chineseClause + "{1,30})"),
            mustNameADocument: true, gates: [regex("提供")]),
        Construction(
            "你把 X 发我一下, 您将 X 转发给客户",
            regex(chineseClauseStart + "(?<frame>(?:你|您)们?(?:这边|那边)?" + chineseAdverbs + ")(?:把|将)(?<object>" + chineseClause + "{1,60}?)(?:也|再|都|先|一起|直接)?(?<verb>" + chineseSends + ")"),
            gates: [chineseSend]),
        Construction(
            "把 X 发我, 把 X 发过来吧, at the start of a clause",
            regex(chineseClauseStart + "(?<frame>" + chineseAdverbs + ")(?:把|将)(?<object>" + chineseClause + "{1,60}?)(?:也|再|都|先|一起|直接)?(?<verb>" + chineseSends + ")"),
            towardTheWriter: true, gates: [chineseSend]),
        Construction(
            "X 发我一下, X 也发我一份吧, X 发过来",
            regex(chineseClauseStart + "(?<object>" + chineseTopic + "{1,30}?)(?<frame>(?:(?:你|您)们?)?(?:" + chineseFrames + "|也|再|就|先|都|还|能|方便|有空|帮忙|尽快|赶紧|直接|顺便|" + chineseWhen + "){0,4})(?<verb>发|传|寄|转发|转|分享|共享|发送)(?=给?(?:我|我们)(?:一下|一份|一个|个|吧|吗|呢|哈|呀|啊|哦|呗|看看|参考|就行|就好|就可以|即可|好吗|可以吗)*(?:$|[,，;；:：。!！?？\\s])|过来)"),
            mustNameADocument: true, gates: [chineseSendCharacter]),
        Construction(
            "发我一份 X, 你发我一下 X, at the start of a clause",
            regex(chineseClauseStart + "(?<frame>(?:你|您)?们?" + chineseAdverbs + ")(?<verb>(?:发|传|寄|转发|转|分享|共享|发送)给?(?:我|我们))(?<object>" + chineseClause + "{0,30})"),
            gates: [chineseSendCharacter]),
        Construction(
            "发 X 给我, 传 X 过来, at the start of a clause",
            regex(chineseClauseStart + "(?<frame>(?:你|您)?们?" + chineseAdverbs + ")(?<verb>" + chineseBareSend + ")(?<object>" + chineseClause + "{1,30}?)(?=给(?:我|我们)|过来)"),
            gates: [chineseSendCharacter]),
        Construction(
            "给我发一份 X, 能给我传一下 X 吗",
            regex(chineseClauseStart + "(?<frame>(?:" + chineseFrames + ")?(?:你|您)?们?(?:能不能|能|可以|方便)?)(?<verb>给(?:我|我们)(?:发|传|寄|转发))(?<object>" + chineseClause + "{0,30})"),
            gates: [regex("给")]),
        Construction(
            "给我一份 X, 能给我 X 吗",
            regex(chineseClauseStart + "(?<frame>(?:" + chineseFrames + ")?(?:你|您)?们?(?:能不能|能|可以|方便)?)(?<verb>给(?:我|我们)(?:一份|一下|一个|一张|个)?)(?!发|传|寄|转|打|回|讲|说|看)(?<object>" + chineseClause + "{1,30})"),
            mustNameADocument: true, gates: [regex("给")]),
        Construction(
            "想跟你要一份 X, 找您要一下 X",
            regex("(?<frame>(?:想|能|可以|方便)?(?:跟|向|找)(?:你|您)们?)(?<verb>要(?:一份|一下|一个|个|一张)?)(?<object>" + chineseClause + "{1,30})"),
            mustNameADocument: true, gates: [regex("要")]),
        Construction(
            "我们需要 X, 我们还缺 X, not a verb as in 我们需要讨论平面图",
            regex("(?<frame>(?:我们|我司|本公司|我这边|我们这边|我)(?:这边|还|也|现在|目前|急|很)?)(?<verb>需要|要|缺少|缺|还差|少了)(?!(?:(?:你|您)(?!们?的)|讨论|确认|看|了解|修改|调整|知道|开会|安排|沟通|商量|审核|核对|更新|准备|提交|签|做|画|改|出|跟|和|与|去|来|再|重新|尽快|先))(?<object>" + chineseClause + "{1,30})"),
            mustNameADocument: true, gates: [regex("要|缺|差|少")]),
        Construction(
            "有没有 X?, not a question about what the reader did, as in 你有没有看过平面图",
            regex("(?<verb>有没有)" + chineseNotDone + "(?<object>" + chineseClause + "{1,30}?)(?:吗|$|[?？])"),
            mustNameADocument: true, gates: [regex("有没有")]),
        Construction(
            "你有 X 吗?",
            regex("(?<verb>(?:你|您)们?(?:这边|那边|手上|手里|手边|那里|那儿)?有)" + chineseNotDone + "(?<object>" + chineseClause + "{1,30}?)吗"),
            mustNameADocument: true, gates: [regex("有")]),
        Construction(
            "想看看 X, 希望收到 X, 客户想先过目 X",
            regex("(?<frame>(?:我|我们|她|他|她们|他们|客户|对方|老板|领导|候选人|同事|大家|业主|甲方|老师)?(?:很|也|还|都|先|正|一直|特别)?(?:想|希望|想要|期待|盼着|打算)(?:能|可以)?(?:先|提前|尽快|再|早点|早日)?)(?<verb>看看|看一下|看一看|看下|瞧瞧|过目|拿到|收到|看到|拿一份|要一份|参考一下|参考|看(?!过|了))(?<object>" + chineseClause + "{1,30})"),
            mustNameADocument: true, gates: [regex("想|希望|期待|盼|打算")]),
        Construction(
            "给我看看 X, 能让我看一下 X 吗",
            regex("(?<frame>(?:能不能|能否|可否|可以|能|麻烦|请)?(?:你|您)?(?:让|给)(?:我|我们))(?<verb>看看|看一下|看一看|过目|瞧瞧|参考一下)(?<object>" + chineseClause + "{1,30})"),
            mustNameADocument: true, gates: [regex("看|过目|瞧|参考")]),
        Construction(
            "能不能先把 X 给我看看, 麻烦把 X 给我们过目",
            regex("(?<frame>" + chineseFrames + ")(?<gap>" + chineseClause + "{0,10}?)(?:把|将)(?<object>" + chineseClause + "{1,60}?)(?<verb>" + chineseShowMe + ")"),
            mustNameADocument: true, gates: [regex("给")]),
        Construction(
            "你把 X 给我看看, 把 X 给我们过目, at the start of a clause",
            regex(chineseClauseStart + "(?<frame>(?:(?:你|您)们?(?:这边|那边)?)?" + chineseAdverbs + ")(?:把|将)(?<object>" + chineseClause + "{1,60}?)(?<verb>" + chineseShowMe + ")"),
            mustNameADocument: true, gates: [regex("给")]),
    ]

    /// Showing the writer a document after 把, as in 把方案给我看看, which also takes a hand or
    /// a room, so what is shown must name a document.
    private static let chineseShowMe = "给(?:我|我们)(?:看看|看一下|看一看|看下|过目|瞧瞧|参考一下|参考)"

    /// Not a verb after 有没有 or 你有, as in 你有没有看过平面图, which asks whether the reader did
    /// something to a document, not for it.
    private static let chineseNotDone = "(?!(?:没有)?(?:看|查看|查阅|阅读|读|确认|核对|核实|检查|审核|审阅|审批|批准|批过|签|盖章|更新|修改|修订|调整|改|收到|收好|拿到|下载|上传|保存|打印|提交|提供|准备|完成|处理|做|画过|画了|画好|找到|找过|用过|用了|使用|参考|考虑|讨论|联系|通知|安排|整理|发过|发了|发给|发送|发出|传过|传了|传给|寄过|寄了|寄出|转发|分享|共享|附上))"
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
    private static let chineseObjectEnd = regex(#"(?:给|到|至)(?=我|我们|你|您|他|她|他们|她们|大家|客户|对方|同事|邮箱|这个|那个|公司|微信|群)|过来|过去|吧|吗|呢|哦|啊|谢谢|哈|呗|好吗|可以吗|请|麻烦|劳烦|烦请"#)
    /// After the verb: a file that came, as in 你发给我的平面图 or 发来的报价单, and what was
    /// done, as in 发给我了, which ask for nothing. After 发到 or 寄至 what follows is a place,
    /// as in 发到我的邮箱.
    private static let chineseCame = regex(#"^(?:给)?(?:我们|我|你们|你|您|他|她)?(?:来|过来)?(?:一下|一份)?的"#)
    private static let chineseDone = regex(#"^(?:给)?(?:我们|我|你们|你|您|他|她)?(?:来|过来)?(?:一下|一份)?(?:了|过)"#)
    /// Toward the writer, after a verb of a clause that starts with 把: 发我, 发给我, 发过来,
    /// or the end of a request, as in 发一下吧.
    private static let chineseTowardTheWriter = regex(#"^(?:给)?(?:我们|我|过来)|^(?:一下|一份)?(?:吧|呗|哈|啊|呀)|^(?:一下)?(?:$|[,，;；:：。!！?？])"#)
    /// A verb whose next words name whom or where it goes, not what.
    private static let chineseToWhom = regex(#"(?:给|到|至|抄送)$"#)
    /// A verb that handles what 把 takes before it is sent, followed by 一下, 后, 好, 完 or 成
    /// or by the verb of sending, as in 整理一下, 汇总后, 扫描后, 签好 or 整理成表, but not
    /// before 的, as in 更新后的报价单 or 整理好的资料, where it tells which document.
    private static let chineseHandled = regex(#"(?:整理|汇总|总结|归纳|扫描|签字|签名|签好|签完|签署|盖章|盖好|盖完|打印|修改|改好|改完|填好|填完|填写|确认|核对|检查|翻译|压缩|打包|转换|导出|做成|做好|准备好|准备|补充|完善|更新|处理|标注|审核|审阅|校对|看完|看过|拍好|拍完)(?:(?=(?:一下|之后|以后|后|好|完|成|了|过|并|再)(?!的))|$)"#)
    /// What asks for the document named before it.
    private static let chinesePointer = regex(#"^(?:它|它们|这个|那个|这份|那份|这些|那些|这一份|那一份|这个东西|那个东西)$"#)

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
        for construction in chineseConstructions where construction.mayMatch(sentence) {
            for match in frames(construction.pattern, sentence) {
                guard !own(match), let whole = Range(match.range, in: sentence),
                      let verb = construction.range("verb", in: match, of: sentence) else { continue }
                let frame = construction.range("frame", in: match, of: sentence).flatMap { $0.isEmpty ? nil : $0 }
                let gap = construction.range("gap", in: match, of: sentence)
                let objectRange = construction.range("object", in: match, of: sentence)
                if let frame {
                    // 我们需要你提供 asks the reader, whoever stands before it. The sender as the
                    // one who sends, before the frame or between it and the verb, as in 请等我
                    // 把平面图发给你 or 请问需要我把合同发给你吗, asks nothing.
                    let asksTheReader = sentence[frame].contains("你") || sentence[frame].contains("您")
                    if !asksTheReader, frame.lowerBound == whole.lowerBound,
                       ContentChecks.matches([chineseFirstPerson], String(sentence[..<frame.lowerBound])) {
                        continue
                    }
                    // 并 joins a request only to a clause that asks, so 合并后发给我 asks nothing.
                    if sentence[frame].hasPrefix("并"), !ContentChecks.matches([chineseAsking], String(sentence[..<frame.lowerBound])) { continue }
                }
                if let gap, ContentChecks.matches([chineseFirstPerson], String(sentence[gap])) { continue }
                // 也附上 or 再附上 without a word that asks, in the frame or right after it,
                // brings the sender's own file.
                if sentence[verb].hasPrefix("附") {
                    let asking = frame.map { String(sentence[$0.lowerBound..<(gap?.upperBound ?? $0.upperBound)]) } ?? ""
                    if !ContentChecks.matches([chineseAsking], asking) { continue }
                }
                // 发给我的 or 发来的 name a file that came, and 附上了, 发过 or 发给我了 tell what
                // was done.
                let after = String(sentence[verb.upperBound...])
                let sends = ContentChecks.matches([chineseSendCharacter], String(sentence[verb])) || sentence[verb].contains("附") || sentence[verb].contains("交") || sentence[verb].contains("抄")
                let toAPlace = sentence[verb].hasSuffix("到") || sentence[verb].hasSuffix("至")
                if sends, ContentChecks.matches([chineseDone], after) || (!toAPlace && ContentChecks.matches([chineseCame], after)) { continue }
                if construction.towardTheWriter, !sentence[verb].contains("我"), !sentence[verb].hasSuffix("过来"),
                   !ContentChecks.matches([chineseTowardTheWriter], after) {
                    continue
                }
                guard !negated(sentence, before: verb.lowerBound, negation: chineseNegation),
                      !ContentChecks.matches([portal], clause(of: whole, verb: verb, in: sentence)) else { continue }
                var text = objectRange.map { String(sentence[$0]) } ?? ""
                let objectAfterVerb = objectRange.map { $0.lowerBound >= verb.upperBound } ?? true
                if objectAfterVerb, let end = chineseObjectEnd.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(end.range, in: text) {
                    text = String(text[..<range.lowerBound])
                }
                // What 把 takes ends at a verb that handles it before it is sent, as 整理一下 in
                // 把意见整理一下发给我 or 扫描后 in 把协议扫描后发回, so what is sent is what was
                // handled, and 意见 stays comments.
                if !objectAfterVerb, let handled = chineseHandled.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(handled.range, in: text) {
                    text = String(text[..<range.lowerBound])
                }
                var object = hanObject(text)
                var phrase = hanCleaned(text)
                // After 发给, 传到 or 抄送, or 转发 followed by 给, comes whom or where it goes, as in
                // 发给大家 or 转发给设计团队, so what follows asks for a file only when it names a
                // document, as in 发给我一份报价单.
                if objectAfterVerb, ContentChecks.matches([chineseToWhom], String(sentence[verb])) || text.hasPrefix("给") || text.hasPrefix("到") || text.hasPrefix("至"),
                   kinds(in: object).isEmpty, fileNames(in: text).isEmpty {
                    object = ""
                    phrase = ""
                }
                // Nothing after the verb but me, 一下 or 一份: what is asked for may stand before
                // the words that ask, as in 厨电规格麻烦发我一下, when it names a document.
                // Otherwise it points back.
                if object.isEmpty, objectAfterVerb, let frame {
                    let boundaries = ",;:，；：。!?！？、把将"
                    let start = sentence[..<frame.lowerBound].lastIndex(where: { boundaries.contains($0) }).map { sentence.index(after: $0) } ?? sentence.startIndex
                    let topic = String(sentence[start..<frame.lowerBound].suffix(30))
                    if !kinds(in: hanObject(topic)).isEmpty || !fileNames(in: topic).isEmpty || ContentChecks.matches([chinesePointer], hanObject(topic)) {
                        object = hanObject(topic)
                        phrase = hanCleaned(topic)
                    }
                }
                let pointsBack = object.isEmpty || ContentChecks.matches([chinesePointer], object)
                if pointsBack, construction.mustNameADocument, object.isEmpty { continue }
                let start = objectRange.map { min($0.lowerBound, verb.lowerBound) } ?? verb.lowerBound
                asked.append(Asked(
                    position: match.range.location, object: object, phrase: phrase, before: String(sentence[..<start]),
                    language: .chinese, mustNameADocument: construction.mustNameADocument, pointsBack: pointsBack))
            }
        }
        return asked
    }

    // MARK: Japanese

    /// A character of what is asked for before its particle: no punctuation and no を, so it
    /// starts after the last を before the verb.
    private static let japaneseObject = #"(?:[^を、。,.!?！？\n]|\.(?=[A-Za-z0-9]))"#
    /// What may stand between the particle and the verb, as 2部, メールで or PDFで.
    private static let japaneseGap = #"[^を、。,.!?！？\n]"#
    /// A number of copies or an adverb between the particle and a verb of giving, as 2部 or
    /// 至急.
    private static let japaneseQuantity = #"(?:(?:\d+|[一二三四五六七八九十数]+|何)(?:点|部|枚|通|件|つ|冊|式)か?|いくつか|至急|早めに|改めて|再度|もう一度|今一度|一度|すぐに|先に|ぜひ|是非)?"#
    /// The verbs of sending.
    private static let japaneseSends = #"送って|送付して|お送り|ご送付|再送して|ご再送|再送付して|再送信して|送信して|ご送信|転送して|ご転送|共有して|ご共有|添付して|ご添付|返送して|ご返送|メールして|お届け|届けて|お回し|回して|アップロードして|アップして"#
    /// The endings that ask politely, from ください to いただけないでしょうか.
    private static let japanesePolite = #"いただけますと|頂けますと|いただけましたら|頂けましたら|くださいますと|くださいませんか|くださいますか|くださいますでしょうか|くださいませ|くださいね|ください|下さい|いただけますでしょうか|いただけないでしょうか|いただけないですか|いただけないか|いただけますか|いただけませんか|いただけると|いただければ|いただけたら|いただきたい|いただきたく|頂けますでしょうか|頂けないでしょうか|頂けますか|頂けませんか|頂けると|頂ければ|頂けたら|頂きたい|頂きたく|頂戴できますか|頂戴できれば|頂戴したく|頂戴したい|もらえないでしょうか|もらえますか|もらえませんか|もらえると|もらえたら|もらいたい|くれますか|くれませんか|くれない|ほしいです|欲しいです|ほしい|欲しい|お願いします|お願いいたします|お願い致します|お願いできますでしょうか|お願いできますか|お願いできれば|お願い申し上げます|願います"#
    /// A verb of sending anywhere, and a polite ending anywhere, which the constructions of
    /// sending need.
    private static let japaneseSend = regex(japaneseSends)
    private static let japaneseEnding = regex(japanesePolite)

    /// The ways Japanese asks the reader for a document.
    private static let japaneseConstructions: [Construction] = [
        Construction(
            "X を送っていただけますか, X をお送りください, X を2部お送りいただけますでしょうか",
            regex("(?<object>" + japaneseObject + "{1,30}?)を(?<gap>" + japaneseGap + "{0,15}?)(?<verb>" + japaneseSends + ")(?:して|を)?(?:" + japanesePolite + ")"),
            gates: [regex("を"), japaneseSend, japaneseEnding]),
        Construction(
            "X も送ってください",
            regex("(?<object>" + japaneseObject + "{1,30}?)も(?<gap>" + japaneseGap + "{0,15}?)(?<verb>" + japaneseSends + ")(?:して|を)?(?:" + japanesePolite + ")"),
            mustNameADocument: true, gates: [regex("も"), japaneseSend, japaneseEnding]),
        Construction(
            "X は送っていただけますか, X については送ってください",
            regex("(?<object>" + japaneseObject + "{1,30}?)(?:については|につきましては|は)(?<gap>" + japaneseGap + "{0,15}?)(?<verb>" + japaneseSends + ")(?:して|を)?(?:" + japanesePolite + ")"),
            mustNameADocument: true, gates: [regex("は"), japaneseSend, japaneseEnding]),
        Construction(
            "お送りいただけますか with nothing named before it in its clause, after Xがあれば or a sentence that names X, also after もう一度 or もしよろしければ",
            regex("(?:^|(?<=[、。,，！!？?]))\\s*(?<gap>(?:もう|もし|[^をもは、。,.!?！？\\n]){0,20}?)(?<verb>" + japaneseSends + ")(?:して|を)?(?:" + japanesePolite + ")"),
            gates: [japaneseSend, japaneseEnding]),
        Construction(
            "X のご送付をお願いいたします",
            regex("(?<object>" + japaneseObject + "{1,30}?)の(?<verb>ご送付|ご提供|ご共有|ご送信|ご転送|お送り|ご返送)を(?:お願いします|お願いいたします|お願い致します|お願いできますか|お願いできますでしょうか|お願い申し上げます)"),
            gates: [regex("の"), regex("お願い")]),
        Construction(
            "X 送付のお願い, X ご共有のお願い",
            regex("(?<object>" + japaneseObject + "{1,30}?)の?(?<verb>(?:ご)?(?:送付|共有|提供|送信|転送|返送))の?(?:お願い|ご依頼|依頼)"),
            gates: [regex("お願い|依頼")]),
        Construction(
            "X は PDF でいただけますか, X もいただけますか, a topic before a verb of giving, which also gives time, with only a means such as 紙で or a count between, so ご確認いただけますか asks for no file",
            regex("(?<object>" + japaneseObject + "{1,30}?)(?<!見積もり)(?<!見積り)(?<!見積)(?:については|につきましては|は|も)(?<gap>(?:[\\p{Han}\\p{Katakana}A-Za-z0-9ー]{1,8}で(?:も)?)?" + japaneseQuantity + ")(?<verb>いただけますでしょうか|いただけないでしょうか|いただけますか|いただけませんか|頂けますでしょうか|頂けないでしょうか|頂けますか|頂けませんか|頂戴できますか|頂戴できれば|もらえますか|もらえませんか|いただけると|いただければ|いただけたら|頂けると|頂ければ)"),
            mustNameADocument: true, gates: [regex("は|も"), regex("いただけ|頂け|頂戴|もらえ")]),
        Construction(
            "X をいただけますか, X をください, X を頂戴できますか, not a quote still to prepare",
            regex("(?<object>" + japaneseObject + "{1,30}?)(?<!見積もり)(?<!見積り)(?<!見積)を(?<gap>" + japaneseQuantity + ")(?<verb>いただけますでしょうか|いただけないでしょうか|いただけますか|いただけませんか|頂けますでしょうか|頂けないでしょうか|頂けますか|頂けませんか|ください|下さい|もらえますか|もらえませんか|いただきたい|頂きたい|頂戴できますか|頂戴できれば|頂戴したい|いただけると|いただければ|いただけたら|頂けると|頂ければ)"),
            mustNameADocument: true, gates: [regex("を"), regex("いただ|頂|ください|下さい|もらえ")]),
        Construction(
            "X をお願いします, not a quote still to prepare",
            regex("(?<object>" + japaneseObject + "{1,30}?)(?<!見積もり)(?<!見積り)(?<!見積)を(?<verb>お願いします|お願いいたします|お願い致します|お願いできますでしょうか|お願いできますか|お願いできれば|お願いしたく|お願いしたいです|お願い申し上げます)"),
            mustNameADocument: true, gates: [regex("を"), regex("お願い")]),
        Construction(
            "X が必要です, X が見当たりません",
            regex("(?<object>" + japaneseObject + "{1,30}?)が(?<verb>必要です|必要になります|必要となります|必要でして|必要でございます|必要なのですが|必要なので|ほしいです|欲しいです|足りません|見当たりません|見当たらない)"),
            mustNameADocument: true, gates: [regex("が")]),
        Construction(
            "X を拝見できれば, X を見せていただけますか, X が見たいです",
            regex("(?<object>" + japaneseObject + "{1,30}?)(?:を|が)(?<gap>" + japaneseQuantity + ")(?<verb>(?:拝見|拝読)(?:でき(?:れば|ますか|ますでしょうか|ると|たら)|したい|したく|させて(?:いただけ|頂け|いただきたい|頂きたい|ください|下さい|もらえ))|(?:見せて|お見せ)(?:して)?(?:" + japanesePolite + ")|見たい|目を通したい)"),
            mustNameADocument: true, gates: [regex("を|が"), regex("拝見|拝読|見せ|見たい|目を通")]),
        Construction(
            "ぜひ拝見したいです with nothing named before it in its clause, after a phrase that names X before the comma",
            regex("(?:^|(?<=[、。,，！!？?]))\\s*(?<gap>(?:ぜひ|是非|一度|早めに|先に|事前に|改めて|また|もう一度)?)(?<verb>(?:拝見|拝読)(?:でき(?:れば|ますか|ますでしょうか|ると|たら)|したい|したく|させて(?:いただけ|頂け|いただきたい|頂きたい|ください|下さい|もらえ))|(?:見せて|お見せ)(?:して)?(?:" + japanesePolite + "))"),
            mustNameADocument: true, gates: [regex("拝見|拝読|見せ")]),
        Construction(
            "X を送るのを忘れないでください",
            regex("(?<object>" + japaneseObject + "{1,30}?)を(?<verb>送る|送付する|共有する|添付する|お送りする|転送する)の(?:を)?忘れないで(?:ください|下さい|くださいね|ね)?"),
            gates: [regex("を"), regex("忘れないで")]),
    ]

    private static let japaneseLead = regex(#"^(?:また|あと|それと|それから|さらに|念のため|ついでに|恐れ入りますが|お手数ですが|お手数をおかけしますが|すみませんが|申し訳ありませんが|申し訳ございませんが|至急|もし|もしも|できれば|可能であれば|よろしければ)+"#)
    /// Where what is asked for starts after a clause or a particle before it, as in
    /// 昨日話した図面 or お持ちでしたらそれ: after たら, ので, が, は, に, で, て or た before a
    /// character of a noun.
    private static let japaneseClauseBefore = regex(#"^.*(?:たら|れば|ので|のに|けど|けれど|から|まで|ため|には|では|とは|が|は|に|で|て|へ|た)(?=[\p{Han}\p{Katakana}A-Za-z0-9ー])"#)
    /// What asks for the document named before it.
    private static let japanesePointer = regex(#"^(?:それ|それら|そちら|これ|これら|こちら|あれ|あちら|その件|例の件|例のもの|同じもの|もの)$"#)

    private static func japanese(_ sentence: String) -> [Asked] {
        // Every pattern needs kana, which Chinese has none of.
        guard sentence.contains(where: \.isKana) else { return [] }
        var asked: [Asked] = []
        for construction in japaneseConstructions where construction.mayMatch(sentence) {
            for match in frames(construction.pattern, sentence) {
                guard let whole = Range(match.range, in: sentence), let verb = construction.range("verb", in: match, of: sentence),
                      !ContentChecks.matches([portal], clause(of: whole, verb: verb, in: sentence)) else { continue }
                let objectRange = construction.range("object", in: match, of: sentence)
                let text = objectRange.map { japaneseHead(String(sentence[$0])) } ?? ""
                let object = hanObject(text)
                let pointsBack = object.isEmpty || ContentChecks.matches([japanesePointer], object)
                // A construction that must name a document and reads what is asked for before
                // its verb takes no pronoun, as in それが必要です. One that reads nothing there, as
                // ぜひ拝見したいです, takes the document named before it by a kind or a file name.
                if pointsBack, construction.mustNameADocument, construction.hasObject { continue }
                asked.append(Asked(
                    position: match.range.location, object: object, phrase: hanCleaned(text), before: String(sentence[..<(objectRange?.lowerBound ?? verb.lowerBound)]),
                    language: .japanese, mustNameADocument: construction.mustNameADocument, pointsBack: pointsBack))
            }
        }
        return asked
    }

    /// What a Japanese construction asks for without the words before it: a lead such as
    /// また or お手数ですが, and a clause or a particle before the noun.
    private static func japaneseHead(_ text: String) -> String {
        var text = trimmed(text)
        if let lead = japaneseLead.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(lead.range, in: text) {
            text = String(text[range.upperBound...])
        }
        if let clause = japaneseClauseBefore.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(clause.range, in: text) {
            text = String(text[range.upperBound...])
        }
        return trimmed(text)
    }

    // MARK: What is no file

    /// Whether what is asked for is no file: comments and feedback, availability, an address
    /// or a phone number, bank, tax or identity details, information and answers, money and
    /// goods, a link or a password, the email itself, greetings, or a person. In English the
    /// last word before "of" decides, in Spanish the first word after an article, and in
    /// Chinese and Japanese the end of the head, as 发票信息 is information and 意见书 a file.
    private static func isNoFile(_ object: String, _ language: Language) -> Bool {
        let folded = matchingText(object)
        guard !folded.isEmpty else { return false }
        if folded.contains(where: { $0.isHan || $0.isKana }) {
            let head = trimmed(folded)
            return hanNoFile.contains(where: { head.hasSuffix($0) }) || hanNoFileWhole.contains(head)
                || ContentChecks.matches([hanQuestion], head)
        }
        // A question as what is asked for, as "how the client reacted", "whether the venue has
        // parking" or "cómo quieres seguir", asks for an answer.
        if ContentChecks.matches([latinQuestion], trimmed(object)) {
            return true
        }
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return false }
        let joined = " " + words.joined(separator: " ") + " "
        if latinNoFilePhrases.contains(where: { joined.contains(" \($0) ") }) {
            return true
        }
        switch language {
        case .spanish:
            guard let head = words.first(where: { !spanishDeterminers.contains($0) }) else { return false }
            return spanishNoFile.contains(head)
        default:
            // The word before "of" heads the phrase, as in "a copy of the contract", unless it
            // counts what follows, as in "a couple of times".
            var head = words[words.count - 1]
            if let of = words.firstIndex(of: "of"), of > 0, !englishCounts.contains(words[of - 1]) {
                head = words[of - 1]
            }
            return englishNoFile.contains(head)
        }
    }

    private static let englishNoFile: Set<String> = [
        "comment", "comments", "feedback", "thought", "thoughts", "opinion", "opinions", "views", "input", "suggestion", "suggestions",
        "idea", "ideas", "remark", "remarks", "reaction", "reactions", "impressions",
        "availability", "time", "times", "date", "dates", "slot", "slots",
        "address", "addresses", "phone", "mobile", "number", "numbers", "contact", "contacts", "wechat", "whatsapp", "name", "names",
        "birthday",
        "iban", "swift", "details", "detail", "information", "info", "update", "updates", "news", "status", "answer", "answers",
        "reply", "replies", "response", "responses", "confirmation", "approval", "decision", "rsvp", "question", "questions",
        "payment", "payments", "money", "deposit", "funds", "transfer", "balance", "sample", "samples", "package", "packages",
        "parcel", "parcels", "goods", "product", "products", "order", "orders", "shipment", "gift", "gifts",
        "link", "links", "url", "invite", "invites", "invitation", "password", "passwords", "code", "login", "credentials", "access",
        "email", "emails", "mail", "message", "messages", "thread", "line", "lines", "words", "sentence", "sentences", "paragraph",
        "newsletter", "newsletters", "post", "posts", "blog",
        "regards", "greetings", "wishes", "love", "best",
        "someone", "somebody", "anyone", "anybody", "people", "person", "technician", "driver", "courier", "screen", "location",
        "help", "support", "assistance", "what", "whatever", "anything", "something", "everything", "nothing",
        "price", "prices", "pricing", "rate", "rates", "cost", "costs", "fee", "fees", "amount", "amounts", "total", "totals",
        "quantity", "quantities", "size", "sizes", "measurement", "measurements", "dimensions",
        "username", "handle", "venmo", "paypal", "zelle", "linkedin", "instagram", "twitter", "facebook",
        "preference", "preferences", "restrictions", "allergies",
    ]
    /// Words that count what follows them, as couple in "a couple of times".
    private static let englishCounts: Set<String> = ["couple", "few", "number", "lot", "lots", "bunch", "handful", "pair", "series", "range", "selection", "some", "any", "all", "both", "each", "one", "two", "three"]
    private static let spanishNoFile: Set<String> = [
        "comentario", "comentarios", "opinion", "opiniones", "observacion", "observaciones", "sugerencia", "sugerencias",
        "retroalimentacion", "feedback", "impresiones", "idea", "ideas", "aportes",
        "disponibilidad", "fecha", "fechas", "hora", "horas",
        "direccion", "domicilio", "telefono", "numero", "numeros", "celular", "contacto", "whatsapp", "wechat", "nombre", "nombres",
        "informacion", "info", "detalles", "novedades", "actualizacion", "actualizaciones", "respuesta", "respuestas", "confirmacion",
        "aprobacion", "decision", "noticias", "estatus", "pregunta", "preguntas", "dudas",
        "pago", "pagos", "dinero", "deposito", "anticipo", "transferencia", "saldo", "muestra", "muestras", "paquete", "paquetes",
        "pedido", "pedidos", "regalo", "mercancia",
        "enlace", "enlaces", "link", "liga", "invitacion", "contrasena", "codigo", "acceso",
        "correo", "correos", "mensaje", "mensajes", "hilo", "lineas", "palabras", "parrafo", "boletin", "boletines", "publicacion",
        "saludos", "saludo", "abrazo",
        "alguien", "persona", "personas", "tecnico", "ubicacion", "pantalla", "ayuda", "apoyo", "algo", "todo", "nada",
        "precio", "precios", "tarifa", "tarifas", "costo", "costos", "coste", "costes", "monto", "importe", "total", "cantidad",
        "talla", "tallas", "tamano", "medida", "medidas", "dimensiones",
        "usuario", "venmo", "paypal", "linkedin", "instagram", "preferencias", "restricciones", "alergias",
    ]
    private static let spanishDeterminers: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "tu", "tus", "su", "sus", "mi", "mis", "nuestro", "nuestra", "nuestros",
        "nuestras", "este", "esta", "estos", "estas", "ese", "esa", "esos", "esas", "aquel", "aquella", "todo", "toda", "todos",
        "todas", "algun", "alguna", "algunos", "algunas", "otro", "otra", "mas", "nuevo", "nueva", "ultimo", "ultima", "cualquier", "lo",
    ]
    private static let latinNoFilePhrases = [
        "bank details", "bank account", "account details", "account number", "routing number", "tax id", "tax number", "vat number",
        "passport number", "id number", "phone number", "email address", "e mail address", "mailing address", "shipping address",
        "billing details", "payment details", "contact details", "contact information", "contact info",
        "datos bancarios", "datos fiscales", "datos de contacto", "datos de facturacion", "cuenta bancaria", "numero de cuenta",
        "informacion bancaria", "datos de la cuenta",
    ]
    /// Ends of a Chinese or Japanese head that name no file.
    private static let hanNoFile = [
        "意见", "反馈", "建议", "想法", "看法", "评论", "点评", "感想", "时间", "档期", "日期", "地址", "电话", "手机号", "手机", "号码",
        "联系方式", "微信", "账户", "账号", "帐户", "帐号", "开户行", "户名", "税号", "识别号", "信息", "详情", "情况", "进展", "进度",
        "消息", "回复", "答复", "确认", "结果", "决定", "定金", "订金", "尾款", "付款", "货款", "转账", "样品", "快递", "包裹", "礼物",
        "链接", "网址", "邀请", "密码", "验证码", "权限", "邮件", "问候", "师傅", "位置", "定位", "屏幕", "问题", "句话", "段话",
        "意見", "感想", "フィードバック", "コメント", "指摘", "都合", "空き状況", "候補日", "日時", "住所", "送付先", "連絡先",
        "電話番号", "メールアドレス", "アドレス", "口座情報", "振込先", "口座", "口座番号", "登録番号", "法人番号", "マイナンバー", "情報",
        "詳細", "状況", "進捗", "近況", "返信", "返事", "回答", "確認", "結果", "連絡", "支払い", "代金", "入金", "振込", "振り込み",
        "サンプル", "荷物", "商品", "リンク", "url", "パスワード", "コード", "招待", "担当者", "画面", "質問", "メール", "メッセージ", "一言", "数行",
        "メルマガ", "ニュースレター", "公众号", "推文",
        // Numbers and values: an account, a card or an ID number, a price, a size or a count,
        // and a name, as on a form.
        "号", "价格", "价钱", "单价", "费用", "金额", "尺码", "尺寸", "数量", "人数", "姓名", "名字", "城市",
        "番号", "価格", "料金", "金額", "費用", "サイズ", "寸法", "名前", "氏名", "所属", "アカウント",
    ]
    /// Chinese words that name no file only on their own: money, goods, a person.
    private static let hanNoFileWhole: Set<String> = ["款", "钱", "货", "人"]
    /// A question as what is asked for, as in 怎么去会场, 是否需要停车 or 参加できるかどうか.
    private static let hanQuestion = regex(#"怎么|怎样|如何|为什么|为何|是否|是不是|多少|哪里|哪儿|哪些|哪天|什么时候|何时|几点|几号|かどうか|どのよう|どうやって|いくら|なぜ|何時|何名|何人"#)
    /// A question as what is asked for in English or Spanish, by its first word.
    private static let latinQuestion = latin(#"^(?:how|why|whether|what|when|where|who|whom|whose|which|if|cómo|por qué|qué|cuándo|dónde|quién|quiénes|cuánto|cuánta|cuántos|cuántas|cuál|cuáles)(?![\p{L}\p{N}])"#)

    /// A quote, an estimate, a proposal or an invoice asked for with a or una, which is one
    /// still to prepare, not a file to send, as in "send us a quote for 500 units".
    private static let toPrepare = latin(#"^(?:a|an|un|una)\s+(?:(?:new|nueva|nuevo|quick|rough|formal|detailed|firm)\s+)?(?:quote|quotation|estimate|proposal|invoice|offer|bid|cotizaci[oó]n|presupuesto|propuesta|factura|oferta)\b"#)

    /// Whether what is asked for is a document still to prepare, or one to upload to a portal
    /// or to fill in online.
    private static func isToPrepare(_ object: String) -> Bool {
        ContentChecks.matches([toPrepare], object) || ContentChecks.matches([onlineForm], object)
    }

    /// The clause of a construction, from the start of the clause it starts in to the end
    /// of the clause of its verb, where a portal it asks to upload to would stand.
    private static func clause(of whole: Range<String.Index>, verb: Range<String.Index>, in sentence: String) -> String {
        let boundaries = ",;:，；：。!?！？"
        let start = sentence[..<whole.lowerBound].lastIndex(where: { boundaries.contains($0) }).map { sentence.index(after: $0) } ?? sentence.startIndex
        let end = sentence[verb.upperBound...].firstIndex(where: { boundaries.contains($0) }) ?? sentence.endIndex
        return String(sentence[start..<max(start, end)])
    }

    /// A form online, which the reader fills in and does not send.
    private static let onlineForm = latin(#"\b(?:online|web) form\b|formulario en l[ií]nea|在线表单|网上表格|线上表单|オンラインフォーム|ウェブフォーム"#)
    /// A portal, a platform or a system to upload to or to fill in, which asks for no file to
    /// send: "upload them to the portal", 上传到系统, ポータルにアップロード, súbelos a la plataforma.
    private static let portal = latin(#"\b(?:to|on|onto|via|through|in|into|using)\s+(?:the |our |your |their |this |that )?(?:[\w-]+\s+){0,2}(?:portal|platform)\b|\b(?:upload\w*|submit\w*)\b[^.!?;]{0,60}?(?:\b(?:website|system|app|online|form)\b|\b(?:at|on|via|through)\s+(?:https?://|www\.|[\w-]+\.[a-z]{2,}/))|\b(?:a|al|en|por|mediante|desde|a trav[eé]s de(?:l)?)\s+(?:la |el |nuestra |nuestro |su |tu )?(?:[\w-]+\s+){0,2}(?:portal|plataforma)\b|(?:上传|提交|填写|录入|登记)(?:到|至|进|在)?[^，。！？；]{0,12}?(?:系统|平台|网站|后台|门户|网页|小程序|表单|链接)|在[^，。！？；]{0,10}?(?:系统|平台|网站|后台|门户|网页|小程序|线上|网上)(?:上|里|中)?(?:上传|提交|填写|登记)|(?:在线|线上|网上)(?:提交|填写|上传|登记)|(?:ポータル|システム|サイト|フォーム|ウェブ|専用ページ|マイページ)(?:に|へ|から|で|上で|上に)[^、。！？]{0,10}?(?:アップロード|アップ|登録|入力|提出|送信)|オンラインで(?:ご)?(?:提出|入力|登録)"#)

    // MARK: What a pointer points to

    /// The words that point back, in four languages, which make a sentence look one further
    /// back for what they mean.
    private static let pointerWords: [NSRegularExpression] = [
        latin(#"\b(?:it|them|that|those|one|lo|la|los|las|eso|esto)\b"#),
        regex(#"它|这个|那个|这份|那份|一份|それ|そちら|これ|こちら"#),
    ]

    /// The document a pronoun, a plain file or a verb without an object points to.
    private struct Antecedent {
        var object: String
        var phrase: String
        var language: Language
    }

    /// The document named last before a pointer: in the same sentence before its
    /// construction, or else in the sentence before. A clause names a document by a word for
    /// a kind or a file name, and so do "if you have", "do you have", "we are missing", "you
    /// sent", 如果有, 有没有, 我们还缺, 你之前发过, があれば, が見当たりません, si tienes and nos
    /// falta with what follows or precedes them. A clause where the sender attaches, sends or
    /// promises names none, and neither does a phrase that is no file.
    private static func antecedent(before: String, namedBefore: () -> Antecedent?, ownCounts: Bool) -> Antecedent? {
        let near = String(before.suffix(antecedentReach))
        return lastDocument(in: near, ownCounts: ownCounts) ?? topic(near) ?? namedBefore()
    }

    /// Signing, stamping or filling in before sending back, as in "sign it and send it back",
    /// 盖章后发回, ご署名のうえご返送, fírmalo y envíamelo, which asks for the signed copy of a
    /// paper the sender attached.
    private static let signedAndSentBack = latin(#"\b(?:sign|signed|countersign|stamp|initial|fill (?:in|out)|complete)\b|\bf[ií]rm\w*|\bllen\w*|\bcomplet\w*|\bsell\w*|签字|签名|签章|盖章|签署|签好|盖好|填好|填写|署名|押印|捺印|記入"#)

    /// The clause right before a pointer when it is only a noun phrase, which names what the
    /// pointer means, as in 上次的会议安排，麻烦发我一下, 先日の打ち合わせのまとめ、共有して
    /// いただけますか or "The seating chart from Friday, could you send it?". A clause with
    /// a verb or a person in it is none.
    private static func topic(_ before: String) -> Antecedent? {
        // The clause before the last comma, with no more than a few words that ask between
        // that comma and the verb, as 麻烦, お手数ですが or "could you".
        guard let comma = before.lastIndex(where: { ",;:，；：、".contains($0) }) else { return nil }
        let between = trimmed(String(before[before.index(after: comma)...]))
        let latinGap = !between.contains(where: { $0.isHan || $0.isKana })
        guard between.count <= (latinGap ? 40 : 12) else { return nil }
        let text = trimmed(String(before[..<comma]))
        guard let range = clauseRanges(of: text).last else { return nil }
        let clause = trimmed(String(text[range]))
        guard !clause.isEmpty, clause.count <= 30 else { return nil }
        let found: Antecedent
        if clause.contains(where: \.isKana) {
            guard !ContentChecks.matches([japaneseNotATopic], clause) else { return nil }
            let head = japaneseHead(removing(japaneseTopicMark, from: clause))
            found = Antecedent(object: hanObject(head), phrase: hanCleaned(head), language: .japanese)
        } else if clause.contains(where: \.isHan) {
            guard ContentChecks.matches([chineseTopicMark], clause), !ContentChecks.matches([chineseNotATopic], clause) else { return nil }
            found = Antecedent(object: hanObject(clause), phrase: hanCleaned(clause), language: .chinese)
        } else {
            guard ContentChecks.matches([latinTopic], clause), !ContentChecks.matches([latinNotATopic], clause) else { return nil }
            let language = latinLanguage(clause)
            let (object, phrase) = language == .spanish
                ? spanishObject(after: clause.startIndex, in: clause)
                : (latinObject(after: clause.startIndex, in: clause, lead: englishLead, cut: englishCut, keepGoing: englishKeepGoing), "")
            found = Antecedent(object: object, phrase: phrase.isEmpty ? object : phrase, language: language)
        }
        guard !found.object.isEmpty, !isNoFile(found.object, found.language), !isToPrepare(found.object),
              !kinds(in: found.object).isEmpty || !fileNames(in: found.object).isEmpty || !ownWords(found.phrase).isEmpty
        else { return nil }
        return found
    }

    /// What a clause that is only a noun phrase holds none of: a verb, a person, a word that
    /// asks or a question.
    private static let chineseNotATopic = regex(#"是|有|要|能|了|过|着|吗|呢|吧|我|你|您|他|她|请|麻烦|想|说|问|做|觉得|已|没|不|后$|时$|时候|以后|之后|之前|以前|收到|看到|拿到"#)
    /// What marks a Chinese noun phrase that names a thing: 的 or a demonstrative.
    private static let chineseTopicMark = regex(#"的|那份|这份|那个|这个|那张|这张|那些|这些|上次|上周|之前的|昨天"#)
    private static let japaneseNotATopic = regex(#"です|ます|ました|ません|でした|だった|ください|下さい|ので|けど|から|たら|れば|ない|たい|私|僕|弊社"#)
    private static let japaneseTopicMark = regex(#"(?:については|につきましては|は|も|を|が)$"#)
    private static let latinTopic = latin(#"^(?:the|that|this|these|those|your|our|el|la|los|las|ese|esa|esos|esas|este|esta|tu|tus|su|sus)\b"#)
    private static let latinNotATopic = latin(#"\b(?:is|are|was|were|has|have|had|will|would|can|could|should|do|does|did|i|we|you|es|est[aá]n?|son|fue|tiene|tienen|hay|ser[aá])\b"#)

    private static func lastDocument(in text: String, ownCounts: Bool = false) -> Antecedent? {
        let text = trimmed(text)
        guard !text.isEmpty else { return nil }
        var best: (end: String.Index, found: Antecedent)?
        func consider(_ found: Antecedent, end: String.Index) {
            let object = trimmed(found.object)
            guard !object.isEmpty, !isNoFile(object, found.language), !isToPrepare(object),
                  !kinds(in: object).isEmpty || !fileNames(in: object).isEmpty || !ownWords(found.phrase).isEmpty,
                  best.map({ end >= $0.end }) ?? true
            else { return }
            best = (end, Antecedent(object: object, phrase: trimmed(found.phrase), language: found.language))
        }
        let clauses = clauseRanges(of: text)
        // A clause where the sender attaches, sends or promises a file, or one about a portal
        // or a form online, names nothing a pointer may mean.
        func namesNothing(_ clause: String) -> Bool {
            (!ownCounts && ContentChecks.matches(ownClause, clause)) || ContentChecks.matches([portal, onlineForm], clause)
        }
        func isOwnClause(_ position: String.Index) -> Bool {
            guard let clause = clauses.first(where: { $0.contains(position) || $0.upperBound == position }) else { return false }
            return namesNothing(String(text[clause]))
        }
        for clause in clauses where !namesNothing(String(text[clause])) {
            if let found = documentPhrase(in: String(text[clause])) {
                consider(found, end: clause.upperBound)
            }
        }
        for (gate, pattern, language) in antecedentPatterns where ContentChecks.matches([gate], text) {
            for match in frames(pattern, text) {
                guard let whole = Range(match.range, in: text), !isOwnClause(whole.lowerBound) else { continue }
                switch language {
                case .english, .spanish:
                    // What stands before the verb, as "the file" in "the file you sent".
                    if pattern.pattern.contains("(?<object>") {
                        let objectFound = match.range(withName: "object")
                        guard objectFound.location != NSNotFound, let range = Range(objectFound, in: text) else { continue }
                        let object = trimmed(String(text[range]))
                        consider(Antecedent(object: object, phrase: object, language: language), end: range.upperBound)
                        continue
                    }
                    let (object, phrase) = language == .spanish
                        ? spanishObject(after: whole.upperBound, in: text)
                        : (latinObject(after: whole.upperBound, in: text, lead: englishLead, cut: englishCut, keepGoing: englishKeepGoing), "")
                    let end = text.range(of: object, range: whole.upperBound..<text.endIndex)?.upperBound ?? whole.upperBound
                    consider(Antecedent(object: object, phrase: phrase.isEmpty ? object : phrase, language: language), end: end)
                case .chinese, .japanese:
                    let objectFound = match.range(withName: "object")
                    guard objectFound.location != NSNotFound, let range = Range(objectFound, in: text) else { continue }
                    var object = String(text[range])
                    if language == .japanese {
                        object = japaneseHead(object)
                    }
                    consider(Antecedent(object: hanObject(object), phrase: hanCleaned(object), language: language), end: range.upperBound)
                }
            }
        }
        return best?.found
    }

    /// Where the clauses of a text stand, between its commas and stops.
    private static func clauseRanges(of text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if ",;:，；：、。!?！？".contains(text[index]) {
                if start < index {
                    ranges.append(start..<index)
                }
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        if start < text.endIndex {
            ranges.append(start..<text.endIndex)
        }
        return ranges
    }

    /// The phrase of a clause that names a document by a word for a kind or a file name, read
    /// from the last such word: in Chinese and Japanese the clause up to that word, from its
    /// last particle, and in English and Spanish the phrase from the article before it.
    private static func documentPhrase(in clause: String) -> Antecedent? {
        let names = fileNames(in: clause)
        if clause.contains(where: { $0.isHan || $0.isKana }) {
            // Only the words whose first character the clause holds are looked for, each in
            // one NSString of the clause.
            let searched = clause as NSString
            let characters = Set(clause)
            var end: Int?
            for term in characters.flatMap({ hanKindTermsByFirst[$0] ?? [] }) + names {
                let found = searched.range(of: term, options: [.caseInsensitive, .backwards])
                if found.location != NSNotFound, end.map({ found.location + found.length > $0 }) ?? true {
                    end = found.location + found.length
                }
            }
            guard let end, let range = Range(NSRange(location: 0, length: end), in: clause) else { return nil }
            let endIndex = range.upperBound
            let japanese = clause.contains(where: \.isKana)
            var text = String(clause[..<endIndex])
            text = japanese ? japaneseHead(text) : text
            return Antecedent(object: hanObject(text), phrase: hanCleaned(text), language: japanese ? .japanese : .chinese)
        }
        let searched = clause as NSString
        var term: Range<String.Index>?
        for word in latinKindTerms + names {
            for found in ranges(of: word, in: clause, searched) where term.map({ found.lowerBound > $0.lowerBound }) ?? true {
                term = found
            }
        }
        guard let term else { return nil }
        let language = latinLanguage(clause)
        var start = term.lowerBound
        let before = String(clause[..<term.lowerBound].suffix(40))
        if let article = latinArticle.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)), let range = Range(article.range, in: before) {
            start = clause.index(term.lowerBound, offsetBy: -before.distance(from: range.lowerBound, to: before.endIndex))
        }
        let (object, phrase) = language == .spanish
            ? spanishObject(after: start, in: clause)
            : (latinObject(after: start, in: clause, lead: englishLead, cut: englishCut, keepGoing: englishKeepGoing), "")
        return Antecedent(object: object, phrase: phrase.isEmpty ? object : phrase, language: language)
    }

    /// An article or a possessive up to three words before a word for a kind.
    private static let latinArticle = latin(#"\b(?:the|a|an|your|our|my|his|her|their|this|that|these|those|el|la|los|las|un|una|unos|unas|tu|tus|su|sus|mi|mis|nuestro|nuestra|nuestros|nuestras|este|esta|estos|estas|ese|esa|esos|esas)\s+(?:[\p{L}\p{N}'’-]+\s+){0,3}$"#)
    /// The words of the glossary for a kind other than a plain file, in Chinese and Japanese
    /// script, and in Latin letters.
    private static let hanKindTermsByFirst: [Character: [String]] = {
        var seen: Set<String> = []
        let terms = DocumentKind.allCases.filter { !$0.isGeneric }.flatMap { $0.terms.chinese + $0.terms.japanese }
            .filter { $0.contains(where: { $0.isHan || $0.isKana }) && seen.insert($0).inserted }
        return Dictionary(grouping: terms, by: { $0.first! })
    }()
    private static let latinKindTerms: [String] = {
        var seen: Set<String> = []
        return DocumentKind.allCases.filter { !$0.isGeneric }.flatMap(\.terms.all)
            .filter { !$0.contains(where: { $0.isHan || $0.isKana }) && seen.insert($0).inserted }
    }()

    /// Words that only Spanish of the two Latin languages uses, which tell its phrases apart.
    private static let spanishMarkers = latin(#"\b(?:el|la|los|las|del|una|unos|unas|que|por|para|con|nos|tienes|tiene|hay|falta|faltan|necesito|necesitamos|podr[ií]as|puedes|ya|muy|pero|est[aá])\b"#)

    private static func latinLanguage(_ text: String) -> Language {
        ContentChecks.matches([spanishMarkers], text) ? .spanish : .english
    }

    /// The clauses where the sender attaches, sends or promises a file, in four languages, in
    /// Spanish to tú, usted or ustedes alike, as in te mando, le comparto or aquí tiene.
    private static let ownClause: [NSRegularExpression] = [
        latin(#"\b(?:(?:attached|enclosed) (?:is|are|please find|you will find|you'll find)|(?:please )?find (?:attached|enclosed)|here (?:is|are)|here['’]s|(?:i|we)(?:['’]ve| have)? (?:just |already )?(?:sent|attached|shared|forwarded|uploaded|included)|(?:i|we)(?:['’]ll| will| shall) (?:send|forward|share|attach))\b"#),
        latin(#"\b(?:adjunto|adjunta|adjuntos|adjuntas|(?:te|le|les) (?:env[ií]o|mando|paso|comparto|reenv[ií]o)|aqu[ií] (?:tienes?|tienen|est[aá]n?|va|van))\b"#),
        chineseOwn,
        regex(#"(?:我|我们)(?:已|已经|刚|刚刚|会|稍后|明天|马上)?(?:发|传|寄|转发|附上)(?:给)?(?:你|您)"#),
        regex(#"添付(?:いた)?します|添付しました|添付いたしました|お送りします|お送りいたします|お送りしました|送付いたします|送付します|送付しました|送ります|送りました|共有します|共有しました|添付の"#),
    ]

    /// The constructions that name a document a pronoun may point to: what the reader has or
    /// sent, and what the writer needs or misses, with what follows them in English, Spanish
    /// and Chinese and what precedes them in Japanese, and in English and Japanese a file named
    /// before what the reader did to it or what went wrong with it, as in "the file you sent"
    /// or 添付ファイルが開けませんでした.
    private static let antecedentPatterns: [(gate: NSRegularExpression, pattern: NSRegularExpression, language: Language)] = [
        (latin(#"\b(?:sent|shared|mentioned|showed|prepared|drafted|updated|revised|made|wrote|drew|attached|forwarded|uploaded|gave)\b"#), latin(#"(?<object>\b(?:the|that|this|those|these|your)\s+(?:(?!\b(?:is|are|was|were|has|have|had|will)\b)[^,.;:!?]){1,40}?)\s+(?:(?:that|which)\s+)?(?:you|u)\s+(?:just\s+|already\s+|kindly\s+)?(?:sent|shared|mentioned|showed|prepared|drafted|updated|revised|made|wrote|drew|attached|forwarded|uploaded|gave)\b"#), .english),
        (regex(#"開け|開か|開き|見られ|見れ|表示され|破損|壊れ|届い|届き"#), regex("(?<object>" + japaneseObject + "{1,30}?)(?:が|は|も)(?:まだ|うまく|正しく|なぜか)?(?:開けません|開けない|開けず|開きません|開かない|開かず|見られません|見られない|見れません|見れない|表示されません|表示されない|破損して|壊れて|届いていません|届いていない|届きません|届かない)"), .japanese),
        (latin(#"\b(?:have|has|had|keep|kept|got|find|mentioned|showed|sent|shared|prepared|drafted|updated|revised|made|wrote|drew|missing|lacking|lack|need|needed|lost|misplaced|there|received|asked|asks|requested|requests)\b"#), latin(#"\b(?:if (?:you|u) (?:still |also |happen to |by any chance |already )?(?:have|has|kept|keep|got|find|can find|could find)|do (?:you|u)(?: still| also| happen to| by any chance){0,2} have|(?:you|u) (?:still |also |just )?(?:have|had|kept|mentioned|showed|sent|shared|prepared|drafted|updated|revised|made|wrote|drew)|(?:i|we)(?:['’]re|['’]m| are| am)?(?: still| also)? (?:missing|lacking|lack|need|needed|lost|misplaced)|(?:i|we) (?:can['’]t|cannot|couldn['’]t) find|(?:i|we) (?:still |also )?(?:don['’]t|do not|didn['’]t|did not) have|(?:i|we) (?:still |also )?(?:haven['’]t|have not) (?:got|received)|(?:asked|asks|requested|requests) for|(?:is|are) there(?: still)?)\b"#), .english),
        (latin(#"\b(?:tien\w*|tendr\w*|conserv\w*|guard\w*|cuent\w*|encuentr\w*|falt\w*|necesit\w*|perd\w*|mencion\w*|mostr\w*|envi\w*|mand\w*|compart\w*|prepar\w*|hici\w*|actualiz\w*)"#), latin(#"\b(?:si (?:todav[ií]a |a[uú]n |ya )?(?:tienes|tiene|tienen|conservas|conserva|guardas|guarda|cuentas con|cuenta con|encuentras|encuentra)|(?:tienes|tiene|tienen|tendr[aá]s|tendr[ií]as|cuentas con|cuenta con)|(?:me|nos) (?:falta|faltan|hace falta|hacen falta)|necesito|necesitamos|perd[ií]|perdimos|no encuentro|no encontramos|(?:me |nos )?(?:mencionaste|mostraste|enviaste|mandaste|compartiste|preparaste|hiciste|actualizaste))\b"#), .spanish),
        (regex(#"有|缺|少|差|需要|找不到|丢|给过|发过|提过|提到|说过|做过|准备过|做好|改好|画过|写过"#), regex("(?:(?:如果|要是|若|假如|如)(?:你|您)?们?(?:那边|这边|手上|手里|手边|还|也|已经)*有|有没有|(?:你|您)们?(?:那边|这边|之前|上次|还|也|已经)*(?:有|给过|发过|提过|提到过|提到|说过|说的|讲的|做过|准备过|做好了|改好了|画过|写过)|(?:我们|我)(?:这边|还|也|现在|目前)*(?:缺少|缺|少了|还差|需要|找不到|丢了|弄丢了))(?<object>" + chineseClause + "{1,30})"), .chinese),
        (regex(#"あれば|ありましたら|ございましたら|お持ち|お手元|ありますか|ございますか|必要|足りません|見当たりません|なくして|紛失"#), regex("(?<object>" + japaneseObject + "{1,30}?)(?:が|を|は)?(?:あれば|ありましたら|ございましたら|お持ちでしたら|お持ちであれば|お持ちなら|お手元にあれば|お手元にございましたら|ありますか|ございますか|お持ちですか|必要です|必要になります|足りません|見当たりません|なくして|紛失)"), .japanese),
    ]

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
        // A space before what is left, so a word that ends the object right after the lead
        // ends it there, as "by" in "could you send by Friday".
        rest = " " + rest
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
            // "That" at the start points, as in "that permit", and ends nothing.
            if before == nil, word == "that" {
                continue
            }
            end = range.lowerBound
            break
        }
        // A conjunction the text ends with joins nothing more, as "and" in "sign the form and".
        return removing(trailingConjunction, from: unquoted(String(rest[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: ".!?¿¡"))))
    }

    private static let trailingConjunction = latin(#"\s+(?:and|or|y|o|e|&)$"#)

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

    /// What a Chinese or Japanese request asks for without the words around it that are
    /// none of it, such as 一下, 给我 or 吧.
    private static func hanCleaned(_ text: String) -> String {
        var object = unquoted(text)
        for _ in 0..<3 {
            let stripped = removing(hanTrail, from: removing(hanLead, from: object))
            if stripped == object { break }
            object = trimmed(stripped)
        }
        return object
    }

    /// What a Chinese or Japanese request asks for: the text after the last 的 or の, which
    /// heads it, so 对平面图的意见 asks for comments and 最新的平面图 for the plan. When that
    /// head names only a plain file, as 平面图的电子版, or only a version or a format, as
    /// 平面图的最新版 or 平面図のPDF, the whole object counts. In a list of things, as in
    /// 合同和您的身份证照片, each keeps its own head when the head of the whole would leave a
    /// kind out.
    private static func hanObject(_ text: String) -> String {
        let object = hanCleaned(text)
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
        // データ after a kind is the file of that kind, as カタログのデータ is the catalog.
        let before = trimmed(String(object[..<last]))
        if head == "データ", kinds(in: before).contains(where: { !$0.isGeneric && $0 != .data }) {
            return hanHead(before)
        }
        let headKinds = kinds(in: head)
        let namesOnlyAFile = !headKinds.isEmpty && headKinds.allSatisfy(\.isGeneric)
        let namesOnlyAVersion = headKinds.isEmpty && ContentChecks.matches([hanVersion], head)
        return (namesOnlyAFile || namesOnlyAVersion) && kinds(in: object).contains(where: { !$0.isGeneric }) ? object : head
    }

    /// A version or a format of a file, without a kind of its own: 最新版, 修改稿, 定稿, PDF版,
    /// 最終版, データ and their like.
    private static let hanVersion = latin(#"^(?:(?:最新|最终|最終|最后|最後|新|旧|修改|修订|修正|改訂|更新|正式|完整|当前|現行|初|定|终|終|草|原)(?:版本|版|稿|バージョン)?|版本|バージョン|(?:pdf|cad|dwg|word|excel|jpe?g|png|tiff?|zip|ppt|pptx|xlsx?|docx?)(?:版|格式|形式|ファイル|档|文件)?)$"#)

    private static let hanLead = regex(#"^(?:一下|一份|一个|一张|一版|一稿|(?:几|两|三|若干|多)(?:张|份|个|些|页|套|版)|一些|个|(?:以下|下面|下列|如下|下記)(?:的|の)?(?:内容|事项|事項|几项|几点|项目|項目)?|上述的?|以上的?|下|给我们|给我|过来|我的邮箱|我邮箱|这个邮箱|邮箱|我们|我|你们的|您的|你的|贵司的|贵方的|另外|还有|对了|顺便|此外|然后|把|将|的)"#)
    private static let hanTrail = regex(#"(?:吧|吗|呢|啊|哦|哈|呗|一下|也|再|都|先|过来|给我们|给我|好吗|可以吗|谢谢|嗎|即可|就行|就好|就可以|(?:如果|要是)?有的话|的话|看看|参考)$"#)

    /// The kinds a text names, each once, in the order the text names them.
    static func kinds(in text: String) -> [DocumentKind] {
        let folded = matchingText(text)
        guard !folded.isEmpty else { return [] }
        let searched = folded as NSString
        // Only the words whose first character the text holds are looked for.
        let characters = Set(folded)
        var first: [DocumentKind: Int] = [:]
        for character in characters {
            for (term, kind) in matchingTermsByFirst[character] ?? [] {
                if let position = position(of: term, in: folded, searched), first[kind].map({ position < $0 }) ?? true {
                    first[kind] = position
                }
            }
        }
        return first.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key.order < $1.key.order }.map(\.key)
    }

    /// The words of every kind as the kinds are matched, by their first character.
    private static let matchingTermsByFirst: [Character: [(String, DocumentKind)]] = {
        var terms: [Character: [(String, DocumentKind)]] = [:]
        for kind in DocumentKind.allCases {
            for term in kind.terms.all.map(matchingText) where !term.isEmpty {
                terms[term.first!, default: []].append((term, kind))
            }
        }
        return terms
    }()

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
                    word = stop == "と"
                        ? particleRemoved(stop, from: word)
                        : word.replacingOccurrences(of: stop, with: " ")
                }
                // A single kana left over, as こ of この, is no word to search by.
                words += word.split(separator: " ").map(String.init).filter { !($0.count == 1 && $0.allSatisfy(\.isKana)) }
                continue
            }
            guard !stopWords.contains(word), !generic.contains(word) else { continue }
            words.append(word)
        }
        var seen: Set<String> = []
        return words.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: " ")
    }

    /// A word with the particle と taken out where it joins two words, as in 写真と見積書, and
    /// kept inside a word of hiragana, as in まとめ.
    private static func particleRemoved(_ particle: String, from word: String) -> String {
        let characters = Array(word)
        var result = ""
        for (index, character) in characters.enumerated() {
            let before = index > 0 ? characters[index - 1] : nil
            let after = index + 1 < characters.count ? characters[index + 1] : nil
            if String(character) == particle, !(before?.isHiragana ?? false) || !(after?.isHiragana ?? false) {
                result.append(" ")
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "your", "our", "my", "his", "her", "their", "its", "this", "that", "these", "those", "me", "us", "you",
        "it", "them", "latest", "last", "new", "newest", "updated", "final", "current", "recent", "most", "version", "versions",
        "of", "and", "or", "also", "please", "both", "all", "any", "some", "from", "for", "to", "in", "on", "at", "with", "by",
        "about", "attached", "enclosed", "signed", "back", "below", "above", "listed", "following", "mentioned", "one", "same",
        "el", "la", "los", "las", "un", "una", "unos", "unas", "del", "al", "de", "tu", "tus", "su", "sus", "mi", "mis",
        "nuestro", "nuestra", "nuestros", "nuestras", "este", "esta", "estos", "estas", "ese", "esa", "esos", "esas",
        "ultimo", "ultima", "nuevo", "nueva", "actualizado", "actualizada", "final", "y", "o", "tambien", "version",
        "para", "por", "con", "en", "a", "sobre", "siguiente", "siguientes", "abajo", "indicados", "listados", "lo", "eso", "esto",
    ]
    /// Words before a file name that are none of it, as in "the attached file report.pdf".
    private static let fileNameLead: Set<String> = ["attached", "enclosed", "file", "files", "document", "documents", "archivo", "documento", "adjunto"]
    private static let hanStopWords = ["一下", "一份", "一个", "那个", "这个", "那份", "这份", "最新版", "最新", "新版", "最终版", "你们", "您", "你", "贵司", "和", "与", "及", "的", "例の", "先日", "前回", "最新の", "と", "の", "それ", "これ", "そちら", "こちら", "它"]

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
    /// Hiragana alone.
    fileprivate var isHiragana: Bool {
        unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    /// Hiragana or katakana, the half width forms included.
    fileprivate var isKana: Bool {
        unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9F).contains($0.value) || $0.value == 0x30FC }
    }
}
