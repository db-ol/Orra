import Foundation
import NaturalLanguage

/// What Orra reads on the screen for one dictation while Use names on screen is on, see
/// ScreenReader: the text before the cursor in the focused field and the title of its
/// window. Kept in memory for that dictation only, never logged and never saved.
nonisolated struct ScreenText: Equatable, Sendable {
    /// Up to `ScreenReader.maximumBeforeCursor` characters before the cursor.
    var beforeCursor: String
    /// The title of the focused window, when it has one.
    var windowTitle: String? = nil
}

/// Common words: the whole words of the speech model's tokenizer vocabulary, the vocab.json
/// of Qwen3-ASR with its 151,643 byte level BPE tokens, which ModelInstaller installs with
/// the model. A word the tokenizer holds as one token is frequent in its training text, so
/// it is common. About 30,000 Latin words, written with a leading space in the vocabulary,
/// and 16,000 Han words of two characters or more. Without the file every word counts as
/// rare.
nonisolated struct CommonWords: Sendable {
    let latin: Set<String>
    let han: Set<String>

    static let none = CommonWords(latin: [], han: [])

    /// The words of the installed speech model, read on first use, which takes a moment.
    /// A dictation needs the model, so it is there by then.
    static let installed: CommonWords = SpeechModel.installedFolder().map {
        load(from: $0.appendingPathComponent("vocab.json"))
    } ?? none

    /// The words of a tokenizer vocabulary file, or none when it cannot be read.
    static func load(from url: URL) -> CommonWords {
        guard let data = try? Data(contentsOf: url),
              let vocabulary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return none
        }
        let decoder = byteDecoder()
        var latin = Set<String>()
        var han = Set<String>()
        for token in vocabulary.keys {
            var bytes: [UInt8] = []
            var valid = true
            for scalar in token.unicodeScalars {
                guard let byte = decoder[scalar] else {
                    valid = false
                    break
                }
                bytes.append(byte)
            }
            guard valid, let word = String(bytes: bytes, encoding: .utf8) else { continue }
            if word.hasPrefix(" "), word.count > 1, word.dropFirst().allSatisfy({ $0.isASCII && $0.isLetter }) {
                latin.insert(word.dropFirst().lowercased())
            } else if word.count >= 2, word.allSatisfy(ScreenNames.isHan) {
                han.insert(word)
            }
        }
        return CommonWords(latin: latin, han: han)
    }

    /// GPT-2's table of bytes to the characters that stand for them in the vocabulary,
    /// reversed.
    private static func byteDecoder() -> [Unicode.Scalar: UInt8] {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for byte in 0..<256 where !bytes.contains(byte) {
            bytes.append(byte)
            scalars.append(256 + extra)
            extra += 1
        }
        var table: [Unicode.Scalar: UInt8] = [:]
        for (byte, scalar) in zip(bytes, scalars) {
            if let character = Unicode.Scalar(scalar) { table[character] = UInt8(byte) }
        }
        return table
    }

    /// Whether a Latin word, or the word without a common ending, is one token.
    func isCommonLatin(_ word: String) -> Bool {
        let lower = word.lowercased()
        if latin.isEmpty { return false }
        if latin.contains(lower) { return true }
        for (ending, replacement) in [("'s", ""), ("s", ""), ("es", ""), ("ies", "y"), ("ed", ""), ("ed", "e"), ("ing", ""), ("ing", "e"), ("ly", ""), ("er", ""), ("ers", "")]
        where lower.hasSuffix(ending) && lower.count > ending.count + 2 {
            if latin.contains(String(lower.dropLast(ending.count)) + replacement) { return true }
        }
        return false
    }
}

