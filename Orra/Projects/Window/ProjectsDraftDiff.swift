import Foundation

/// What changed between two versions of a draft, for the highlight of a new version in the
/// email view. Words of Latin text, and each Chinese character on its own, are compared, so
/// a change of one word marks that word and not its whole line. Drafts are in Chinese or
/// English.
nonisolated enum ProjectsDraftDiff {
    /// A run of text that stayed, came new, or went.
    nonisolated struct Segment: Sendable, Equatable {
        nonisolated enum Kind: Sendable, Equatable {
            case same
            case added
            case removed
        }

        var kind: Kind
        var text: String
    }

    /// The most tokens of one side compared, see `tokens(_:)`. A longer draft shows as one
    /// change, since the comparison grows with the square of the tokens when little stays:
    /// two fully different sides of 4,000 tokens took 0.2 s, of 8,000 about 1 s. A draft of
    /// a page holds about 1,000 (a guess).
    static let maximumTokens = 3_000

    /// The segments off the main actor, for the email view.
    @concurrent
    static func highlight(from before: String, to after: String) async -> [Segment] {
        segments(from: before, to: after)
    }

    /// The segments that lead from `before` to `after`: what both hold, in the order of
    /// `after`, with what `before` held and `after` does not right before what replaced it.
    /// Neighboring segments of one kind are joined.
    static func segments(from before: String, to after: String) -> [Segment] {
        guard before != after else { return after.isEmpty ? [] : [Segment(kind: .same, text: after)] }
        let old = tokens(before)
        let new = tokens(after)
        guard old.count <= maximumTokens, new.count <= maximumTokens else {
            return joined([Segment(kind: .removed, text: before), Segment(kind: .added, text: after)])
        }
        let difference = new.difference(from: old)
        var removed: Set<Int> = []
        var added: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var segments: [Segment] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                segments.append(Segment(kind: .removed, text: old[i]))
                i += 1
            } else if j < new.count, added.contains(j) {
                segments.append(Segment(kind: .added, text: new[j]))
                j += 1
            } else if i < old.count, j < new.count {
                segments.append(Segment(kind: .same, text: new[j]))
                i += 1
                j += 1
            } else if i < old.count {
                segments.append(Segment(kind: .removed, text: old[i]))
                i += 1
            } else {
                segments.append(Segment(kind: .added, text: new[j]))
                j += 1
            }
        }
        return joined(segments)
    }

    /// Whether anything changed, for the highlight's line.
    static func hasChanges(_ segments: [Segment]) -> Bool {
        segments.contains { $0.kind != .same }
    }

    /// The text as compared: runs of letters and digits, runs of white space, and each other
    /// character on its own, a Chinese one too.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind: TokenKind?
        for character in text {
            let kind = TokenKind(character)
            if kind == .single || kind != currentKind {
                if !current.isEmpty {
                    tokens.append(current)
                }
                current = ""
            }
            current.append(character)
            currentKind = kind
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private enum TokenKind {
        case word
        case space
        case single

        init(_ character: Character) {
            if character.isWhitespace {
                self = .space
            } else if character.containsHan {
                self = .single
            } else if character.isLetter || character.isNumber {
                self = .word
            } else {
                self = .single
            }
        }
    }

    private static func joined(_ segments: [Segment]) -> [Segment] {
        var joined: [Segment] = []
        for segment in segments where !segment.text.isEmpty {
            if let last = joined.last, last.kind == segment.kind {
                joined[joined.count - 1].text += segment.text
            } else {
                joined.append(segment)
            }
        }
        return joined
    }
}
