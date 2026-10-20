import Foundation

/// Lines in which an email asks to be filed somewhere, such as "file this under …", "this
/// message belongs to the project …", 归入, 归档到 or 放到 … 项目.
///
/// Sorting takes these lines out of the email before anything else reads it, so they never
/// vote with the project words and never reach the sorting prompt. In phase 0 a newsletter
/// and a mail that each asked to be filed steered both the words and the model in every
/// setting. A filing request from a person on the project is taken out too, since only the
/// user's own rules decide where mail goes. The patterns lean toward taking a line out,
/// since a line lost from the vote costs little and a request left in can steer it.
nonisolated enum FilingRequests {
    /// Whether the line asks for the email to be filed somewhere.
    static func isFilingRequest(_ line: String) -> Bool {
        let text = SortingText.matchingForm(line)
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
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

    /// The patterns, built once. They read the matching form, which is lowercased with full
    /// width letters made plain. NSRegularExpression, since it runs these about ten times
    /// faster than Swift's Regex, and sorting reads every line of every email.
    private static let patterns: [NSRegularExpression] = [
        // English
        // "file this under", "file it there.", "filing the email as". "We filed it with
        // the city" is not one.
        #"\bfil(?:e|ing)\s+(?:this|it|that|these|them|(?:the|this|that)\s+(?:e-?mail|message|mail|thread|one))(?:\s+(?:under|in|into|to|as|there|here|away|accordingly)\b|\s*(?:[.!)]|$))"#,
        // "should be filed under", but not "has been filed."
        #"\b(?:be|been|being|get|gets|got)\s+filed\s+(?:under|in|into|to|as|there|here|accordingly)\b"#,
        // A line that starts "File under …" or "Move to …", as a subject or a note may,
        // and "please file under …". "Please file the tax return" is not one.
        #"^\W*(?:file|move|sort)\s+(?:under|into|to|as)\b"#,
        #"\bplease\s+file\s+(?:under|in|into|as)\b"#,
        // "this message belongs to", "the email should go"
        #"\b(?:e-?mail|message|mail|thread)\s+(?:belongs?|should\s+(?:go|be\s+(?:filed|sorted|moved|put|kept|placed)))\b"#,
        // "this belongs to the Harbor Lights project"
        #"\bbelongs?\s+(?:to|in|under|with)\b[^.!?\n]{0,60}\b(?:project|folder|category|mailbox)\b"#,
        // "put this in Harbor Lights", "sort it into …", "this goes in …"
        #"\b(?:put|sort|file)\s+(?:this|it)(?:\s+(?:e-?mail|message|mail|thread|one))?\s+(?:in|into|under|to)\b"#,
        #"\b(?:this|it)(?:\s+(?:e-?mail|message|mail|thread|one))?\s+goes\s+(?:in|into|under)\b"#,
        // "move this email to the … project", "label it as … category"
        #"\b(?:move|put|place|sort|save|archive|store|add|assign|route|categori[sz]e|classify|label|tag)\s+(?:this|it)(?:\s+(?:e-?mail|message|mail|thread|one))?\s+(?:to|in|into|under|as|with)\b[^.!?\n]{0,60}\b(?:project|folder|category|mailbox|label)\b"#,
        #"\b(?:move|place|save|archive|store|assign|route|label|tag)\s+(?:this|the|that)\s+(?:e-?mail|message|mail|thread)\s+(?:to|in|into|under|as)\b"#,
        // Chinese
        // 归入, 归档到, 归档：, 归类为, and 归到 but not 回归到
        #"归入|归进|(?:^|[^回])归到|归档\s*(?:到|至|在|进|入|为|:)|归类(?:到|为|至|在|进)"#,
        // 放到 … 项目, 放在 … 项目下, 移动到 … 文件夹
        #"(?:放|移动?|挪|分|存|划|添加|整理)(?:到|入|进|至)[^。！？；!?\n]{0,24}(?:项目|文件夹|分类|类别|邮箱|标签)"#,
        #"放在[^。！？；!?\n]{0,24}(?:项目|文件夹|分类|类别|邮箱|标签)"#,
        // 这封邮件属于 … 项目
        #"(?:邮件|这封|此封|本封|这条|此信|本信)[^。！？!?\n]{0,8}(?:属于|归)[^。！？!?\n]{0,24}(?:项目|文件夹|分类|类别)"#,
        // 把这封邮件放 …, but not 将信息整理 or 将信用卡账单整理
        #"(?:把|将)(?:这封|此封|本封|该|这|此|本)?(?:邮件|消息|信(?![息用心号任誉]))[^。！？!?\n]{0,24}(?:归|放|移|挪|分类|存|整理)"#,
    ].map { try! NSRegularExpression(pattern: $0) }
}
