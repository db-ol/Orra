import Foundation

/// A translation between English and `language` into `target`, which is English or that
/// language. Each route has its own prompt, prefix cache and checks: Chinese into English
/// and into Chinese, as before the dictation language, Japanese into English and into
/// Japanese, and Spanish into English and into Spanish. A dictation takes the routes of the
/// user's dictation language. Live Captions take those of each sentence's language and of
/// the caption target, and two in turn through English between Chinese, Japanese and
/// Spanish, see CaptionTarget.
nonisolated struct TranslationRoute: Hashable, Sendable {
    let language: DictationLanguage
    let target: TranslationTarget

    /// The route of `language` into `target`, which has to be English or `language`'s own.
    init(_ language: DictationLanguage, into target: TranslationTarget) {
        precondition(language.translationTargets.contains(target), "No route of \(language) into \(target)")
        self.language = language
        self.target = target
    }

    /// A route of Chinese, for the functions that take a target alone.
    static func chinese(_ target: TranslationTarget) -> TranslationRoute {
        TranslationRoute(.chinese, into: target)
    }

    /// For the log: the target alone for Chinese, as before the dictation language, and
    /// with the dictation language otherwise, such as "English for Japanese dictation".
    var logName: String {
        language == .chinese ? target.logName : "\(target.logName) for \(language.rawValue) dictation"
    }
}

/// Which routes RewriteEngine keeps a translation prefix cache for, at most `capacity`.
/// That is `limit`, so a dictation holds no more caches than the two of Chinese did, and
/// while Live Captions run as many as the settings want, up to `captionsLimit`. Each takes
/// 110 to 127 MB.
nonisolated struct TranslationPrefixSlots: Equatable, Sendable {
    /// The two targets of one dictation language.
    static let limit = 2
    /// The two of the dictation language and two more for captions, such as Spanish into
    /// English and English into Japanese for a Chinese user who reads Japanese captions of
    /// a Spanish meeting, see CaptionTarget.routes(into:). Measured on 2026-10-19, the two
    /// more took 0.24 GB with the speech and cleanup models loaded.
    static let captionsLimit = 4

    /// The routes with a cache, the one used longest ago first.
    private(set) var routes: [TranslationRoute] = []
    /// The routes the user's settings want, see `keep(_:)`.
    private(set) var wanted: Set<TranslationRoute> = []
    /// The most caches kept now: as many as the settings want, from `limit` up to
    /// `captionsLimit`, see `keep(_:)`.
    private(set) var capacity = TranslationPrefixSlots.limit

    /// Marks `route` as used, and gives back the routes to drop so the caches stay within
    /// `capacity`: first those the settings do not want, then those used longest ago.
    mutating func use(_ route: TranslationRoute) -> [TranslationRoute] {
        routes.removeAll { $0 == route }
        routes.append(route)
        return dropBeyondCapacity()
    }

    /// Keeps only the routes in `wanted` and gives back those to drop. The routes the
    /// dictation language wants keep `limit`, and those captions want too raise it, up to
    /// `captionsLimit`.
    mutating func keep(_ wanted: Set<TranslationRoute>) -> [TranslationRoute] {
        self.wanted = wanted
        capacity = min(max(Self.limit, wanted.count), Self.captionsLimit)
        let dropped = routes.filter { !wanted.contains($0) }
        routes.removeAll { !wanted.contains($0) }
        return dropped + dropBeyondCapacity()
    }

    /// Drops routes until the caches fit `capacity`, those the settings do not want first,
    /// then those used longest ago, never the one used last.
    private mutating func dropBeyondCapacity() -> [TranslationRoute] {
        var dropped: [TranslationRoute] = []
        while routes.count > capacity {
            let others = routes.dropLast()
            let victim = others.first { !wanted.contains($0) } ?? others.first!
            routes.removeAll { $0 == victim }
            dropped.append(victim)
        }
        return dropped
    }

    /// Forgets a route whose cache could not be filled.
    mutating func remove(_ route: TranslationRoute) {
        routes.removeAll { $0 == route }
    }
}
