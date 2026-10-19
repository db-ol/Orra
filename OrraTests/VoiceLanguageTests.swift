#if canImport(Qwen3TTS)
import Foundation
import Qwen3TTS
import Testing
@testable import Orra

/// Every target of translation has a language tag Qwen3-TTS knows, so a Japanese or
/// Spanish translation is spoken in its language and never falls back to another.
/// CosyVoice3 reads the language from the text.
struct VoiceLanguageTests {
    @Test func everyTargetHasATagTheVoiceModelKnows() {
        for target in TranslationTarget.allCases {
            #expect(CodecTokens.languageId(for: target.voiceTag) != nil, "\(target)")
        }
        #expect(CodecTokens.languageId(for: TranslationTarget.japanese.voiceTag) == CodecTokens.languageJapanese)
        #expect(CodecTokens.languageId(for: TranslationTarget.spanish.voiceTag) == CodecTokens.languageSpanish)
        #expect(SpeechLanguage(.japanese) == .japanese)
        #expect(SpeechLanguage(.spanish) == .spanish)
    }
}
#endif
