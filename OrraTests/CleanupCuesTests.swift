import Testing
@testable import Orra

struct CleanupCuesTests {
    @Test func fillersAndCorrectionsGoToTheModel() {
        #expect(CleanupStep.hasWorkForModel("这个 bug 那个，就是说，还没修好。"))
        #expect(CleanupStep.hasWorkForModel("周五有个两点的电话会，哦不对，三点。"))
        #expect(CleanupStep.hasWorkForModel("我们先去北京再去上海，反了，先去上海再去北京。"))
        #expect(CleanupStep.hasWorkForModel("Book a table for four, no, make it six."))
        #expect(CleanupStep.hasWorkForModel("Send it Monday, I mean Tuesday."))
        #expect(CleanupStep.hasWorkForModel("It's, like, done."))
    }

    @Test func plainTextIsPastedAtOnce() {
        #expect(!CleanupStep.hasWorkForModel("周五的聚餐取消了。"))
        #expect(!CleanupStep.hasWorkForModel("The build is failing on the main branch."))
        // A cue only counts as a whole English word.
        #expect(!CleanupStep.hasWorkForModel("Please review the summary."))
    }

    @Test func repeatsGoToTheModel() {
        #expect(CleanupStep.hasWorkForModel("中中英能够夹杂起来说。"))
        #expect(CleanupStep.hasWorkForModel("他，他说明天不来了。"))
        #expect(CleanupStep.hasWorkForModel("我觉得我觉得价格有点高。"))
        #expect(CleanupStep.hasWorkForModel("Send the the file to Lisa."))
        #expect(CleanupStep.hasWorkForModel("We we need more time."))
        #expect(CleanupStep.hasWorkForModel("It's it's not ready."))
        #expect(CleanupStep.hasWorkForModel("Can you, can you check it?"))
        #expect(CleanupStep.hasWorkForModel("打开 Xcode 打开 Xcode 看一下。"))
        // Doubled words go too, and the model keeps them.
        #expect(CleanupStep.hasWorkForModel("谢谢你的帮助。"))
        #expect(CleanupStep.hasWorkForModel("This is very very important."))
    }

    @Test func wordsApartAreNoRepeat() {
        #expect(!CleanupStep.hasRepeat("我买了苹果。苹果很甜。"))
        #expect(!CleanupStep.hasRepeat("The theme is new."))
        #expect(!CleanupStep.hasRepeat("We met at 3, 3 days ago."))
        #expect(!CleanupStep.hasRepeat("周五的聚餐取消了。"))
        #expect(!CleanupStep.hasRepeat(String(repeating: "我们明天下午开会讨论一下。", count: 20)))
    }

    @Test func aFillerTheRuleRemovedStillGoesToTheModel() {
        let heard = "呃，我们周五开会。"
        let ruled = FillerRules.removingFillers(from: heard)
        #expect(!CleanupStep.hasWorkForModel(ruled))
        #expect(CleanupStep.hasWorkForModel(ruled, heard: heard))
        #expect(CleanupStep.hasWorkForModel("Ship it today.", heard: "Um, ship it today."))
        #expect(!CleanupStep.hasWorkForModel("周五的聚餐取消了。", heard: "周五的聚餐取消了。"))
    }
}
