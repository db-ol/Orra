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
    static let both = SpokenLanguages(adding: [.spanish, .japanese])

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

    @Test func aLanguageTheUserAddedIsNotForeign() {
        let spanish = SpokenLanguages(adding: [.spanish])
        let japanese = SpokenLanguages(adding: [.japanese])
        #expect(LanguageGuard.isForeign(Self.spanish))
        #expect(!LanguageGuard.isForeign(Self.spanish, speaking: spanish))
        #expect(LanguageGuard.isForeign(Self.spanish, speaking: japanese))
        #expect(!LanguageGuard.isForeign(Self.japanese, speaking: japanese))
        #expect(LanguageGuard.isForeign(Self.japanese, speaking: spanish))
        // 々 is written with Han characters and counts as Japanese.
        #expect(!LanguageGuard.isForeign("人々は様々な意見を持っている。", speaking: japanese))
        #expect(LanguageGuard.verdict(on: Self.spanish, speaking: Self.both) == .added(.spanish))
        #expect(LanguageGuard.verdict(on: Self.japanese, speaking: Self.both) == .added(.japanese))
        #expect(LanguageGuard.addedLanguage(of: Self.spanish, speaking: Self.both) == .spanish)
        #expect(LanguageGuard.addedLanguage(of: Self.japanese, speaking: Self.both) == .japanese)
        #expect(LanguageGuard.addedLanguage(of: Self.spanish, speaking: .chineseAndEnglish) == nil)
    }

    /// Spanish must not let its neighbors through, nor the Swedish of the Mandarin clip.
    @Test func otherLanguagesStayForeignWithBothAdded() {
        for text in [
            Self.swedish,
            "Este é um jantar simples com pão e azeite que comemos à noite com a família.",
            "Aquest és un sopar senzill amb pa i oli d'oliva que mengem a la nit amb la família.",
            "Questa è una cena semplice con pane e olio d'oliva che mangiamo la sera con la famiglia.",
            "Internet une et mélange composants propres de la communication massive et entre personnes.",
            "Das ist ein einfaches Abendessen mit Brot und Olivenöl.",
            "빵과 올리브 오일로 만든 간단한 저녁입니다.",
            "Это простой ужин с хлебом и оливковым маслом.",
        ] {
            #expect(LanguageGuard.verdict(on: text, speaking: Self.both) == .foreign)
        }
    }

    @Test func chineseAndEnglishReadTheSameWithBothAdded() {
        for text in [
            Self.chinese, Self.english, "其实呢，badminton有一个就是badminton，因为basketball的话，主要是。",
            "I met José and François at the café in São Paulo yesterday.", "",
            // A kana in Chinese text, and Japanese in Han characters only, read as before.
            "我们去了小确幸の店，买了三本书。", "東京大学",
        ] {
            #expect(LanguageGuard.verdict(on: text, speaking: Self.both) == .chineseOrEnglish)
            #expect(LanguageGuard.addedLanguage(of: text, speaking: Self.both) == nil)
        }
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

    @Test func aLanguageTheUserAddedIsTranscribedOnce() async throws {
        speech.reply = Self.spanish
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1, languages: SpokenLanguages(adding: [.spanish]))
        #expect(text == Self.spanish)
        #expect(speech.receivedLanguages == [nil])
    }

    /// The model kept Spanish with Chinese as the language, which stands for a user who
    /// speaks it, instead of the English pass that would translate it.
    @Test func aPassInALanguageTheUserAddedStands() async throws {
        speech.reply = Self.swedish
        speech.replyInLanguage = [.chinese: Self.spanish, .english: Self.english]
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1, languages: SpokenLanguages(adding: [.spanish]))
        #expect(text == Self.spanish)
        #expect(speech.receivedLanguages == [nil, .chinese])
    }

    @Test func theAddedLanguagesArePassesAfterChineseAndEnglish() async throws {
        speech.reply = Self.swedish
        speech.replyInLanguage = [.japanese: Self.japanese]
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1, languages: Self.both)
        #expect(text == Self.japanese)
        #expect(speech.receivedLanguages == [nil, .chinese, .english, .spanish, .japanese])
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
