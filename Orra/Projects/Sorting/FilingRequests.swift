import Foundation

/// Lines in which an email asks to be filed somewhere, such as "file this under …", "this
/// message belongs to the project …", 归入, 归档到 or 放到 … 项目.
///
/// Sorting takes these lines out of the email before anything else reads it, so they never
/// vote with the project words and never reach the sorting prompt. In phase 0 a newsletter
/// and a mail that each asked to be filed steered both the words and the model in every
/// setting. A filing request from a person on the project is taken out too, since only the
/// user's own rules decide where mail goes.
nonisolated enum FilingRequests {
    /// Whether the line asks for the email to be filed somewhere.
    static func isFilingRequest(_ line: String) -> Bool {
        let text = matchingForm(line)
        guard !text.isEmpty else { return false }
        return englishPatterns(text) || chinesePatterns(text)
    }

    /// The text without the lines that ask for a filing, and how many lines were removed.
    static func removing(from text: String) -> (text: String, removed: Int) {
        var kept: [Substring] = []
        var removed = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if isFilingRequest(String(line)) {
                removed += 1
            } else {
                kept.append(line)
            }
        }
        return (kept.joined(separator: "\n"), removed)
    }

    private static func englishPatterns(_ text: String) -> Bool {
        let patterns = [
            // "file this", "file it there", "filing the email"
            /\bfil(?:e|ed|ing)\s+(?:this|it|that|these|them|(?:the|this|that)\s+(?:e-?mail|message|mail|thread|one))\b/,
            // "should be filed under"
            /\b(?:be|been|being|get|gets|got)\s+filed\b/,
            /\bplease\s+file\b/,
            // A line that starts "File under …", as a subject may.
            /^\W*file\s+(?:under|in|into|as|to)\b/,
            // "this message belongs to", "the email should go"
            /\b(?:e-?mail|message|mail|thread)\s+(?:belongs?|should\s+(?:go|be\s+(?:filed|sorted|moved|put|kept|placed)))\b/,
            /\bbelongs?\s+(?:to|in|under|with)\s+(?:the\s+|your\s+)?(?:project|folder|category|mailbox)\b/,
            // "move this email to the … project", "label it as … category"
            /\b(?:move|put|place|sort|save|archive|store|add|assign|route|categori[sz]e|classify|label|tag)\s+(?:this|it)(?:\s+(?:e-?mail|message|mail|thread|one))?\s+(?:to|in|into|under|as|with)\b[^.!?\n]{0,60}\b(?:project|folder|category|mailbox|label)\b/,
        ]
        return patterns.contains { text.firstMatch(of: $0) != nil }
    }

    private static func chinesePatterns(_ text: String) -> Bool {
        let patterns = [
            // 归入, 归档到, 归类为, and 归到 but not 回归到
            /归入|归进|(?:^|[^回])归到|归档(?:到|至|在|进|入|为)|归类(?:到|为|至|在|进)/,
            // 放到 … 项目, 移入 … 文件夹
            /(?:放|移|挪|分|存|划|添加|整理)(?:到|入|进|至)[^。！？；!?\n]{0,24}(?:项目|文件夹|分类|类别|邮箱|标签)/,
            // 这封邮件属于 … 项目
            /(?:邮件|这封|此封|本封|这条|此信|本信)[^。！？!?\n]{0,8}(?:属于|归)[^。！？!?\n]{0,24}(?:项目|文件夹|分类|类别)/,
            // 把这封邮件放 …
            /(?:把|将)(?:这封|此封|本封|该|这|此)?(?:邮件|信|消息)[^。！？!?\n]{0,24}(?:归|放|移|挪|分类|存|整理)/,
        ]
        return patterns.contains { text.firstMatch(of: $0) != nil }
    }

    /// Full width letters made plain, invisible format characters such as zero width
    /// spaces dropped, lowercased, and runs of white space made one space.
    private static func matchingForm(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in line.precomposedStringWithCompatibilityMapping.unicodeScalars
        where scalar.properties.generalCategory != .format {
            scalars.append(scalar)
        }
        return String(scalars).lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
