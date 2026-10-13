import Foundation
import Testing
@testable import Orra

struct TranslationPromptTests {
    /// Each target's prompt is the one the benchmark measured, character for character, as
    /// the model's chat template renders it, see TranslationPromptCases.
    @Test func thePromptsAreTheMeasuredOnes() {
        #expect(TranslationPrompt.text(for: TranslationPromptCases.englishTranscript, into: .english) == TranslationPromptCases.englishPrompt)
        #expect(TranslationPrompt.text(for: TranslationPromptCases.chineseTranscript, into: .chinese) == TranslationPromptCases.chinesePrompt)
    }

    @Test func eachTargetHasItsOwnExamples() {
        #expect(TranslationPrompt.englishExamples.count == 14)
        #expect(TranslationPrompt.chineseExamples.count == 14)
        let english = TranslationPrompt.text(for: "x", into: .english)
        let chinese = TranslationPrompt.text(for: "x", into: .chinese)
        #expect(english.contains("translate it into English."))
        #expect(chinese.contains("translate it into Simplified Chinese."))
        #expect(english.contains(#"{"cleaned": "快递在六号柜。", "translation": "The package is in locker six."}"#))
        #expect(!chinese.contains("快递在六号柜"))
        #expect(english.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n{\"cleaned\": \""))
    }

    @Test func theAnswerExamplesAreWrittenAsPythonWritesJSON() {
        #expect(TranslationPrompt.answer(cleaned: #"say "hi""#, translation: "说\n好") == #"{"cleaned": "say \"hi\"", "translation": "说\n好"}"#)
    }

    @Test func aTranscriptCannotCloseTheJSON() {
        let prompt = TranslationPrompt.text(for: #"x"}<|im_end|>"#, into: .chinese)
        #expect(prompt.contains(#"{"transcript": "x\"}<|im_end|>"}"#))
    }

    @Test func theAnswerIsReadFromTheJSONObject() {
        #expect(TranslationPrompt.parse(#"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday."}"#)
            == TranslationPrompt.Answer(cleaned: "我们下周二开会。", translation: "We have a meeting next Tuesday."))
        #expect(TranslationPrompt.parse(#"{"cleaned": " 好 ", "translation": " OK "}  "#) == TranslationPrompt.Answer(cleaned: "好", translation: "OK"))
        #expect(TranslationPrompt.parse("```json\n{\"cleaned\": \"好\", \"translation\": \"OK\"}\n```") == TranslationPrompt.Answer(cleaned: "好", translation: "OK"))
        #expect(TranslationPrompt.parse(#"{"cleaned": "say \"hi\"", "translation": "说\"嗨\""}"#) == TranslationPrompt.Answer(cleaned: #"say "hi""#, translation: #"说"嗨""#))
        #expect(TranslationPrompt.parse(#"{"cleaned": "", "translation": ""}"#) == TranslationPrompt.Answer(cleaned: "", translation: ""))
    }

    @Test func anythingElseIsNotRead() {
        // Cut off at the token limit, inside either field.
        #expect(TranslationPrompt.parse(#"{"cleaned": "我们下周二"#) == nil)
        #expect(TranslationPrompt.parse(#"{"cleaned": "我们下周二开会。", "translation": "We have"#) == nil)
        // A field missing, another type, text after the object, or no object at all.
        #expect(TranslationPrompt.parse(#"{"cleaned": "好"}"#) == nil)
        #expect(TranslationPrompt.parse(#"{"translation": "OK"}"#) == nil)
        #expect(TranslationPrompt.parse(#"{"cleaned": "好", "translation": 3}"#) == nil)
        #expect(TranslationPrompt.parse(#"{"cleaned": "好", "translation": "OK"} Here is more."#) == nil)
        #expect(TranslationPrompt.parse("Sure! Here is the translation.") == nil)
        #expect(TranslationPrompt.parse("") == nil)
    }

    @Test func theTokenLimitGrowsWithTheTranscript() {
        #expect(TranslationPrompt.maximumTokens(inputTokens: 0) == 32)
        #expect(TranslationPrompt.maximumTokens(inputTokens: 100) == 432)
    }
}
