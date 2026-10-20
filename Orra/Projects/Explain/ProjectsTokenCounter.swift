import Foundation

/// Counts the tokens of a Projects prompt as the cleanup model reads them, with the model's
/// own tokenizer, see CleanupTokenizer. It reads the tokenizer files of the installed model
/// only: no model, no GPU work and no download. So a prompt is measured and trimmed before
/// it holds the model, and the count is a plain synchronous closure, as ExplainPrompt needs.
nonisolated struct ProjectsTokenCounter: Sendable {
    private let tokenizer: CleanupTokenizer

    /// Reads the tokenizer files in `folder`, a folder of the cleanup model.
    @concurrent
    static func reading(_ folder: URL) async throws -> ProjectsTokenCounter {
        ProjectsTokenCounter(tokenizer: try await CleanupTokenizer(folder: folder))
    }

    /// The tokenizer of the cleanup model that ModelInstaller installed, or nil when not
    /// every file of the model is in place at its size. Off the main actor, since the
    /// tokenizer file is large.
    @concurrent
    static func installed(in folders: ModelFolders = .liveCleanup) async throws -> ProjectsTokenCounter? {
        let folder = folders.installed(.qwen35Cleanup)
        guard ModelDisk.isComplete(folder, .qwen35Cleanup) else { return nil }
        return try await reading(folder)
    }

    private init(tokenizer: CleanupTokenizer) {
        self.tokenizer = tokenizer
    }

    /// The tokens of `text` inside a prompt, without the tokens a tokenizer adds at the
    /// start of a whole text.
    func count(_ text: String) -> Int {
        tokenizer.encode(text: text, addSpecialTokens: false).count
    }

    /// `count` as the closure ExplainPrompt and ExplainService take.
    var countTokens: @Sendable (String) -> Int {
        { [tokenizer] text in tokenizer.encode(text: text, addSpecialTokens: false).count }
    }
}
