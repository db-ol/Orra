import CoreServices
import Foundation
import os

/// Watches the folders of one project with FSEvents and hands on what changed in them, in
/// batches, so FolderIndex reads again only what it must.
///
/// - The stream reports file events with their file IDs (extended data), on a dispatch
///   queue of its own, never the main thread.
/// - A rename gives two events with the same file ID, the old path and the new one. They
///   are paired by that ID. An old path without its pair moved out of the folders and
///   counts as removed, a new path without its pair moved in and counts as changed.
/// - Saves often go through a temporary file, so temporary names are ignored, and so is
///   everything in a hidden folder or node_modules, which the index never reads.
/// - Events are collected until none came for `quiet`, or for at most `maximumWait`, and
///   then handed on. Whether a path still exists is looked up then, so only the end state
///   of a burst counts.
/// - When events were lost, when a watched folder itself moved, or when more than `limit`
///   paths changed, the batch only says that a full sweep is needed.
/// - It starts from the last event FolderIndex stored, so changes made while Orra was closed
///   are reported too. FolderIndex still sweeps at start and now and then, which covers
///   whatever FSEvents does not report.
///
/// All state lives on `queue`. `start()` and `stop()` return at once and do their work there.
nonisolated final class FolderEvents: @unchecked Sendable {
    /// One FSEvents event.
    nonisolated struct Event: Sendable, Equatable {
        var path: String
        var flags: UInt32
        var id: UInt64
        /// The file ID from the extended data, nil when the event has none.
        var fileID: UInt64?
    }

    /// A path that moved, a file or a folder.
    nonisolated struct Rename: Sendable, Equatable {
        var from: String
        var to: String
    }

    /// What changed in the watched folders since the last batch.
    nonisolated struct Changes: Sendable, Equatable {
        /// Paths that moved within the folders, in the order they moved.
        var renamed: [Rename] = []
        /// Paths that are gone, files or folders.
        var removed: Set<String> = []
        /// Paths created or changed, files or folders.
        var changed: Set<String> = []
        /// Whether only a full sweep can tell what changed.
        var mustSweep = false
        /// The newest event ID seen, to start from next time.
        var lastEventID: UInt64 = 0

        var isEmpty: Bool {
            renamed.isEmpty && removed.isEmpty && changed.isEmpty && !mustSweep
        }

        /// Adds a later batch. A path's later state wins. Past `limit` paths, the changes
        /// only ask for a full sweep, so what waits stays small.
        mutating func merge(_ later: Changes, limit: Int) {
            lastEventID = max(lastEventID, later.lastEventID)
            renamed += later.renamed
            for path in later.removed {
                changed.remove(path)
                removed.insert(path)
            }
            for path in later.changed {
                removed.remove(path)
                changed.insert(path)
            }
            if mustSweep || later.mustSweep || renamed.count + removed.count + changed.count > limit {
                self = Changes(mustSweep: true, lastEventID: lastEventID)
            }
        }
    }

    /// Collects events into changes. Pure, so tests pass events, times and a stand in for
    /// the disk.
    nonisolated struct Collector: Sendable {
        /// The watched folders, by their real paths.
        let roots: [String]
        let quiet: Duration
        let maximumWait: Duration
        let limit: Int

        private struct Half: Sendable {
            var fileID: UInt64
            var path: String
        }

        private var renamed: [Rename] = []
        /// Renamed paths still waiting for the other path with their file ID.
        private var halves: [Half] = []
        private var touched: Set<String> = []
        private var mustSweep = false
        private var lastEventID: UInt64 = 0
        private var first: ContinuousClock.Instant?
        private var last: ContinuousClock.Instant?

        init(roots: [String], quiet: Duration = FolderEvents.quiet, maximumWait: Duration = FolderEvents.maximumWait, limit: Int = FolderEvents.limit) {
            self.roots = roots
            self.quiet = quiet
            self.maximumWait = maximumWait
            self.limit = limit
        }

        /// When the changes may be handed on, nil while none wait.
        var readyAt: ContinuousClock.Instant? {
            guard let first, let last else { return nil }
            return min(last + quiet, first + maximumWait)
        }

        mutating func add(_ events: [Event], at now: ContinuousClock.Instant) {
            for event in events {
                lastEventID = max(lastEventID, event.id)
                if event.flags & FolderEvents.sweepFlags != 0 {
                    note(now)
                    askForSweep()
                    continue
                }
                guard let root = root(of: event.path), !FolderEvents.isIgnored(event.path, under: root) else { continue }
                note(now)
                guard !mustSweep else { continue }
                if event.flags & FolderEvents.renamedFlag != 0, let fileID = event.fileID {
                    if let index = halves.firstIndex(where: { $0.fileID == fileID }) {
                        let other = halves.remove(at: index)
                        if other.path == event.path {
                            touched.insert(event.path)
                        } else {
                            renamed.append(Rename(from: other.path, to: event.path))
                        }
                    } else {
                        halves.append(Half(fileID: fileID, path: event.path))
                    }
                } else {
                    touched.insert(event.path)
                }
                if renamed.count + halves.count + touched.count > limit {
                    askForSweep()
                }
            }
        }

        /// Hands on what was collected and starts again. A rename whose old path exists and
        /// whose new path does not came in the other order. A path left unpaired is removed
        /// when it no longer exists, and changed when it does.
        mutating func take(exists: (String) -> Bool) -> Changes {
            var changes = Changes(mustSweep: mustSweep, lastEventID: lastEventID)
            if !mustSweep {
                for rename in renamed {
                    let reversed = exists(rename.from) && !exists(rename.to)
                    changes.renamed.append(reversed ? Rename(from: rename.to, to: rename.from) : rename)
                }
                for path in touched.union(halves.map(\.path)) {
                    if exists(path) {
                        changes.changed.insert(path)
                    } else {
                        changes.removed.insert(path)
                    }
                }
            }
            self = Collector(roots: roots, quiet: quiet, maximumWait: maximumWait, limit: limit)
            return changes
        }

        private mutating func note(_ now: ContinuousClock.Instant) {
            if first == nil { first = now }
            last = now
        }

        private mutating func askForSweep() {
            mustSweep = true
            renamed = []
            halves = []
            touched = []
        }

        /// The longest watched folder that holds `path` or is it.
        private func root(of path: String) -> String? {
            roots.filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
        }
    }

    /// How long FSEvents gathers events before it reports them, in seconds.
    static let latency: CFTimeInterval = 0.5
    /// How long no event must come before a batch is handed on.
    static let quiet: Duration = .seconds(1)
    /// How long a batch waits at most while events keep coming.
    static let maximumWait: Duration = .seconds(10)
    /// The most paths a batch names before it only asks for a full sweep.
    static let limit = 10_000

    /// Events lost by FSEvents or the kernel, IDs that wrapped, a watched folder or a disk
    /// that moved: only a full sweep can tell what changed.
    static let sweepFlags = UInt32(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount)
    static let renamedFlag = UInt32(kFSEventStreamEventFlagItemRenamed)

    /// Whether a path below `root` cannot matter to the index: it lies in a hidden folder or
    /// node_modules, is hidden itself, or has a temporary name.
    static func isIgnored(_ path: String, under root: String) -> Bool {
        guard path.count > root.count else { return false }
        let components = path.dropFirst(root.count).split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" || $0.hasPrefix("(A Document Being Saved By") }) {
            return true
        }
        return components.last.map { isTemporary(String($0)) } ?? false
    }

    /// Names that editors and browsers use while they save or download: Office's ~$ owner
    /// files, backups that end in ~, the safe save copies of macOS (.sb-), and the usual
    /// temporary and partial download extensions.
    static func isTemporary(_ name: String) -> Bool {
        if name.hasPrefix("~") || name.hasSuffix("~") || name.contains(".sb-") { return true }
        let fileExtension = (name as NSString).pathExtension.lowercased()
        return ["tmp", "temp", "swp", "swx", "part", "partial", "crdownload", "download"].contains(fileExtension)
    }

    private let folders: [String]
    private let since: UInt64?
    private let quiet: Duration
    private let maximumWait: Duration
    private let limit: Int
    private let deliver: @Sendable (Changes) -> Void
    private let queue = DispatchQueue(label: "io.github.db-ol.Orra.projects-folder-events", qos: .utility)
    private var collector: Collector
    private var stream: FSEventStreamRef?
    private var timer: (any DispatchSourceTimer)?

    /// Watches `folders` from the event after `since`, or from now when nil, and hands each
    /// batch to `deliver` on its own queue.
    init(
        folders: [String],
        since: UInt64?,
        quiet: Duration = FolderEvents.quiet,
        maximumWait: Duration = FolderEvents.maximumWait,
        limit: Int = FolderEvents.limit,
        deliver: @escaping @Sendable (Changes) -> Void
    ) {
        self.folders = folders
        self.since = since
        self.quiet = quiet
        self.maximumWait = maximumWait
        self.limit = limit
        self.deliver = deliver
        collector = Collector(roots: [], quiet: quiet, maximumWait: maximumWait, limit: limit)
    }

    /// Starts the stream. Call `stop()` when done, since the stream keeps this object.
    func start() {
        queue.async { self.startNow() }
    }

    /// Stops the stream. No batch is handed on after it.
    func stop() {
        queue.async { self.stopNow() }
    }

    private func startNow() {
        guard stream == nil else { return }
        let roots = folders.map { Self.realPath($0) ?? $0 }
        collector = Collector(roots: roots, quiet: quiet, maximumWait: maximumWait, limit: limit)
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseExtendedData
                | kFSEventStreamCreateFlagWatchRoot)
        // An ID from before the event store was reset would be in the future.
        let start = since.flatMap { $0 <= FSEventsGetCurrentEventId() ? $0 : nil } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context, roots as CFArray, start, Self.latency, flags) else {
            Unmanaged<FolderEvents>.fromOpaque(info).release()
            Logger.projectsIndex.error("Watching project folders failed")
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            Unmanaged<FolderEvents>.fromOpaque(info).release()
            Logger.projectsIndex.error("Watching project folders failed")
            return
        }
        stream = created
    }

    private func stopNow() {
        timer?.cancel()
        timer = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        collector = Collector(roots: collector.roots, quiet: quiet, maximumWait: maximumWait, limit: limit)
        Unmanaged.passUnretained(self).release()
    }

    /// With UseCFTypes and UseExtendedData, each path is a dictionary with the path and
    /// the file ID.
    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let events = Unmanaged<FolderEvents>.fromOpaque(info).takeUnretainedValue()
        let entries = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var received: [Event] = []
        received.reserveCapacity(count)
        for index in 0..<min(count, entries.count) {
            guard let entry = entries[index] as? NSDictionary, let path = entry["path"] as? String else { continue }
            received.append(Event(path: path, flags: flags[index], id: ids[index], fileID: (entry["fileID"] as? NSNumber)?.uint64Value))
        }
        events.received(received)
    }

    private func received(_ events: [Event]) {
        guard stream != nil else { return }
        collector.add(events, at: .now)
        schedule()
    }

    private func schedule() {
        guard let readyAt = collector.readyAt else { return }
        let timer = timer ?? {
            let made = DispatchSource.makeTimerSource(queue: queue)
            made.setEventHandler { [weak self] in self?.fire() }
            made.resume()
            self.timer = made
            return made
        }()
        let wait = max(.zero, ContinuousClock.now.duration(to: readyAt))
        let (seconds, attoseconds) = wait.components
        timer.schedule(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18)
    }

    private func fire() {
        guard stream != nil, let readyAt = collector.readyAt else { return }
        guard ContinuousClock.now >= readyAt else {
            schedule()
            return
        }
        let changes = collector.take(exists: Self.exists)
        if !changes.isEmpty {
            deliver(changes)
        }
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
