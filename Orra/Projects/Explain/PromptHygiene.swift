import Foundation

/// Takes out of mail and file text what must never reach the model, and says what it took
/// out, so the user sees it. Code step 2 of phase 0.
///
/// In order:
/// - Unicode tag characters, which can spell text no one sees, are removed. A flag emoji's
///   tag sequence stays.
/// - Zero width and other invisible characters are removed, and so are stacked variation
///   selectors on one character. A zero width joiner inside an emoji or a conjunct stays,
///   and so does a zero width non joiner after Arabic or Indic letters.
/// - Bidirectional embeddings, overrides and isolates are removed. Direction marks and soft
///   hyphens are removed without a finding, since mail programs write them on their own.
/// - Text after a run of 8 or more blank lines is cut.
/// - HTML comments become a marker.
/// - The tokens of a chat template, and every line from the first to the last line that
///   holds one, become a marker.
/// - A line that addresses an assistant or a model, speaks as the system or as Orra, or
///   fakes the format of a model's answer becomes a marker, together with the rest of its
///   paragraph. A line in brackets, such as "[Note to the AI: …]", goes alone.
///
/// The model gets the text with the markers and, from ExplainPrompt, only the kind of each
/// finding. The text a finding took out is for the user only. Phase 0 found that removing
/// these lines took every wrong fact that came from injected text out of the explanations,
/// and halved the attack failures of the 4B. The patterns are adapted from its common.py
/// and explain.py, and widened to more wordings of the same kinds.
///
/// Cleaning text twice gives the same text as cleaning it once.
nonisolated struct PromptHygiene: Sendable, Equatable, Codable {
    /// Where the text comes from, which decides the warning for a line that addresses an
    /// assistant.
    nonisolated enum Source: Sendable, Equatable, Codable {
        case mail
        case file
    }

    /// Something the hygiene took out.
    nonisolated struct Finding: Sendable, Equatable, Codable {
        nonisolated enum Kind: Sendable, Hashable, Codable {
            /// Text or characters the reader does not see, or the tokens of a chat template.
            case hidden(ProjectsHiddenText)
            /// A passage that addresses an assistant or a model, speaks as the system, or
            /// fakes the format of a model's answer.
            case addressesAssistant
        }

        var kind: Kind
        /// The text taken out, for the user to read. Empty for characters that hold no
        /// text, such as zero width spaces. Never for the model or a log.
        var text: String
        /// Whether the text taken out addresses an assistant, as a hidden line may.
        var addressesAssistant: Bool
        /// Whether the text taken out claims to come from Orra.
        var claimsToBeOrra: Bool

        /// The warnings the user sees for this finding.
        func warnings(source: Source) -> [ProjectsWarning] {
            var warnings: [ProjectsWarning] = []
            // The tokens of a chat template show in the text. Phase 0 labeled a fake turn as
            // words to an assistant only, so they give no hidden text warning.
            if case .hidden(let hidden) = kind, hidden != .chatTemplateTokens {
                warnings.append(.hiddenText)
            }
            if kind == .addressesAssistant || addressesAssistant {
                warnings.append(source == .mail ? .instructionToAssistant : .documentInstruction)
            }
            if claimsToBeOrra {
                warnings.append(.claimsToBeOrra)
            }
            return warnings
        }
    }

    /// The text the model may read, with markers where passages were taken out.
    let text: String
    /// What was taken out, in the order of the steps.
    let findings: [Finding]
    let source: Source

    /// Cleans `text`, writing the markers in `language`, the language of the prompt.
    init(_ text: String, source: Source, language: ProjectsLanguage = .en) {
        self.source = source
        let markers = Markers(language)
        var findings: [Finding] = []
        var text = Self.withPlainLineBreaks(text)
        text = Self.removingTagCharacters(text, into: &findings)
        text = Self.removingInvisibleCharacters(text, into: &findings)
        text = Self.cuttingAfterBlankLines(text, marker: markers.afterBlankLines, into: &findings)
        text = Self.replacingComments(text, source: source, marker: markers.comment, into: &findings)
        text = Self.replacingTemplateBlocks(text, marker: markers.assistant, into: &findings)
        text = Self.replacingAssistantLines(text, marker: markers.assistant, into: &findings)
        self.text = Self.withoutRepeatedMarkers(text)
        self.findings = findings
    }

    /// The warnings for the user, each once, in the order found.
    var warnings: [ProjectsWarning] {
        var warnings: [ProjectsWarning] = []
        for warning in findings.flatMap({ $0.warnings(source: source) }) where !warnings.contains(warning) {
            warnings.append(warning)
        }
        return warnings
    }

    /// The kinds of hidden text found, each once, in the order found. Chat template tokens
    /// are left out, as in the warnings: the reader sees them, so they count as words to an
    /// assistant and not as hidden text.
    var hiddenText: [ProjectsHiddenText] {
        var kinds: [ProjectsHiddenText] = []
        for finding in findings {
            if case .hidden(let kind) = finding.kind, kind != .chatTemplateTokens, !kinds.contains(kind) {
                kinds.append(kind)
            }
        }
        return kinds
    }

    /// The text without the markers of either language, and without lines that held only
    /// a marker. What a reading of the text, such as its language, should look at.
    static func withoutMarkers(_ text: String) -> String {
        var result = text
        for marker in Markers(.zh).all + Markers(.en).all {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !line.allSatisfy(\.isWhitespace) }
            .joined(separator: "\n")
    }

    /// Whether the line addresses an assistant or a model, speaks as the system or as Orra,
    /// or fakes the format of a model's answer.
    static func addressesAssistant(_ line: String) -> Bool {
        matches(line, assistantPatterns) || claimsToBeOrra(line)
    }

    /// Whether the line speaks as Orra or names Orra as its sender.
    static func claimsToBeOrra(_ line: String) -> Bool {
        matches(line, orraPatterns)
    }

    // MARK: Markers

    /// The markers that stand where text was taken out. None of them is ever taken out
    /// itself, so cleaning twice changes nothing.
    nonisolated struct Markers {
        let assistant: String
        let comment: String
        let afterBlankLines: String

        init(_ language: ProjectsLanguage) {
            if language == .zh {
                assistant = "[已去掉一段写给助手的话]"
                comment = "[已去掉一段隐藏的注释]"
                afterBlankLines = "[已去掉空行后面藏着的文字]"
            } else {
                assistant = "[removed: words addressed to an assistant]"
                comment = "[removed: a hidden comment]"
                afterBlankLines = "[removed: text hidden after blank lines]"
            }
        }

        var all: [String] { [assistant, comment, afterBlankLines] }
    }

    private static let allMarkers = Set(Markers(.zh).all + Markers(.en).all)

    // MARK: Characters

    private static func withPlainLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
    }

    /// Removes runs of tag characters, except the tag sequence of a flag emoji after a
    /// black flag. The finding holds the ASCII they spell.
    private static func removingTagCharacters(_ text: String, into findings: inout [Finding]) -> String {
        guard text.unicodeScalars.contains(where: isTag) else { return text }
        let scalars = Array(text.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var spelled = ""
        var index = 0
        while index < scalars.count {
            guard isTag(scalars[index]) else {
                kept.append(scalars[index])
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, isTag(scalars[end]) {
                end += 1
            }
            let run = scalars[index..<end]
            let isFlag = index > 0 && scalars[index - 1] == blackFlag && run.count <= 7 && run.last == cancelTag
            if isFlag {
                kept.append(contentsOf: run)
            } else {
                for scalar in run {
                    if let ascii = Unicode.Scalar(scalar.value - 0xE0000), (0x20..<0x7F).contains(ascii.value) {
                        spelled.unicodeScalars.append(ascii)
                    }
                }
                spelled += " "
            }
            index = end
        }
        let hidden = spelled.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if kept.count != scalars.count {
            findings.append(finding(.hidden(.tagCharacters), text: hidden))
        }
        return String(kept)
    }

    /// Removes invisible characters and bidirectional controls, character by character.
    private static func removingInvisibleCharacters(_ text: String, into findings: inout [Finding]) -> String {
        guard text.unicodeScalars.contains(where: mayBeRemoved) else { return text }
        var result = String.UnicodeScalarView()
        var invisible = false
        var bidi = false
        var previous: Unicode.Scalar?
        for (characterIndex, character) in text.enumerated() {
            let scalars = Array(character.unicodeScalars)
            let selectors = scalars.filter(isVariationSelector).count
            for (index, scalar) in scalars.enumerated() {
                defer { previous = scalar }
                switch scalar.value {
                case 0x200D:
                    // A joiner inside an emoji or a conjunct has more of its character after it.
                    if index < scalars.count - 1 {
                        result.append(scalar)
                    } else {
                        invisible = true
                    }
                case 0x200C:
                    if let previous, joinsLetters(previous) {
                        result.append(scalar)
                    } else {
                        invisible = true
                    }
                case 0xFEFF where characterIndex == 0 && index == 0:
                    break
                case 0x00AD, 0x200E, 0x200F, 0x061C:
                    break
                case 0x202A...0x202E, 0x2066...0x2069:
                    bidi = true
                default:
                    if invisibleScalars.contains(scalar.value) {
                        invisible = true
                    } else if selectors > 1, isVariationSelector(scalar) {
                        invisible = true
                    } else {
                        result.append(scalar)
                    }
                }
            }
        }
        if invisible {
            findings.append(finding(.hidden(.invisibleCharacters), text: ""))
        }
        if bidi {
            findings.append(finding(.hidden(.bidiControls), text: ""))
        }
        return String(result)
    }

    /// Whether the step above may take the scalar out, so text without any such scalar,
    /// which is most text, is left as it is.
    private static func mayBeRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200C, 0x200D, 0x00AD, 0x200E, 0x200F, 0x061C, 0x202A...0x202E, 0x2066...0x2069:
            true
        default:
            invisibleScalars.contains(scalar.value) || isVariationSelector(scalar)
        }
    }

    private static let blackFlag: Unicode.Scalar = "\u{1F3F4}"
    private static let cancelTag: Unicode.Scalar = "\u{E007F}"

    private static func isTag(_ scalar: Unicode.Scalar) -> Bool {
        (0xE0000...0xE007F).contains(scalar.value)
    }

    private static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
    }

    /// Letters a zero width non joiner works between: Arabic and the Indic scripts.
    private static func joinsLetters(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFC, 0x0900...0x0DFF:
            true
        default:
            false
        }
    }

    /// Characters that show nothing: zero width space, word joiner, invisible operators,
    /// the Mongolian vowel separator, Hangul fillers, the combining grapheme joiner,
    /// interlinear annotation marks and a byte order mark after the start.
    private static let invisibleScalars: Set<UInt32> = [
        0x200B, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0x180E, 0x034F,
        0x115F, 0x1160, 0x3164, 0xFFA0, 0xFFF9, 0xFFFA, 0xFFFB, 0xFEFF,
    ]

    // MARK: Blank lines and comments

    /// Cuts the text after a run of 8 or more blank lines when text follows it.
    private static func cuttingAfterBlankLines(_ text: String, marker: String, into findings: inout [Finding]) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var blank = 0
        for (index, line) in lines.enumerated() {
            if line.allSatisfy(\.isWhitespace) {
                blank += 1
                continue
            }
            if blank >= blankLineRun, index > blank {
                let hidden = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                findings.append(finding(.hidden(.afterBlankLines), text: hidden))
                let kept = lines[..<(index - blank)].joined(separator: "\n")
                return kept + "\n\n" + marker
            }
            blank = 0
        }
        return text
    }

    /// The blank lines after which text counts as hidden. Phase 0 used 8.
    private static let blankLineRun = 8

    /// Replaces each HTML comment, and an unclosed one to the end, with the marker. An empty
    /// comment that closes goes without one.
    ///
    /// A file's chunk may start inside a comment that opened in the chunk before it. So in
    /// a file, text before a "-->" that ends its line, with no "<!--" before it, is the rest
    /// of a comment too. An arrow such as "A --> B" has text after it and stays.
    private static func replacingComments(_ text: String, source: Source, marker: String, into findings: inout [Finding]) -> String {
        var result = ""
        var rest = Substring(text)
        if source == .file, let close = rest.range(of: "-->"), !rest[..<close.lowerBound].contains("<!--"),
           rest[close.upperBound...].prefix(while: { !$0.isNewline }).allSatisfy(\.isWhitespace) {
            let content = rest[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                result += marker
                findings.append(finding(.hidden(.htmlComment), text: content))
            }
            rest = rest[close.upperBound...]
        }
        guard rest.contains("<!--") else { return result + rest }
        while let open = rest.range(of: "<!--") {
            result += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            let close = after.range(of: "-->")
            let content = (close.map { after[..<$0.lowerBound] } ?? after).trimmingCharacters(in: .whitespacesAndNewlines)
            // An unclosed comment, even an empty one, goes on in the text that follows,
            // such as the next chunk of a file.
            if !content.isEmpty || close == nil {
                result += marker
                findings.append(finding(.hidden(.htmlComment), text: content))
            }
            rest = close.map { after[$0.upperBound...] } ?? ""
        }
        return result + rest
    }

    // MARK: Lines

    /// Replaces the lines from the first to the last that holds a chat template token,
    /// with the rest of the last one's paragraph, with the marker.
    private static func replacingTemplateBlocks(_ text: String, marker: String, into findings: inout [Finding]) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let holding = lines.indices.filter { hasTemplateToken(lines[$0]) }
        guard let first = holding.first, let last = holding.last else { return text }
        let end = paragraphEnd(after: last, in: lines)
        let hidden = lines[first...end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        findings.append(Finding(kind: .hidden(.chatTemplateTokens), text: hidden, addressesAssistant: true, claimsToBeOrra: claimsToBeOrra(hidden)))
        lines.replaceSubrange(first...end, with: [marker])
        return lines.joined(separator: "\n")
    }

    /// Replaces each line that addresses an assistant, with the rest of its paragraph, with
    /// the marker. A heading of the explanation's answer that a person may also write, such
    /// as "Points:", counts only when the text holds another one, as a fake answer does.
    private static func replacingAssistantLines(_ text: String, marker: String, into findings: inout [Finding]) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fakesAnswer = Set(lines.compactMap(answerHeading)).count > 1
        var index = 0
        while index < lines.count {
            let line = withoutInlineMarkers(lines[index])
            guard !allMarkers.contains(lines[index].trimmingCharacters(in: .whitespaces)),
                  addressesAssistant(line) || (fakesAnswer && answerHeading(line) != nil) else {
                index += 1
                continue
            }
            let end = isBracketed(lines[index]) ? index : paragraphEnd(after: index, in: lines)
            let hidden = lines[index...end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let claims = lines[index...end].contains { claimsToBeOrra($0) }
            findings.append(Finding(kind: .addressesAssistant, text: hidden, addressesAssistant: true, claimsToBeOrra: claims))
            lines.replaceSubrange(index...end, with: [marker])
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    /// The last line of the paragraph that holds the line at `index`: the line before the
    /// next blank line or marker, or the last line.
    private static func paragraphEnd(after index: Int, in lines: [String]) -> Int {
        var end = index
        while end + 1 < lines.count {
            let next = lines[end + 1]
            if next.allSatisfy(\.isWhitespace) || allMarkers.contains(next.trimmingCharacters(in: .whitespaces)) {
                break
            }
            end += 1
        }
        return end
    }

    /// Whether the line is one passage in brackets, as "[Note to the AI: …]" is.
    private static func isBracketed(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, let last = text.last, text.count > 1 else { return false }
        return ["[": "]", "【": "】", "(": ")", "（": "）", "<": ">"][first] == last
    }

    private static func withoutInlineMarkers(_ line: String) -> String {
        var line = line
        for marker in allMarkers {
            line = line.replacingOccurrences(of: marker, with: " ")
        }
        return line
    }

    /// Takes repeated markers on lines of their own down to one.
    private static func withoutRepeatedMarkers(_ text: String) -> String {
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let last = kept.last, last == line, allMarkers.contains(String(line)) {
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    private static func finding(_ kind: Finding.Kind, text: String) -> Finding {
        Finding(kind: kind, text: text, addressesAssistant: addressesAssistant(text), claimsToBeOrra: claimsToBeOrra(text))
    }

    // MARK: Patterns

    private static func hasTemplateToken(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return templateTokens.firstMatch(in: line, range: range) != nil
    }

    /// The heading of the explanation's answer that the line is, on a line of its own, or
    /// nil.
    private static func answerHeading(_ line: String) -> String? {
        let form = SortingText.matchingForm(line)
        let range = NSRange(form.startIndex..., in: form)
        guard let match = answerHeadings.firstMatch(in: form, range: range), let word = Range(match.range(at: 1), in: form) else { return nil }
        return String(form[word])
    }

    private static let answerHeadings = try! NSRegularExpression(
        pattern: #"^\W*(警告|要点|回复前需确认|回复草稿|warnings|points|before you reply|draft reply)\s*[:：]\s*$"#
    )

    /// Whether any line of the text matches one of the patterns, which read the matching
    /// form: lowercased, with full width letters made plain and white space made one space.
    private static func matches(_ text: String, _ patterns: [NSRegularExpression]) -> Bool {
        for line in text.split(whereSeparator: \.isNewline) {
            let form = SortingText.matchingForm(String(line))
            guard !form.isEmpty else { continue }
            let range = NSRange(form.startIndex..., in: form)
            if patterns.contains(where: { $0.firstMatch(in: form, range: range) != nil }) {
                return true
            }
        }
        return false
    }

    /// The tokens of chat templates (Qwen, Llama, Gemma and others), reasoning tags, role
    /// tags such as <system>, and tags that would close a part of a Projects prompt, such
    /// as </email>. Tags a badly filled form letter may hold, such as <user> or <email>,
    /// are left alone.
    private static let templateTokens = try! NSRegularExpression(
        pattern: #"<\|[^|<>\n]{1,40}\|>|</?think>|\[/?INST\]|<</?SYS>>|<(?:start|end)_of_turn>|</?(?:system|assistant|instructions?)\s*>|</(?:email|thread|other_files|files?|checks|project_mail|project|message|mail)\s*>|<(?:checks|project_mail|other_files)\s*>"#,
        options: [.caseInsensitive]
    )

    /// Whom a line may address: a model, a bot, or an assistant that is software. A plain
    /// "assistant" is often a person, so it counts only in the narrow wordings below.
    private static let machine = #"(?:ai|a\.i\.|llm|llms|gpt|chatbots?|bots?|language models?|(?:ai|e-?mail|mail|inbox|automated|automatic|digital|smart)\s+(?:assistants?|agents?))"#
    /// The same in Chinese. A plain 助手 or 模型 is often a person or a physical model.
    private static let machineZh = #"(?:ai|人工智能|大模型|语言模型|ai\s*模型|机器人|自动程序|(?:ai|智能|邮件|自动)\s*(?:助手|助理))"#
    /// What a line asks of an assistant it names with a colon or a comma, as in
    /// "Assistant: tell the user …". "Assistant: Jana Holt" names a person and stays.
    private static let request = #"(?:please|tell|say|write|reply|include|forward|send|summari[sz]e|ignore|disregard|do not|don['’]t|draft|add|(?:file|move|mark)\s+(?:it|this|them|the|all|as)|(?:when|while|as|if)\s+you)\b"#
    /// The same in Chinese, after a colon or a comma.
    private static let requestZh = #"(?:请(?!求)|不要|别|忽略|告诉|回复|转发|发送|总结|记住|标记|把)"#

    private static let assistantPatterns: [NSRegularExpression] = [
        // English
        // "Note to any AI assistant", "instructions for email assistants"
        #"\b(?:note|message|instructions?|reminder|attention|notice|request|memo)\s+(?:to|for)\s+(?:(?:any|the|all|every|each|an?)\s+)?(?:\w+\s+)?"# + machine + #"(?![a-z])"#,
        // "Note to the assistant:", which a person rarely writes to a person
        #"\b(?:note|message|instructions?)\s+(?:to|for)\s+(?:any|the|all|every)\s+assistants?\s*[:：,]"#,
        // "To the AI reading this"
        #"\bto\s+(?:the|any|all|every)\s+"# + machine + #"(?![a-z])"#,
        // "AI reading this", "assistants summarizing this email"
        #"\b(?:"# + machine + #"|assistants?)\s+(?:that\s+)?(?:reads?|reading|process(?:es|ing)?|summari[sz](?:es|ing|e)|handl(?:es|ing|e)|scann?(?:s|ing)?|pars(?:es|ing|e))\s+(?:this|these|the\s+(?:e-?mail|message|mail|folder|file|document)|incoming)\b"#,
        // "Assistant: tell the user", "[image: AI assistant: …]", "(Assistant: file it there.)"
        // and "Assistant, when you draft", at the start of a line or after a bracket, a
        // colon or the end of a sentence
        #"(?:^\W*|[\[【(（:：.。!！?？;；]\s*)(?:(?:ai|e-?mail|orra)\s+)?assistants?\s*[:：,，]\s*"# + request,
        // "AI assistant: please …" anywhere in a line
        #"\b(?:ai|e-?mail|orra)\s+assistants?\s*[:：,，]\s*"# + request,
        #"\b(?:dear|hey|hi|hello|attention|attn)\s*,?\s+"# + machine + #"(?![a-z])"#,
        #"\bif\s+you(?:'re|’re|\s+are)\s+(?:an?\s+)?"# + machine + #"(?![a-z])"#,
        #"\b(?:ignore|disregard|forget|override|bypass)\s+(?:all\s+|any\s+|every\s+)?(?:of\s+)?(?:your\s+|the\s+|my\s+|these\s+|those\s+)?(?:previous|prior|earlier|above|preceding|original|existing|other|system)\s+(?:instructions?|rules|prompts?|directions|guidelines|directives|context|commands)\b"#,
        #"\b(?:ignore|disregard)\s+(?:all|any)\s+(?:instructions?|rules)\b"#,
        #"^\W*(?:system|ai)(?:\s+(?:message|note|prompt|instruction|override))?\s*[:：]"#,
        #"\bsystem\s+(?:prompt|instructions?|override)\b"#,
        #"\byou\s+are\s+(?:now\s+)?(?:in\s+)?(?:maintenance|developer|admin|debug|god|jailbreak|unrestricted)\s+mode\b"#,
        #"\b(?:enter|entering|switch\s+to|activate)\s+(?:maintenance|developer|admin|debug)\s+mode\b"#,
        #"\bnew\s+instructions?\s*[:：]"#,
        #"\bdo\s+not\s+(?:show|display|reveal)\s+(?:this|these)\s+(?:note|instructions?|lines?|paragraph)\s+to\s+the\s+(?:user|owner|reader)\b"#,
        // A bracket tag at the start that speaks as the system or to an assistant.
        #"^\W*[\[【(（<]\s*(?:system\s+(?:message|prompt|instruction|override|note|notice)|(?:ai|assistant)\s+(?:note|notice|instructions?|message)|(?:ai|assistant)\s*[:：]|系统(?:消息|提示|指令)|助手(?:须知|注意|指令|提示))"#,
        // Chinese
        #"(?:致|给|写给|提醒|告诉)[^。！？!?\n]{0,12}"# + machineZh + #"(?![员师店])"#,
        #"(?:处理|阅读|读取|总结|整理|分析)(?:本|这封|此|该|这份|这个|这些)(?:邮件|信|文件|文档|文件夹|资料|内容)?\s*的\s*(?:ai|人工智能|助手|模型|自动程序|机器人)"#,
        #"(?:ai|助手|模型)\s*请注意|请\s*(?:ai|助手|模型)\s*注意"#,
        // "AI 助手：请…" anywhere in a line, "AI助手请…" and "请AI助手…"
        #"(?:(?<![a-z])ai|智能|邮件|orra)\s*(?:助手|助理)\s*(?:[:：,，]\s*"# + requestZh + #"|请(?!求))"#,
        #"请\s*(?:ai|智能|orra)\s*(?:助手|助理)"#,
        #"(?:忽略|无视|忘记|忘掉|不要理会|不用理会|跳过)\s*(?:你|您)?(?:之前|以上|前面|先前|上面|此前|原来|原有|上述|所有|全部|一切)(?:的)?(?:所有|全部|一切)?(?:的)?(?:指令|指示|设定|提示词|系统提示|规则)"#,
        #"^\W*(?:系统|ai|人工智能)\s*(?:消息|提示|指令)?\s*[:：]"#,
        #"系统提示词|系统指令"#,
        #"(?:你|您)现在(?:是|扮演|作为)(?:一个|一名)?(?:(?:邮件|系统|ai|人工智能)(?:管理员|助手|模型|机器人)|ai|人工智能|机器人|助手)"#,
        #"(?:不要|别|切勿|请勿)(?:向|给)[^。！？!?\n]{1,6}显示(?:这段|这句|这条|此段|此条|本段)"#,
        // Headings that open instructions for an assistant. "## Instructions" or "## 系统"
        // alone heads ordinary text in many documents.
        #"^#{1,6}\s*(?:(?:ai|assistant|model|llm)\s+instructions?|instructions?\s+(?:for|to)\s+(?:the\s+|any\s+)?(?:ai|assistants?|models?|llms?)|(?:给|致)\s*(?:ai|助手|模型)\s*的?\s*(?:指令|说明)|(?:ai|助手|模型)\s*指令)\s*$"#,
        // The format of a model's answer: a JSON object with the keys Orra's prompts ask
        // for, or a heading of the explanation's answer that only a draft has. The other
        // headings count when two of them appear, see replacingAssistantLines.
        #"^\W*\{\s*"(?:project|cleaned|translation|answer|reply|draft|decision|warnings|summary|confidence|reason)"\s*:"#,
        #"^\W*(?:回复前需确认|回复草稿|draft reply)\s*[:：]\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Things Orra's own messages would be, after "Orra".
    private static let orraThings = #"(?:system|assistant|security|notice|alert|warning|message|team|support|notification|admin)"#
    private static let orraThingsZh = #"(?:系统|助手|提示|通知|安全|团队|消息|管理员|提醒)"#

    /// Wordings that speak as Orra or name it as the sender. A mail that only names Orra, as
    /// feedback from its users or a notice about its code may, does not count.
    private static let orraPatterns: [NSRegularExpression] = [
        // A sender line, "Sent from Orra"
        #"^\W*(?:sent\s+)?(?:from|by|via)\s+orra\s*[:：.]?\s*$"#,
        #"\b(?:message|notice|alert|warning|notification|reminder|sent|generated|written|issued)\s+(?:from|by|via)\s+orra\b"#,
        // "Orra Security: …", "Orra Team" alone, "[Orra system notice]"
        #"^\W*orra\s+"# + orraThings + #"\s*(?:[:：.!]|$)"#,
        #"[\[【(（<]\s*orra\s+"# + orraThings + #"\b"#,
        #"^\W*orra\s*[:：]"#,
        // "Verified by Orra", "已由 Orra 安全验证"
        #"\b(?:verified|checked|scanned|approved|certified|confirmed)\s+(?:as\s+\w+\s+)?by\s+orra\b"#,
        #"(?:由|经|被)\s*orra\s*的?\s*(?:安全)?\s*(?:验证|检查|扫描|审核|认证|确认)"#,
        #"来自\s*orra\s*的?\s*"# + orraThingsZh + #"|来自\s*orra\s*[:：]?\s*$"#,
        #"^\W*orra\s*"# + orraThingsZh + #"\s*(?:[:：]|$)"#,
        #"[\[【(（<]\s*orra\s*"# + orraThingsZh,
    ].map { try! NSRegularExpression(pattern: $0) }
}
