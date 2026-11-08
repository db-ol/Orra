import Foundation
@testable import Orra

/// The filler and number rules as PushToTalkController runs them with both switches on, as
/// by default, before the word replacement step. For the evaluations that stand in for a
/// dictation without the controller, so their ruled text is what a dictation pastes.
enum DictationRules {
    /// Texts that the rules of the dictation languages treat apart, for the tests that
    /// check a path runs the rules as a dictation does.
    static let samples = [
        "Um、明日の会議は三時です。", "Uh, la reunión es mañana.", "Um, okay.", "呃，我们下午两点开会。",
        "Um, let's meet at two.", "呃，um，我们走吧。", "내일 um 회의가 있어요.",
        "¡Uh! Se me olvidó la llave.", "El Sr. Um llegó tarde.",
    ]

    static func ruled(_ text: String, for language: DictationLanguage) -> String {
        let rules = LanguageGuard.rules(for: text, language: language)
        var ruled = text
        if rules.englishFillers {
            ruled = FillerRules.removingFillers(from: ruled, englishOnly: !rules.chineseAndEnglish)
        }
        if rules.chineseAndEnglish {
            ruled = NumberRules.writingNumbersAsDigits(in: ruled)
        }
        return ruled
    }
}
