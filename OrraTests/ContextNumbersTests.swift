import Foundation
import Testing
@testable import Orra

/// Numbers taken from the pass without the vocabulary. The texts are written for these
/// tests, after the patterns the speech corpus showed.
struct ContextNumbersTests {
    @Test func spokenNumbersAreFound() {
        #expect(ContextNumbers.mayHoldSpokenNumber("自一九六六年以来"))
        #expect(ContextNumbers.mayHoldSpokenNumber("生活着四百只老虎"))
        #expect(ContextNumbers.mayHoldSpokenNumber("增长了百分之三十"))
        #expect(ContextNumbers.mayHoldSpokenNumber("达到六点五级"))
        #expect(ContextNumbers.mayHoldSpokenNumber("在六点半出发"))
        #expect(ContextNumbers.mayHoldSpokenNumber("比分是六比六"))
    }

    @Test func singleNumeralsNeedNoSecondPass() {
        #expect(!ContextNumbers.mayHoldSpokenNumber("我买了三本书"))
        #expect(!ContextNumbers.mayHoldSpokenNumber("快一点，等我一下"))
        #expect(!ContextNumbers.mayHoldSpokenNumber("我们用 Claude Code 写的"))
        #expect(!ContextNumbers.mayHoldSpokenNumber(""))
    }

    @Test(arguments: [
        ("一九六六", "1966"), ("二零零二", "2002"), ("零五", "05"), ("四百", "400"), ("十五", "15"),
        ("两千零五", "2005"), ("三十三万", "330000"), ("六千", "6000"), ("一百零五", "105"),
        ("六点五", "6.5"), ("零点五", "0.5"), ("十一", "11"), ("六", "6"), ("两", "2"),
    ])
    func chineseNumbersHaveTheirValue(text: String, value: String) {
        #expect(ContextNumbers.value(of: text) == value)
    }

    @Test(arguments: ["三万五", "一百五", "二十三十", "两两", "十一点三十五", "", "三个"])
    func unclearNumbersHaveNoValue(text: String) {
        #expect(ContextNumbers.value(of: text) == nil)
    }

    @Test func digitsOfTheSameValueReplaceTheWords() {
        let merged = ContextNumbers.merging(
            "自一九六六年以来，目前生活着四百只老虎和大约三万只鹿。",
            plain: "自1966年以来，目前生活着400只老虎和大约3万只鹿。",
            terms: ["老虎保护"]
        )
        #expect(merged == "自1966年以来，目前生活着400只老虎和大约3万只鹿。")
    }

    @Test func timesPercentagesAndModelNumbersAreTaken() {
        #expect(ContextNumbers.merging("晚上十一点三十五分扑灭了大火。", plain: "晚上11点35分扑灭了大火。", terms: ["x"])
            == "晚上11点35分扑灭了大火。")
        #expect(ContextNumbers.merging("收入增长了百分之三十。", plain: "收入增长了30%。", terms: ["x"]) == "收入增长了30%。")
        // The space before M is not part of the number and stays.
        #expect(ContextNumbers.merging("他的 M 十六步枪", plain: "他的M16步枪", terms: ["x"]) == "他的 M16步枪")
        #expect(ContextNumbers.merging("没有达到六点五级", plain: "没有达到6.5级", terms: ["x"]) == "没有达到6.5级")
    }

    @Test func punctuationAroundTheNumberComesWithTheDigits() {
        #expect(ContextNumbers.merging("距离五十公里、三十一英里的城市", plain: "距离50公里（31英里）的城市", terms: ["x"])
            == "距离50公里（31英里）的城市")
    }

    @Test func everythingElseStaysAsWrittenWithTheVocabulary() {
        // The term comes from the pass with the vocabulary, the number from the other.
        let merged = ContextNumbers.merging(
            "我们在二零二四年开始用 Claude Code。",
            plain: "我们在2024年开始用 Cloud Code。",
            terms: ["Claude Code"]
        )
        #expect(merged == "我们在2024年开始用 Claude Code。")
    }

    @Test func aDifferentNumberIsNotTaken() {
        #expect(ContextNumbers.merging("生活着四百只老虎", plain: "生活着40只老虎", terms: ["x"]) == "生活着四百只老虎")
        #expect(ContextNumbers.merging("大约三万五千人", plain: "大约3.5万人", terms: ["x"]) == "大约三万五千人")
        #expect(ContextNumbers.merging("增长了百分之三十", plain: "增长了30", terms: ["x"]) == "增长了百分之三十")
    }

    @Test func aTermWithANumberStays() {
        #expect(ContextNumbers.merging("我在读三体第二部", plain: "我在读3体第二部", terms: ["三体"]) == "我在读三体第二部")
        #expect(ContextNumbers.merging("他是十三号员工", plain: "他是13号员工", terms: ["十三号"]) == "他是十三号员工")
    }

    @Test func emptyOrEqualPassesChangeNothing() {
        #expect(ContextNumbers.merging("一九六六年", plain: "", terms: ["x"]) == "一九六六年")
        #expect(ContextNumbers.merging("一九六六年", plain: "一九六六年", terms: ["x"]) == "一九六六年")
        #expect(ContextNumbers.merging("", plain: "1966年", terms: ["x"]) == "")
    }
}

@MainActor
struct ContextNumbersTranscriptionTests {
    let speech = FakeSpeech()

    @Test func numbersComeFromThePassWithoutTheVocabulary() async throws {
        speech.reply = "Orra 在二零二四年发布。"
        speech.replyWithoutContext = "Aura 在2024年发布。"
        let text = try await speech.transcription.transcribe([0.1], vocabulary: ["Orra"], audioSeconds: 1)
        #expect(text == "Orra 在2024年发布。")
        #expect(speech.receivedContexts == ["Orra", nil])
    }

    @Test func textWithoutSpokenNumbersIsTranscribedOnce() async throws {
        speech.reply = "Orra 发布了三个版本。"
        let text = try await speech.transcription.transcribe([0.1], vocabulary: ["Orra"], audioSeconds: 1)
        #expect(text == "Orra 发布了三个版本。")
        #expect(speech.receivedContexts == ["Orra"])
    }

    @Test func withoutAVocabularyThereIsNoSecondPass() async throws {
        speech.reply = "在二零二四年发布。"
        let text = try await speech.transcription.transcribe([0.1], vocabulary: [], audioSeconds: 1)
        #expect(text == "在二零二四年发布。")
        #expect(speech.receivedContexts == [nil])
    }

    @Test func aFailedPassKeepsTheText() async throws {
        speech.reply = "Orra 在二零二四年发布。"
        speech.transcribeErrorWithoutContext = TestError()
        let text = try await speech.transcription.transcribe([0.1], vocabulary: ["Orra"], audioSeconds: 1)
        #expect(text == "Orra 在二零二四年发布。")
    }

    @Test func cancellationIsNotSwallowed() async {
        speech.reply = "Orra 在二零二四年发布。"
        speech.transcribeErrorWithoutContext = CancellationError()
        await #expect(throws: CancellationError.self) {
            try await speech.transcription.transcribe([0.1], vocabulary: ["Orra"], audioSeconds: 1)
        }
    }
}
