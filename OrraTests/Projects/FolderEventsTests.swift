import CoreServices
import Foundation
import Synchronization
import Testing
@testable import Orra

/// How folder events become changes: with made up events, times and a stand in for the
/// disk, so no time decides a result. One test watches a real folder, only when asked for
/// with TEST_RUNNER_ORRA_FOLDER_EVENTS=1, since FSEvents takes its own time.
struct FolderEventsTests {
    let root = "/Projects/Alpha"
    let start = ContinuousClock.now

    private static let renamed = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
    private static let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
    private static let modified = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
    private static let removed = UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)

    private func event(_ name: String, _ flags: UInt32, id: UInt64 = 1, fileID: UInt64? = nil) -> FolderEvents.Event {
        FolderEvents.Event(path: root + "/" + name, flags: flags, id: id, fileID: fileID)
    }

    private func collect(_ events: [FolderEvents.Event], existing: Set<String>) -> FolderEvents.Changes {
        var collector = FolderEvents.Collector(roots: [root])
        collector.add(events, at: start)
        return collector.take { existing.contains($0) }
    }

    private func paths(_ names: String...) -> Set<String> {
        Set(names.map { root + "/" + $0 })
    }

    @Test func aRenameIsPairedByFileID() {
        let changes = collect(
            [event("brief.docx", Self.renamed, id: 5, fileID: 77), event("Brief v2.docx", Self.renamed, id: 6, fileID: 77)],
            existing: paths("Brief v2.docx"))
        #expect(changes.renamed == [FolderEvents.Rename(from: root + "/brief.docx", to: root + "/Brief v2.docx")])
        #expect(changes.removed.isEmpty)
        #expect(changes.changed.isEmpty)
        #expect(changes.lastEventID == 6)
        #expect(!changes.mustSweep)
    }

    /// Which path is new is read from the disk, whatever order the events came in.
    @Test func aRenameInTheOtherOrderIsTurnedAround() {
        let changes = collect(
            [event("new.md", Self.renamed, fileID: 3), event("old.md", Self.renamed, fileID: 3)], existing: paths("new.md"))
        #expect(changes.renamed == [FolderEvents.Rename(from: root + "/old.md", to: root + "/new.md")])
    }

    /// A file moved out of the folders gives only its old path, and one moved in only its new
    /// path.
    @Test func anUnpairedOldPathIsRemovedAndAnUnpairedNewPathChanged() {
        let changes = collect(
            [event("gone.pdf", Self.renamed, fileID: 1), event("arrived.pdf", Self.renamed, fileID: 2)], existing: paths("arrived.pdf"))
        #expect(changes.renamed.isEmpty)
        #expect(changes.removed == paths("gone.pdf"))
        #expect(changes.changed == paths("arrived.pdf"))
    }

    @Test func renameHalvesFromDifferentCallbacksStillPair() {
        var collector = FolderEvents.Collector(roots: [root])
        collector.add([event("a.txt", Self.renamed, id: 1, fileID: 9)], at: start)
        collector.add([event("b.txt", Self.renamed, id: 2, fileID: 9)], at: start + .milliseconds(400))
        let changes = collector.take { $0 == root + "/b.txt" }
        #expect(changes.renamed == [FolderEvents.Rename(from: root + "/a.txt", to: root + "/b.txt")])
    }

    /// Only the end state of a burst counts: a file made and removed again is removed, one
    /// changed several times is changed once.
    @Test func otherEventsCountByWhetherThePathStillExists() {
        let changes = collect(
            [event("notes.md", Self.created), event("notes.md", Self.modified), event("draft.md", Self.created),
             event("draft.md", Self.removed), event("old.md", Self.removed)],
            existing: paths("notes.md"))
        #expect(changes.changed == paths("notes.md"))
        #expect(changes.removed == paths("draft.md", "old.md"))
    }

    /// A save through a temporary file: the temporary name is ignored, so the real name is
    /// unpaired and counts as changed.
    @Test func aSaveThroughATemporaryFileChangesTheRealFile() {
        let changes = collect(
            [event("brief.docx.sb-1a2b3c4d-XyZ", Self.created | Self.renamed, fileID: 12), event("brief.docx", Self.renamed, fileID: 12),
             event("~$brief.docx", Self.created)],
            existing: paths("brief.docx", "~$brief.docx"))
        #expect(changes.renamed.isEmpty)
        #expect(changes.changed == paths("brief.docx"))
        #expect(changes.removed.isEmpty)
    }

    @Test func temporaryHiddenAndOutsidePathsAreIgnored() {
        var collector = FolderEvents.Collector(roots: [root])
        let ignored = [
            "~$brief.docx", "~WRL0001.tmp", "notes.txt~", "data.tmp", "data.TEMP", ".notes.md.swp", "video.mp4.crdownload",
            "report.pdf.download", "file.part", "brief.docx.sb-12ab34cd-Q1w2E3", ".DS_Store", ".git/index", ".git/objects/ab/cd",
            "node_modules/kit/readme.md", "sub/.hidden/notes.md", "(A Document Being Saved By TextEdit)/notes.rtf",
        ]
        collector.add(ignored.map { event($0, Self.modified) }, at: start)
        collector.add([FolderEvents.Event(path: "/Projects/Beta/notes.md", flags: Self.modified, id: 9, fileID: nil),
                       FolderEvents.Event(path: "/Projects/Alphabet/notes.md", flags: Self.modified, id: 10, fileID: nil)], at: start)
        #expect(collector.readyAt == nil)
        #expect(collector.take { _ in true }.isEmpty)
        #expect(!FolderEvents.isTemporary("notes.md"))
        #expect(!FolderEvents.isTemporary("Q3 plan.docx"))
        #expect(!FolderEvents.isIgnored(root + "/sub/notes.md", under: root))
        #expect(!FolderEvents.isIgnored(root, under: root))
    }

    @Test func aPathGoesToTheLongestRootThatHoldsIt() {
        var collector = FolderEvents.Collector(roots: [root, root + "/node_modules/kit"])
        collector.add([event("node_modules/kit/readme.md", Self.modified)], at: start)
        #expect(collector.take { _ in true }.changed == paths("node_modules/kit/readme.md"))
    }

    @Test(arguments: [
        kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
        kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount,
        kFSEventStreamEventFlagUnmount,
    ])
    func lostEventsOrAMovedRootAskForASweep(flag: Int) {
        var collector = FolderEvents.Collector(roots: [root])
        collector.add([event("a.md", Self.modified, id: 3), FolderEvents.Event(path: root, flags: UInt32(flag), id: 4, fileID: nil),
                       event("b.md", Self.modified, id: 5)], at: start)
        #expect(collector.take { _ in true } == FolderEvents.Changes(mustSweep: true, lastEventID: 5))
    }

    @Test func theEndOfAReplayAloneIsNothing() {
        var collector = FolderEvents.Collector(roots: [root])
        collector.add([FolderEvents.Event(path: "", flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: 8, fileID: nil)], at: start)
        #expect(collector.readyAt == nil)
    }

    /// What waits stays small: past the limit, only a full sweep is asked for.
    @Test func tooManyPathsAskForASweep() {
        var collector = FolderEvents.Collector(roots: [root], limit: 3)
        collector.add((1...4).map { event("file \($0).md", Self.modified, id: UInt64($0)) }, at: start)
        collector.add([event("file 5.md", Self.modified, id: 5)], at: start)
        #expect(collector.take { _ in true } == FolderEvents.Changes(mustSweep: true, lastEventID: 5))
    }

    /// A batch waits until no event came for the quiet time, but no longer than the most it
    /// may wait.
    @Test func aBatchWaitsForQuietButNotForever() {
        var collector = FolderEvents.Collector(roots: [root], quiet: .seconds(1), maximumWait: .seconds(10))
        #expect(collector.readyAt == nil)
        collector.add([event("a.md", Self.modified)], at: start)
        #expect(collector.readyAt == start + .seconds(1))
        collector.add([event("a.md", Self.modified)], at: start + .milliseconds(800))
        #expect(collector.readyAt == start + .milliseconds(1_800))
        for step in 1...12 {
            collector.add([event("a.md", Self.modified)], at: start + .milliseconds(800 * step))
        }
        #expect(collector.readyAt == start + .seconds(10))
        _ = collector.take { _ in true }
        #expect(collector.readyAt == nil)
        #expect(collector.take { _ in true }.isEmpty)
    }

    @Test func laterChangesWinWhenMerged() {
        var changes = FolderEvents.Changes(removed: paths("a.md"), changed: paths("b.md"), lastEventID: 4)
        changes.merge(
            FolderEvents.Changes(renamed: [FolderEvents.Rename(from: "x", to: "y")], removed: paths("b.md"), changed: paths("a.md"), lastEventID: 3),
            limit: 10)
        #expect(changes == FolderEvents.Changes(
            renamed: [FolderEvents.Rename(from: "x", to: "y")], removed: paths("b.md"), changed: paths("a.md"), lastEventID: 4))
        changes.merge(FolderEvents.Changes(changed: paths("c.md", "d.md", "e.md", "f.md", "g.md", "h.md", "i.md", "j.md"), lastEventID: 9), limit: 10)
        #expect(changes == FolderEvents.Changes(mustSweep: true, lastEventID: 9))
        changes.merge(FolderEvents.Changes(changed: paths("k.md"), lastEventID: 2), limit: 10)
        #expect(changes == FolderEvents.Changes(mustSweep: true, lastEventID: 9))
    }

    /// A real folder: a new file, a rename, a removal, and a change made while nothing
    /// watched, found from the last event ID.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_FOLDER_EVENTS"] != nil), .timeLimit(.minutes(1)))
    func aRealFolder() async throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("FolderEventsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }
        let folder = try #require(made.path.withCString { realpath($0, nil) }.map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let received = Mutex<[FolderEvents.Changes]>([])
        func watch(since: UInt64?) -> FolderEvents {
            let events = FolderEvents(folders: [folder], since: since, quiet: .milliseconds(300)) { changes in
                received.withLock { $0.append(changes) }
            }
            events.start()
            return events
        }
        func waitFor(_ found: (FolderEvents.Changes) -> Bool) async throws -> FolderEvents.Changes {
            while true {
                if let match = received.withLock({ $0.first(where: found) }) { return match }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        var events = watch(since: nil)
        try await Task.sleep(for: .seconds(1))
        try Data("one".utf8).write(to: URL(fileURLWithPath: folder + "/a.txt"))
        _ = try await waitFor { $0.changed.contains(folder + "/a.txt") }
        try FileManager.default.moveItem(atPath: folder + "/a.txt", toPath: folder + "/b.txt")
        _ = try await waitFor { $0.renamed.contains(FolderEvents.Rename(from: folder + "/a.txt", to: folder + "/b.txt")) }
        try FileManager.default.removeItem(atPath: folder + "/b.txt")
        let last = try await waitFor { $0.removed.contains(folder + "/b.txt") }.lastEventID
        events.stop()

        try Data("two".utf8).write(to: URL(fileURLWithPath: folder + "/c.txt"))
        try await Task.sleep(for: .seconds(1))
        received.withLock { $0 = [] }
        events = watch(since: last)
        _ = try await waitFor { $0.changed.contains(folder + "/c.txt") }
        events.stop()
    }
}
