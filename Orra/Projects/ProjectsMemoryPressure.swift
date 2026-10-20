import Darwin
import Foundation
import Observation
import os

/// The memory pressure of the Mac, so Projects starts no model work while memory runs low,
/// see ProjectsModelQueue. A dispatch source reports each change on a queue of its own, and
/// the level is kept on the main actor. A warning or a critical level pauses Projects until
/// the level is normal again.
@Observable
final class ProjectsMemoryPressure {
    nonisolated enum Level: String, Sendable {
        case normal
        case warning
        case critical
    }

    /// The latest level the system reported. Normal until `start()`.
    private(set) var level: Level = .normal
    @ObservationIgnored private var source: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private let queue = DispatchQueue(label: "io.github.db-ol.Orra.projects-memory-pressure", qos: .utility)

    /// Starts watching, from the level the system reports now. The source starts first, so
    /// a change while the level is read is reported after it.
    func start() {
        guard source == nil else { return }
        source = Self.watch(on: queue) { [weak self] level in
            Task { @MainActor in
                self?.update(level)
            }
        }
        if let now = Self.currentLevel() {
            update(now)
        }
    }

    /// Stops watching. The level goes back to normal, so nothing stays paused for it.
    func stop() {
        source?.cancel()
        source = nil
        update(.normal)
    }

    /// A level the system reported. Internal for tests.
    func update(_ level: Level) {
        guard level != self.level else { return }
        self.level = level
        Logger.projectsModel.notice("Memory pressure is \(level.rawValue, privacy: .public)")
    }

    /// The level of a memory pressure event, the highest one it holds.
    nonisolated static func level(of event: DispatchSource.MemoryPressureEvent) -> Level? {
        if event.contains(.critical) {
            return .critical
        }
        if event.contains(.warning) {
            return .warning
        }
        if event.contains(.normal) {
            return .normal
        }
        return nil
    }

    /// The level now, from the kernel, which uses the same values as the dispatch source.
    /// Nil when it cannot be read.
    nonisolated static func currentLevel() -> Level? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return nil }
        return level(of: DispatchSource.MemoryPressureEvent(rawValue: UInt(value)))
    }

    /// A source that reports every change of level on `queue`.
    nonisolated private static func watch(on queue: DispatchQueue, report: @escaping @Sendable (Level) -> Void) -> any DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak source] in
            guard let event = source?.data, let level = level(of: event) else { return }
            report(level)
        }
        source.resume()
        return source
    }
}
