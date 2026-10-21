import Foundation
import Synchronization
import Testing
@testable import Orra

/// Translate into a language outside the pair of English and the dictation language: the
/// plan for each text, the way through English with a stand in model, and the checks of
/// such a route. The texts are written for these tests.
struct TranslationPlanTests {
    private static func plan(_ text: String, into direction: TranslationDirection, in language: DictationLanguage) async -> TranslationPlan? {
        await direction.plan(for: text, in: language)
    }

    private static let japanese = TranslationRoute(.japanese, into: .japanese)
    private static let spanish = TranslationRoute(.spanish, into: .spanish)

    // MARK: Plans

    /// Text in the dictation language goes through English, English takes the route from
    /// English alone, and text in the target already is pasted as it was said.
    @Test func eachTextGetsItsWayIntoATargetOutsideThePair() async {
        // Chinese dictation into Japanese.
        #expect(await Self.plan("我们明天下午开会。", into: .japanese, in: .chinese) == .throughEnglish(.chinese(.english), source: .partner, then: Self.japanese))
        #expect(await Self.plan("See you tomorrow.", into: .japanese, in: .chinese) == .route(Self.japanese, source: .english))
        // English mixed with Chinese goes through English too, so the Chinese route applies
        // its correction.
        #expect(await Self.plan("Deadline 是 Friday，sorry，是 Thursday。", into: .japanese, in: .chinese) == .throughEnglish(.chinese(.english), source: .english, then: Self.japanese))
        // Japanese with kanji reads as Chinese under the Chinese rule, but holds kana.
        #expect(await Self.plan("明日の会議は10時からです。", into: .japanese, in: .chinese) == .inTarget(.japanese))
        // Chinese dictation into Spanish. Spanish reads as English under the Chinese rule, and
        // the Spanish rule of the route finds it Spanish, so the step pastes it as said.
        #expect(await Self.plan("这个 PR 你帮我 review 一下。", into: .spanish, in: .chinese) == .throughEnglish(.chinese(.english), source: .partner, then: Self.spanish))
        #expect(await Self.plan("Nos vemos mañana en la oficina.", into: .spanish, in: .chinese) == .route(Self.spanish, source: .partner))
        // Japanese dictation into Chinese. Chinese reads as Japanese under the Japanese rule,
        // but holds no kana.
        #expect(await Self.plan("明日の会議は10時からです。", into: .chinese, in: .japanese) == .throughEnglish(TranslationRoute(.japanese, into: .english), source: .partner, then: .chinese(.chinese)))
        #expect(await Self.plan("我们明天下午开会。", into: .chinese, in: .japanese) == .inTarget(.chinese))
        // Japanese in kanji only that NLLanguageRecognizer finds Japanese is not Chinese.
        #expect(await Self.plan("品川駅集合。", into: .chinese, in: .japanese) == .throughEnglish(TranslationRoute(.japanese, into: .english), source: .partner, then: .chinese(.chinese)))
        #expect(await Self.plan("契約書最終確認後、署名予定。", into: .chinese, in: .japanese) == .inTarget(.chinese))
        #expect(await Self.plan("Can you check the report?", into: .chinese, in: .japanese) == .route(.chinese(.chinese), source: .english))
        #expect(await Self.plan("Thanks, 山田さん", into: .chinese, in: .japanese) == .throughEnglish(TranslationRoute(.japanese, into: .english), source: .english, then: .chinese(.chinese)))
        // Japanese dictation into Spanish, with Korean, which is neither language.
        #expect(await Self.plan("안녕하세요", into: .spanish, in: .japanese) == .throughEnglish(TranslationRoute(.japanese, into: .english), source: .other, then: Self.spanish))
        // Spanish dictation into Chinese and Japanese.
        #expect(await Self.plan("¿Me mandas el reporte hoy?", into: .chinese, in: .spanish) == .throughEnglish(TranslationRoute(.spanish, into: .english), source: .partner, then: .chinese(.chinese)))
        #expect(await Self.plan("Saluda a 王小明 de mi parte.", into: .chinese, in: .spanish) == .throughEnglish(TranslationRoute(.spanish, into: .english), source: .partner, then: .chinese(.chinese)))
        #expect(await Self.plan("我们明天下午开会。", into: .chinese, in: .spanish) == .inTarget(.chinese))
        #expect(await Self.plan("ありがとうございます", into: .japanese, in: .spanish) == .inTarget(.japanese))
        #expect(await Self.plan("我们明天下午开会。", into: .japanese, in: .spanish) == .throughEnglish(TranslationRoute(.spanish, into: .english), source: .other, then: Self.japanese))
        #expect(await Self.plan("Can you check the report?", into: .japanese, in: .spanish) == .route(Self.japanese, source: .english))
        // Nothing to translate.
        #expect(await Self.plan("123", into: .japanese, in: .chinese) == nil)
        #expect(await Self.plan("😀", into: .chinese, in: .spanish) == nil)
    }

