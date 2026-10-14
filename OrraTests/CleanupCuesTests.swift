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
}
