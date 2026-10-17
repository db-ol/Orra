import Foundation

/// Character classes the text rules share.
nonisolated extension Character {
    /// Whether every scalar is a Chinese character in U+3400...U+9FFF or U+F900...U+FAFF,
    /// which leaves out the characters of the supplementary planes.
    var isHan: Bool {
        unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    /// Whether any scalar is a Chinese character, those of the supplementary planes
    /// included, see `ChineseText.isHan(_:)`.
    var containsHan: Bool {
        unicodeScalars.contains(where: ChineseText.isHan)
    }

    var isASCIILetter: Bool {
        isASCII && isLetter
    }

    var isASCIILetterOrDigit: Bool {
        isASCII && (isLetter || isNumber)
    }
}
