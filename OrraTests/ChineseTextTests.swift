import Testing
@testable import Orra

struct ChineseTextTests {
    @Test func convertsTraditionalCharacters() {
        // An output from the public baseline that switched script mid sentence.
        #expect(ChineseText.simplified("预计国会议員諾曼·蘭姆將接替代為空出的商業部長一職")
            == "预计国会议员诺曼·兰姆将接替代为空出的商业部长一职")
    }

    @Test(arguments: ["他在这里著书", "乾隆皇帝", "著名作家", "干净的面条", "理发", "俱乐部", "大阪"])
    func keepsValidSimplifiedText(_ text: String) {
        #expect(ChineseText.simplified(text) == text)
    }

    @Test func convertsMixedChineseAndEnglish() {
        #expect(ChineseText.simplified("這個 PR 先 merge 一下") == "这个 PR 先 merge 一下")
        #expect(ChineseText.simplified("還有 James Harden") == "还有 James Harden")
    }

    @Test func convertsTraditionalCharactersThatAreAlsoInGB2312() {
        #expect(ChineseText.simplified("然後我們再討論關於這個問題。") == "然后我们再讨论关于这个问题。")
    }

    @Test func leavesCharactersWithoutAGoodSimplifiedFormAlone() {
        #expect(ChineseText.simplified("看到這個真的很噁心") == "看到这个真的很噁心")
    }

    @Test(arguments: ["日本語を話します", "電車で会社に行きます。"])
    func leavesJapaneseAlone(_ text: String) {
        #expect(ChineseText.simplified(text) == text)
    }

    @Test func leavesMostlyEnglishTextAlone() {
        #expect(ChineseText.simplified("I really love the food in 臺北 today") == "I really love the food in 臺北 today")
        #expect(ChineseText.simplified("Ship it.") == "Ship it.")
        #expect(ChineseText.simplified("") == "")
    }

    @Test func mostlyChineseCountsCharactersAgainstWords() {
        #expect(ChineseText.isMostlyChinese("这个 PR 先 merge 一下"))
        #expect(ChineseText.isMostlyChinese("Hello world") == false)
        #expect(ChineseText.isMostlyChinese("2026 年") == true)
    }
}
