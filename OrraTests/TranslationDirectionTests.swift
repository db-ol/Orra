import Foundation
import Testing
@testable import Orra

struct TranslationDirectionTests {
    private struct Case: Decodable {
        let set: String
        let id: String
        let text: String
        let label: String
        let source: String?
    }

    private static let cases: [Case] = TranslationDirectionCases.jsonl
        .split(separator: "\n")
        .map { try! JSONDecoder().decode(Case.self, from: Data($0.utf8)) }

    private static func language(_ code: String?) -> TranslationTarget? {
        code.flatMap(TranslationTarget.init(rawValue:))
    }

    /// The Swift rule gives every text the language direction.py gave it.
    @Test func everyTextGetsThePythonLanguage() {
        #expect(Self.cases.count == 493)
        #expect(Self.cases.filter { $0.set != "extra" }.count == 358)
        for item in Self.cases {
            #expect(TranslationDirection.sourceLanguage(of: item.text) == Self.language(item.source), "\(item.id) \(item.text)")
        }
    }

    /// On the 354 cases with a label it was tuned on, the rule is wrong once: cm04, mostly
    /// English words in a Chinese sentence.
    @Test func theRuleMatchesTheLabelsItWasTunedOn() {
        let labelled = Self.cases.filter { ["zh", "en", "none"].contains($0.label) }
        #expect(labelled.count == 354)
        let wrong = labelled.filter { TranslationDirection.sourceLanguage(of: $0.text) != Self.language($0.label == "none" ? nil : $0.label) }
        #expect(wrong.map(\.id) == ["cm04"])
    }

    @Test func namesInTheOtherLanguageDoNotTurnTheDirection() {
        #expect(TranslationDirection.sourceLanguage(of: "Send it to 王小明.") == .english)
        #expect(TranslationDirection.sourceLanguage(of: "Let's meet at 星巴克 on 中关村大街 tomorrow.") == .english)
        #expect(TranslationDirection.sourceLanguage(of: "这个 PR 你帮我 review 一下。") == .chinese)
        #expect(TranslationDirection.sourceLanguage(of: "请把 Q3 的 OKR 发给 HR。") == .chinese)
    }

    @Test func theCountsAreTheOnesTheRuleWeighs() {
        let counts = TranslationDirection.Counts("我们 let's go 的 the")
        #expect(counts.han == 3)
        #expect(counts.letters == 9)
        #expect(counts.chineseFunction == 3)
        #expect(counts.englishFunction == 2)
        // Full width letters and a curly apostrophe count as direction.py counts them.
        #expect(TranslationDirection.Counts("Ｈｅｌｌｏ").letters == 0)
        #expect(TranslationDirection.Counts("let’s").englishFunction == 0)
    }

    /// The automatic direction translates into the other language, a fixed one always into
    /// its target, and nothing without a Han character or a Latin letter.
    @Test func theTargetFollowsTheSetting() {
        #expect(TranslationDirection.automatic.target(for: "我们下周二开会。") == .english)
        #expect(TranslationDirection.automatic.target(for: "We meet next Tuesday.") == .chinese)
        #expect(TranslationDirection.english.target(for: "We meet next Tuesday.") == .english)
        #expect(TranslationDirection.english.target(for: "我们下周二开会。") == .english)
        #expect(TranslationDirection.chinese.target(for: "我们下周二开会。") == .chinese)
        #expect(TranslationDirection.chinese.target(for: "OK") == .chinese)
        for direction in TranslationDirection.allCases {
            for text in ["", "123", "3:30", "。，！", "😀", "13800138000"] {
                #expect(direction.target(for: text) == nil, "\(direction) \(text)")
            }
        }
    }

    @Test func theSettingIsAutomaticUntilSaved() throws {
        let suite = "io.github.db-ol.OrraTests.translation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TranslationDirection.load(from: defaults) == .automatic)
        TranslationDirection.chinese.save(to: defaults)
        #expect(TranslationDirection.load(from: defaults) == .chinese)
        TranslationDirection.automatic.save(to: defaults)
        #expect(TranslationDirection.load(from: defaults) == .automatic)
        defaults.set("klingon", forKey: TranslationDirection.defaultsKey)
        #expect(TranslationDirection.load(from: defaults) == .automatic)
    }
}
