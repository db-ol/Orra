import Foundation
@testable import Orra

/// The filler and number rules as PushToTalkController runs them with both switches on, as
/// by default, before the word replacement step. For the evaluations that stand in for a
/// dictation without the controller, so their ruled text is what a dictation pastes.
enum DictationRules {
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
