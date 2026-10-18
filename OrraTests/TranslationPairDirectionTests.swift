import Foundation
import Testing
@testable import Orra

/// The direction of translation for a user who dictates in Japanese or Spanish: English
/// goes into that language, and everything else into English. Chinese keeps its rule, see
/// TranslationDirectionTests.
struct TranslationPairDirectionTests {
    /// Texts written by hand for these tests, each with the target Automatic gives it: en,
    /// the dictation language, or none when there is nothing to translate. None repeats an
    /// evaluation case.
    static let japanese: [(String, String?)] = [
        // Kana only.
        ("はい", "en"), ("うん、いいよ", "en"), ("ありがとう", "en"), ("そうなんだ", "en"), ("おはようございます", "en"),
        ("いってきます", "en"), ("ちょっとまってね", "en"), ("すごいね！", "en"), ("だいじょうぶです", "en"),
        ("カレーにしよう", "en"), ("コーヒーのみたい", "en"), ("おつかれさま", "en"), ("ええ、そうです", "en"),
        ("いいえ、ちがいます", "en"), ("もしもし", "en"), ("ごめんね", "en"),
        // Han characters only, which Chinese shares.
        ("了解", "en"), ("承知", "en"), ("会議中", "en"), ("本日休業", "en"), ("東京駅", "en"), ("新製品発表会", "en"),
        ("来週月曜日", "en"), ("予算超過", "en"), ("我们明天开会", "en"), ("这个问题很复杂", "en"),
        // Japanese with English words.
        ("このPRをmergeしてください", "en"), ("明日のmeetingは10時からです", "en"), ("Slackで送っておきます", "en"),
        ("iPhoneの充電が切れそう", "en"), ("OKです", "en"), ("Zoomのリンクを共有します", "en"),
        ("ExcelのファイルをGoogle Driveに上げました", "en"), ("deadlineは金曜日です", "en"),
        ("AIの使い方について話しましょう", "en"), ("ちょっとbusyなので後で連絡します", "en"), ("ＰＲは見ました", "en"),
        ("Emilyさんに確認します", "en"), ("今日はWFHです", "en"), ("新しいMacBookを買いました", "en"),
        // Sentences.
        ("昨日の資料、もう一度送ってもらえますか？", "en"), ("お先に失礼します", "en"), ("大丈夫ですか？", "en"),
        ("Wi-Fiのパスワードを教えてください", "en"), ("来週の火曜日は空いていますか", "en"), ("駅前のカフェで待っています", "en"),
        ("来月から新しいプロジェクトが始まります", "en"), ("先に帰ってもいいですか", "en"), ("田中さん、ちょっといいですか", "en"),
        // English, with Japanese names and places.
        ("Send it to 田中さん by Friday.", "ja"), ("Thanks, 山田さん", "ja"), ("Let's meet at 渋谷駅 at 3.", "ja"),
        ("I'll be in Osaka next week.", "ja"), ("Please call Suzuki-san tomorrow.", "ja"), ("Can you check the report?", "ja"),
        ("See you tomorrow!", "ja"), ("Sounds good.", "ja"), ("Thanks!", "ja"), ("OK", "ja"), ("Sure.", "ja"),
        ("I think 佐藤部長 will join the call.", "ja"), ("We're flying from Narita to Seoul.", "ja"),
        ("Is the 新幹線 ticket booked?", "ja"), ("Thanks for the omiyage!", "ja"), ("The meeting with 鈴木様 is at noon.", "ja"),
        ("Got it.", "ja"), ("No worries.", "ja"), ("Happy birthday!", "ja"), ("Where is the nearest station?", "ja"),
        ("Please review the PR before lunch.", "ja"), ("Emilyさん, can you send me the slides?", "ja"),
        ("Thank you for coming today.", "ja"), ("Could you resend the invoice?", "ja"), ("I'm on my way.", "ja"),
        ("Let's go with plan B.", "ja"), ("Have a nice weekend!", "ja"), ("Is 木村さん joining us?", "ja"), ("Hello", "ja"),
        ("I'll send it 来週.", "ja"),
        // Other languages go into English.
        ("안녕하세요", "en"), ("감사합니다", "en"), ("Привет", "en"),
        // Nothing to translate.
        ("123", nil), ("3:30", nil), ("。、！", nil), ("😀", nil), ("100%", nil), ("", nil),
    ]

