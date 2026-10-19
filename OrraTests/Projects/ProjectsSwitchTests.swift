import Foundation
import Testing
@testable import Orra

/// The Projects switch: off by default, only in builds that show Projects and on Macs with
/// 16 GB, saved in its preference, and turning it off keeps or deletes the data as asked.
/// Each test has preferences of its own and a temporary folder, never the real ones.
@MainActor
struct ProjectsSwitchTests {
    static let sixteenGB: UInt64 = 16 << 30
    static let eightGB: UInt64 = 8 << 30

    let suite = "io.github.db-ol.OrraTests.projects-\(UUID().uuidString)"
    let defaults: UserDefaults
    let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("ProjectsSwitchTests-\(UUID().uuidString)", isDirectory: true))

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: storage.root)
    }

    private func makeSwitch(isVisible: Bool = true, physicalMemory: UInt64 = ProjectsSwitchTests.sixteenGB) -> ProjectsSwitch {
        ProjectsSwitch(defaults: defaults, isVisible: isVisible, physicalMemory: physicalMemory, storage: storage)
    }

    /// The saved value itself, nil while nothing is saved.
    private var saved: Bool? {
        defaults.persistentDomain(forName: suite)?[ProjectsSwitch.key] as? Bool
    }

    /// A file of `bytes` bytes in the index, as an index would leave.
    private func storeData(bytes: Int = 1_000) throws {
        try storage.create()
        try Data(repeating: 7, count: bytes).write(to: storage.indexFolder.appendingPathComponent("chunks.db"))
    }

    @Test func projectsIsOffByDefaultAndReadingSavesNothing() {
        defer { cleanUp() }
        let projects = makeSwitch()
        #expect(!projects.isOn)
        #expect(projects.canTurnOn)
        #expect(saved == nil)
        // Nothing is measured or created until Settings asks.
        #expect(projects.storedBytes == nil)
        #expect(!projects.holdsData)
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
    }

    @Test func turningOnIsSavedAndReadAtTheNextLaunch() async {
        defer { cleanUp() }
        let projects = makeSwitch()
        projects.turnOn()
        #expect(projects.isOn)
        #expect(saved == true)
        // Turning on creates nothing on disk.
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
        #expect(makeSwitch().isOn)
        await projects.turnOff(keepingData: true)
        #expect(!projects.isOn)
        #expect(saved == false)
        #expect(!makeSwitch().isOn)
    }

    /// The bar of cleanup: 16 GB. Below it the switch stays off, also when a Mac with more
    /// memory saved it as on, and the page names the memory.
    @Test func projectsCannotBeTurnedOnBelowSixteenGigabytes() {
        defer { cleanUp() }
        let small = makeSwitch(physicalMemory: Self.eightGB)
        #expect(!small.hasEnoughMemory)
        #expect(!small.canTurnOn)
        #expect(small.memoryGigabytes == 8)
        small.turnOn()
        #expect(!small.isOn)
        #expect(saved == nil)
        // Just under 16 GiB is still too little, 16 GiB is enough.
        #expect(!makeSwitch(physicalMemory: Self.sixteenGB - 1).canTurnOn)
        #expect(makeSwitch(physicalMemory: Self.sixteenGB).canTurnOn)
        defaults.set(true, forKey: ProjectsSwitch.key)
        #expect(!makeSwitch(physicalMemory: Self.eightGB).isOn)
        #expect(makeSwitch(physicalMemory: Self.sixteenGB).isOn)
    }

    /// Debug and release builds share the preferences. A release build that hides Projects
    /// never has it on, even after a Debug run saved it as on, and cannot turn it on.
    @Test func projectsIsNeverOnWhileTheBuildHidesIt() {
        defer { cleanUp() }
        defaults.set(true, forKey: ProjectsSwitch.key)
        let hidden = makeSwitch(isVisible: false)
        #expect(!hidden.isOn)
        #expect(!hidden.canTurnOn)
        hidden.turnOn()
        #expect(!hidden.isOn)
        // The Debug run's choice stays saved for the next Debug run.
        #expect(saved == true)
        #expect(makeSwitch(isVisible: true).isOn)
    }

    @Test func turningOffCanKeepTheData() async throws {
        defer { cleanUp() }
        try storeData(bytes: 1_000)
        let projects = makeSwitch()
        projects.turnOn()
        await projects.measureStorage()
        #expect(projects.holdsData)
        await projects.turnOff(keepingData: true)
        #expect(!projects.isOn)
        #expect(FileManager.default.fileExists(atPath: storage.indexFolder.appendingPathComponent("chunks.db").path))
        #expect(projects.storedBytes == 1_000)
        #expect(!projects.deleteFailed)
    }

    @Test func turningOffCanDeleteTheData() async throws {
        defer { cleanUp() }
        try storeData(bytes: 1_000)
        let projects = makeSwitch()
        projects.turnOn()
        await projects.turnOff(keepingData: false)
        #expect(!projects.isOn)
        #expect(saved == false)
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
        #expect(projects.storedBytes == 0)
        #expect(!projects.holdsData)
        #expect(!projects.deleteFailed)
    }

    /// With nothing kept, turning off has nothing to ask about.
    @Test func withNothingKeptThereIsNoDataToAskAbout() async throws {
        defer { cleanUp() }
        let projects = makeSwitch()
        projects.turnOn()
        await projects.measureStorage()
        #expect(projects.storedBytes == 0)
        #expect(!projects.holdsData)
        // Empty folders are no data either.
        try storage.create()
        await projects.measureStorage()
        #expect(!projects.holdsData)
    }

    /// Delete All Projects Data leaves the switch as it is.
    @Test func deletingAllDataKeepsTheSwitch() async throws {
        defer { cleanUp() }
        try storeData()
        let projects = makeSwitch()
        projects.turnOn()
        await projects.deleteAllData()
        #expect(projects.isOn)
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
        #expect(projects.storedBytes == 0)
        // Nothing left to delete is no failure.
        await projects.deleteAllData()
        #expect(!projects.deleteFailed)
    }
}