    /// Automatic and the fixed choices of the pair take the one route they always took.
    @Test func thePairKeepsItsRoutes() async {
        let texts = TranslationPairDirectionTests.japanese.map(\.0) + TranslationPairDirectionTests.spanish.map(\.0) + ["我们明天下午开会。", "Send it to 王小明.", "这个 PR 你帮我 review 一下"]
        for language in DictationLanguage.allCases {
            for direction in TranslationDirection.allCases where direction.fits(language) {
                for text in texts {
                    let source = TranslationDirection.source(of: text, in: language)
                    let expected = source.flatMap { source in direction.target(source: source, in: language).map { TranslationPlan.route(TranslationRoute(language, into: $0), source: source) } }
                    #expect(await Self.plan(text, into: direction, in: language) == expected, "\(text) \(direction) \(language)")
                }
            }
        }
    }

    @Test func theRouteFromEnglishIsThatOfTheTargetsPair() {
        #expect(TranslationRoute.fromEnglish(into: .chinese) == .chinese(.chinese))
        #expect(TranslationRoute.fromEnglish(into: .japanese) == Self.japanese)
        #expect(TranslationRoute.fromEnglish(into: .spanish) == Self.spanish)
        #expect(TranslationPlan.inTarget(.spanish).target == .spanish)
        #expect(TranslationPlan.throughEnglish(.chinese(.english), source: .partner, then: Self.japanese).target == .japanese)
    }

    // MARK: Through English

    /// A stand in model that answers per route and records each call.
    private final class Model: Sendable {
        let answers: [TranslationRoute: String]
        let delays: [TranslationRoute: Duration]
        let calls = Mutex<[String]>([])

        init(_ answers: [TranslationRoute: String], delays: [TranslationRoute: Duration] = [:]) {
            self.answers = answers
            self.delays = delays
        }

        var complete: @Sendable (String, TranslationRoute) async throws -> String {
            { [self] text, route in
                calls.withLock { $0.append("\(route.language.rawValue) \(route.target.rawValue) \(text)") }
                if let delay = delays[route] {
                    try await Task.sleep(for: delay)
                }
                guard let answer = answers[route] else { throw TestError() }
                return answer
            }
        }
    }

    private static let chinese = "呃，我们下周一，哦不是，下周二开会。"
    private static let intoEnglish = #"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday."}"#
    private static let intoJapanese = #"{"cleaned": "We have a meeting next Tuesday.", "translation": "来週の火曜日に会議があります。"}"#

    /// Both parts pass: the Japanese is pasted, and Paste Original Text brings back the
    /// model's cleanup of the Chinese, as on one route.
    @Test func bothPartsPassAndTheTranslationIsPasted() async {
        let model = Model([.chinese(.english): Self.intoEnglish, Self.japanese: Self.intoJapanese])
        let plan = TranslationPlan.throughEnglish(.chinese(.english), source: .partner, then: Self.japanese)
        let result = await TranslationStep.run(Self.chinese, plan: plan, in: .chinese, cleansUp: true, complete: model.complete)
        #expect(result == TranslationStep.Result(text: "来週の火曜日に会議があります。", untranslated: "我们下周二开会。", outcome: .translated))
        #expect(model.calls.withLock { $0 } == ["Chinese en \(Self.chinese)", "Japanese ja We have a meeting next Tuesday."])
        let ruled = await TranslationStep.run(Self.chinese, plan: plan, in: .chinese, cleansUp: false, complete: model.complete)
        #expect(ruled.untranslated == Self.chinese)
    }

