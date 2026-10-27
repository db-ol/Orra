import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Orra

/// Vision on this Mac, through TextRecognizer as the index calls it, on a PNG of English and
/// Chinese drawn with CoreText. Every other test of recognition uses a stand in. Only with
/// TEST_RUNNER_ORRA_RECOGNITION=1, never in CI: on the virtual machine of CI, with macOS
/// 27.0.1 on 2026-10-27, Vision could not read the image, and the test took 55 s to skip
/// itself. It skips itself where Vision lacks Chinese or English, and where Vision cannot
/// read an image at all, so it never fails for that. It runs Vision, so only under the lock
/// the GPU work of the tests shares:
///
///     TEST_RUNNER_ORRA_RECOGNITION=1 xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/VisionTextRecognitionTests
@Suite(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["ORRA_RECOGNITION"] != nil))
struct VisionTextRecognitionTests {
    /// Whether Vision's accurate recognition lists Chinese and English, which the test reads.
    static var readsChineseAndEnglish: Bool {
        guard let languages = VisionText.supportedLanguages() else { return false }
        return TextRecognizer.chineseAndEnglish.allSatisfy(languages.contains)
    }

    @Test(.enabled(if: readsChineseAndEnglish, "Vision reads Chinese and English on this Mac"))
    func recognizesEnglishAndChineseOnThisMac() async throws {
        // The app asks for Chinese and English first on such a Mac, then what it reads of
        // Japanese and Spanish.
        #expect(VisionText.languages.starts(with: TextRecognizer.chineseAndEnglish))
        let folder = try TextRecognitionTests.Folder()
        defer { folder.remove() }
        let image = try RecognitionTestFiles.image(["Lobby lamps 12 pcs", "灯具清单"], width: 1_200, height: 300, points: 64)
        let job = try folder.job("lamps.png", try RecognitionTestFiles.data([image], type: .png), pages: 1)
        let read = try await TextRecognizer().recognize(job, mayGoOn: { true }).get()
        guard read.tried[0] != .failed else {
            try Test.cancel("Vision could not read an image on this Mac")
        }
        let text = read.pages.map(\.text).joined(separator: "\n").filter { !$0.isWhitespace }
        #expect(text.contains("Lobbylamps12pcs"), "\(read.pages.map(\.text))")
        #expect(text.contains("灯具清单"), "\(read.pages.map(\.text))")
        #expect(read.tried == [0: .text] && read.isDone && read.hiddenRuns == 0)
    }
}
