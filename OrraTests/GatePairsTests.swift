import Foundation
import Testing
@testable import Orra

/// What the release gate's runs of the dictation pairs decide without a model: the sets a
/// run takes for its dictation language, the name of that language, the clip list of the
/// corpus evaluation and the count of the speech corpus. The evaluations themselves run only
/// when asked for, see GateSetEvaluationTests and SpeechCorpusEvaluationTests.
struct GatePairsTests {
    @Test func everyPairHasTheCodeOfItsLanguage() {
        #expect(DictationLanguage.allCases.map(\.pairCode) == ["zh", "ja", "es"])
    }

    /// A clip in the language of a pair but Chinese also runs with its language as the hint.
    @Test func theOtherLanguagesAreThoseOfThePairsButChinese() {
        #expect(SpeechCorpus.otherLanguages == ["ja": .japanese, "es": .spanish])
    }

    /// A name that is no dictation language must not run as Chinese.
    @Test func aDictationLanguageIsNamedAsTheChoiceIs() {
        #expect(SpeechCorpus.dictationLanguage(named: nil) == .chinese)
        #expect(SpeechCorpus.dictationLanguage(named: "Chinese") == .chinese)
        #expect(SpeechCorpus.dictationLanguage(named: "Japanese") == .japanese)
        #expect(SpeechCorpus.dictationLanguage(named: "Spanish") == .spanish)
        #expect(SpeechCorpus.dictationLanguage(named: "japanese") == nil)
        #expect(SpeechCorpus.dictationLanguage(named: "ja") == nil)
        #expect(SpeechCorpus.dictationLanguage(named: "") == nil)
    }

    @Test func aListOfClipsRunsInTheManifestsOrder() throws {
        let manifest = [(id: "a", language: "zh"), (id: "b", language: "ja"), (id: "c", language: "ja")]
        #expect(try SpeechCorpus.clips(manifest, listed: nil).map(\.id) == ["a", "b", "c"])
        #expect(try SpeechCorpus.clips(manifest, listed: ["c", "b"]).map(\.id) == ["b", "c"])
        #expect(throws: SpeechCorpus.UnknownClips.self) {
            _ = try SpeechCorpus.clips(manifest, listed: ["b", "x"])
        }
    }

    /// The count of 392 holds for the speech corpus only: Chinese, English, both, and the
    /// clips without speech.
    @Test func onlyTheSpeechCorpusHoldsItsLangsAlone() {
        let speech = [(id: "a", language: "zh"), (id: "b", language: "en"), (id: "c", language: "mixed"), (id: "d", language: "none")]
        #expect(SpeechCorpus.isSpeechCorpus(speech))
        #expect(!SpeechCorpus.isSpeechCorpus(speech + [(id: "e", language: "ko")]))
        #expect(!SpeechCorpus.isSpeechCorpus([(id: "f", language: "yue")]))
        #expect(!SpeechCorpus.isSpeechCorpus([(id: "g", language: "ja")]))
    }

    @Test func aRunTakesTheSetsOfItsPair() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.set("gate-core", in: root)
        try Self.set("zh-numbers-negation", in: root, settings: #"{"variants": [{"suffix": "_ctx0", "context": []}]}"#)
        try Self.set("zh-mirror", in: root, settings: #"{"pair": "zh"}"#)
        try Self.set("ja-core", in: root, settings: #"{"description": "Japanese", "pair": "ja"}"#)
        try Self.set("ko-core", in: root, settings: #"{"pair": "ko"}"#)
        try Self.set("ja-unbuilt", in: root, settings: #"{"pair": "ja"}"#, manifest: false)
        #expect(try GateSets.sets(in: root, for: .chinese) == ["gate-core", "zh-mirror", "zh-numbers-negation"])
        #expect(try GateSets.sets(in: root, for: .japanese) == ["ja-core"])
        #expect(try GateSets.sets(in: root, for: .spanish).isEmpty)
    }

    @Test func aBrokenSetJSONStopsTheRun() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.set("broken", in: root, settings: "{")
        #expect(throws: (any Error).self) {
            _ = try GateSets.sets(in: root, for: .chinese)
        }
    }

    private static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("io.github.db-ol.OrraTests.gate-pairs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func set(_ name: String, in root: URL, settings: String? = nil, manifest: Bool = true) throws {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if manifest {
            try Data("{\"id\": \"a\"}\n".utf8).write(to: folder.appendingPathComponent("manifest.jsonl"))
        }
        if let settings {
            try Data(settings.utf8).write(to: folder.appendingPathComponent("set.json"))
        }
    }
}