    /// A first part that fails stops there, and the second never runs.
    @Test func aFirstPartThatFailsStopsTheTranslation() async {
        let model = Model([.chinese(.english): #"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday at 3."}"#, Self.japanese: Self.intoJapanese])
        let result = await TranslationStep.run(Self.chinese, into: .chinese(.english), source: .partner, then: Self.japanese, cleansUp: false, complete: model.complete)
        #expect(result == TranslationStep.Result(text: Self.chinese, untranslated: Self.chinese, outcome: .heldBack(.newNumber(["3"]))))
        #expect(model.calls.withLock { $0.count } == 1)
    }

    /// A second part that fails its checks, here Chinese characters in Japanese that the
    /// checks of the pair let through, pastes the text without translation.
    @Test func aSecondPartThatFailsItsChecksIsNotPasted() async {
        let model = Model([.chinese(.english): Self.intoEnglish, Self.japanese: #"{"cleaned": "We have a meeting next Tuesday.", "translation": "下周二有会议。"}"#])
        let result = await TranslationStep.run(Self.chinese, into: .chinese(.english), source: .partner, then: Self.japanese, cleansUp: true, complete: model.complete)
        #expect(result == TranslationStep.Result(text: "我们下周二开会。", untranslated: "我们下周二开会。", outcome: .heldBack(.hanOutsideJapanese)))
        // The same answer passes the checks of a Japanese user's own route from English.
        #expect(TranslationGuard.check(source: "We have a meeting next Tuesday.", output: "下周二有会议。", route: Self.japanese) == nil)
    }

    /// English that the second part gives back as it was passed its checks, so it is the
    /// translation, such as OK for 好的.
    @Test func englishGivenBackIsTheTranslation() async {
        let model = Model([.chinese(.english): #"{"cleaned": "好的。", "translation": "OK."}"#, Self.spanish: #"{"cleaned": "OK.", "translation": "OK."}"#])
        let result = await TranslationStep.run("好的。", into: .chinese(.english), source: .partner, then: Self.spanish, cleansUp: false, complete: model.complete)
        #expect(result == TranslationStep.Result(text: "OK.", untranslated: "好的。", outcome: .translated))
    }

    /// Both parts share the time limit of one, so a slow second part runs out of time.
    @Test func bothPartsShareOneTimeLimit() async {
        let model = Model(
            [.chinese(.english): Self.intoEnglish, Self.japanese: Self.intoJapanese],
            delays: [.chinese(.english): .milliseconds(600), Self.japanese: .milliseconds(900)]
        )
        let result = await TranslationStep.run(Self.chinese, into: .chinese(.english), source: .partner, then: Self.japanese, cleansUp: false, timeout: .seconds(1), complete: model.complete)
        #expect(result == TranslationStep.Result(text: Self.chinese, untranslated: Self.chinese, outcome: .timedOut))
        #expect(model.calls.withLock { $0.count } == 2)
    }

    /// Text in the target already is pasted as it was said, and the model does not run.
    @Test func textInTheTargetIsPastedAsSaid() async {
        let model = Model([:])
        let result = await TranslationStep.run("明日の会議は10時からです。", plan: .inTarget(.japanese), in: .chinese, cleansUp: true, complete: model.complete)
        #expect(result == TranslationStep.Result(text: "明日の会議は10時からです。", untranslated: "明日の会議は10時からです。", outcome: .unchanged))
        #expect(model.calls.withLock { $0.isEmpty })
    }

    /// English into a target outside the pair takes one route with the checks of such a
    /// route, and into the dictation language the checks it always had.
    @Test func englishIntoATargetOutsideThePairGetsItsChecks() async {
        let answer = #"{"cleaned": "The report is at 10 tomorrow.", "translation": "明天10点有报告。"}"#
        let model = Model([Self.japanese: answer])
        let outside = await TranslationStep.run("The report is at 10 tomorrow.", plan: .route(Self.japanese, source: .english), in: .chinese, cleansUp: false, complete: model.complete)
        #expect(outside.outcome == .heldBack(.hanOutsideJapanese))
        let own = await TranslationStep.run("The report is at 10 tomorrow.", plan: .route(Self.japanese, source: .english), in: .japanese, cleansUp: false, complete: model.complete)
        #expect(own.outcome == .translated)
    }

    // MARK: Checks

    /// Japanese never writes a simplified form such as 报, 龙 or 该, unless the source
    /// holds it, as a short Chinese name may stay in the English.
    @Test func japaneseHoldsNoHanThatJapaneseDoesNotWrite() {
        #expect(TranslationGuard.hasHanOutsideJapanese("据报道，该镇的居民将于明天投票。", source: "Reportedly the town votes tomorrow."))
        #expect(TranslationGuard.hasHanOutsideJapanese("九龙に行きました。", source: "I went to Kowloon."))
        #expect(!TranslationGuard.hasHanOutsideJapanese("東京駅の八重洲中央口で待っています。", source: "I'm waiting at the Yaesu central exit."))
        #expect(!TranslationGuard.hasHanOutsideJapanese("髙橋さんと﨑山さんに連絡しました。", source: "I contacted Takahashi and Sakiyama."))
        #expect(!TranslationGuard.hasHanOutsideJapanese("刘洋さんに請求書を送ってください。", source: "Please send the invoice to 刘洋."))
        // Chinese given as Japanese, which the checks of the pair let through when it is short
        // and holds at most one of the simplified forms they know.
        let chinese = "九龙的天气很好。"
        #expect(TranslationGuard.check(source: "The weather in Kowloon is nice.", output: chinese, route: Self.japanese) == nil)
        #expect(TranslationGuard.checkOutsidePair(source: "The weather in Kowloon is nice.", output: chinese, route: Self.japanese) == .hanOutsideJapanese)
    }

    /// A 1 that counts one thing is no new number when the English has a word for one.
    @Test func aOneThatCountsIsNoNewNumber() {
        #expect(TranslationGuard.countingOnes(in: "1つの文化", source: "a singular culture") == "一つの文化")
        #expect(TranslationGuard.countingOnes(in: "1分間沸騰させる", source: "boil it for a minute") == "一分間沸騰させる")
        #expect(TranslationGuard.countingOnes(in: "1つの文化", source: "two cultures") == "1つの文化")
        #expect(TranslationGuard.countingOnes(in: "10時1分に始まります", source: "It starts at a quarter past ten") == "10時1分に始まります")
        #expect(TranslationGuard.countingOnes(in: "11人と1人", source: "eleven people and one more") == "11人と一人")
        #expect(TranslationGuard.countingOnes(in: "3分の1です", source: "It is a third") == "3分の一です")
        #expect(TranslationGuard.countingOnes(in: "交通は1年中続きます", source: "Traffic goes on all year round") == "交通は一年中続きます")
        #expect(TranslationGuard.countingOnes(in: "交通は1年中続きます", source: "Traffic goes on every year") == "交通は1年中続きます")
        let source = "A civilization is a singular culture shared by a large group of people."
        let output = "文明とは、大きな集団が共有する1つの文化のことです。"
        #expect(TranslationGuard.check(source: source, output: output, route: Self.japanese) == .newNumber(["1"]))
        #expect(TranslationGuard.checkOutsidePair(source: source, output: output, route: Self.japanese) == nil)
        // A changed number is still caught.
        #expect(TranslationGuard.checkOutsidePair(source: "We need two rooms for a week.", output: "1週間、3部屋必要です。", route: Self.japanese) == .newNumber(["3"]))
    }

    /// Portuguese or French given as Spanish is held back, Spanish and short text are not.
    /// Portuguese without its own accents, such as ã or ê, passes the checks of the pair.
    @Test func spanishIsNotPortugueseOrFrench() {
        let portuguese = "Eu queria saber se pode enviar o relatorio ainda hoje, por favor."
        let french = "Je voudrais savoir si tu peux envoyer le rapport avant demain matin, s'il te plaît."
        let spanish = "Quería saber si puedes enviar el informe hoy mismo, por favor."
        #expect(TranslationGuard.isOtherThanSpanish(portuguese))
        #expect(TranslationGuard.isOtherThanSpanish(french))
        #expect(!TranslationGuard.isOtherThanSpanish(spanish))
        // Under 30 letters, where short Spanish may read as Portuguese.
        #expect(!TranslationGuard.isOtherThanSpanish("Por favor, revisen esta PR."))
        let source = "I wanted to know if you can send the report today, please."
        #expect(TranslationGuard.check(source: source, output: portuguese, route: Self.spanish) == nil)
        #expect(TranslationGuard.checkOutsidePair(source: source, output: portuguese, route: Self.spanish) == .otherThanSpanish)
        #expect(TranslationGuard.checkOutsidePair(source: source, output: spanish, route: Self.spanish) == nil)
    }

    /// Into Chinese the route's checks stay, and they hold back kana already.
    @Test func chineseKeepsItsChecks() {
        let source = "I'll send the report tomorrow."
        #expect(TranslationGuard.checkOutsidePair(source: source, output: "明日レポートを送ります。", route: .chinese(.chinese)) == .foreignScript)
        #expect(TranslationGuard.checkOutsidePair(source: source, output: "我明天发报告。", route: .chinese(.chinese)) == nil)
    }
}
