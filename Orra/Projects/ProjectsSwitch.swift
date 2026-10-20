import Foundation
import Observation
import os

extension Logger {
    /// Projects turned on or off, and its data kept or deleted. Sizes and error codes only.
    nonisolated static let projects = Logger(subsystem: ProblemReport.subsystem, category: "projects")
}

/// Projects, the optional module for mail and project folders, on or off. Off until the user
/// turns it on in Settings, and saved in the preference `projectsOn`.
///
/// Projects needs 16 GB of memory, as cleanup does, see CleanupDefault. It is never on in a
/// build that hides it, whatever a Debug run saved, since both builds share the preferences.
/// Turning it on starts nothing by itself. Turning it off keeps or deletes what Projects
/// keeps on this Mac, as the user chose.
@Observable
final class ProjectsSwitch {
    /// The preference that holds the user's choice.
    static let key = "projectsOn"

    /// Whether this build shows Projects, see ProjectsAvailability.
    let isVisible: Bool
    /// The Mac's memory in bytes.
    let physicalMemory: UInt64
    /// Where Projects keeps its data.
    let storage: ProjectsStorage
    /// The bytes Projects keeps on this Mac as last measured, nil before the first look.
    private(set) var storedBytes: Int64?
    /// Whether the last delete left data behind, so Settings says so. Cleared once nothing
    /// is left.
    private(set) var deleteFailed = false
    /// Whether a delete runs. Projects cannot be turned on meanwhile, so it never starts on
    /// a folder that is being deleted, and a second delete returns at once.
    private(set) var isDeleting = false
    /// What the user chose, as saved.
    private var chosen: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        isVisible: Bool = ProjectsAvailability.isVisible,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        storage: ProjectsStorage = .live
    ) {
        self.defaults = defaults
        self.isVisible = isVisible
        self.physicalMemory = physicalMemory
        self.storage = storage
        chosen = defaults.bool(forKey: Self.key)
    }

    /// Whether this Mac has the memory Projects needs, the same bar as cleanup.
    var hasEnoughMemory: Bool {
        CleanupDefault.hasEnoughMemory(physicalMemory)
    }

    /// The Mac's memory in whole gigabytes, for the line that says why the switch stays off.
    var memoryGigabytes: Int64 {
        CleanupDefault.gigabytes(physicalMemory)
    }

    /// Whether the switch can be turned on: in a build that shows Projects, on a Mac with
    /// enough memory.
    var canTurnOn: Bool {
        isVisible && hasEnoughMemory
    }

    /// Whether Projects is on. Never where it cannot be turned on, whatever is saved.
    var isOn: Bool {
        chosen && canTurnOn
    }

    /// Whether Projects keeps anything on this Mac, as last measured.
    var holdsData: Bool {
        (storedBytes ?? 0) > 0
    }

    /// Turns Projects on and saves it. It starts nothing else: no prompt, no index and no model.
    func turnOn() {
        guard canTurnOn, !isOn, !isDeleting else { return }
        chosen = true
        defaults.set(true, forKey: Self.key)
        Logger.projects.notice("Projects on")
    }

    /// Turns Projects off at once when it keeps nothing on this Mac, and returns false. When
    /// it keeps something, Projects stays on and this returns true, so Settings asks first
    /// whether to keep or delete it, see turnOff(keepingData:).
    func turnOffOrAsk() async -> Bool {
        await measureStorage()
        guard !holdsData else { return true }
        switchOff()
        return false
    }

    /// Turns Projects off and saves it, then keeps what it holds on this Mac for the next
    /// time, or deletes it.
    func turnOff(keepingData: Bool) async {
        switchOff()
        if keepingData {
            await measureStorage()
            if holdsData {
                Logger.projects.notice("Projects data kept: \(self.storedBytes ?? 0, privacy: .public) bytes")
            }
        } else {
            await deleteAllData()
        }
    }

    /// Measures what Projects keeps on this Mac, for Settings.
    func measureStorage() async {
        storedBytes = await storage.size()
        if !holdsData {
            deleteFailed = false
        }
    }

    /// Deletes everything Projects keeps on this Mac, and measures again. Returns at once
    /// while another delete runs.
    func deleteAllData() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        let bytes = await storage.size()
        do {
            try await storage.deleteAll()
            Logger.projects.notice("Projects data deleted: \(bytes, privacy: .public) bytes")
        } catch {
            let code = (error as NSError).code
            Logger.projects.error("Deleting Projects data failed with error \(code, privacy: .public)")
        }
        await measureStorage()
        deleteFailed = holdsData
    }

    /// Saves Projects as off.
    private func switchOff() {
        let wasOn = isOn
        chosen = false
        defaults.set(false, forKey: Self.key)
        if wasOn {
            Logger.projects.notice("Projects off")
        }
    }
}