    static let spanish: [(String, String?)] = [
        // Short replies.
        ("Sí", "en"), ("Claro", "en"), ("Gracias", "en"), ("Vale", "en"), ("¿Qué?", "en"), ("Sí, claro", "en"),
        ("Perdón", "en"), ("Buenas noches", "en"), ("Ya voy", "en"), ("Mañana", "en"), ("Nos vemos", "en"),
        // Sentences.
        ("Hola, ¿cómo estás?", "en"), ("Buenos días a todos", "en"), ("Nos vemos mañana", "en"),
        ("Mañana no puedo ir a la oficina", "en"), ("Ya llegué", "en"), ("¿Me mandas el archivo?", "en"),
        ("Estoy en una reunión", "en"), ("Te llamo en un rato", "en"), ("Perdón por la demora", "en"),
        ("Muchas gracias por tu ayuda", "en"), ("Necesito el reporte para el viernes", "en"),
        ("Hay que revisar los números", "en"), ("Ahorita voy", "en"), ("Que tengas buen día", "en"),
        ("¡Qué buena noticia!", "en"), ("¿Dónde dejaste las llaves?", "en"), ("Mi vuelo sale a las ocho", "en"),
        // Without accents, as speech recognition may write them.
        ("Manana tengo cita con el doctor", "en"), ("Si, ya termine", "en"), ("Como estas", "en"),
        ("Donde estan las llaves", "en"), ("Que hora es", "en"), ("Te veo en la tarde", "en"),
        // With English words.
        ("Mándame el link por WhatsApp", "en"), ("El deadline es el viernes", "en"), ("Hay que hacer el deploy hoy", "en"),
        ("Revisa el pull request por favor", "en"), ("Tengo un meeting a las 3", "en"), ("Ya subí los cambios al repo", "en"),
        ("Te veo later", "en"), ("Estoy super busy hoy", "en"),
        ("¿Cuánto cuesta?", "en"), ("Ahí nos vemos", "en"), ("Ándale pues", "en"), ("Está lloviendo mucho", "en"),
        ("Llego en cinco minutos", "en"), ("¿Ya cenaron?", "en"), ("Dale, nos vemos", "en"),
        // English, with Spanish names and places.
        ("Thanks!", "es"), ("See you later", "es"), ("Can you send me the file?", "es"),
        ("I'll be there in ten minutes", "es"), ("Let's meet at the office", "es"), ("Send it to María by Friday", "es"),
        ("I'm flying to Bogotá tomorrow", "es"), ("We had dinner at El Farolito", "es"), ("The office is in Los Angeles", "es"),
        ("Tell José the meeting moved to Monday", "es"), ("Please call Dr. García about the results", "es"), ("Yes", "es"),
        ("Hello everyone", "es"), ("Happy birthday!", "es"), ("What time is the call?", "es"),
        ("Send it to María de la Cruz by Friday.", "es"), ("Did you book the hotel in Cancún?", "es"),
        ("Can you review the PR before lunch?", "es"), ("Is Sofia coming to the party?", "es"),
        ("Thank you so much", "es"), ("I'll be late today", "es"), ("Where are you?", "es"), ("Let me know when you arrive", "es"),
        ("Have a good night", "es"), ("We're almost done", "es"), ("Thanks, Don Ramón", "es"),
        // Other languages go into English.
        ("東京駅", "en"), ("我们明天开会", "en"), ("안녕하세요", "en"), ("ありがとう", "en"),
        // Nothing to translate.
        ("123", nil), ("3:30", nil), ("¿?", nil), ("😀", nil), ("$45.99", nil), ("", nil),
    ]

    private static func target(_ code: String?) -> TranslationTarget? {
        code.flatMap(TranslationTarget.init(rawValue:))
    }

    @Test func japaneseGoesIntoEnglishAndEnglishIntoJapanese() {
        let wrong = Self.japanese.filter { TranslationDirection.automatic.target(for: $0.0, in: .japanese) != Self.target($0.1) }.map(\.0)
        #expect(wrong.isEmpty, "\(wrong)")
        #expect(Self.japanese.count >= 80)
    }

    @Test func spanishGoesIntoEnglishAndEnglishIntoSpanish() {
        let wrong = Self.spanish.filter { TranslationDirection.automatic.target(for: $0.0, in: .spanish) != Self.target($0.1) }.map(\.0)
        #expect(wrong.isEmpty, "\(wrong)")
        #expect(Self.spanish.count >= 80)
    }

