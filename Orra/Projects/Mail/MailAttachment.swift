import Foundation

/// An attachment of an email, with what Projects read of it. The maintainer asked on
/// 2026-10-20 for the text of attachments, in place of names and types only (decision 14
/// of the phase 1 plan).
///
/// - The bytes come from the MIME parts of the source the scan reads anyway, see
///   MIMEMessage. Nothing sends another Apple Event for them, and nothing reads
///   ~/Library/Mail. A part that holds nothing, as one Mail has not downloaded may, keeps
///   its name only and says so.
/// - PDF, docx, doc, rtf, odt, xlsx, pptx, md and txt go through FileTextExtractor, with
///   the limits and checks of the files in project folders: hidden text is dropped and
///   counted, nothing goes online, and no script or macro runs. csv and ics are plain text,
///   so they are read as txt. No text is recognized in an image or a scanned PDF.
///   A text file is read in the charset its part names. Every other type keeps its name,
///   type and size only.
/// - Reading waits while the user dictates, as the folder index does, since dictation
///   goes first.
/// - Caps: `maximumBytes` an attachment, `maximumTextBytes` of text from each,
///   `maximumRead` attachments an email and `maximumTime` for them all.
/// - The text is data from the sender, as the email's own text is. It is mail text for
///   Retention, and goes with the email's text.
nonisolated struct MailAttachment: Sendable, Equatable, Codable {
    /// Whether Projects read the attachment's text, or why not.
    nonisolated enum State: String, Sendable, Codable, CaseIterable {
        /// Its text was read.
        case read
        /// Mail has not downloaded it, so only its name is known.
        case notDownloaded
        /// Over `maximumBytes`.
        case tooLarge
        /// In an email too large for the scan to read, see MailScan.largestSource.
        case emailTooLarge
        /// A type Projects does not read, such as an image.
        case otherType
        /// Its content does not match its type, it is locked, or it took too long.
        case unreadable
        /// It holds no text, such as a scanned PDF. Its hidden text, if any, is counted.
        case noText
        /// Not read for another reason: the email had more than `maximumRead` such
        /// attachments or took longer than `maximumTime`.
        case notRead
        /// Saved by an Orra that read the names and types of attachments only.
        case savedEarlier
    }

    var name: String
    /// The MIME type in lowercase, such as application/pdf.
    var type: String
    /// Its size in bytes, nil when neither the part nor Mail gives it.
    var size: Int? = nil
    var state: State
    /// The runs of hidden text FileTextExtractor dropped from it, see FileTextResult.
    var hiddenRuns = 0
    /// Whether its text was cut at `maximumTextBytes`, or pages of a PDF were left out.
    var isCut = false
    /// The text read, nil unless `state` is `read`. It never goes into the JSON of an
    /// attachment, since MailStore keeps it apart for Retention.
    var text: String? = nil

    private enum CodingKeys: String, CodingKey {
        case name, type, size, state, hiddenRuns, isCut
    }

    init(name: String, type: String, size: Int? = nil, state: State, hiddenRuns: Int = 0, isCut: Bool = false, text: String? = nil) {
        self.name = name
        self.type = type
        self.size = size
        self.state = state
        self.hiddenRuns = hiddenRuns
        self.isCut = isCut
        self.text = text
    }

    /// An attachment an earlier Orra saved with its name and type only reads as
    /// `savedEarlier`, and a state a later Orra wrote as not read.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        state = container.contains(.state) ? (try? container.decode(State.self, forKey: .state)) ?? .notRead : .savedEarlier
        hiddenRuns = try container.decodeIfPresent(Int.self, forKey: .hiddenRuns) ?? 0
        isCut = try container.decodeIfPresent(Bool.self, forKey: .isCut) ?? false
    }

    // MARK: Reading

    /// The most bytes of one attachment that are read.
    static let maximumBytes = 10_000_000
    /// The most bytes of text kept from one attachment, in UTF-8.
    static let maximumTextBytes = 65_536
    /// The most attachments read in one email. The rest keep their names.
    static let maximumRead = 10
    /// The time the attachments of one email may take together (a guess), not counting the
    /// waits while the user dictates. Word, RTF and OpenDocument files are read in one call,
    /// which cannot stop, so the time is checked between attachments, after each page of a
    /// PDF and as an xlsx or pptx is read.
    static let maximumTime: Duration = .seconds(20)
    /// The pages read from a PDF. 64 KB of text rarely needs more.
    static let pdfPages = 100

    /// The formats of FileTextExtractor by file name extension, csv and ics as text.
    private static let formatsByExtension: [String: FileTextExtractor.Format] = [
        "pdf": .pdf, "docx": .docx, "doc": .doc, "rtf": .rtf, "odt": .odt,
        "xlsx": .xlsx, "xlsm": .xlsx, "pptx": .pptx, "ppsx": .pptx,
        "md": .text, "txt": .text, "csv": .text, "ics": .text,
    ]

    /// The formats by MIME type, for a name without one of the extensions above.
    private static let formatsByType: [String: FileTextExtractor.Format] = [
        "application/pdf": .pdf,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": .docx,
        "application/msword": .doc,
        "application/rtf": .rtf,
        "text/rtf": .rtf,
        "application/vnd.oasis.opendocument.text": .odt,
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": .xlsx,
        "application/vnd.ms-excel.sheet.macroenabled.12": .xlsx,
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": .pptx,
        "application/vnd.openxmlformats-officedocument.presentationml.slideshow": .pptx,
        "text/markdown": .text,
        "text/x-markdown": .text,
        "text/plain": .text,
        "text/csv": .text,
        "text/calendar": .text,
    ]

    /// The limits under which MIMEMessage decodes the content of the attachments this reads,
    /// on top of `base`.
    static func mimeLimits(_ base: MIMEMessage.Limits = MIMEMessage.Limits()) -> MIMEMessage.Limits {
        var limits = base
        limits.attachmentBytes = maximumBytes
        limits.attachmentExtensions = Set(formatsByExtension.keys)
        limits.attachmentTypes = Set(formatsByType.keys)
        return limits
    }

    /// The format to read an attachment as: by its name's extension, else by its MIME type
    /// when the name has no extension that names another format, as MIMEMessage decides.
    static func format(name: String?, type: String) -> FileTextExtractor.Format? {
        let fileExtension = MIMEMessage.fileExtension(of: name)
        if let format = formatsByExtension[fileExtension] {
            return format
        }
        return MIMEMessage.namesAFormat(fileExtension) ? nil : formatsByType[type.lowercased()]
    }

    /// The named attachments of a message parsed under `mimeLimits()`, in order, with the
    /// text of those it reads. Off the main actor, since PDFKit and the Office readers take
    /// a while.
    /// - Parameters:
    ///   - modified: the date the extractor's results carry, the email's.
    ///   - waitWhileDictating: returns once no dictation runs, before each attachment is read.
    ///   - now: the clock of the time limits. Tests pass a stand in.
    @concurrent
    static func read(
        _ parts: [MIMEMessage.Attachment],
        modified: Date,
        waitWhileDictating: @Sendable () async -> Void = {},
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) async -> [MailAttachment] {
        let started = now()
        var waited: Duration = .zero
        var reads = 0
        var attachments: [MailAttachment] = []
        for part in parts {
            guard let name = part.name, !name.isEmpty else { continue }
            var attachment = MailAttachment(name: name, type: part.mimeType, size: part.size, state: .otherType)
            let readAs = Self.format(name: name, type: part.mimeType)
            switch part.content {
            case .notDownloaded?:
                attachment.state = .notDownloaded
            case .tooLarge?:
                attachment.state = readAs == nil ? .otherType : .tooLarge
            case .data(let data)?:
                guard let readAs else { break }
                var after = now()
                if reads < maximumRead {
                    let before = after
                    await waitWhileDictating()
                    after = now()
                    waited += before.duration(to: after)
                }
                let spent = started.duration(to: after) - waited
                guard reads < maximumRead, spent < maximumTime, !Task.isCancelled else {
                    attachment.state = .notRead
                    break
                }
                reads += 1
                // MIMEMessage caps the bytes at `maximumBytes`, so the extractor keeps its own
                // limits, among them the size a docx or odt unpacks to.
                var limits = FileTextExtractor.Limits()
                limits.pdfPages = pdfPages
                limits.pdfTime = min(limits.pdfTime, maximumTime - spent)
                limits.officeTime = min(limits.officeTime, maximumTime - spent)
                let extractor = FileTextExtractor(limits: limits, now: now)
                let bytes = readAs == .text ? Self.utf8(data, charset: part.charset) : data
                attachment.take(await extractor.text(of: bytes, format: readAs, modified: modified))
            case nil:
                // A readable type left undecoded: the parser stopped at its limits.
                if readAs != nil {
                    attachment.state = .notRead
                }
            }
            attachments.append(attachment)
        }
        return attachments
    }

    /// The bytes of a text file in UTF-8, read in the charset its part names, as the text of
    /// an email is read. Bytes labeled UTF-8 or without a charset macOS knows stay as they
    /// are, for the extractor to tell their encoding, since mislabeled bytes read better
    /// that way. The text is cut to `maximumBytes`, far more than the text kept.
    static func utf8(_ data: Data, charset: String?) -> Data {
        guard let charset, let encoding = MailHeaders.encoding(charset), encoding != .utf8 else { return data }
        return Data(prefix(MailHeaders.text(data, charset: charset), bytes: maximumBytes).utf8)
    }

    /// Takes what the extractor read, with the text cut to `maximumTextBytes`. Hidden runs
    /// count even where no visible text is left.
    private mutating func take(_ result: Result<FileTextResult, FileSkipReason>) {
        switch result {
        case .success(let read) where read.pages.isEmpty:
            state = .noText
            hiddenRuns = read.hiddenRuns
        case .success(let read):
            let whole = read.pages.map(\.text).joined(separator: "\n\n")
            let kept = Self.prefix(whole, bytes: Self.maximumTextBytes)
            text = kept
            state = .read
            hiddenRuns = read.hiddenRuns
            isCut = read.isCut || kept.utf8.count < whole.utf8.count
        case .failure(.noText):
            state = .noText
        case .failure(.cancelled):
            state = .notRead
        case .failure:
            // Among them a docx or odt that unpacks to more than the extractor allows. The
            // bytes themselves are within `maximumBytes`.
            state = .unreadable
        }
    }

    /// The longest start of `text` of at most `bytes` bytes in UTF-8, whole characters only.
    static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var count = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            guard count + size <= bytes else { break }
            count += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
