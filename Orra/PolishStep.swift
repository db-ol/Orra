import Foundation
import os

/// The polish step after the rule steps, in place of the cleanup step while Polish is on:
/// runs the model on the polish prompt of the user's style, reads its answer and checks it.
/// Anything other than a polish that passes every check gives back the text it was given,
/// and the caller then pastes what it would paste without Polish, see
/// PushToTalkController, so a dictation is never lost.
nonisolated enum PolishStep {
    nonisolated enum Outcome: Equatable, Sendable {
        /// The model's polish passed the checks and differs from the text.
        case polished
        /// The model gave the text back as it was.
        case unchanged
        /// The answer was not the JSON object the prompt asks for.
        case unreadable
        case heldBack(PolishGuard.Failure)
        case timedOut
        case failed

        /// For the log, without any text.
        var logName: String {
            switch self {
            case .polished: "polished"
            case .unchanged: "unchanged"
            case .unreadable: "answer not readable"
            case .heldBack(let failure): "held back by the \(failure.logName) check"
            case .timedOut: "timed out"
            case .failed: "failed"
            }
        }

        /// Whether the step's text may be pasted as the polish.
        var isUsable: Bool {
            self == .polished || self == .unchanged
        }
    }

    /// The longest Orra waits for a polish of this text before it pastes the text without
    /// it, as long as for a cleanup, see CleanupStep.timeout(for:). On an M5 Pro in a
    /// Release build with the prefix cache, PolishModelEvaluationTests measured a Clear
    /// polish of 342 Chinese characters in 1.5 s and of 846 in 3.3 s, and a Concise one in
    /// 2.0 s and 4.3 s, while other work ran on the Mac. This allows 7.1 s and 14.7 s.
    static func timeout(for text: String) -> Duration {
        .seconds(2) + .milliseconds(15) * text.count
    }

    /// The longest text Orra polishes, in characters, longer than a cleanup takes, since a
    /// long dictation gains the most from a polish. 1,000 characters are more than three
    /// minutes of Chinese speech or about a minute of English, and the measurement above
    /// polished 1,022 Chinese characters in 3.8 s in Clear and 4.4 s in Concise.
    static let maximumLength = 1_000

    /// Whether a text is worth a polish: at least three letters or digits, as for a
    /// cleanup, and no longer than `maximumLength`.
    static func isWorthPolishing(_ text: String) -> Bool {
        text.count <= maximumLength
            && text.unicodeScalars.lazy.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.prefix(3).count == 3
    }

    /// Why the model's polish of `text` is held back, nil when it may be pasted.
    static func check(_ polished: String, of text: String, style: PolishStyle) -> PolishGuard.Failure? {
        PolishGuard.check(source: text, output: polished, style: style)
    }

    /// The text to paste and what happened: the polish when it passes, and otherwise the
    /// text it was given. Logs the style, the outcome and the time, never text.
    @concurrent
    static func run(_ text: String, style: PolishStyle, timeout: Duration? = nil, complete: @escaping @Sendable (String, PolishStyle) async throws -> String) async -> (text: String, outcome: Outcome) {
        let started = ContinuousClock.now
        let (result, timedOut) = await TimedCall.run(within: timeout ?? Self.timeout(for: text)) { try await complete(text, style) }
        let outcome: Outcome
        var polished = text
        if timedOut {
            outcome = .timedOut
        } else {
            switch result {
            case .success(let answer):
                if let parsed = PolishPrompt.parse(answer) {
                    if let failure = check(parsed, of: text, style: style) {
                        outcome = .heldBack(failure)
                    } else if parsed == text {
                        outcome = .unchanged
                    } else {
                        outcome = .polished
                        polished = parsed
                    }
                } else {
                    outcome = .unreadable
                }
            case .failure(let error):
                outcome = .failed
                Logger.rewrite.error("Polish failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
        Logger.rewrite.notice("Polish in the \(style.rawValue, privacy: .public) style \(outcome.logName, privacy: .public) after \(started.duration(to: .now), privacy: .public)")
        return (polished, outcome)
    }
}

/// Whether the user turned Polish on. Off until they do, in Settings, for every user: the
/// welcome window never turns it on.
nonisolated enum PolishPreference {
    static let defaultsKey = "polishesWithLocalModel"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? false
    }

    static func save(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}

/// The style the user picked for Polish, saved apart from the switch, so it stays while
/// Polish is off. Clear until the user picks another, also for a value a later version
/// saved that this one does not know.
nonisolated enum PolishStylePreference {
    static let defaultsKey = "polishStyle"

    static func load(from defaults: UserDefaults = .standard) -> PolishStyle {
        defaults.string(forKey: defaultsKey).flatMap(PolishStyle.init(rawValue:)) ?? .clear
    }

    static func save(_ style: PolishStyle, to defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: defaultsKey)
    }
}
