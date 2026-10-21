import Foundation
import Testing
@testable import Orra

@MainActor
struct LanguageGuardTests {
    let speech = FakeSpeech()
    /// What the model wrote for a Mandarin clip of the speech corpus that starts with a
    /// Catalan dish name.
    static let swedish = "Pan om ol är en typ av enkelt och lätt måltid som är populär i sommar. Det består av bröd med olivolja, tomat och några andra ingredienser."
    static let chinese = "Pa amb Oli 是一种在夏天尤为流行的简单晚餐。"
    static let english = "Pa amb Oli is a simple dinner that is popular in summer."
    /// Short enough for the length a short test recording allows, see TranscriptGuard.
    static let spanish = "No, mañana tenemos una reunión con el equipo de ventas."
    static let japanese = "これはパンとオリーブオイルの簡単な夕食です。"
    /// Japanese in Han characters only, as the model writes some short sentences. Han
    /// characters alone cannot tell it from Chinese.
    static let japaneseInHan = "東京駅"

    @Test func chineseEnglishAndTheirMixAreNotForeign() {
        #expect(!LanguageGuard.isForeign(Self.chinese))
        #expect(!LanguageGuard.isForeign(Self.english))
        #expect(!LanguageGuard.isForeign("其实呢，badminton有一个就是badminton，因为basketball的话，主要是。"))
        #expect(!LanguageGuard.isForeign("我们去了 Göteborg 和 Malmö 玩了三天。"))
        // Cantonese is written in Han characters and counts as Chinese.
        #expect(!LanguageGuard.isForeign("我哋今日去咗飲茶，啲點心好好食。"))
        #expect(!LanguageGuard.isForeign("Since the foundation of Asunción in 1537, Paraguay has managed to keep a lot of its indigenous character."))
        #expect(!LanguageGuard.isForeign("I met José and François at the café in São Paulo yesterday."))
        #expect(!LanguageGuard.isForeign("Uh, I live in Hang Ho."))
        #expect(!LanguageGuard.isForeign(""))
        #expect(!LanguageGuard.isForeign("2026。"))
    }

    @Test func otherLanguagesAreForeign() {
        #expect(LanguageGuard.isForeign(Self.swedish))
        #expect(LanguageGuard.isForeign("Ini adalah makan malam sederhana dengan roti dan minyak zaitun."))
        #expect(LanguageGuard.isForeign("Das ist ein einfaches Abendessen mit Brot und Olivenöl."))
        #expect(LanguageGuard.isForeign("これはパンとオリーブオイルの簡単な夕食です。"))
        #expect(LanguageGuard.isForeign("빵과 올리브 오일로 만든 간단한 저녁입니다."))
        #expect(LanguageGuard.isForeign("Это простой ужин с хлебом и оливковым маслом."))
    }

    /// With Japanese chosen, kana and Han characters are Japanese, also mixed with English,
    /// and Latin text is English or foreign as for Chinese.
    @Test func japaneseTakesKanaHanCharactersAndEnglish() {
        for text in [
            Self.japanese, Self.japaneseInHan, "人々は様々な意見を持っている。", "このmeetingは明日の十時からです。",
            // Chinese cannot be told from Japanese in Han characters, so it is taken as Japanese.
            "我们明天开会。", "其实呢，badminton有一个就是badminton，因为basketball的话，主要是。",
        ] {
            #expect(LanguageGuard.verdict(on: text, for: .japanese) == .japanese, "\(text)")
        }
        for text in [Self.english, "OK.", "Uh, I live in Hang Ho.", "I met José and François at the café in São Paulo yesterday.", "", "2026。"] {
            #expect(LanguageGuard.verdict(on: text, for: .japanese) == .chineseOrEnglish, "\(text)")
        }
        for text in [Self.swedish, Self.spanish, "빵과 올리브 오일로 만든 간단한 저녁입니다.", "Это простой ужин с хлебом и оливковым маслом."] {
            #expect(LanguageGuard.isForeign(text, for: .japanese), "\(text)")
        }
    }

    /// With Spanish chosen, Latin text is Spanish when NLLanguageRecognizer finds Spanish
    /// the most likely, English, or foreign. Han characters and kana are foreign, and Latin
    /// text too short to judge counts as Spanish.
    @Test func spanishTakesSpanishAndEnglish() {
        for text in [Self.spanish, "Mañana vamos a la playa con mis amigos y después comemos paella.", "Hola, ¿qué tal?", ""] {
            #expect(LanguageGuard.verdict(on: text, for: .spanish) == .spanish, "\(text)")
        }
        for text in [Self.english, "Since the foundation of Asunción in 1537, Paraguay has managed to keep a lot of its indigenous character."] {
            #expect(LanguageGuard.verdict(on: text, for: .spanish) == .chineseOrEnglish, "\(text)")
        }
        // Its neighbors, the Swedish of the Mandarin clip, Chinese and Japanese stay foreign.
        for text in [
            Self.swedish, Self.chinese, Self.japanese, Self.japaneseInHan, "我们明天开会。",
            "Este é um jantar simples com pão e azeite que comemos à noite com a família.",
            "Aquest és un sopar senzill amb pa i oli d'oliva que mengem a la nit amb la família.",
            "Questa è una cena semplice con pane e olio d'oliva che mangiamo la sera con la famiglia.",
            "Internet une et mélange composants propres de la communication massive et entre personnes.",
            "Das ist ein einfaches Abendessen mit Brot und Olivenöl.",
            "Это простой ужин с хлебом и оливковым маслом.",
        ] {
            #expect(LanguageGuard.isForeign(text, for: .spanish), "\(text)")
        }
    }

