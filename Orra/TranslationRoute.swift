import Foundation

/// A translation of a user who dictates in `language` into `target`, which is English or
/// that language. Each route has its own prompt, prefix cache and checks: Chinese into
/// English and into Chinese, as before the dictation language, Japanese into English and
/// into Japanese, and Spanish into English and into Spanish.
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

/// Which routes RewriteEngine keeps a translation prefix cache for, at most `limit`, so
/// no user holds more caches than the two of Chinese did. Each takes about 110 MB.
nonisolated struct TranslationPrefixSlots: Equatable, Sendable {
    /// The two targets of one dictation language.
    static let limit = 2

    /// The routes with a cache, the one used longest ago first.
    private(set) var routes: [TranslationRoute] = []
    /// The routes the user's settings want, see `keep(_:)`.
    private(set) var wanted: Set<TranslationRoute> = []

    /// Marks `route` as used, and gives back the routes to drop so the caches stay within
    /// `limit`: first those the settings do not want, then those used longest ago.
    mutating func use(_ route: TranslationRoute) -> [TranslationRoute] {
        routes.removeAll { $0 == route }
        routes.append(route)
        var dropped: [TranslationRoute] = []
        while routes.count > Self.limit {
            let others = routes.dropLast()
            let victim = others.first { !wanted.contains($0) } ?? others.first!
            routes.removeAll { $0 == victim }
            dropped.append(victim)
        }
        return dropped
    }

    /// Keeps only the routes in `wanted` and gives back those to drop.
    mutating func keep(_ wanted: Set<TranslationRoute>) -> [TranslationRoute] {
        self.wanted = wanted
        let dropped = routes.filter { !wanted.contains($0) }
        routes.removeAll { !wanted.contains($0) }
        return dropped
    }

    /// Forgets a route whose cache could not be filled.
    mutating func remove(_ route: TranslationRoute) {
        routes.removeAll { $0 == route }
    }
}