/// Takes names and rare words out of the text on the screen, for the speech model's
/// context. Measured on 2026-10-15 and 16 with Qwen3-ASR 1.7B: when a name the user says
/// is on the page, giving the model the names and rare words of the text before the cursor
/// and the names elsewhere on the page raised the names written right from 107 to 173 of
/// 201 (59 to 73 of 81 on real speech), and the other words did not get worse. Orra reads
/// no names elsewhere on the page, see ScreenReader, and its own path wrote 164 of 201 (73
/// of 81) right on the same clips, see ScreenNamesEvaluationTests. The text itself is
/// never given to the model, since then the model writes it out when nobody speaks. The
/// known risk: when a name on the screen sounds like a name the user says that is not
/// there, the model can write the name on the screen instead, 13 times in 59 such names on
/// real speech, and no check found so far tells the two cases apart. So Use names on
/// screen is off by default.
///
/// Written for that experiment with what every Mac and Orra already have, and moved here
/// with one change: the experiment took Chinese names from NLTagger, which finds none on
/// macOS 27, so Orra finds them with its own rules below on every system.
/// - personal, place and organization names in Latin letters that NLTagger finds.
/// - Latin words that are not common: capitalized inside a sentence, mixed case such as
///   gRPC, all capitals of 2 to 6 letters such as QBR, letters with digits such as p99,
///   and lower case words of 5 letters or more that are not common words (CommonWords),
///   such as hysteresis or escrow. Neighbouring capitalized words are joined, so Thornsby
///   Labs stays one term, and a courtesy title before a name is dropped.
/// - in Chinese text, every Latin run of up to four words, such as idempotency key or
///   consent: a word the writer kept in English is a term.
/// - Han words of the system's word breaker that are not common words, such as 蜉蝣 or 拓扑,
///   joined when they stand together, as 嵌合抗原.
/// - Chinese personal names of a common surname and a given name of one or two characters
///   that the word breaker does not hold as a word, such as 甄若岚 or 欧阳澈, where the name
///   ends cleanly: no character or rare word goes on after it.
/// - runs of 2 to 4 Han characters that the word breaker leaves as single characters and
///   that hold no grammar character, which is how it treats names it does not know, such as
///   星澜 or 戈马, when the run is followed by or ends in a word that says what it names,
///   which makes it a name, as 青岚计划 or 汀澜岛, occurs twice, or sits where names sit
///   (after 是, 由 or 给, before punctuation, 你好, 负责 or 老师).
/// - text in 《》, 「」 or Chinese quotation marks up to 12 characters.
///
/// The window title is read as a line above the text, the farthest from the cursor. The
/// terms are ranked names first, then the other terms, each by how many times they occur
/// and then by how close their last occurrence is to the cursor. When there are more than
/// `limit`, the ones nearest the cursor stay. The experiment found 20 too few on a page full
/// of names, and 40 better with no more mistakes. It took 2 to 3 ms for a text of a few
/// hundred characters, and up to 124 ms when NLTagger switched between Chinese and English.
/// NLTagger now runs only on text with Latin letters.
nonisolated enum ScreenNames {
    /// At most this many terms reach the model with a dictation.
    static let limit = 40

    nonisolated struct Term: Equatable, Sendable {
        var text: String
        var source: Source
        var count: Int
        /// The character offset of its last occurrence. Higher is nearer the cursor.
        var lastPosition: Int
    }

    nonisolated enum Source: Int, Comparable, Sendable {
        case name = 1
        case other = 2
        case rare = 3

        static func < (a: Source, b: Source) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    /// The terms of the screen text for the speech model, best first.
    static func terms(in screen: ScreenText, common: CommonWords, limit: Int = limit) -> [String] {
        rankedTerms(in: screen, common: common, limit: limit).map(\.text)
    }

    static func rankedTerms(in screen: ScreenText, common: CommonWords, limit: Int = limit) -> [Term] {
        let title = screen.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = title.isEmpty ? screen.beforeCursor : title + "\n" + screen.beforeCursor
        var found: [String: Term] = [:]
        var order: [String] = []
        func add(_ raw: String, source: Source, position: Int) {
            var term = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?，。；：！？、()（）\"'")))
            if term.hasSuffix("'s") || term.hasSuffix("’s") { term = String(term.dropLast(2)) }
            guard term.count >= 2, term.count <= 40 else { return }
            let key = term.lowercased()
            if var known = found[key] {
                known.lastPosition = max(known.lastPosition, position)
                known.source = min(known.source, source)
                found[key] = known
            } else {
                found[key] = Term(text: term, source: source, count: 1, lastPosition: position)
                order.append(key)
            }
        }
        let tokens = latinTokens(in: text)
        let names = taggedNames(in: text, tokens: tokens, common: common)
        for (term, position) in names { add(term, source: .name, position: position) }
        for (term, position) in latinTerms(in: text, tokens: tokens, common: common) { add(term, source: .other, position: position) }
        for (term, position) in latinInChinese(in: text) { add(term, source: .other, position: position) }
        for (term, position, source) in hanTerms(in: text, common: common) { add(term, source: source, position: position) }
        for (term, position) in quoted(in: text) { add(term, source: .name, position: position) }

        var terms = order.compactMap { found[$0] }
        // A term found inside a longer term, such as 青岚 in 青岚计划, stays only when it also
        // stands alone somewhere.
        terms = terms.filter { term in
            let longer = terms.filter { $0.text.count > term.text.count && $0.text.lowercased().contains(term.text.lowercased()) }
            guard !longer.isEmpty else { return true }
            let alone = occurrences(of: term.text, in: text) - longer.reduce(0) { $0 + occurrences(of: $1.text, in: text) }
            return alone > 0
        }
        terms = terms.map { term in
            var term = term
            term.count = max(1, occurrences(of: term.text, in: text))
            return term
        }
        if terms.count > limit {
            terms = Array(terms.sorted { $0.lastPosition > $1.lastPosition }.prefix(limit))
        }
        terms.sort { a, b in
            if (a.source == .name) != (b.source == .name) { return a.source == .name }
            if a.count != b.count { return a.count > b.count }
            return a.lastPosition > b.lastPosition
        }
        return terms
    }

    static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        return text.lowercased().components(separatedBy: term.lowercased()).count - 1
    }

    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { LanguageGuard.isHan($0) }
    }

    // MARK: Latin tokens

    nonisolated struct LatinToken {
        var word: String
        var start: Int
        var sentenceStart: Bool
    }

    static let sentenceMarks: Set<Character> = [".", "!", "?", "。", "！", "？", "\n", ":", "："]

    static func latinTokens(in text: String) -> [LatinToken] {
        let characters = Array(text)
        var tokens: [LatinToken] = []
        var index = 0
        var atSentenceStart = true
        while index < characters.count {
            let character = characters[index]
            if character.isASCIILetterOrDigit {
                let start = index
                while index < characters.count, characters[index].isASCIILetterOrDigit
                        || ("-'.".contains(characters[index]) && index + 1 < characters.count && characters[index + 1].isASCIILetter) {
                    index += 1
                }
                tokens.append(LatinToken(word: String(characters[start..<index]), start: start, sentenceStart: atSentenceStart))
                atSentenceStart = false
                continue
            }
            if sentenceMarks.contains(character) {
                atSentenceStart = true
            } else if !character.isWhitespace, !"\"'“”‘’()（）-—".contains(character) {
                atSentenceStart = false
            }
            index += 1
        }
        return tokens
    }

    // MARK: Names

    /// Courtesy titles, said but no part of the name to spell.
    static let titles: Set<String> = ["mister", "missus", "mr", "mrs", "ms", "dr", "doctor", "madame", "miss", "sir", "lord", "lady",
                                      "captain", "colonel", "lieutenant", "professor", "prof", "monsieur"]

    static func isTitle(_ word: String) -> Bool {
        titles.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    /// Names in Latin letters that NLTagger finds. Its name type scheme is for English: on
    /// macOS 26 it also found Chinese names, but on macOS 27 it finds none, so Chinese names
    /// come from hanTerms on every system.
    static func taggedNames(in text: String, tokens: [LatinToken], common: CommonWords) -> [(String, Int)] {
        guard tokens.contains(where: { $0.word.contains(where: \.isLetter) }) else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var result: [(String, Int)] = []
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]
        let startsOnly = Set(tokens.filter(\.sentenceStart).map { $0.word.lowercased() })
            .subtracting(tokens.filter { !$0.sentenceStart }.map { $0.word.lowercased() })
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            guard let tag, wanted.contains(tag), !text[range].contains(where: isHan) else { return true }
            var name = String(text[range])
            var position = text.distance(from: text.startIndex, to: range.lowerBound)
            var parts = name.split(separator: " ").map(String.init)
            while parts.count > 1, isTitle(parts[0]) {
                position += parts[0].count + 1
                parts.removeFirst()
            }
            name = parts.joined(separator: " ")
            // A plain word the tagger took for a name at the start of a line, as Character in
            // "Character notes".
            if parts.count == 1, titles.contains(name.lowercased()) || startsOnly.contains(name.lowercased()) && common.isCommonLatin(name) {
                return true
            }
            result.append((name, position))
            return true
        }
        return result
    }

    /// Words after a Han name that say what it names, kept with the name, longest first.
    static let suffixWords: [String] = [
        "科技", "公司", "集团", "项目", "计划", "系统", "平台", "工作室", "实验室", "数据", "社区", "银行", "医院",
        "大学", "学院", "中心", "研究所", "基金", "资本", "群岛", "岛", "山脉", "火山", "山", "湖", "河", "语",
        "村", "县", "市", "省", "区", "英镑", "数", "虎",
    ].sorted { $0.count > $1.count }

    // MARK: Latin

    static let notTerms: Set<String> = [
        "i", "ok", "okay", "hi", "hello", "dear", "thanks", "thank", "best", "regards", "cheers", "re", "fw", "fwd", "cc", "to", "from", "subject",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "christmas", "easter",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "am", "pm", "the", "a", "an", "of", "and", "or", "in", "on", "at", "for", "with", "is", "are", "be", "it", "this", "that",
    ]

    static func latinTerms(in text: String, tokens: [LatinToken], common: CommonWords) -> [(String, Int)] {
        let characters = Array(text)
        func isTerm(_ token: LatinToken) -> Bool {
            let word = token.word
            guard word.count >= 2, word.contains(where: \.isLetter) else { return false }
            if notTerms.contains(word.lowercased()) { return false }
            let letters = word.filter(\.isLetter)
            let upper = letters.filter(\.isUppercase).count
            if word.contains(where: \.isNumber) { return true }
            if upper == letters.count, letters.count >= 2, letters.count <= 6 { return true }
            if upper >= 2 || (upper == 1 && word.first?.isLowercase == true) { return true }
            if word.first?.isUppercase == true {
                return !token.sentenceStart || !common.isCommonLatin(word)
            }
            return word.count >= 5 && !common.isCommonLatin(word)
        }
        var result: [(String, Int)] = []
        var run: [LatinToken] = []
        func flush() {
            defer { run = [] }
            guard let first = run.first else { return }
            var words = run
            // A title just before the run, as Colonel at a sentence start before Wheeler.
            var hadTitle = false
            if let index = tokens.firstIndex(where: { $0.start == first.start }), index > 0, isTitle(tokens[index - 1].word) {
                hadTitle = true
            }
            while words.count > 1, isTitle(words[0].word) {
                words.removeFirst()
                hadTitle = true
            }
            // A single capitalized common word inside a sentence, as Grant in "to Grant", is a
            // term only when the tagger also names it or a title comes before it.
            if !hadTitle, words.count == 1, let only = words.first, only.word.first?.isUppercase == true,
               only.word.dropFirst().allSatisfy({ $0.isLowercase }), common.isCommonLatin(only.word) || titles.contains(only.word.lowercased()) {
                return
            }
            guard let start = words.first?.start, let last = words.last else { return }
            result.append((String(characters[start..<(last.start + last.word.count)]), start))
        }
        for token in tokens {
            if isTerm(token) {
                let joins = token.word.first?.isUppercase == true && run.last?.word.first?.isUppercase == true
                if let last = run.last {
                    let gap = String(characters[(last.start + last.word.count)..<token.start])
                    if gap != " " || !joins { flush() }
                }
                run.append(token)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// Latin runs of up to four words inside Chinese text, as idempotency key in
    /// 是 idempotency key 冲突.
    static func latinInChinese(in text: String) -> [(String, Int)] {
        let characters = Array(text)
        guard characters.contains(where: isHan) else { return [] }
        var result: [(String, Int)] = []
        var index = 0
        while index < characters.count {
            guard characters[index].isASCIILetterOrDigit else {
                index += 1
                continue
            }
            let start = index
            var end = index
            var words = 0
            var scan = index
            while scan < characters.count, characters[scan].isASCIILetterOrDigit {
                while scan < characters.count, characters[scan].isASCIILetterOrDigit || "-'.".contains(characters[scan]) {
                    scan += 1
                }
                words += 1
                end = scan
                if scan + 1 < characters.count, characters[scan] == " ", characters[scan + 1].isASCIILetter, words < 4 {
                    scan += 1
                } else {
                    break
                }
            }
            index = max(end, index + 1)
            // Only a run that sits in Chinese text: Han or Chinese punctuation on one side.
            let before = start > 0 ? characters[start - 1] : "\n"
            let after = end < characters.count ? characters[end] : "\n"
            let besideChinese = [before, after].contains { isHan($0) || "，。：；！？、（）“”".contains($0) }
                || (before == " " && start > 1 && isHan(characters[start - 2]))
                || (after == " " && end + 1 < characters.count && isHan(characters[end + 1]))
            let phrase = String(characters[start..<end]).trimmingCharacters(in: CharacterSet(charactersIn: ".-'"))
            if besideChinese, phrase.count >= 2, !notTerms.contains(phrase.lowercased()) {
                result.append((phrase, start))
            }
        }
        return result
    }

    // MARK: Han

    /// Han words of the word breaker that are not common words, joined when they stand
    /// together, runs of single characters that look like unknown names, and names that
    /// start with a surname. None of these needs the system to know the name.
    static func hanTerms(in text: String, common: CommonWords) -> [(String, Int, Source)] {
        let string = text as NSString
        guard string.length > 0 else { return [] }
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRangeMake(0, string.length),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "zh-Hans") as CFLocale)
        var tokens: [(text: String, location: Int)] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            tokens.append((string.substring(with: NSRange(location: range.location, length: range.length)), range.location))
        }
        // UTF-16 offsets to character offsets: Han text in the BMP has one unit per character,
        // which is all this looks at, but other text before it may not.
        var offsets: [Int: Int] = [:]
        var unit = 0
        for (index, character) in text.enumerated() {
            offsets[unit] = index
            unit += character.utf16.count
        }
        offsets[unit] = text.count

        enum Kind { case single, rare, other }
        func kind(_ token: String) -> Kind {
            let characters = Array(token)
            guard characters.allSatisfy(isHan) else { return .other }
            if characters.count == 1 {
                return OneCharacterFix.functionWords.contains(characters[0]) || commonSingles.contains(characters[0])
                    || nameNeighbours.contains(token) ? .other : .single
            }
            if characters.allSatisfy({ commonSingles.contains($0) || OneCharacterFix.functionWords.contains($0) }) { return .other }
            return common.han.contains(token) || characters.contains(where: OneCharacterFix.functionWords.contains) ? .other : .rare
        }
        let kinds = tokens.map { kind($0.text) }
        func end(_ index: Int) -> Int {
            tokens[index].location + tokens[index].text.utf16.count
        }
        /// Whether the token at `index` starts where the one before it ends.
        func follows(_ index: Int) -> Bool {
            index > 0 && index < tokens.count && tokens[index].location == end(index - 1)
        }
        /// The word right after the token at `index`, as one token and as two, since the word
        /// breaker splits some of them, as 你好 into 你 and 好.
        func words(after index: Int) -> [String] {
            guard follows(index + 1) else { return [] }
            let next = tokens[index + 1].text
            return follows(index + 2) ? [next, next + tokens[index + 2].text] : [next]
        }
        /// The word right before the token at `index`, as one token and as two.
        func words(before index: Int) -> [String] {
            guard follows(index) else { return [] }
            let previous = tokens[index - 1].text
            return follows(index - 1) ? [previous, tokens[index - 2].text + previous] : [previous]
        }
        func isBoundary(_ unit: Int) -> Bool {
            guard unit >= 0, unit < string.length else { return true }
            let character = Character(UnicodeScalar(string.character(at: unit)) ?? " ")
            return !character.isLetter && !character.isNumber
        }
        /// The character before the UTF-16 offset `unit`, past any spaces.
        func character(before unit: Int) -> Character? {
            var unit = unit - 1
            while unit >= 0, string.character(at: unit) == 0x20 {
                unit -= 1
            }
            return unit >= 0 ? UnicodeScalar(string.character(at: unit)).map(Character.init) : nil
        }

        var result: [(String, Int, Source)] = []
        // Personal names that start with a surname, as 甄若岚 or 欧阳澈: the surname, then a
        // given name of one or two characters that the word breaker does not hold as a word.
        var inName = [Bool](repeating: false, count: tokens.count)
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            var surname = tokens[index].text
            var next = index + 1
            if surname.count == 1, follows(next), compoundSurnames.contains(surname + tokens[next].text) {
                surname += tokens[next].text
                next += 1
            }
            guard compoundSurnames.contains(surname) || surname.count == 1 && surnames.contains(surname),
                  let position = offsets[tokens[index].location] else { continue }
            // Not the end of a word the word breaker does not know, and not a measure word
            // after a number, as 张 in 一张纸 or 余 in 20 余人.
            if follows(index), kinds[index - 1] != .other { continue }
            if let mark = character(before: tokens[index].location), countWords.contains(mark) { continue }
            var given: [String] = []
            while follows(next), given.joined().count < 2 {
                let token = tokens[next].text
                let isFirst = given.isEmpty
                guard token.allSatisfy(isHan), !nameNeighbours.contains(token),
                      token.count == 1 && (!OneCharacterFix.functionWords.contains(Character(token)) || isFirst && token == "一")
                      || isFirst && token.count == 2 && kinds[next] == .rare else { break }
                given.append(token)
                next += 1
            }
            guard let last = given.last, let lastCharacter = last.last, given != ["一"] else { continue }
            let name = surname + given.joined()
            let following = follows(next) ? tokens[next].text : nil
            // A given name ends in a character that is no common word on its own, as 好 or 下,
            // and no character of the name follows it, nor a word that makes it a verb, as 了
            // in 钟停了.
            if last.count == 1 && commonSingles.contains(lastCharacter) { continue }
            if let following, kinds[next] == .single || notAfterNames.contains(following) { continue }
            let besideName = words(before: index).first.map(beforeNames.contains) == true
                || words(after: next - 1).contains(where: nameNeighbours.contains)
                || following == nil || occurrences(of: name, in: text) >= 2
            if last.count == 2 {
                // A rare word, which a given name of two characters often is to the word breaker,
                // as 思远 in 覃思远, makes a name only where names sit, so 高纬度 is none.
                guard besideName else { continue }
            } else if given.count == 1, let following {
                // A given name of one character, as 悦 in 林悦, is not followed by a rare word
                // that could be the rest of a longer word, as 泰利 after 马尔, nor by grammar
                // unless the name sits where names sit, as 从 after 白烟.
                let grammar = following.count == 1 && OneCharacterFix.functionWords.contains(Character(following))
                if kinds[next] == .rare || grammar && !besideName { continue }
            }
            result.append((name, position, .name))
            for token in index..<next {
                inName[token] = true
            }
            index = next - 1
        }

        /// A run of single characters and rare words, from the token at `first` to the one at `last`.
        func addRun(from first: Int, to last: Int) {
            let start = tokens[first].location
            var term = string.substring(with: NSRange(location: start, length: end(last) - start))
            let singles = (first...last).filter { kinds[$0] == .single }.count
            let hasRare = (first...last).contains { kinds[$0] == .rare }
            let after = words(after: last)
            var named = false
            if let next = after.first, suffixWords.contains(next) {
                term += next
                named = true
            } else if !hasRare, let suffix = suffixWords.first(where: { term.hasSuffix($0) }), term.count - suffix.count >= 2 {
                // The word that says what it names left as a single character too, as 岛 in 汀澜岛.
                named = true
            }
            guard term.count >= 2, term.count <= 8, let position = offsets[start] else { return }
            if hasRare {
                result.append((term, position, .rare))
                return
            }
            guard (2...4).contains(singles) else { return }
            // A name the word breaker does not know sits where names sit: before a word that
            // says what it names, which makes it a name, said twice, after 是, 由 or 给, or
            // before punctuation, 你好, 负责 or 老师.
            let repeated = occurrences(of: String(term.prefix(singles)), in: text) >= 2
            let besideName = (words(before: first) + after).contains(where: nameNeighbours.contains) || isBoundary(end(last))
            if named {
                result.append((term, position, .name))
            } else if repeated || besideName {
                result.append((term, position, .other))
            }
        }
        var first = 0
        while first < tokens.count {
            guard kinds[first] != .other, !inName[first] else {
                first += 1
                continue
            }
            var last = first
            while follows(last + 1), kinds[last + 1] != .other, !inName[last + 1] {
                last += 1
            }
            addRun(from: first, to: last)
            first = last + 1
        }
        return result
    }

    /// Single character surnames, the common ones of the Chinese surname lists, without those
    /// that are mostly grammar or a word of their own, as 于, 和, 成 or 全.
    static let surnames: Set<String> = Set("""
        王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾
        夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵钱严覃武戴莫孔汤常温康施文牛樊葛邢安齐易乔伍庞颜倪庄聂章鲁岳翟殷詹申欧
        耿关兰焦俞左柳甘祝宁符舒阮柯纪梅童凌毕季裴霍涂苗谷盛曲翁冉骆蓝辛靳柴蒙鲍华喻祁蒲房滕屈饶牟艾尤阳穆卓吉缪
        麦褚娄窦戚岑卜冷晏柏宗瞿桂佟臧闵苟邬卞姬仇栾隋刁巫寇桑甄丛仲虞敖巩佘池麻苑迟邝
        匡鞠荆冀郁胥储栗燕楚鄢劳谌奚皮粟冼蔺闻厉伊仝郜阚权帅屠豆朴廉禹漆狄
        扈晁芮阙浦戈鹿邸雍辜裘亓邰赫杭况逯茹嵇湛戎茅尉檀昝濮隗邴芈訾逄
        """.filter(\.isHan).map(String.init))

    /// Surnames of two characters.
    static let compoundSurnames: Set<String> = [
        "欧阳", "司马", "上官", "诸葛", "东方", "皇甫", "尉迟", "公孙", "慕容", "令狐", "夏侯", "长孙", "宇文", "司徒", "端木",
        "独孤", "南宫", "西门", "百里", "呼延", "澹台", "公冶", "申屠", "太史", "轩辕", "钟离", "闻人", "赫连", "万俟", "司空",
    ]

    /// Characters before a measure word, which 张 or 条 follow as often as a surname does.
    static let countWords: Set<Character> = Set("一二两三四五六七八九十百千万几这那哪每某各半整多0123456789")

    /// Words that do not follow a name but the verb or adjective that two characters after a
    /// surname can be.
    static let notAfterNames: Set<String> = ["了", "着", "过", "得", "地", "一"]

    /// Words that stand before a name: who is asked, given or told something.
    static let beforeNames: Set<String> = ["是", "由", "和", "跟", "与", "给", "让", "找", "叫", "请", "问", "@"]

    /// Words that stand next to a name: who does what, and how people are addressed.
    static let nameNeighbours: Set<String> = ["是", "由", "和", "跟", "与", "给", "让", "找", "叫", "请", "问", "@", "负责", "说", "建议", "提出",
                                              "认为", "表示", "老师", "同学", "经理", "总", "你好", "您好", "那边", "这边", "也", "已经", "在"]

    /// Single characters the word breaker leaves alone in ordinary text, beyond Orra's grammar
    /// list: 好 in 你好, 下 in 一下, numbers and measure words, and common verbs.
    static let commonSingles: Set<Character> = Set("好下上中里外前后多少大小新老高低长短再先最更太只才刚正已将会能可该得着过们么啥呀哦嗯呃哈嘿喂零〇二两三四五六七八九十百千万亿第每各某本此其之而或但若如因所于以至自由并且即则年日号点分秒次位件条张份些放讲改换提别完供仅句章块哪设做写读算定开关")

    // MARK: Quoted

    static func quoted(in text: String) -> [(String, Int)] {
        var result: [(String, Int)] = []
        let pairs: [(Character, Character)] = [("《", "》"), ("「", "」"), ("“", "”")]
        let characters = Array(text)
        for (open, close) in pairs {
            var index = 0
            while index < characters.count {
                if characters[index] == open, let end = characters[(index + 1)...].firstIndex(of: close) {
                    let inner = String(characters[(index + 1)..<end])
                    if (2...12).contains(inner.count) { result.append((inner, index)) }
                    index = end + 1
                } else {
                    index += 1
                }
            }
        }
        return result
    }
}

/// Whether Orra gives the speech model names from the screen, see ScreenNames. Off until the
/// user turns it on in Settings.
nonisolated enum ScreenNamesPreference {
    static let defaultsKey = "usesScreenNames"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey, default: false)
    }

    static func save(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}