    /// Chinese reads every text as before the choice, so Japanese and Spanish stay foreign.
    @Test func chineseReadsAsBeforeTheChoice() {
        #expect(LanguageGuard.isForeign(Self.spanish))
        #expect(LanguageGuard.isForeign(Self.japanese))
        #expect(LanguageGuard.verdict(on: Self.japaneseInHan) == .chineseOrEnglish)
        #expect(LanguageGuard.verdict(on: Self.chinese, for: .chinese) == .chineseOrEnglish)
        #expect(LanguageGuard.verdict(on: Self.swedish, for: .chinese) == .foreign)
    }

    /// The rules and the cleanup model take every text with Chinese chosen, and English
    /// only with Japanese or Spanish.
    @Test func onlyEnglishTakesTheStepsOfAnotherDictationLanguage() {
        for text in [Self.chinese, Self.english, Self.japanese, Self.spanish, Self.swedish] {
            #expect(LanguageGuard.takesChineseAndEnglishSteps(text, for: .chinese))
        }
        #expect(LanguageGuard.takesChineseAndEnglishSteps(Self.english, for: .japanese))
        #expect(LanguageGuard.takesChineseAndEnglishSteps(Self.english, for: .spanish))
        for text in [Self.japanese, Self.japaneseInHan, Self.swedish] {
            #expect(!LanguageGuard.takesChineseAndEnglishSteps(text, for: .japanese), "\(text)")
        }
        for text in [Self.spanish, "Hola, ¿qué tal?", Self.chinese] {
            #expect(!LanguageGuard.takesChineseAndEnglishSteps(text, for: .spanish), "\(text)")
        }
    }

    /// Captions keep text in any of the four languages, whatever the dictation language,
    /// and take a fifth language, in Latin letters or another script, for foreign.
    @Test func captionsTakeOnlyAFifthLanguageForForeign() {
        for text in [Self.chinese, Self.english, Self.japanese, Self.japaneseInHan, Self.spanish, "我哋今日去咗飲茶，啲點心好好食。", "このPRをreviewしてください。", "Hola, ¿qué tal?", "OK", ""] {
            #expect(!LanguageGuard.isForeignToCaptions(text), "\(text)")
        }
        for text in [Self.swedish, "Das ist ein einfaches Abendessen mit Brot und Olivenöl.", "빵과 올리브 오일로 만든 간단한 저녁입니다.", "Это простой ужин с хлебом и оливковым маслом."] {
            #expect(LanguageGuard.isForeignToCaptions(text), "\(text)")
        }
    }

