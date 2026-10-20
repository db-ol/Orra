import Foundation

/// Warnings about who sent an email, found in code, so the user sees them even when the
/// model leaves them out:
/// - `lookalikeDomain`: a sender domain that looks like the domain of a person the user
///   works with, or of the user, without being it. Homoglyphs (a Cyrillic а for a Latin a,
///   0 for o, rn for m), a punycode label that spells one, letters of two scripts in one
///   label, another top level domain, the real domain as a part of a longer one
///   (harborlights.example.verify.example, pike-build-pay.example), and one or two letters
///   changed (harborlighs.example).
/// - `senderNameMismatch`: a display name that holds another address, or a known name, the
///   user's own included, on an address that person never used.
///
/// The phase 0 prototype (common.py, `sender_checks`) is the reference. Mail from one of
/// the user's own addresses gets no warning.
nonisolated enum SenderChecks {
    /// A person as the display name and the address of a mail header.
    nonisolated struct Person: Sendable, Equatable, Hashable {
        var name: String
        var address: String
    }

    nonisolated struct Input: Sendable, Equatable {
        /// The sender, with the display name of the From header.
        var sender: Person
        /// The people the user listed for any project and everyone the user exchanged mail
        /// with before. Their domains are guarded against lookalikes, and their names
        /// against use on another address.
        var people: [Person] = []
        /// The domains the user listed for projects. A new address at one of them is still
        /// the same organization, so a known name there gets no warning.
        var domains: [String] = []
        /// The user's own names and addresses.
        var own: [Person] = []
    }

    /// The warnings about the sender, in the order of `ProjectsWarning.allCases`.
    static func warnings(for input: Input) -> [ProjectsWarning] {
        let ownAddresses = Set(input.own.compactMap { address($0.address) })
        guard let sender = address(input.sender.address), !ownAddresses.contains(sender) else { return [] }
        var warnings: Set<ProjectsWarning> = []
        let guarded = Set((input.people + input.own).compactMap { address($0.address).map(domain) } + input.domains.map(normalizedDomain))
        if isLookalike(domain(sender), of: guarded.filter { !$0.isEmpty }) {
            warnings.insert(.lookalikeDomain)
        }
        if nameMismatches(input, sender: sender) {
            warnings.insert(.senderNameMismatch)
        }
        return ProjectsWarning.allCases.filter(warnings.contains)
    }

    // MARK: Domains

    /// Whether `domain` looks like one of the guarded domains without being it or a
    /// subdomain of it.
    static func isLookalike(_ domain: String, of guarded: Set<String>) -> Bool {
        let domain = normalizedDomain(domain)
        guard !domain.isEmpty else { return false }
        if guarded.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
            return false
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false).map(decodedLabel)
        if labels.contains(where: mixesScripts) {
            return true
        }
        let shape = skeleton(labels.joined(separator: "."))
        let name = registeredName(shape)
        for known in guarded {
            let knownShape = skeleton(known)
            if shape == knownShape {
                return true
            }
            let knownName = registeredName(knownShape)
            guard !name.isEmpty, !knownName.isEmpty else { continue }
            if knownName.count >= 5, holdsAsPart(name, knownName) {
                return true
            }
            if knownName.count >= 6, abs(name.count - knownName.count) <= 2 {
                let distance = editDistance(Array(name), Array(knownName))
                if distance <= (knownName.count >= 10 ? 2 : 1) {
                    return true
                }
            }
        }
        return false
    }

    /// The domain without the top level label, such as "pike-build" for
    /// pike-build.example. Empty for a domain of one label.
    private static func registeredName(_ domain: String) -> String {
        guard let dot = domain.lastIndex(of: ".") else { return "" }
        return String(domain[..<dot])
    }

    /// Whether `part` stands in `name` between dots, hyphens or the ends, as pike-build does
    /// in pike-build-pay, but not as harbor does in harborlights.
    private static func holdsAsPart(_ name: String, _ part: String) -> Bool {
        var start = name.startIndex
        while let found = name.range(of: part, range: start..<name.endIndex) {
            let before = found.lowerBound == name.startIndex ? nil : name[name.index(before: found.lowerBound)]
            let after = found.upperBound == name.endIndex ? nil : name[found.upperBound]
            if (before == nil || before == "." || before == "-") && (after == nil || after == "." || after == "-") {
                return true
            }
            start = name.index(after: found.lowerBound)
        }
        return false
    }

    /// Whether a label holds ASCII letters and letters of another script that pass for
    /// Latin ones, such as the Cyrillic а in shаnlan.
    private static func mixesScripts(_ label: String) -> Bool {
        let scalars = label.unicodeScalars
        return scalars.contains { $0.isASCII && $0.properties.isAlphabetic }
            && scalars.contains { !$0.isASCII && confusables[$0] != nil }
    }

    /// The form two domains that look alike share: compatibility forms made plain,
    /// lowercase, letters of other scripts that pass for Latin ones made Latin, 0 as o,
    /// 1 and i as l, rn as m and vv as w.
    private static func skeleton(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            scalars.append(confusables[scalar] ?? scalar)
        }
        return String(scalars)
            .replacingOccurrences(of: "rn", with: "m")
            .replacingOccurrences(of: "vv", with: "w")
    }

    /// Letters and digits that pass for Latin letters, with the letter they pass for.
    private static let confusables: [Unicode.Scalar: Unicode.Scalar] = [
        // Cyrillic
        "а": "a", "в": "b", "е": "e", "ё": "e", "һ": "h", "і": "l", "ї": "l", "ј": "j", "к": "k",
        "ӏ": "l", "м": "m", "н": "h", "о": "o", "р": "p", "ԛ": "q", "с": "c", "ѕ": "s", "т": "t",
        "у": "y", "ԝ": "w", "х": "x", "ԁ": "d", "ү": "y",
        // Greek
        "α": "a", "β": "b", "ε": "e", "η": "n", "ι": "l", "κ": "k", "ν": "v", "ο": "o", "ρ": "p",
        "τ": "t", "υ": "u", "χ": "x", "ω": "w",
        // Latin letters and digits
        "ı": "l", "ɡ": "g", "ɩ": "l", "i": "l", "1": "l", "0": "o",
    ]

    /// A domain as the checks compare it: trimmed, lowercased, in its composed form and
    /// without a dot at the end.
    private static func normalizedDomain(_ domain: String) -> String {
        var domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping
        while domain.hasSuffix(".") {
            domain.removeLast()
        }
        return domain
    }

    /// The label with a punycode label ("xn--…") decoded, or the label as it is when it is
    /// not one or does not decode.
    private static func decodedLabel(_ label: Substring) -> String {
        guard label.hasPrefix("xn--"), let decoded = punycodeDecoded(label.dropFirst(4)) else { return String(label) }
        return decoded
    }

    /// RFC 3492 decoding of a label without its "xn--" prefix, or nil when it is not valid
    /// punycode or longer than a label may be.
    private static func punycodeDecoded(_ encoded: Substring) -> String? {
        let base = 36, tMin = 1, tMax = 26
        guard !encoded.isEmpty, encoded.count <= 63, encoded.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        var output: [Unicode.Scalar] = []
        var input = Array(encoded.unicodeScalars)
        if let delimiter = input.lastIndex(of: "-") {
            output = Array(input[..<delimiter])
            input = Array(input[(delimiter + 1)...])
        }
        var code = 128
        var position = 0
        var bias = 72
        var index = 0
        while index < input.count {
            let start = position
            var weight = 1
            var k = base
            while true {
                guard index < input.count, let digit = punycodeDigit(input[index]) else { return nil }
                index += 1
                let (step, overflow) = digit.multipliedReportingOverflow(by: weight)
                guard !overflow, position <= Int(Int32.max) - step else { return nil }
                position += step
                let threshold = k <= bias ? tMin : min(k - bias, tMax)
                if digit < threshold { break }
                weight *= base - threshold
                guard weight <= Int(Int32.max) else { return nil }
                k += base
            }
            let count = output.count + 1
            bias = punycodeBias(position - start, count: count, first: start == 0)
            code += position / count
            position %= count
            guard let scalar = Unicode.Scalar(UInt32(clamping: code)), code < 0x110000 else { return nil }
            output.insert(scalar, at: position)
            position += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func punycodeDigit(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x61...0x7A: Int(scalar.value) - 0x61
        case 0x41...0x5A: Int(scalar.value) - 0x41
        case 0x30...0x39: Int(scalar.value) - 0x30 + 26
        default: nil
        }
    }

    private static func punycodeBias(_ delta: Int, count: Int, first: Bool) -> Int {
        var delta = first ? delta / 700 : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((36 - 1) * 26) / 2 {
            delta /= 36 - 1
            k += 36
        }
        return k + (36 * delta) / (delta + 38)
    }

    // MARK: Names

    /// Whether the display name holds an address other than the sender's, or names a known
    /// person, or the user, on an address that person never used.
    private static func nameMismatches(_ input: Input, sender: String) -> Bool {
        let name = input.sender.name
        for match in addressPattern.matches(in: name, range: NSRange(name.startIndex..., in: name)) {
            if let range = Range(match.range, in: name), let shown = address(String(name[range])), shown != sender {
                return true
            }
        }
        let forms = Set(nameForms(name))
        guard !forms.isEmpty else { return false }
        let addresses = (input.people + input.own)
            .filter { !forms.isDisjoint(with: nameForms($0.name)) }
            .compactMap { address($0.address) }
        guard !addresses.isEmpty, !addresses.contains(sender) else { return false }
        let senderDomain = domain(sender)
        let sameOrganization = input.domains.map(normalizedDomain).contains(senderDomain)
            && addresses.contains { domain($0) == senderDomain }
        return !sameOrganization
    }

    /// The forms a person's name is compared in: the whole name, and its Chinese and Latin
    /// parts on their own, so 卢安琪 Amy Lu matches both 卢安琪 and Amy Lu.
    ///
    /// Everything is in compatibility form, lowercase, without quotes, format characters
    /// or text in brackets, with one space between words and none between Chinese
    /// characters. A Chinese part needs two characters and a Latin part two words, so a
    /// lone given name such as Lin never stands for a person. An address is no name.
    static func nameForms(_ name: String) -> [String] {
        var text = SortingText.withoutFormatCharacters(name.precomposedStringWithCompatibilityMapping).lowercased()
        text = bracketed.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        text = String(text.map { "\"'“”‘’`".contains($0) ? " " : $0 })
        let words = text.split(whereSeparator: \.isWhitespace)
        var whole = ""
        for word in words {
            if let last = whole.last, let first = word.first, !(last.isHan && first.isHan) {
                whole.append(" ")
            }
            whole += word
        }
        guard !whole.isEmpty, !whole.contains("@") else { return [] }
        var forms = [whole]
        var hanRun = ""
        var hanRuns: [String] = []
        for character in whole {
            if character.isHan {
                hanRun.append(character)
            } else if !hanRun.isEmpty {
                hanRuns.append(hanRun)
                hanRun = ""
            }
        }
        if !hanRun.isEmpty {
            hanRuns.append(hanRun)
        }
        forms += hanRuns.filter { $0.count >= 2 }
        let latin = whole.filter { !$0.isHan }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if latin.split(separator: " ").count >= 2 {
            forms.append(latin)
        }
        var seen: Set<String> = []
        return forms.filter { seen.insert($0).inserted }
    }

    /// Where a name or an address stands in the text, ignoring case and width. A term that
    /// starts or ends with a Latin letter or digit is not found inside a longer word, so
    /// Amy Lu is not found in Amy Luna, and Lin not in online.
    static func occurrences(of term: String, in text: String) -> [Range<String.Index>] {
        guard !term.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: term, options: [.caseInsensitive, .widthInsensitive], range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let cutBefore = term.first?.isASCIILetterOrDigit == true && before?.isASCIILetterOrDigit == true
            let cutAfter = term.last?.isASCIILetterOrDigit == true && after?.isASCIILetterOrDigit == true
            if !cutBefore, !cutAfter {
                found.append(range)
            }
            start = range.upperBound
        }
        return found
    }

    /// An address in the lowercase local@domain form, or nil.
    private static func address(_ text: String) -> String? {
        ProjectsAddress.normalized(text)
    }

    private static func domain(_ address: String) -> String {
        address.split(separator: "@").last.map(String.init) ?? ""
    }

    /// Something that looks like an address inside a display name.
    private static let addressPattern = try! NSRegularExpression(pattern: #"[^\s<>()\[\]"'“”‘’,;:]+@[^\s<>()\[\]"'“”‘’,;:]+\.[^\s<>()\[\]"'“”‘’,;:]+"#)

    /// Text in round, square or full width brackets, such as the company after a name.
    private static let bracketed = try! NSRegularExpression(pattern: #"[(\[（【][^)\]）】]*[)\]）】]"#)
}
