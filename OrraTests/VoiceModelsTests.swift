import Foundation
import Testing
@testable import Orra

/// The voice model's two downloads as one line and one button.
struct VoiceModelStatusTests {
    private let model = ModelManifest.qwen3Voice.totalBytes
    private let codec = ModelManifest.qwen3VoiceCodec.totalBytes

    private func status(_ first: ModelInstaller.State, _ second: ModelInstaller.State) -> VoiceModelStatus {
        VoiceModelStatus(first, second, modelTotal: model, codecTotal: codec)
    }

    @Test func bothInstalledIsInstalled() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        #expect(status(.installed(folder), .installed(folder)) == .installed)
        #expect(status(.installed(folder), .installed(folder)).line == nil)
        #expect(status(.installed(folder), .installed(folder)).buttonTitle == nil)
    }

    @Test func whatIsLeftCountsBoth() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        #expect(status(.missing(bytesPresent: 0), .missing(bytesPresent: 0)) == .missing(bytesLeft: model + codec))
        #expect(status(.missing(bytesPresent: 100), .installed(folder)) == .missing(bytesLeft: model - 100))
        #expect(status(.missing(bytesPresent: 0), .missing(bytesPresent: 0)).buttonTitle == "Download Voice Model (\(ModelInstaller.State.size(model + codec)))")
        #expect(status(.downloading(bytes: model, source: .huggingFace), .missing(bytesPresent: 0)) == .downloading(bytes: model, total: model + codec))
        #expect(status(.downloading(bytes: 0, source: nil), .installed(folder)).buttonTitle == "Cancel Download")
        #expect(status(.verifying, .installed(folder)) == .verifying)
        #expect(status(.failed(.offline), .downloading(bytes: 0, source: nil)) == .downloading(bytes: 0, total: model + codec))
        #expect(status(.failed(.offline), .installed(folder)) == .failed)
        #expect(status(.failed(.offline), .installed(folder)).buttonTitle == "Try Again")
        #expect(status(.checking, .installed(folder)) == .checking)
    }

    /// Weights pinned with their hashes, from two servers that carry both repositories.
    @Test func theManifestsArePinned() {
        for manifest in [ModelManifest.qwen3Voice, .qwen3VoiceCodec] {
            #expect(manifest.huggingFaceRevision.count == 40)
            #expect(manifest.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
            #expect(manifest.files.last?.name == "model.safetensors")
            #expect(manifest.files.last?.resumable == true)
        }
        #expect(VoiceModels.sources == [.huggingFace, .hfMirror])
    }
}