    /// A caption in Japanese or Spanish keeps its first pass for a user who dictates in
    /// Chinese, where a dictation is transcribed again. A fifth language gets the passes of
    /// the dictation language, as a dictation does.
    @Test func captionsInAnyOfTheFourLanguagesAreTranscribedOnce() async throws {
        for text in [Self.japanese, Self.spanish, Self.chinese, Self.english] {
            speech.reply = text
            #expect(try await speech.transcription.transcribeCaption([0.1], language: .chinese) == text)
        }
        #expect(speech.receivedLanguages == [nil, nil, nil, nil])
        #expect(speech.receivedContexts == [nil, nil, nil, nil])
        speech.reply = Self.chinese
        #expect(try await speech.transcription.transcribeCaption([0.1], language: .spanish) == Self.chinese)
        #expect(speech.receivedLanguages.count == 5)
        // A dictation of the same text in Chinese still asks for Chinese, then English.
        speech.reply = Self.japanese
        _ = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1)
        #expect(Array(speech.receivedLanguages.dropFirst(5)) == [nil, .chinese, .english])
    }

    @Test func aFifthLanguageInACaptionGetsThePassesOfTheDictationLanguage() async throws {
        speech.reply = Self.swedish
        speech.replyInLanguage = [.japanese: Self.japanese, .chinese: Self.chinese]
        #expect(try await speech.transcription.transcribeCaption([0.1], language: .japanese) == Self.japanese)
        #expect(speech.receivedLanguages == [nil, .japanese])
        // No pass helps: the first text stands.
        speech.replyInLanguage = [:]
        #expect(try await speech.transcription.transcribeCaption([0.1], language: .spanish) == Self.swedish)
        #expect(speech.receivedLanguages == [nil, .japanese, nil, .spanish, .english])
    }

    @Test func chineseOrEnglishTextIsTranscribedOnce() async throws {
        speech.reply = Self.chinese
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1)
        #expect(text == Self.chinese)
        #expect(speech.receivedLanguages == [nil])
    }

    @Test func aThirdLanguageIsTranscribedAgainInChinese() async throws {
        speech.reply = Self.swedish
        speech.replyInLanguage = [.chinese: Self.chinese, .english: Self.english]
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1)
        #expect(text == Self.chinese)
        #expect(speech.receivedLanguages == [nil, .chinese])
        #expect(speech.receivedContexts == [nil, nil])
    }

    @Test func englishIsTriedWhenChineseDoesNotHelp() async throws {
        speech.reply = Self.swedish
        speech.replyInLanguage = [.chinese: Self.swedish, .english: Self.english]
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1)
        #expect(text == Self.english)
        #expect(speech.receivedLanguages == [nil, .chinese, .english])
    }

    @Test func textInTheDictationLanguageIsTranscribedOnce() async throws {
        speech.reply = Self.japanese
        #expect(try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1, language: .japanese) == Self.japanese)
        speech.reply = Self.spanish
        #expect(try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1, language: .spanish) == Self.spanish)
        #expect(speech.receivedLanguages == [nil, nil])
    }

    /// Japanese in Han characters only is kept as Japanese, with no other pass.
    @Test func japaneseInHanCharactersOnlyIsKept() async throws {
        speech.reply = Self.japaneseInHan
        speech.replyInLanguage = [.japanese: Self.japanese, .english: "Tokyo Station"]
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1, language: .japanese)
        #expect(text == Self.japaneseInHan)
        #expect(speech.receivedLanguages == [nil])
    }

    /// Chinese output for a user who dictates in Spanish goes to the pass in Spanish first.
    @Test func chineseForASpanishSpeakerIsTranscribedAgainInSpanish() async throws {
        speech.reply = "不，明天我们和销售团队开会。"
        speech.replyInLanguage = [.spanish: Self.spanish, .english: Self.english]
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1, language: .spanish)
        #expect(text == Self.spanish)
        #expect(speech.receivedLanguages == [nil, .spanish])
    }

    /// The passes are the dictation language, then English. Chinese is never asked for.
    @Test func thePassesAreTheDictationLanguageThenEnglish() async throws {
        speech.reply = Self.swedish
        let japanese = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1, language: .japanese)
        #expect(japanese == Self.swedish)
        #expect(speech.receivedLanguages == [nil, .japanese, .english])
        speech.replyInLanguage = [.spanish: Self.swedish, .english: Self.english]
        let spanish = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1, language: .spanish)
        #expect(spanish == Self.english)
        #expect(speech.receivedLanguages == [nil, .japanese, .english, nil, .spanish, .english])
    }

    @Test func anEmptyPassDoesNotReplaceTheText() async throws {
        speech.reply = Self.swedish
        speech.replyInLanguage = [.chinese: " ", .english: Self.english]
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1)
        #expect(text == Self.english)
    }

    @Test func theTextStandsWhenNoPassHelps() async throws {
        speech.reply = Self.swedish
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1)
        #expect(text == Self.swedish)
        #expect(speech.receivedLanguages == [nil, .chinese, .english])
    }

    @Test func theVocabularyStaysOnTheSecondPass() async throws {
        speech.reply = Self.swedish
        speech.replyInLanguage = [.chinese: Self.chinese]
        let text = try await speech.transcription.transcribe([0.1], vocabulary: ["Pa amb Oli", "Orra"], audioSeconds: 1)
        #expect(text == Self.chinese)
        #expect(speech.receivedContexts == ["Pa amb Oli\nOrra", "Pa amb Oli\nOrra"])
    }

    @Test func aFailedPassKeepsTheText() async throws {
        let failing = Transcription(
            load: {},
            transcribe: { _, _, language in
                if language != nil { throw TestError() }
                return Self.swedish
            }
        )
        let text = try await failing.transcribe([0.1], vocabulary: [], audioSeconds: 1)
        #expect(text == Self.swedish)
    }

    @Test func cancellationIsNotSwallowed() async {
        let cancelled = Transcription(
            load: {},
            transcribe: { _, _, language in
                if language != nil { throw CancellationError() }
                return Self.swedish
            }
        )
        await #expect(throws: CancellationError.self) {
            try await cancelled.transcribe([0.1], vocabulary: [], audioSeconds: 1)
        }
    }

    @Test func anEchoOfTheVocabularyIsCheckedOnTheTextInChinese() async throws {
        // The Chinese pass gives only the term, and the pass without the vocabulary
        // hears nothing, so it was an echo.
        speech.reply = Self.swedish
        speech.replyInLanguage = [.chinese: "Pa amb Oli。"]
        speech.replyWithoutContext = ""
        let text = try await speech.transcription.transcribe([0.1], vocabulary: ["Pa amb Oli"], audioSeconds: 1)
        #expect(text == "")
        #expect(speech.receivedLanguages == [nil, .chinese, nil])
    }
}
