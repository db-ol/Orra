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
        // 0302_mixed in earlier runs, with a Latin word right after the letters.
        ("我们之前有聊过一个 A I Robert。", "我们之前有聊过一个 AI Robert。"),
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
        ("N.B.A. 总决赛", "NBA 总决赛"),
        ("U.S.-China 关系", "US-China 关系"),
        // Versions and model names.
        ("用 G P T-4o 写的", "用 GPT-4o 写的"),
        ("Qwen3 A S R 很准", "Qwen3 ASR 很准"),
        ("R L H F 和 D P O 的区别", "RLHF 和 DPO 的区别"),
        // Dates, money and sizes.
        ("11 月 6 号 P R 合并", "11 月 6 号 PR 合并"),
        ("一共 100 U S D", "一共 100 USD"),
        ("一共 R M B 100 元", "一共 RMB 100 元"),
        ("12 G B 内存和 512 G B 硬盘", "12GB 内存和 512GB 硬盘"),
        ("这个文件 3.5 G B", "这个文件 3.5GB"),
        // A Latin word in the sentence, but not one space before the letters, and a Latin
        // word right after them.
        ("这个 bug 的 P R 我看了", "这个 bug 的 PR 我看了"),
        ("提 P R review 一下", "提 PR review 一下"),
        ("等 C I pass 了再 merge", "等 CI pass 了再 merge"),
        ("这个 A P I call 太慢", "这个 API call 太慢"),
        ("I R S transcripts 我还没收到。", "IRS transcripts 我还没收到。"),
        // Japanese with kanji counts as text with Chinese characters. A Japanese dictation
        // skips the rule steps, see PushToTalkControllerTests.
        ("この P R を確認してください", "この PR を確認してください"),
    ]

    /// Known costs of the rule, kept here so that a change of them is deliberate: letters
    /// meant apart, initials of a name, and a capital after a number one space away that
    /// belongs to it.
    static let knownCosts: [(String, String)] = [
        ("A B 两组", "AB 两组"),
        ("有 S M L 三个尺码", "有 SML 三个尺码"),
        ("J.K. 罗琳的新书", "JK 罗琳的新书"),
        ("5 G A 股涨了", "5 GA 股涨了"),
    ]

    static let kept = [
        // A Latin word one space before the letters.
        "我的 iPhone X S 坏了。",
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
        "P R 를 머지해 주세요.", "", "I said A B C",
        // Versions after a Latin word one space before the letters.
        "用 Mac O S 15 的时候", "升级到 i O S 18 了",
        // Capitals glued to a number that are no byte unit, and a lone one after a number.
        "5P M 开会", "一共 100U S D", "月薪 20 K",
        // Capitals apart in other ways.
        "从 A 到 B", "A、B 两组", "S.H.E 的歌", "U.S.A 的", "这个 M o E 模型",
        // A dictation about letters.
        "字母 A B C",
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

    @Test(arguments: knownCosts)
    func joinsDespiteTheKnownCosts(_ input: String, _ expected: String) {
        #expect(SpelledLetters.joining(in: input) == expected)
    }

    /// The rule steps in the order of the app: a filler between or around the letters goes
    /// first, then the numbers, then the join.
    @Test func joinsAfterTheFillerAndNumberRules() {
        let cases = [
            ("嗯，这个 P R 呃先别 merge，等 C I 跑完。", "这个 PR 先别 merge，等 CI 跑完。"),
            ("这个 P 呃 R 先别合。", "这个 PR 先别合。"),
            ("嗯 A B 测试呃做完了，用了两百五十六 G B。", "AB 测试做完了，用了256GB。"),
            ("呃 O.K. 那就这样。", "OK 那就这样。"),
        ]
        for (input, expected) in cases {
            let ruled = SpelledLetters.joining(in: NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: input)))
            #expect(ruled == expected, "\(input)")
        }
    }

    @Test func applyingTwiceChangesNothingMore() {
        for text in (Self.stored + Self.joined + Self.knownCosts).flatMap({ [$0.0, $0.1] }) + Self.kept {
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

    /// Gate run folders named in TEST_RUNNER_ORRA_SPELLED_LETTERS_RUNS, separated by colons.
    static var storedRuns: [URL]? {
        guard let paths = ProcessInfo.processInfo.environment["ORRA_SPELLED_LETTERS_RUNS"], !paths.isEmpty else { return nil }
        return paths.split(separator: ":").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// Joins the stored texts of release gate runs, so the change can be scored without a
    /// model. Only when asked for, with TEST_RUNNER_ORRA_SPELLED_LETTERS_RUNS naming the run
    /// folders and TEST_RUNNER_ORRA_SPELLED_LETTERS_OUT a folder for the results:
    ///
    ///     TEST_RUNNER_ORRA_SPELLED_LETTERS_RUNS=<run>[:<run>...] TEST_RUNNER_ORRA_SPELLED_LETTERS_OUT=<folder> xcodebuild ... test -only-testing:OrraTests/SpelledLettersTests
    ///
    /// For each run it writes <folder>/<run>.json with two maps: corpus, the ruled_text of
    /// every clip of raw/corpus.json after the join, where the dictation language of the
    /// corpus evaluation takes the rule steps, and sets, the text of every clip of
    /// raw/sets-raw.json after the join, by set and ID. The set evaluation dictates in
    /// Chinese, so every text takes the rule steps. Copies of the run with these texts can
    /// then be scored with Tools/release-gate/gate.py. Counts only on the console.
    @Test(.enabled(if: SpelledLettersTests.storedRuns != nil))
    @MainActor
    func joinTheStoredTextsOfGateRuns() throws {
        let runs = try #require(Self.storedRuns)
        let path = try #require(ProcessInfo.processInfo.environment["ORRA_SPELLED_LETTERS_OUT"], "no TEST_RUNNER_ORRA_SPELLED_LETTERS_OUT")
        let out = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for run in runs {
            var corpus: [String: String] = [:]
            var sets: [String: String] = [:]
            var changed = 0
            let corpusFile = run.appendingPathComponent("raw/corpus.json")
            if FileManager.default.fileExists(atPath: corpusFile.path) {
                let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: corpusFile)) as? [String: Any])
                let clips = try #require(document["clips"] as? [String: [String: Any]])
                for (id, row) in clips {
                    let text = row["text"] as? String ?? ""
                    let ruled = row["ruled_text"] as? String ?? text
                    let takesSteps = LanguageGuard.takesChineseAndEnglishSteps(text, for: SpeechCorpus.dictationLanguage)
                    corpus[id] = takesSteps ? SpelledLetters.joining(in: ruled) : ruled
                    changed += corpus[id] == ruled ? 0 : 1
                }
            }
            let setsFile = run.appendingPathComponent("raw/sets-raw.json")
            if FileManager.default.fileExists(atPath: setsFile.path) {
                let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: setsFile)) as? [String: Any])
                let clips = try #require(document["clips"] as? [[String: Any]])
                for row in clips {
                    let set = try #require(row["set"] as? String)
                    let id = try #require(row["id"] as? String)
                    let key = "\(set)/\(id)"
                    let text = row["text"] as? String ?? ""
                    sets[key] = SpelledLetters.joining(in: text)
                    changed += sets[key] == text ? 0 : 1
                }
            }
            try #require(!corpus.isEmpty || !sets.isEmpty, "no stored texts in \(run.path)")
            let data = try JSONSerialization.data(withJSONObject: ["corpus": corpus, "sets": sets], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: out.appendingPathComponent("\(run.lastPathComponent).json"))
            print("\(run.lastPathComponent): \(corpus.count) corpus texts, \(sets.count) set texts, \(changed) changed")
        }
    }
}
