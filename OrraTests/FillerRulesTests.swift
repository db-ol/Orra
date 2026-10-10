import Foundation
import Testing
@testable import Orra

/// The filler rules on the evaluation set in Tools/rewrite-eval and on focused cases.
struct FillerRulesTests {
    struct Case: Decodable, CustomTestStringConvertible {
        let id: String
        let category: String
        let input: String
        let cleanup: String
        let rules: Bool

        var testDescription: String { id }
    }

    /// The cases of the evaluation set, read from the source tree.
    static let cases: [Case] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/rewrite-eval/cases.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Case.self, from: Data(line.utf8))
        }
    }()

    /// The filler, particle and control cases that the rules alone should get right.
    static let ruleCases = cases.filter { item in
        item.rules && (item.category.hasPrefix("filler_") || item.category == "particle_keep" || item.category == "control_keep")
    }

    @Test func theEvaluationSetIsRead() {
        #expect(Self.cases.count >= 170)
        #expect(Self.ruleCases.count >= 90)
        // Particles and controls must stay as they are, so the rules get every one of them.
        let kept = Self.cases.filter { $0.category == "particle_keep" || $0.category == "control_keep" }
        #expect(kept.allSatisfy { $0.rules && $0.cleanup == $0.input })
    }

    @Test(arguments: ruleCases)
    func evaluationCase(_ item: Case) {
        #expect(FillerRules.removingFillers(from: item.input) == item.cleanup)
    }

    /// Cases that need a model may keep fillers the rules cannot judge, but the rules never
    /// take a word or a number away from them.
    @Test func casesForAModelLoseOnlyFillers() {
        let fillers: Set<String> = ["呃", "额", "嗯", "啊", "哦", "um", "umm", "uh", "uhh", "uhm", "erm"]
        for item in Self.cases where !item.rules {
            let before = Self.words(item.input).filter { !fillers.contains($0) }
            let after = Self.words(FillerRules.removingFillers(from: item.input)).filter { !fillers.contains($0) }
            #expect(before == after, "\(item.id)")
        }
    }

    /// Chinese characters one by one and other words whole, in lowercase.
    private static func words(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber, character.isASCII {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                result.append(word)
                word = ""
            }
            if character.isLetter {
                result.append(String(character))
            }
        }
        if !word.isEmpty {
            result.append(word)
        }
        return result
    }

    @Test(arguments: [
        ("呃，你好。", "你好。"),
        ("我觉得呃这样不好。", "我觉得这样不好。"),
        ("我想问一下，呃，报销流程。", "我想问一下，报销流程。"),
        ("好的，呃", "好的"),
        ("嗯呃，我们走吧。", "我们走吧。"),
        ("我们用 uh React 吧。", "我们用 React 吧。"),
        ("这个 API 嗯 返回空值。", "这个 API 返回空值。"),
        ("Um，我觉得可以。", "我觉得可以。"),
        ("So, um, I think so.", "So, I think so."),
        ("I uh think so.", "I think so."),
        ("Done. Uh, next one.", "Done. Next one."),
        ("UMM so we start.", "UMM so we start."),
        ("Um. Let me think.", "Let me think."),
        ("Um, iPhone sales are up.", "iPhone sales are up."),
        ("um, so we start.", "so we start."),
        ("It costs uh $5.", "It costs $5."),
    ])
    func removes(_ input: String, _ expected: String) {
        #expect(FillerRules.removingFillers(from: input) == expected)
    }

    @Test(arguments: [
        "嗯", "嗯嗯", "嗯。", "呃，", "Um.", "就这样吧，嗯。", "就这样。嗯。下一个。", "uh", "嗯，好的。", "嗯对。", "嗯，是这样。", "嗯？你说什么？",
        "Um? What?", "好啊，走吧。", "是啊，对呀。", "今天天气真好啊！", "哦？真的吗？", "那个文件我看看。",
        "这个周末吧。", "他怎么还没来呢？", "别急嘛。", "金额不对。", "这个额度不够。", "额外的费用。",
        "他叫额尔敦。", "呃逆。", "Uh-huh, sure.", "Uh huh, sure.", "Uh oh, it broke.", "The UM campus.",
        "I like it.", "an umbrella", "Erm's not a word.", "我我我觉得可以。", "",
    ])
    func keeps(_ input: String) {
        #expect(FillerRules.removingFillers(from: input) == input)
    }

    @Test func thePreferenceIsOnUntilTurnedOff() throws {
        let suite = "io.github.db-ol.OrraTests.fillers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FillerPreference.load(from: defaults))
        FillerPreference.save(false, to: defaults)
        #expect(!FillerPreference.load(from: defaults))
        FillerPreference.save(true, to: defaults)
        #expect(FillerPreference.load(from: defaults))
    }

    @Test(arguments: [
        // A change of mind keeps its 哦.
        ("会议三点，哦，不是四点。", "会议三点，哦，不是四点。"),
        ("啊，不对，是周二。", "啊，不对，是周二。"),
        // An ellipsis goes with the filler.
        ("Um... I think we should go.", "I think we should go."),
        ("Um… I think so.", "I think so."),
        ("呃……我想说一下。", "我想说一下。"),
        ("呃... 我觉得可以", "我觉得可以"),
        // 嗯 as an answer.
        ("他问我去不去，我说嗯。", "他问我去不去，我说嗯。"),
        ("嗯。明天见。", "嗯。明天见。"),
        ("他说嗯", "他说嗯"),
        // Quoted fillers are words.
        ("He said \"um\" twice.", "He said \"um\" twice."),
        ("他回了一个“嗯”字。", "他回了一个“嗯”字。"),
        // Surnames.
        ("Please email Dr. Um about it.", "Please email Dr. Um about it."),
        ("I met Mr. Uh yesterday.", "I met Mr. Uh yesterday."),
        // A reply must be a word of its own to keep 嗯.
        ("嗯，好像不太对。", "好像不太对。"),
        ("嗯，是不是应该先开会？", "是不是应该先开会？"),
        ("嗯，好的。", "嗯，好的。"),
        // English fillers against Chinese characters.
        ("我uh觉得可以", "我觉得可以"),
    ])
    func edgeCasesFoundInReview(input: String, expected: String) {
        #expect(FillerRules.removingFillers(from: input) == expected)
    }
}

