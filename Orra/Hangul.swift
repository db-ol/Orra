import Foundation

/// Hangul, the script of Korean, for the checks that tell scripts apart. Each check keeps
/// the part of the script it always counted, so no verdict changes: RewriteGuard and
/// SpeechCheck count the syllables, and ProblemReport takes the whole script. LanguageGuard
/// counts Hangul among the other scripts that make a transcript foreign and has no range
/// of its own yet.
nonisolated enum Hangul {
    /// Whether the scalar is in the block of precomposed syllables, U+AC00 to U+D7AF, in
    /// which Korean is written. Jamo on their own, such as ㅋㅋ, are not.
    static func isSyllable(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7AF).contains(scalar.value)
    }

    /// The whole script as a property of NSRegularExpression: the syllables and the jamo
    /// of every block, compatibility and halfwidth ones too.
    static let scriptPattern = #"\p{Hangul}"#
}
