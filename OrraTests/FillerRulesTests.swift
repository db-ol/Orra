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
        try withTestDefaults("fillers") { defaults in
            #expect(FillerPreference.load(from: defaults))
            FillerPreference.save(false, to: defaults)
            #expect(!FillerPreference.load(from: defaults))
            FillerPreference.save(true, to: defaults)
            #expect(FillerPreference.load(from: defaults))
        }
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
        // Interjections that start with 嗯 keep it.
        ("嗯哼，你说得对。", "嗯哼，你说得对。"),
        ("嗯呢，我到了。", "嗯呢，我到了。"),
        ("嗯哪，我这就过去。", "嗯哪，我这就过去。"),
        ("嗯呐，马上到。", "嗯呐，马上到。"),
        ("嗯哼", "嗯哼"),
        ("嗯呐", "嗯呐"),
        ("嗯哪！", "嗯哪！"),
        ("他说嗯哼，然后就走了。", "他说嗯哼，然后就走了。"),
        ("嗯嗯哼，有意思。", "嗯嗯哼，有意思。"),
        ("呃，嗯哼，你说得对。", "嗯哼，你说得对。"),
        // A doubled interjection stays whole.
        ("嗯哪嗯哪，我知道了。", "嗯哪嗯哪，我知道了。"),
        ("嗯呐嗯呐，马上就好。", "嗯呐嗯呐，马上就好。"),
        ("嗯呢嗯呢，到了。", "嗯呢嗯呢，到了。"),
        ("嗯哼嗯哼，有道理。", "嗯哼嗯哼，有道理。"),
        ("他说嗯哪嗯哪", "他说嗯哪嗯哪"),
        // 哼, 呢, 哪 and 呐 also start words, so 嗯 before such a word is a filler.
        ("嗯哪个方案都行，你定吧。", "哪个方案都行，你定吧。"),
        ("嗯哪里出了问题？", "哪里出了问题？"),
        ("我觉得嗯哪个都可以。", "我觉得哪个都可以。"),
        ("他嗯哼着歌走了。", "他哼着歌走了。"),
        ("嗯呢子大衣挺好看的。", "呢子大衣挺好看的。"),
        ("她嗯呢喃了几句。", "她呢喃了几句。"),
        ("嗯呐喊声太大了。", "呐喊声太大了。"),
        // A space does not end the word, since the speech model writes one before English.
        ("嗯哪 PR 还没合并？", "哪 PR 还没合并？"),
        // A comma parts 嗯 from the next word, so it goes.
        ("嗯，哼，我才不去。", "哼，我才不去。"),
        // What goes and what stays around them is as before.
        ("嗯，我们先开会。", "我们先开会。"),
        ("嗯嗯，我看一下。", "我看一下。"),
        ("额，文件发你了。", "文件发你了。"),
        ("啊，我忘了带钥匙。", "我忘了带钥匙。"),
        ("哦，周五取消了。", "周五取消了。"),
        ("啊对，就是这个。", "啊对，就是这个。"),
        ("额外的费用。", "额外的费用。"),
        ("呃逆。", "呃逆。"),
    ])
    func edgeCasesFoundInReview(input: String, expected: String) {
        #expect(FillerRules.removingFillers(from: input) == expected)
    }
}

