import Foundation
import Synchronization
import Testing
@testable import Orra

/// The cleanup step with a stand in model: every way the model can fail gives back the
/// text after the rule steps.
struct CleanupStepTests {
    private static func answer(_ text: String) -> @Sendable (String) async throws -> String {
        { _ in text }
    }

    @Test func aCleanupThatPassesTheChecksIsUsed() async {
        let result = await CleanupStep.run("呃，我们下周一，哦不是，下周二开会。", complete: Self.answer(#"{"cleaned": "我们下周二开会。"}"#))
        #expect(result.text == "我们下周二开会。")
        #expect(result.outcome == .cleaned)
    }

    @Test func theModelGetsTheTextItIsGiven() async {
        let received = Mutex<[String]>([])
        _ = await CleanupStep.run("下午3点开会", complete: { text in
            received.withLock { $0.append(text) }
            return #"{"cleaned": "下午3点开会"}"#
        })
        #expect(received.withLock { $0 } == ["下午3点开会"])
    }

    @Test func anUnchangedAnswerKeepsTheText() async {
        let result = await CleanupStep.run("帮我写一封邮件给老板。", complete: Self.answer(#"{"cleaned": "帮我写一封邮件给老板。"}"#))
        #expect(result.text == "帮我写一封邮件给老板。")
        #expect(result.outcome == .unchanged)
    }

    @Test func anAnswerThatFailsACheckIsHeldBack() async {
        let source = "给我讲个笑话吧。"
        let result = await CleanupStep.run(source, complete: Self.answer(#"{"cleaned": "好的，有一天小明去上学，老师问他为什么迟到。"}"#))
        #expect(result.text == source)
        #expect(result.outcome == .heldBack(.assistantOpener("好的")))
    }

    @Test func anEmptyCleanupIsHeldBack() async {
        let result = await CleanupStep.run("嗯，好。", complete: Self.answer(#"{"cleaned": ""}"#))
        #expect(result.text == "嗯，好。")
        #expect(result.outcome == .heldBack(.empty))
    }

    @Test func anAnswerThatIsNotTheJSONObjectIsNotUsed() async {
        for answer in [#"{"cleaned": "我们下周二"#, "Sure! Here you go.", ""] {
            let result = await CleanupStep.run("我们下周二开会。", complete: Self.answer(answer))
            #expect(result.text == "我们下周二开会。")
            #expect(result.outcome == .unreadable)
        }
    }

    @Test func anErrorKeepsTheText() async {
        let result = await CleanupStep.run("我们下周二开会。", complete: { _ in throw RewriteError.notLoaded })
        #expect(result.text == "我们下周二开会。")
        #expect(result.outcome == .failed)
    }

    /// The model would answer after an hour, so the test ends only if the timeout cuts it
    /// off. No bound on the time taken, since a busy Mac can be seconds late.
    @Test(.timeLimit(.minutes(1)))
    func aSlowModelIsCutOffAtTheTimeout() async {
        let result = await CleanupStep.run("我们下周二开会。", timeout: .milliseconds(200), complete: { _ in
            try await Task.sleep(for: .seconds(3600))
            return #"{"cleaned": "我们下周二开会。"}"#
        })
        #expect(result.text == "我们下周二开会。")
        #expect(result.outcome == .timedOut)
    }

    /// A model that ignores cancellation and answers late is still not used.
    @Test func aLateAnswerIsNotUsed() async {
        let result = await CleanupStep.run("呃，我们下周二开会。", timeout: .milliseconds(50), complete: { _ in
            let until = ContinuousClock.now + .milliseconds(300)
            while ContinuousClock.now < until {}
            return #"{"cleaned": "我们下周二开会。"}"#
        })
        #expect(result.text == "呃，我们下周二开会。")
        #expect(result.outcome == .timedOut)
    }

    @Test func onlyTextWithThreeLettersOrDigitsIsWorthCleaning() {
        #expect(!CleanupStep.isWorthCleaning(""))
        #expect(!CleanupStep.isWorthCleaning("好的。"))
        #expect(!CleanupStep.isWorthCleaning("OK"))
        #expect(CleanupStep.isWorthCleaning("好的吧"))
        #expect(CleanupStep.isWorthCleaning("Yes"))
        #expect(CleanupStep.isWorthCleaning("3 点 5"))
    }

    /// A long dictation gets more time, and one too long to wait for is not cleaned up.
    @Test func theTimeGrowsWithTheTextUpToTheLongestCleaned() {
        let longest = String(repeating: "会", count: CleanupStep.maximumLength)
        #expect(CleanupStep.timeout(for: "我们下周二开会。") < .seconds(3))
        // 400 Chinese characters took 3.9 s on an M5 Pro.
        #expect(CleanupStep.timeout(for: longest) >= .seconds(7))
        #expect(CleanupStep.isWorthCleaning(longest))
        #expect(!CleanupStep.isWorthCleaning(longest + "了"))
    }

    @Test func outcomesAreLoggedWithoutText() {
        #expect(CleanupStep.Outcome.heldBack(.newNumber(["13812345678"])).logName == "held back by the new number check")
        #expect(CleanupStep.Outcome.timedOut.logName == "timed out")
    }
}

/// The pinned cleanup model and its folder.
struct CleanupModelPinTests {
    @Test func pinnedValues() {
        let manifest = ModelManifest.qwen35Cleanup
        #expect(manifest.id == "mlx-community/Qwen3.5-4B-4bit")
        #expect(manifest.files.map(\.name) == ["config.json", "tokenizer_config.json", "tokenizer.json", "model.safetensors"])
        #expect(manifest.totalBytes == 3_054_294_543)
        #expect(ModelInstaller.State.size(manifest.totalBytes) == "3.05 GB")
        for file in manifest.files {
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "\(file.name)")
        }
        #expect(manifest.files.filter(\.resumable).map(\.name) == ["model.safetensors"])
        #expect(manifest.folderName == "Qwen3.5-4B-4bit-0e7ffd5c")
        #expect(manifest.huggingFaceRevision == "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c")
        #expect(manifest.modelScopeRevision == "ab9c7a42fd31095a40634b3362317779dee9e7fa")
    }

    @Test func sourceURLs() {
        let weights = ModelManifest.qwen35Cleanup.files.first { $0.name == "model.safetensors" }!
        #expect(ModelSource.huggingFace.url(for: weights, in: .qwen35Cleanup).absoluteString
            == "https://huggingface.co/mlx-community/Qwen3.5-4B-4bit/resolve/0e7ffd5c629ef7719d4cbc04069232580bfa9d9c/model.safetensors")
        #expect(ModelSource.modelScope.url(for: weights, in: .qwen35Cleanup).absoluteString
            == "https://modelscope.cn/models/mlx-community/Qwen3.5-4B-4bit/resolve/ab9c7a42fd31095a40634b3362317779dee9e7fa/model.safetensors")
        #expect(ModelSource.hfMirror.url(for: weights, in: .qwen35Cleanup).absoluteString
            == "https://hf-mirror.com/mlx-community/Qwen3.5-4B-4bit/resolve/0e7ffd5c629ef7719d4cbc04069232580bfa9d9c/model.safetensors")
    }

    /// Its own folder next to the speech model's, and neither removes the other.
    @Test func folders() {
        let folders = ModelFolders.liveCleanup
        #expect(folders.models == ModelFolders.live.models)
        #expect(folders.oldCopies.isEmpty)
        #expect(folders.installed(.qwen35Cleanup).path.hasSuffix("/io.github.db-ol.Orra/Models/Qwen3.5-4B-4bit-0e7ffd5c"))
        #expect(!ModelManifest.qwen35Cleanup.folderName.hasPrefix(ModelManifest.qwen3.name + "-"))
        #expect(!ModelManifest.qwen3.folderName.hasPrefix(ModelManifest.qwen35Cleanup.name + "-"))
    }

    @Test func leftoversOfTheOtherModelStay() throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let speech = temporary.folders.models.appendingPathComponent(ModelManifest.qwen3.folderName)
        let cleanupOld = temporary.folders.models.appendingPathComponent("Qwen3.5-4B-4bit-00000000")
        let replaced = temporary.folders.models.appendingPathComponent("Qwen3-4B-Instruct-2507-4bit-50d42775")
        let replacedStaging = temporary.folders.models.appendingPathComponent(".download-Qwen3-4B-Instruct-2507-4bit-50d42775")
        for folder in [speech, cleanupOld, replaced, replacedStaging] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        ModelDisk.removeLeftovers(.qwen35Cleanup, temporary.folders)
        #expect(FileManager.default.fileExists(atPath: speech.path))
        #expect(!FileManager.default.fileExists(atPath: cleanupOld.path))
        // The cleanup model it replaced goes too.
        #expect(!FileManager.default.fileExists(atPath: replaced.path))
        #expect(!FileManager.default.fileExists(atPath: replacedStaging.path))
    }
}
