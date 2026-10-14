import Foundation

nonisolated extension CleanupStep {
    /// Words that give the cleanup model something to do: fillers it removes and cues of a
    /// spoken self correction. They come from the prompt in RewritePrompt.swift and the
    /// cases in Tools/rewrite-eval. The list errs on the side of a cue, since a missed one
    /// pastes a filler or a correction as spoken, and an extra one only costs the model run.
    static let chineseCues = [
        "呃", "嗯", "啊", "哦", "噢", "额", "那个", "就是", "然后", "这个", "不对", "不是", "我是说",
        "我的意思是", "说错了", "改成", "改为", "应该是", "算了", "删掉", "撤回", "重来", "反了",
        "不，", "等一下", "等等", "其实",
    ]

    static let englishCues = [
        "um", "umm", "uh", "uhh", "er", "erm", "hmm", "mm", "like", "you know", "i mean",
        "sorry", "actually", "scratch that", "no wait", "wait", "so", "well", "basically",
        "literally", "sort of", "kind of", "rather", "correction", "make that", "make it", "no",
        "oops", "okay so",
    ]

    nonisolated(unsafe) private static let englishCuePattern: Regex<AnyRegexOutput> = {
        let words = englishCues.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        return try! Regex("\\b(?:" + words.joined(separator: "|") + ")\\b").ignoresCase()
    }()

    /// Whether the text holds a filler or a self correction cue, so the cleanup model may
    /// change it. Text without one is pasted at once, without waiting for the model.
    static func hasWorkForModel(_ text: String) -> Bool {
        if chineseCues.contains(where: text.contains) { return true }
        return text.contains(englishCuePattern)
    }
}
