import Foundation
import Testing
@testable import Orra

/// The first sweep of the folder of 0.6.0 formats that FolderIndexMeasurementTests makes,
/// timed alone, so it can be timed the same way on a build that reads only those formats:
/// this file uses nothing Orra 0.6.0 lacks, so it compiles and runs there as it is. Only
/// when asked for, never in CI, and in a Release build, with TEST_RUNNER_ORRA_INDEX_BENCH
/// set to the folder FolderIndexMeasurementTests made and TEST_RUNNER_ORRA_INDEX_BENCH_LABEL
/// to a name for the build, such as main:
///
///     TEST_RUNNER_ORRA_INDEX_BENCH=<folder> TEST_RUNNER_ORRA_INDEX_BENCH_LABEL=main xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/FolderSweepMeasurementTests
///
/// It adds its rounds to sweep-<label>-<scale>.json in that folder, with times and counts
/// only, so runs on two builds can take turns, which a Mac busy with other work needs, since
/// the index works at background priority. The fastest round of each build counts. It keeps
/// the store of its last round in store-<label>, where FolderIndexMeasurementTests opens a
/// copy as an update would. Optional, with the same prefix: SCALE, the scale of the folder,
/// 1 by default, and ROUNDS, the sweeps of a run, each in a new store, 2 by default.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_INDEX_BENCH_LABEL"] != nil))
@MainActor
struct FolderSweepMeasurementTests {
    /// The project of the bench, the same in every store, so a store one build wrote can be
    /// swept by another.
    static let project = UUID(uuidString: "D0D0D0D0-0000-4000-8000-000000000006")!

    /// The sweeps of one build.
    struct Result: Codable {
        var label: String
        /// The fastest first sweep, in seconds.
        var seconds: Double
        var rounds: [Double]
        /// The fastest walk of the folders alone, in seconds.
        var walkSeconds: Double
        var indexed: Int
        var chunks: Int
        var textBytes: Int64
        var skipped: Int
        var storeBytes: Int64
    }

    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// The folder that holds the synthetic folders, the reports and the stores.
    static var bench: URL {
        URL(fileURLWithPath: environment["ORRA_INDEX_BENCH"] ?? NSTemporaryDirectory(), isDirectory: true)
    }

    static var scale: Double {
        Double(environment["ORRA_INDEX_BENCH_SCALE"] ?? "") ?? 1
    }

    static var rounds: Int {
        max(1, Int(environment["ORRA_INDEX_BENCH_ROUNDS"] ?? "") ?? 2)
    }

    /// The synthetic folder of a scale: 060 holds the formats Orra 0.6.0 reads and files it
    /// skipped, such as images and drawings, and new holds the formats it skipped.
    static func folder(scale: Double) -> URL {
        bench.appending(path: "folder-\(scale)", directoryHint: .isDirectory)
    }

    static func write(_ value: some Encodable, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: bench.appending(path: name))
    }

    @Test func sweepsTheFolderOf060Formats() async throws {
        let label = try #require(Self.environment["ORRA_INDEX_BENCH_LABEL"])
        let folder = Self.folder(scale: Self.scale).appending(path: "060", directoryHint: .isDirectory)
        try #require(FileManager.default.fileExists(atPath: folder.path), "FolderIndexMeasurementTests makes the folder first")
        var result = try await Self.sweep([folder], label: label, keep: Self.bench.appending(path: "store-\(label)", directoryHint: .isDirectory))
        if let earlier = Self.result(label) {
            result.rounds = earlier.rounds + result.rounds
            result.seconds = result.rounds.min() ?? result.seconds
            result.walkSeconds = min(earlier.walkSeconds, result.walkSeconds)
        }
        try Self.write(result, to: Self.resultName(label))
    }

    static func resultName(_ label: String) -> String {
        "sweep-\(label)-\(scale).json"
    }

    /// The rounds a build's runs added up to now, nil before its first run.
    static func result(_ label: String) -> Result? {
        guard let data = try? Data(contentsOf: bench.appending(path: resultName(label))) else { return nil }
        return try? JSONDecoder().decode(Result.self, from: data)
    }

    /// Times the walk of `folders`, then their first sweep as one project, each of `rounds`
    /// in a new store, and gives the fastest. The last round's store is handed to `inspect`
    /// before it closes, and kept at `keep` when given.
    static func sweep(
        _ folders: [URL], label: String, rounds: Int = FolderSweepMeasurementTests.rounds, keep: URL? = nil,
        inspect: (ProjectsDatabase) async throws -> Void = { _ in }
    ) async throws -> Result {
        func seconds(since start: ContinuousClock.Instant) -> Double {
            start.duration(to: .now) / .seconds(1)
        }
        var walk = Double.infinity
        for _ in 0..<rounds {
            let started = ContinuousClock.now
            for folder in folders {
                _ = try await FolderWalk().list(folder)
            }
            walk = min(walk, seconds(since: started))
        }
        var times: [Double] = []
        var last: FolderIndex.Report?
        var storeBytes: Int64 = 0
        for round in 1...rounds {
            let isLast = round == rounds
            let root = isLast ? keep ?? Self.temporaryStore() : Self.temporaryStore()
            try? FileManager.default.removeItem(at: root)
            let storage = ProjectsStorage(root: root)
            let database = try await ProjectsDatabase.open(in: storage)
            let index = FolderIndex(database: database, isDictating: { false }, watch: { _, _, _ in {} })
            let started = ContinuousClock.now
            index.start(project: project, folders: folders)
            // The sweep alone, the same way on every build. Where text recognition follows
            // the sweep, waitUntilIdle() would wait for it too, so this waits until the
            // project page would stop saying Indexing…, and the index stops before the store
            // is looked at, so no recognized text comes into it.
            while index.reports[project]?.isIndexing != false {
                try await Task.sleep(for: .milliseconds(10))
            }
            times.append(seconds(since: started))
            let report = index.reports[project]
            index.stopAll()
            if isLast {
                last = report
                try await inspect(database)
            }
            await database.close()
            if isLast {
                storeBytes = await storage.size()
            }
            if !isLast || keep == nil {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let report = last ?? FolderIndex.Report()
        return Result(
            label: label, seconds: times.min() ?? 0, rounds: times, walkSeconds: walk, indexed: report.indexed, chunks: report.chunks,
            textBytes: report.textBytes, skipped: report.skipped.values.reduce(0, +), storeBytes: storeBytes)
    }

    /// A store of one round, in the bench folder, since a store of a large folder takes a
    /// few hundred megabytes.
    static func temporaryStore() -> URL {
        bench.appending(path: "store-round-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
