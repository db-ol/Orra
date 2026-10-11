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

    @Test func aSlowModelIsCutOffAtTheTimeout() async {
        let started = ContinuousClock.now
        let result = await CleanupStep.run("我们下周二开会。", timeout: .milliseconds(200), complete: { _ in
            try await Task.sleep(for: .seconds(10))
            return #"{"cleaned": "我们下周二开会。"}"#
        })
        #expect(result.text == "我们下周二开会。")
        #expect(result.outcome == .timedOut)
        #expect(started.duration(to: .now) < .seconds(5))
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

    @Test func outcomesAreLoggedWithoutText() {
        #expect(CleanupStep.Outcome.heldBack(.newNumber(["13812345678"])).logName == "held back by the new number check")
        #expect(CleanupStep.Outcome.timedOut.logName == "timed out")
    }
}

/// The pinned cleanup model and its folder.
struct CleanupModelPinTests {
    @Test func pinnedValues() {
        let manifest = ModelManifest.qwen3Cleanup
        #expect(manifest.id == "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        #expect(manifest.files.map(\.name) == ["config.json", "generation_config.json", "tokenizer_config.json", "merges.txt", "vocab.json", "model.safetensors"])
        #expect(manifest.totalBytes == 2_267_477_719)
        #expect(ModelInstaller.State.size(manifest.totalBytes) == "2.27 GB")
        for file in manifest.files {
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "\(file.name)")
        }
        #expect(manifest.files.filter(\.resumable).map(\.name) == ["model.safetensors"])
        #expect(manifest.folderName == "Qwen3-4B-Instruct-2507-4bit-50d42775")
        #expect(manifest.huggingFaceRevision == "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b")
        #expect(manifest.modelScopeRevision == "ec7ca96008a45bebdd03ad3d09d86f6e61a3e4af")
    }

    @Test func sourceURLs() {
        let weights = ModelManifest.qwen3Cleanup.files[5]
        #expect(ModelSource.huggingFace.url(for: weights, in: .qwen3Cleanup).absoluteString
            == "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/model.safetensors")
        #expect(ModelSource.modelScope.url(for: weights, in: .qwen3Cleanup).absoluteString
            == "https://modelscope.cn/models/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/ec7ca96008a45bebdd03ad3d09d86f6e61a3e4af/model.safetensors")
        #expect(ModelSource.hfMirror.url(for: weights, in: .qwen3Cleanup).absoluteString
            == "https://hf-mirror.com/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/model.safetensors")
    }

    /// Its own folder next to the speech model's, and neither removes the other.
    @Test func folders() {
        let folders = ModelFolders.liveCleanup
        #expect(folders.models == ModelFolders.live.models)
        #expect(folders.oldCopies.isEmpty)
        #expect(folders.installed(.qwen3Cleanup).path.hasSuffix("/io.github.db-ol.Orra/Models/Qwen3-4B-Instruct-2507-4bit-50d42775"))
        #expect(!ModelManifest.qwen3Cleanup.folderName.hasPrefix(ModelManifest.qwen3.name + "-"))
        #expect(!ModelManifest.qwen3.folderName.hasPrefix(ModelManifest.qwen3Cleanup.name + "-"))
    }

    @Test func leftoversOfTheOtherModelStay() throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let speech = temporary.folders.models.appendingPathComponent(ModelManifest.qwen3.folderName)
        let cleanupOld = temporary.folders.models.appendingPathComponent("Qwen3-4B-Instruct-2507-4bit-00000000")
        for folder in [speech, cleanupOld] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        ModelDisk.removeLeftovers(.qwen3Cleanup, temporary.folders)
        #expect(FileManager.default.fileExists(atPath: speech.path))
        #expect(!FileManager.default.fileExists(atPath: cleanupOld.path))
    }
}
