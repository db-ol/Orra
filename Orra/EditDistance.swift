import Foundation

/// The fewest insertions, deletions and substitutions that turn `a` into `b`, the
/// Levenshtein distance, with one row of the table at a time.
nonisolated func editDistance<Element: Equatable>(_ a: [Element], _ b: [Element]) -> Int {
    var row = Array(0...b.count)
    for (i, x) in a.enumerated() {
        var previous = row[0]
        row[0] = i + 1
        for (j, y) in b.enumerated() {
            let current = row[j + 1]
            row[j + 1] = min(row[j + 1] + 1, row[j] + 1, previous + (x == y ? 0 : 1))
            previous = current
        }
    }
    return row[b.count]
}