    /// The sources behind the targets: text in neither language counts as other, and goes
    /// into English like the dictation language.
    @Test func eachTextHasASource() {
        #expect(TranslationDirection.source(of: "はい", in: .japanese) == .partner)
        #expect(TranslationDirection.source(of: "Thanks, 山田さん", in: .japanese) == .english)
        #expect(TranslationDirection.source(of: "안녕하세요", in: .japanese) == .other)
        #expect(TranslationDirection.source(of: "東京駅", in: .spanish) == .other)
        #expect(TranslationDirection.source(of: "Gracias", in: .spanish) == .partner)
        #expect(TranslationDirection.source(of: "Thanks", in: .spanish) == .english)
        #expect(TranslationDirection.source(of: "我们明天开会", in: .chinese) == .partner)
        #expect(TranslationDirection.source(of: "Hello", in: .chinese) == .english)
        #expect(TranslationDirection.source(of: "123", in: .spanish) == nil)
    }

    /// An honorific after a name does not count as Japanese, and capitals such as LA or PR
    /// do not count as function words.
    @Test func namesDoNotTurnTheDirection() {
        #expect(TranslationDirection.japaneseSource(of: "Thanks, 山田さん") == .english)
        #expect(TranslationDirection.japaneseSource(of: "Thanks, 山田") == .english)
        #expect(TranslationDirection.SpanishCounts("LA").spanish == 0)
        #expect(TranslationDirection.SpanishCounts("la").spanish == 1)
        #expect(TranslationDirection.SpanishCounts("María de la Cruz").spanish == 2)
        #expect(TranslationDirection.SpanishCounts("¿qué?").spanish == 5)
        #expect(TranslationDirection.SpanishCounts("I don't know").english == 4)
    }

    /// The Chinese rule is the one it always was: the functions without a dictation
    /// language and those for Chinese give the same target for every labelled text.
    @Test func chineseKeepsItsRule() {
        let texts = Self.japanese.map(\.0) + Self.spanish.map(\.0) + ["我们下周二开会。", "We meet next Tuesday.", "这个 PR 你帮我 review 一下。"]
        for direction in TranslationDirection.choices(for: .chinese) {
            for text in texts {
                #expect(direction.target(for: text, in: .chinese) == direction.target(for: text), "\(direction) \(text)")
            }
        }
    }

    /// Settings offers Automatic, English and the dictation language. A choice saved for
    /// another language acts as Automatic, and comes back with its language.
    @Test func eachLanguageHasItsChoices() {
        #expect(TranslationDirection.choices(for: .chinese) == [.automatic, .english, .chinese])
        #expect(TranslationDirection.choices(for: .japanese) == [.automatic, .english, .japanese])
        #expect(TranslationDirection.choices(for: .spanish) == [.automatic, .english, .spanish])
        #expect(TranslationDirection.chinese.effective(for: .spanish) == .automatic)
        #expect(TranslationDirection.chinese.effective(for: .chinese) == .chinese)
        #expect(TranslationDirection.japanese.effective(for: .chinese) == .automatic)
        #expect(TranslationDirection.english.effective(for: .japanese) == .english)
        #expect(TranslationDirection.chinese.target(for: "Hello there", in: .spanish) == .spanish)
        #expect(TranslationDirection.chinese.target(for: "Hola a todos", in: .spanish) == .english)
        #expect(TranslationDirection.japanese.target(for: "Hello there") == .chinese)
        #expect(TranslationDirection.spanish.target(for: "Hello there", in: .spanish) == .spanish)
        #expect(TranslationDirection.spanish.target(for: "Hola a todos", in: .spanish) == .spanish)
        #expect(TranslationDirection.english.target(for: "Hola a todos", in: .spanish) == .english)
        for language in DictationLanguage.allCases {
            for direction in TranslationDirection.allCases {
                #expect(TranslationDirection.choices(for: language).contains(direction.effective(for: language)))
            }
        }
    }

    /// The saved value stays, so an older Orra that does not know Japanese or Spanish reads
    /// Automatic, and a newer one reads it back.
    @Test func aChoiceOfJapaneseOrSpanishIsSaved() throws {
        try withTestDefaults("translation-pairs") { defaults in
            TranslationDirection.spanish.save(to: defaults)
            #expect(defaults.string(forKey: TranslationDirection.defaultsKey) == "spanish")
            #expect(TranslationDirection.load(from: defaults) == .spanish)
            TranslationDirection.japanese.save(to: defaults)
            #expect(TranslationDirection.load(from: defaults) == .japanese)
        }
    }

    /// Kana only Japanese has something to translate, and so does short Spanish.
    @Test func shortTextIsWorthTranslating() {
        #expect(TranslationStep.isWorthTranslating("はい", in: .japanese))
        #expect(!TranslationStep.isWorthTranslating("はい"))
        #expect(TranslationStep.isWorthTranslating("Sí", in: .spanish))
        #expect(!TranslationStep.isWorthTranslating("123", in: .spanish))
        #expect(!TranslationStep.isWorthTranslating(String(repeating: "あ", count: 301), in: .japanese))
    }
}
