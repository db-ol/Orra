import Foundation
import Testing

/// Waits until `condition` holds, for a minute not counting stalls, and ends the test at
/// the caller's line when it does not. It returns as soon as the condition holds, so the
/// long limit only matters on a slow machine, such as a shared CI runner. A gap of more
/// than a second between two looks counts as one second. On that runner the test process
/// can go a minute without running this loop or the work the test waits for, so time the
/// loop does not get must not use up the minute. A long gap still counts as a second, so
/// a wait made only of long gaps ends after 60 looks. A failed wait throws, so the test
/// ends there instead of going on to await work that may never finish. The failure says
/// how long the wait took and names the longest gap. Since a condition that never holds
/// fails the test, this is no pause before a check that something did not happen.
@MainActor
func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let started = ContinuousClock.now
    var deadline = started + .seconds(60)
    var longestGap = Duration.zero
    while !condition(), ContinuousClock.now < deadline {
        let looked = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(5))
        let gap = looked.duration(to: .now)
        longestGap = max(longestGap, gap)
        deadline += max(gap - .seconds(1), .zero)
    }
    try #require(condition(), "Waited \(started.duration(to: .now)). The longest gap between two looks was \(longestGap).", sourceLocation: sourceLocation)
}

/// A UserDefaults suite of a test's own, never Orra's real settings, which `remove()`
/// deletes with its file. The suite is named by the path of a file in a new folder in the
/// temporary folder. UserDefaults writes that file as soon as a value changes, so nothing
/// writes it again once the folder is gone. A suite with a plain name keeps its file in
/// ~/Library/Preferences. removePersistentDomain(forName:) leaves that file, and cfprefsd
/// writes a change up to 10 s later, so the file comes back after a test deletes it. The
/// folder's name ends in a fresh UUID, so tests that run at the same time never share a
/// suite.
final class TestDefaults {
    /// The suite's name, which UserDefaults(suiteName:) and persistentDomain(forName:) take.
    let name: String
    let defaults: UserDefaults
    /// The folder that holds the suite's file.
    let folder: URL

    init(_ label: String) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("io.github.db-ol.OrraTests.defaults-\(label)-\(UUID().uuidString)", isDirectory: true)
        name = folder.appendingPathComponent("defaults").path
        defaults = try #require(UserDefaults(suiteName: name))
    }

    /// Deletes the suite's folder. The suite also goes when the last reference to it does,
    /// so the one a suite type keeps goes after each test, also after a test that fails,
    /// throws or never calls this.
    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    deinit {
        remove()
    }
}

/// Runs `body` with a UserDefaults suite of its own, see TestDefaults, and removes the
/// suite afterwards.
func withTestDefaults(_ name: String, _ body: (UserDefaults) throws -> Void) throws {
    let suite = try TestDefaults(name)
    defer { suite.remove() }
    try body(suite.defaults)
}
