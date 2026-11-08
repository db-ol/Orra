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

    /// Whether the text holds a filler or a self correction cue of the lists above.
    static func hasFillerOrCorrectionCue(_ text: String) -> Bool {
        if chineseCues.contains(where: text.contains) { return true }
        return text.contains(englishCuePattern)
    }

    /// Whether the text holds a filler, a self correction cue or a repeat, so the cleanup
    /// model may change it. Text without one is pasted at once, without waiting for the model.
    static func hasWorkForModel(_ text: String) -> Bool {
        hasFillerOrCorrectionCue(text) || hasRepeat(text)
    }

    /// Whether a Chinese character, an English word or a phrase of up to four of them comes
    /// twice in a row, with nothing, a space or a comma between, in any case: 我我觉得,
    /// 然后，然后, “the the”, “We we” or 这个 PR 这个 PR. Doubled words such as 看看 and
    /// 谢谢 count too, which only costs a model run, since the model keeps them.
    static func hasRepeat(_ text: String) -> Bool {
        // Chinese characters and English words, and nil for anything but a space or a comma
        // between them.
        var units: [String?] = []
        var word = ""
        for character in text.lowercased() + " " {
            if character.isASCIILetter || (character == "'" && !word.isEmpty) {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                units.append(word)
                word = ""
            }
            if character.containsHan {
                units.append(String(character))
            } else if !character.isWhitespace, !",，、".contains(character) {
                units.append(nil)
            }
        }
        for length in 1...4 {
            for start in units.indices where start + 2 * length <= units.count {
                let first = units[start ..< start + length]
                if !first.contains(nil), first.elementsEqual(units[start + length ..< start + 2 * length]) {
                    return true
                }
            }
        }
        return false
    }

    /// The gate the app uses. The filler rule removes um, uh and 呃 before the model runs,
    /// and the text around them may still need the model, so a cue in the heard text
    /// counts as well as one in the ruled text.
    static func hasWorkForModel(_ ruled: String, heard: String) -> Bool {
        hasWorkForModel(ruled) || hasWorkForModel(heard)
    }

    /// The gate without repeats, for the notice that a dictation over `maximumLength` was
    /// pasted without cleanup. A repeat alone gets no notice, since a long Chinese dictation
    /// often holds doubled words that are meant, such as 看看 or 谢谢谢谢.
    static func hasFillerOrCorrectionCue(_ ruled: String, heard: String) -> Bool {
        hasFillerOrCorrectionCue(ruled) || hasFillerOrCorrectionCue(heard)
    }
}
