import Foundation
import Testing

/// Waits until `condition` holds, for at most five seconds. It returns as soon as the
/// condition holds, so the long limit only matters on a slow machine, such as a
/// shared CI runner.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Runs `body` with a UserDefaults suite of its own, never Orra's real settings, and
/// removes the suite afterwards. The suite name ends in a fresh UUID, so tests that run at
/// the same time never share one.
func withTestDefaults(_ name: String, _ body: (UserDefaults) throws -> Void) throws {
    let suite = "io.github.db-ol.OrraTests.\(name)-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}
