import Foundation
import Testing

/// TestDefaults keeps each test's suite in a folder of its own in the temporary folder, so a
/// test run leaves nothing in ~/Library/Preferences, and the folder goes when the test ends.
struct TestDefaultsTests {
    /// The suite's file is in its folder as soon as a value is set, so no late write brings
    /// it back once the folder is gone. A second object of the suite reads the same values.
    @Test func theSuiteIsWrittenToItsFolderAtOnceAndGoesWithIt() throws {
        let suite = try TestDefaults("helper")
        defer { suite.remove() }
        suite.defaults.set(["one"], forKey: "words")
        #expect(FileManager.default.fileExists(atPath: suite.name + ".plist"))
        #expect(suite.defaults.persistentDomain(forName: suite.name)?["words"] as? [String] == ["one"])
        #expect(UserDefaults(suiteName: suite.name)?.stringArray(forKey: "words") == ["one"])
        suite.remove()
        #expect(!FileManager.default.fileExists(atPath: suite.folder.path))
    }

    /// A suite that nobody removes goes with its last reference, as the one a suite type
    /// keeps does after each test.
    @Test func aSuiteGoesWithItsLastReference() throws {
        var folder: URL?
        do {
            let suite = try TestDefaults("helper")
            suite.defaults.set(true, forKey: "written")
            folder = suite.folder
            #expect(FileManager.default.fileExists(atPath: suite.folder.path))
        }
        let gone = try #require(folder)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }
}
