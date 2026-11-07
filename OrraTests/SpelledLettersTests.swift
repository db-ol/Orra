import Foundation
import Testing
@testable import Orra

/// The join of spelled capitals on what Orra pasted in stored runs and on focused cases.
struct SpelledLettersTests {
    /// Every text that the join changes in the release gate run of the 0.6.4 candidate
    /// (2026-11-05), and three more from earlier runs of the speech corpus evaluation.
    static let stored: [(String, String)] = [
        // gate-core/mixed_terms_2, with PR and CI in the vocabulary.
        ("这个 P R 先别 merge，等 C I 跑完再说。", "这个 PR 先别 merge，等 CI 跑完再说。"),
        // zh-numbers-negation/num38_ctx0, num39_ctx0 and num45_ctx0.
        ("这个文件有3.5G B。", "这个文件有3.5GB。"),
        ("这台 MacBook 有16 G B 内存。", "这台 MacBook 有16GB 内存。"),
        ("这个 P R 改了三百多行代码。", "这个 PR 改了三百多行代码。"),
        // The speech corpus, 0295_mixed and 0302_mixed.
        ("O.K. 所以我 come from 福建。", "OK 所以我 come from 福建。"),
        ("我们之前有聊过一个A.I. Robert。", "我们之前有聊过一个AI Robert。"),
        // Earlier runs of the speech corpus, 0323_mixed, 0334_mixed and 0342_mixed.
        ("对，然后我们 U G 的时候，我们每我们会有分那个。", "对，然后我们 UG 的时候，我们每我们会有分那个。"),
        ("因为 G P U 不是一个硬性条件嘛。", "因为 GPU 不是一个硬性条件嘛。"),
        ("A I可以就是很大很大程度上改善我们的生活，比如说什么一些translation啊，还有一些就是。", "AI可以就是很大很大程度上改善我们的生活，比如说什么一些translation啊，还有一些就是。"),
    ]

    static let joined: [(String, String)] = [
        // Chinese characters or punctuation right beside the letters, and the ends of the text.
        ("这个P R先别合。", "这个PR先别合。"),
        ("先看（P R）再说。", "先看（PR）再说。"),
        ("P R 合了吗？", "PR 合了吗？"),
        ("合了这个 P R", "合了这个 PR"),
        // Two runs, and five letters.
        ("P R 和 C I 都过了。", "PR 和 CI 都过了。"),
        ("用 S W I F T 写的。", "用 SWIFT 写的。"),
        // A byte unit after a number, and other letters after a number.
        ("下载了512 M B。", "下载了512MB。"),
        ("买了 2 T B 的硬盘。", "买了 2TB 的硬盘。"),
        ("2026 A I 大会", "2026 AI 大会"),
        // Dotted capitals.
        ("我同意，O.K.。", "我同意，OK。"),
        ("U.S.A. 的选举", "USA 的选举"),
    ]

    static let kept = [
        // A Latin word one space away.
        "我的 iPhone X S 坏了。", "I R S transcripts 我还没收到。",
        // A lone capital.
        "我们 A 组先上。", "选 A 还是 B？", "这件 T 恤",
        // Latin words, and letters already joined.
        "这个 PR 先别 merge，等 CI 跑完再说。", "我们用 Kubernetes 部署。",
        // Capitals that touch letters.
        "XA B 测试", "PR D E 测试", "A Bc 测试", "abc D E 测试", "A.B.c 测试", "x.A.B. 测试",
        // Six spelled capitals and five dotted ones.
        "A B C D E F 六个", "A.B.C.D.E. 五个",
        // Other capitals glued to a digit.
        "5G A 股涨了。",
        // A number and a byte unit that the model already joined, with a space between.
        "这台 MacBook 有16 GB 内存。",
        // Letters spelled on purpose.
        "Lee 的拼写是 L E E。", "我叫 Lee，L E E。", "这个 PR 和那个 P R", "C I 怎么拼？", "Spell it 一下，P R。",
        // Lower case, two spaces, full width letters, and periods with spaces.
        "p r 先别合", "P  R 先别合", "Ｐ Ｒ 先别合", "O. K. 吧",
        // No Chinese characters: English, kana and Hangul.
        "iPhone X S", "The P R and the C I are ready.", "O.K., the A.I. is here.", "この P R をみてください。",
        "P R 를 머지해 주세요.", "",
    ]

    @Test(arguments: stored)
    func storedTextsAreJoined(_ input: String, _ expected: String) {
        #expect(SpelledLetters.joining(in: input) == expected)
    }

    @Test(arguments: joined)
    func joins(_ input: String, _ expected: String) {
        #expect(SpelledLetters.joining(in: input) == expected)
    }

    @Test(arguments: kept)
    func keeps(_ text: String) {
        #expect(SpelledLetters.joining(in: text) == text)
    }

    @Test func applyingTwiceChangesNothingMore() {
        for text in (Self.stored + Self.joined).flatMap({ [$0.0, $0.1] }) + Self.kept {
            let once = SpelledLetters.joining(in: text)
            #expect(SpelledLetters.joining(in: once) == once, "\(text)")
        }
    }

    /// No text of Tools/rewrite-eval holds capitals the join changes, so the cleanup and
    /// translation evaluations get the same texts as before it.
    @Test func theEvaluationTextsStayTheSame() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: RewriteEvalFiles.folder.path)
            .filter { $0.hasSuffix(".jsonl") }
            .sorted()
        #expect(files.count >= 11)
        var checked = 0
        for file in files {
            for object in try RewriteEvalFiles.objects(file) {
                for (key, value) in object {
                    let texts = value as? [String] ?? (value as? String).map { [$0] } ?? []
                    for text in texts {
                        #expect(SpelledLetters.joining(in: text) == text, "\(file) \(object["id"] ?? "") \(key)")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked >= 8000)
    }

    @Test func longTextIsJoinedInOnePass() {
        let sentence = "这个 P R 先别 merge，等 C I 跑完再说，这台 MacBook 有16 G B 内存，O.K.。"
        let expected = "这个 PR 先别 merge，等 CI 跑完再说，这台 MacBook 有16GB 内存，OK。"
        let text = String(repeating: sentence, count: 500)
        let clock = ContinuousClock()
        var result = ""
        let elapsed = clock.measure {
            result = SpelledLetters.joining(in: text)
        }
        #expect(result == String(repeating: expected, count: 500))
        #expect(elapsed < .seconds(5))
    }
}
