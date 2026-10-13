import Foundation

/// The start of the cleanup prompt that is the same for every transcript: the system text,
/// the examples and the start of the last user message. RewriteEngine runs the model on
/// these tokens once after it loads and keeps the cache, so a cleanup only has to run the
/// model on the tokens that follow.
///
/// The prefix is found by comparing the tokens of two prompts with different transcripts,
/// as the prefix cache test of the translation benchmark did. The tokenizer can merge the
/// end of the fixed text with the start of a transcript, so the prefix stops a little
/// before the first token that differs, and each prompt is checked against it before the
/// cache is used.
nonisolated enum PromptPrefix {
    /// How many tokens the prefix stops before the first token that differs.
    static let margin = 2

    /// The prefix of the cleanup prompt, from the prompts for a Chinese and an English
    /// transcript, which differ from their first character.
    static func cleanupPrompt(encode: (String) -> [Int]) -> [Int] {
        shared(encode(RewritePrompt.text(for: "你好")), encode(RewritePrompt.text(for: "Hello there")))
    }

    /// The tokens two prompts share at their start, less `margin`. Empty when they share
    /// fewer than that.
    static func shared(_ first: [Int], _ second: [Int]) -> [Int] {
        var count = 0
        while count < first.count, count < second.count, first[count] == second[count] {
            count += 1
        }
        return Array(first.prefix(max(0, count - margin)))
    }

    /// The tokens of a prompt after the prefix, or nil when the prompt does not start with
    /// the prefix or has nothing after it. Nil means the cache does not fit this prompt, and
    /// the whole prompt has to be run.
    static func remainder(of prompt: [Int], after prefix: [Int]) -> [Int]? {
        guard !prefix.isEmpty, prompt.count > prefix.count, prompt.starts(with: prefix) else { return nil }
        return Array(prompt[prefix.count...])
    }
}
