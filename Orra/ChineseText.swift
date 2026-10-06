import Foundation

/// Keeps Chinese output in simplified characters.
///
/// The public baseline saw a few outputs switch to traditional characters mid sentence.
/// The ICU transform "Traditional-Simplified" applied to a whole sentence also rewrites
/// valid simplified text (乾隆 becomes 干隆, 著书 becomes 着书). So only characters
/// outside GB2312, the simplified character set, are converted, one at a time. 後 and 於
/// are in GB2312 but are almost always traditional, so they are converted too. 噁 is left
/// alone, because ICU maps it to a rare character many fonts lack. Text that is mostly
/// English, by count of Chinese characters against words, is left alone, and so is
/// Japanese, which has kana.
nonisolated enum ChineseText {
    private static let gb2312 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_CN.rawValue))
    )
    private static let alwaysConverted: Set<Character> = ["後", "於"]
    private static let neverConverted: Set<Character> = ["噁"]

    static func simplified(_ text: String) -> String {
        guard isMostlyChinese(text) else { return text }
        var result = ""
        for character in text {
            let isTraditional = alwaysConverted.contains(character)
                || (String(character).data(using: gb2312) == nil && !neverConverted.contains(character))
            if isHan(character), isTraditional,
               let converted = String(character).applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) {
                result += converted
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// True when the text has Chinese characters, at least as many of them as words in
    /// other scripts, and no Japanese kana.
    static func isMostlyChinese(_ text: String) -> Bool {
        var chinese = 0
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if (0x3040...0x30FF).contains(scalar.value) {
                return false
            }
            if isHan(scalar) {
                chinese += 1
                inWord = false
            } else if scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                if !inWord {
                    words += 1
                    inWord = true
                }
            } else {
                inWord = false
            }
        }
        return chinese > 0 && chinese >= words
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: isHan)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF:
            true
        default:
            false
        }
    }
}
