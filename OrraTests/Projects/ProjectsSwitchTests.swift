import Foundation
import Testing
@testable import Orra

/// The Projects switch: off by default, only in builds that show Projects and on Macs with
/// 16 GB, saved in its preference, and turning it off keeps or deletes the data as asked.
/// Also the setting of the talk key in the Projects window.
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
        // A test may have left the index unwritable.
        try? FileManager.default.setAttributes([.posixPermissions: ProjectsStorage.folderPermissions], ofItemAtPath: storage.indexFolder.path)
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

    /// Decision 13: the talk key's words in the change box change the draft as soon as the
    /// dictation ends, until the user turns that off. Nothing is saved before a change.
    @Test func theChangeAfterADictationIsOnUntilTurnedOff() {
        defer { cleanUp() }
        let projects = makeSwitch()
        #expect(projects.revisesAfterDictation)
        #expect(defaults.persistentDomain(forName: suite)?[ProjectsSwitch.revisesAfterDictationKey] == nil)
        projects.setRevisesAfterDictation(false)
        #expect(!projects.revisesAfterDictation)
        #expect(defaults.persistentDomain(forName: suite)?[ProjectsSwitch.revisesAfterDictationKey] as? Bool == false)
        #expect(!makeSwitch().revisesAfterDictation)
        projects.setRevisesAfterDictation(true)
        #expect(projects.revisesAfterDictation)
        #expect(makeSwitch().revisesAfterDictation)
        // It is its own setting: turning Projects on and off leaves it alone.
        projects.setRevisesAfterDictation(false)
        projects.turnOn()
        #expect(!projects.revisesAfterDictation)
        #expect(!makeSwitch().revisesAfterDictation)
    }

    /// Debug and release builds share the preferences. A build that hides Projects, as
    /// release builds did before the preview, never has it on, even after a Debug run saved
    /// it as on, and cannot turn it on.
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

    /// With nothing kept, the switch turns off without a question. Empty folders are no data
    /// either.
    @Test func withNothingKeptTurningOffAsksNothing() async throws {
        defer { cleanUp() }
        let projects = makeSwitch()
        projects.turnOn()
        #expect(await !projects.turnOffOrAsk())
        #expect(!projects.isOn)
        #expect(saved == false)
        #expect(projects.storedBytes == 0)
        try storage.create()
        projects.turnOn()
        #expect(await !projects.turnOffOrAsk())
        #expect(!projects.isOn)
        #expect(FileManager.default.fileExists(atPath: storage.indexFolder.path))
    }

    /// With data kept, Projects stays on until the user chooses to keep or delete it.
    @Test func withDataKeptTurningOffAsksFirst() async throws {
        defer { cleanUp() }
        try storeData(bytes: 1_000)
        let projects = makeSwitch()
        projects.turnOn()
        #expect(await projects.turnOffOrAsk())
        #expect(projects.isOn)
        #expect(saved == true)
        #expect(projects.storedBytes == 1_000)
        await projects.turnOff(keepingData: false)
        #expect(!projects.isOn)
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
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

    /// Two deletes at once, as two quick clicks would start, run as one and end without a
    /// failure.
    @Test func twoDeletesAtOnceEndWithoutAFailure() async throws {
        defer { cleanUp() }
        try storeData()
        let projects = makeSwitch()
        async let first: Void = projects.deleteAllData()
        async let second: Void = projects.deleteAllData()
        _ = await (first, second)
        #expect(!projects.deleteFailed)
        #expect(!projects.isDeleting)
        #expect(projects.storedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
    }

    /// While a delete runs, the switch cannot be turned on, so Projects never starts on a
    /// folder that is being deleted.
    @Test func projectsCannotBeTurnedOnWhileADeleteRuns() async throws {
        defer { cleanUp() }
        try storeData()
        let projects = makeSwitch()
        projects.turnOn()
        let turningOff = Task { await projects.turnOff(keepingData: false) }
        var turns = 0
        while !projects.isDeleting, turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        try #require(projects.isDeleting)
        projects.turnOn()
        #expect(!projects.isOn)
        #expect(saved == false)
        await turningOff.value
        #expect(!projects.isDeleting)
        projects.turnOn()
        #expect(projects.isOn)
    }

    /// Turning off with Delete closes the database and the project list first, so nothing
    /// writes into the files the delete removes or brings them back after it.
    @Test func aDeleteClosesWhatProjectsRunsFirst() async throws {
        defer { cleanUp() }
        let store = MailStore(database: try await ProjectsDatabase.open(in: storage))
        let list = ProjectList(storage: storage)
        try await list.load()
        try await list.add(Project(name: "Harbor Lights signage"), mail: store)
        let projects = makeSwitch()
        projects.turnOn()
        var listWasThere: Bool?
        projects.closeBeforeDelete = {
            listWasThere = FileManager.default.fileExists(atPath: list.file.path)
            await list.close()
            await store.close()
        }
        await projects.turnOff(keepingData: false)
        #expect(listWasThere == true)
        #expect(!projects.deleteFailed)
        await #expect(throws: ProjectsDatabase.Failure.self) {
            try await store.counts()
        }
        await #expect(throws: ProjectList.Failure.closed) {
            try await list.update(Project(name: "Late"))
        }
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
    }

    /// A delete that leaves data behind says so and keeps the count. The message goes once a
    /// later delete leaves nothing.
    @Test func aDeleteThatLeavesDataBehindSaysSo() async throws {
        defer { cleanUp() }
        try storeData(bytes: 1_000)
        // No file can be removed from the index.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storage.indexFolder.path)
        let projects = makeSwitch()
        await projects.deleteAllData()
        #expect(projects.deleteFailed)
        #expect(projects.storedBytes == 1_000)
        #expect(!projects.isDeleting)
        try FileManager.default.setAttributes([.posixPermissions: ProjectsStorage.folderPermissions], ofItemAtPath: storage.indexFolder.path)
        await projects.deleteAllData()
        #expect(!projects.deleteFailed)
        #expect(projects.storedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
    }
}
