import Foundation
import Synchronization
import Testing
@testable import Orra

/// The download through the real URLSession code, against stand in servers that run in the
/// test process. No request reaches the network, and every file goes to temporary folders.
struct ModelDownloadTests {
    struct Outcome {
        let result: Result<URL, any Error>
        let sleeps: [Duration]
        let events: [ModelDownload.Event]

        var failure: ModelDownload.Failure? {
            if case .failure(let error) = result { error as? ModelDownload.Failure } else { nil }
        }
    }

    /// Runs one download and records its pauses and events. Pauses return at once.
    private func download(
        _ servers: StubServers,
        _ temporary: TemporaryModelFolders,
        sources: [ModelSource] = ModelSource.order,
        freeSpace: Int64? = 100_000_000_000,
        fetch: FileFetch? = nil,
        onPause: @escaping @Sendable () -> Void = {}
    ) async -> Outcome {
        let sleeps = Mutex<[Duration]>([])
        let events = Mutex<[ModelDownload.Event]>([])
        let environment = ModelDownload.Environment(
            fetch: fetch ?? servers.fetch,
            freeSpace: { _ in freeSpace },
            sleep: { duration in
                sleeps.withLock { $0.append(duration) }
                onPause()
            }
        )
        let result: Result<URL, any Error>
        do {
            let url = try await ModelDownload.run(temporary.manifest, temporary.folders, sources: sources, environment: environment) { event in
                events.withLock { $0.append(event) }
            }
            result = .success(url)
        } catch {
            result = .failure(error)
        }
        return Outcome(result: result, sleeps: sleeps.withLock { $0 }, events: events.withLock { $0 })
    }

    private var names: [String] {
        TestModel.manifest.files.map(\.name)
    }

    /// The five small files whole and the first `bytes` of the weights, as a cancelled
    /// download leaves them.
    private func writePartial(_ temporary: TemporaryModelFolders, weights bytes: Int) throws {
        try temporary.write(Array(names.dropLast()), to: temporary.staging)
        try TestModel.weights.prefix(bytes).write(to: temporary.staging.appendingPathComponent("model.safetensors"))
    }

    @Test func plainDownload() async throws {
        let servers = StubServers()
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(temporary.isInstalled())
        #expect(try temporary.isExcludedFromBackup(temporary.installed))
        // Small files first, and no Range header on a fresh download.
        #expect(servers.log == names.map { "huggingface.co \($0) -" })
        #expect(outcome.sleeps.isEmpty)
        // Progress names the server, never passes the total, and ends at the total before
        // the check.
        let bytes = outcome.events.compactMap { event -> Int64? in
            if case .progress(let bytes, let source) = event, source == .huggingFace { bytes } else { nil }
        }
        #expect(bytes.count == outcome.events.count - 1)
        #expect(bytes.allSatisfy { $0 <= temporary.manifest.totalBytes })
        #expect(bytes.last == temporary.manifest.totalBytes)
        #expect(outcome.events.last == .verifying)
    }

    @Test func failoverWithoutPause() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(unreachable: true)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == ["huggingface.co config.json -"] + names.map { "modelscope.cn \($0) -" })
        #expect(outcome.sleeps.isEmpty)
        #expect(temporary.isInstalled())
    }

    @Test func notFoundMovesOn() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(status: 404), .modelScope: StubBehavior(status: 403)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == ["huggingface.co config.json -", "modelscope.cn config.json -"] + names.map { "hf-mirror.com \($0) -" })
        #expect(outcome.sleeps.isEmpty)
    }

    @Test func offlineStopsAtOnce() async {
        let servers = StubServers()
        servers.setAll(StubBehavior(offline: true))
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let outcome = await download(servers, temporary)
        #expect(outcome.failure == .offline)
        #expect(servers.log == ["huggingface.co config.json -"])
    }

    @Test func resumesWithRange() async throws {
        let servers = StubServers()
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try writePartial(temporary, weights: 1_234_567)
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == ["huggingface.co model.safetensors bytes=1234567-"])
        #expect(temporary.isInstalled())
        // The first event counts the bytes already on disk.
        #expect(outcome.events.first == .progress(bytes: temporary.manifest.totalBytes - TestModel.size("model.safetensors") + 1_234_567, source: .huggingFace))
    }

    /// modelscope.cn answers a Range request on a small file with a cut body that starts at
    /// the asked offset. Small files are therefore always asked for whole, even when part of
    /// one is on disk.
    @Test func smallFilesAreNeverAskedForARange() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(unreachable: true), .modelScope: StubBehavior(shiftsRanges: true)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try temporary.write(["tokenizer_config.json", "model.safetensors.index.json", "merges.txt"], to: temporary.staging)
        try TestModel.contents["config.json"]!.prefix(4_000).write(to: temporary.staging.appendingPathComponent("config.json"))
        try TestModel.contents["vocab.json"]!.prefix(100).write(to: temporary.staging.appendingPathComponent("vocab.json"))
        try TestModel.weights.write(to: temporary.staging.appendingPathComponent("model.safetensors"))
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == ["huggingface.co config.json -", "modelscope.cn config.json -", "modelscope.cn vocab.json -"])
        #expect(temporary.isInstalled())
    }

    /// The same answer to a Range request on the weights: its bytes are dropped and the
    /// next server sends the file from the start.
    @Test func aShiftedShortBodyIsDropped() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(unreachable: true), .modelScope: StubBehavior(shiftsRanges: true)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try writePartial(temporary, weights: 1_000_000)
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == [
            "huggingface.co model.safetensors bytes=1000000-",
            "modelscope.cn model.safetensors bytes=1000000-",
            "hf-mirror.com model.safetensors -",
        ])
        #expect(outcome.sleeps.isEmpty)
        #expect(temporary.isInstalled())
    }

    /// A 502 on a ranged request from a server that has not sent anything yet moves on at
    /// once.
    @Test func badGatewayOnARangedRequestMovesOn() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(unreachable: true), .modelScope: StubBehavior(rangeStatus: 502)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try writePartial(temporary, weights: 1_000_000)
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == [
            "huggingface.co model.safetensors bytes=1000000-",
            "modelscope.cn model.safetensors bytes=1000000-",
            "hf-mirror.com model.safetensors bytes=1000000-",
        ])
        #expect(outcome.sleeps.isEmpty)
    }

    /// From a server that was sending, a 502 gets two more tries with pauses before the
    /// download moves on.
    @Test func badGatewayFromASendingServerIsTriedAgain() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(unreachable: true), .modelScope: StubBehavior(rangeStatus: 502)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try writePartial(temporary, weights: 1_000_000)
        // modelscope.cn sends vocab.json first, so it counts as sending when the 502 comes.
        try FileManager.default.removeItem(at: temporary.staging.appendingPathComponent("vocab.json"))
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == [
            "huggingface.co vocab.json -",
            "modelscope.cn vocab.json -",
            "modelscope.cn model.safetensors bytes=1000000-",
            "modelscope.cn model.safetensors bytes=1000000-",
            "modelscope.cn model.safetensors bytes=1000000-",
            "hf-mirror.com model.safetensors bytes=1000000-",
        ])
        #expect(outcome.sleeps == [.seconds(2), .seconds(10)])
        #expect(temporary.isInstalled())
    }

    @Test func serverIgnoringRange() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(ignoresRange: true)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try writePartial(temporary, weights: 1_000)
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        // The whole file came back, so it started over and still installs.
        #expect(servers.log == ["huggingface.co model.safetensors bytes=1000-"])
        #expect(temporary.isInstalled())
    }

    /// A 200 counts as the whole file only without a Content-Range header.
    @Test func aWholeFileAnswerWithARangeMovesOn() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(contentRangeOn200: true)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == ["huggingface.co config.json -"] + names.map { "modelscope.cn \($0) -" })
        #expect(outcome.sleeps.isEmpty)
    }

    @Test func droppedConnectionPausesAndResumes() async throws {
        // A short pause between pieces lets the pieces before the drop reach the file, so
        // there are bytes on disk when the connection breaks.
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(dropAfter: 1_500_000, chunkDelay: .milliseconds(1))])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let weights = temporary.staging.appendingPathComponent("model.safetensors")
        // Read during the pause, after the drop and before the retry touches the file.
        let atPause = Mutex<Int64?>(nil)
        let outcome = await download(servers, temporary) {
            atPause.withLock { $0 = ModelDisk.size(weights) }
        }
        #expect(try outcome.result.get() == temporary.installed)
        #expect(temporary.isInstalled())
        let log = servers.log
        #expect(log.count == 7)
        // The retry continues from the bytes that reached the disk, not from byte 0. They
        // can be fewer than 1,500,000, because URLSession may drop bytes in flight.
        let kept = try #require(atPause.withLock { $0 })
        #expect(kept > 0 && kept <= 1_500_000)
        #expect(log.last == "huggingface.co model.safetensors bytes=\(kept)-")
        #expect(outcome.sleeps == [.seconds(2)])
    }

    /// Cancel can land just before a request starts. The task then ends before the fetch
    /// waits for it, and the fetch must still finish instead of waiting for good.
    @Test(.timeLimit(.minutes(1)))
    func aRequestThatEndsBeforeTheWaitStillEndsTheFetch() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("io.github.db-ol.OrraTests.receiver-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: file) }
        let receiver = RangeReceiver(handle: try FileHandle(forWritingTo: file), offset: 0, size: 10) { _ in }
        // The task is never resumed, so nothing goes to the network.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://example.invalid/")!)
        receiver.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        await #expect(throws: URLError.self) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                receiver.start(continuation)
            }
        }
    }

    @Test func wrongBytesFetchedFromNextServer() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(corrupt: true)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(temporary.isInstalled())
        #expect(servers.log == names.map { "huggingface.co \($0) -" } + names.map { "modelscope.cn \($0) -" })
        #expect(outcome.events.filter { $0 == .verifying }.count == 2)
    }

    @Test func wrongBytesEverywhereAreDamaged() async throws {
        let servers = StubServers()
        servers.setAll(StubBehavior(corrupt: true))
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let outcome = await download(servers, temporary)
        #expect(outcome.failure == .damaged)
        #expect(servers.log.count == 18)
        #expect(!FileManager.default.fileExists(atPath: temporary.installed.path))
    }

    @Test func everyServerFailsThenTryAgain() async throws {
        let servers = StubServers()
        servers.setAll(StubBehavior(status: 404))
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try writePartial(temporary, weights: 1_000_000)
        let outcome = await download(servers, temporary)
        #expect(outcome.failure == .unreachable)
        #expect(servers.log == ModelSource.order.map { "\($0.rawValue) model.safetensors bytes=1000000-" })
        // The bytes stay for the next try, which starts at the first server again.
        #expect(ModelDisk.bytesPresent(temporary.staging, temporary.manifest) == temporary.manifest.totalBytes - TestModel.size("model.safetensors") + 1_000_000)
        servers.setAll(StubBehavior())
        let again = await download(servers, temporary)
        #expect(try again.result.get() == temporary.installed)
        #expect(servers.log.last == "huggingface.co model.safetensors bytes=1000000-")
        #expect(temporary.isInstalled())
    }

    @Test func notEnoughSpaceMakesNoRequest() async throws {
        let servers = StubServers()
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let outcome = await download(servers, temporary, freeSpace: 1_000)
        #expect(outcome.failure == .notEnoughSpace(needed: temporary.manifest.totalBytes + ModelDisk.spaceMargin, available: 1_000))
        #expect(servers.log.isEmpty)
        // What is on disk already counts.
        try writePartial(temporary, weights: 2_000_000)
        let partial = await download(servers, temporary, freeSpace: 1_000)
        #expect(partial.failure == .notEnoughSpace(needed: 1_000_000 + ModelDisk.spaceMargin, available: 1_000))
        #expect(servers.log.isEmpty)
    }

    @Test func cancelKeepsPartialFile() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(20))])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let weights = temporary.staging.appendingPathComponent("model.safetensors")
        let task = Task { await download(servers, temporary) }
        for _ in 0..<1_000 where (ModelDisk.size(weights) ?? 0) < 300_000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let outcome = await task.value
        #expect(throws: CancellationError.self) { try outcome.result.get() }
        let partial = try #require(ModelDisk.size(weights))
        #expect(partial >= 300_000 && partial < TestModel.size("model.safetensors"))
        #expect(!FileManager.default.fileExists(atPath: temporary.installed.path))

        // Resume asks for the rest only.
        servers.set(StubBehavior(), for: .huggingFace)
        let resumed = await download(servers, temporary)
        #expect(try resumed.result.get() == temporary.installed)
        #expect(servers.log.last == "huggingface.co model.safetensors bytes=\(partial)-")
        #expect(temporary.isInstalled())
    }

    @Test func tooManyBytesStops() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(extraBytes: 10)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == ["huggingface.co config.json -"] + names.map { "modelscope.cn \($0) -" })
        #expect(temporary.isInstalled())
    }

    @Test func wrongContentRangeMovesOn() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(wrongContentRange: true)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try writePartial(temporary, weights: 1_000_000)
        let outcome = await download(servers, temporary)
        #expect(try outcome.result.get() == temporary.installed)
        #expect(servers.log == ["huggingface.co model.safetensors bytes=1000000-", "modelscope.cn model.safetensors bytes=1000000-"])
        #expect(outcome.sleeps.isEmpty)
        #expect(temporary.isInstalled())
    }

    @Test func writeErrorIsCouldNotSave() async throws {
        let servers = StubServers()
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        // A file that cannot be written.
        let config = temporary.staging.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: temporary.staging, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: config.path, contents: Data(), attributes: [.posixPermissions: 0o444]))
        let file = await download(servers, temporary)
        #expect(file.failure == .couldNotSave)
        #expect(servers.log.isEmpty)

        // A staging folder that cannot be written.
        try FileManager.default.removeItem(at: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: temporary.staging.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.staging.path) }
        let folder = await download(servers, temporary)
        #expect(folder.failure == .couldNotSave)
        #expect(servers.log.isEmpty)
    }

    /// The first request to a server waits 8 s for data, later ones 30 s.
    @Test func idleTimeouts() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(dropAfter: 50_000)])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let timeouts = Mutex<[String]>([])
        let live = servers.fetch
        let recording = FileFetch { url, destination, offset, size, idleTimeout, progress in
            timeouts.withLock { $0.append("\(url.host ?? "") \(url.lastPathComponent) \(Int(idleTimeout))") }
            try await live.fetch(url, destination, offset, size, idleTimeout, progress)
        }
        let outcome = await download(servers, temporary, fetch: recording)
        #expect(try outcome.result.get() == temporary.installed)
        // The drop comes on model.safetensors.index.json, the first file over 50,000 bytes.
        #expect(timeouts.withLock { $0 } == [
            "huggingface.co config.json 8",
            "huggingface.co tokenizer_config.json 30",
            "huggingface.co model.safetensors.index.json 30",
            "huggingface.co model.safetensors.index.json 30",
            "huggingface.co merges.txt 30",
            "huggingface.co vocab.json 30",
            "huggingface.co model.safetensors 30",
        ])
        // A small file starts over after a drop.
        #expect(servers.log[3] == "huggingface.co model.safetensors.index.json -")
    }

    @Test func progressIsThrottled() async throws {
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(10))])
        defer { servers.close() }
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try FileManager.default.createDirectory(at: temporary.staging, withIntermediateDirectories: true)
        let destination = temporary.staging.appendingPathComponent("model.safetensors")
        #expect(FileManager.default.createFile(atPath: destination.path, contents: nil))
        let reports = Mutex<[(ContinuousClock.Instant, Int64)]>([])
        let weights = TestModel.manifest.files[5]
        let started = ContinuousClock.now
        try await servers.fetch.fetch(ModelSource.huggingFace.url(for: weights, in: TestModel.manifest), destination, 0, weights.size, 30) { length in
            reports.withLock { $0.append((.now, length)) }
        }
        let elapsed = started.duration(to: .now)
        let all = reports.withLock { $0 }
        #expect(try Data(contentsOf: destination) == TestModel.weights)
        // About 46 pieces of 64 KiB arrived, but at most one report per 0.25 s.
        #expect(!all.isEmpty)
        #expect(Double(all.count) <= elapsed / .milliseconds(250) + 1)
        for (earlier, later) in zip(all, all.dropFirst()) {
            #expect(earlier.0.duration(to: later.0) >= .milliseconds(240))
            #expect(earlier.1 < later.1)
        }
    }

    @Test func failuresAreSortedByWhatHelps() {
        #expect(ModelDownload.isOffline(URLError(.notConnectedToInternet)))
        #expect(ModelDownload.isOffline(URLError(.dataNotAllowed)))
        #expect(!ModelDownload.isOffline(URLError(.timedOut)))
        #expect(!ModelDownload.isOffline(URLError(.networkConnectionLost)))
        for code in [400, 403, 404, 410, 416] {
            #expect(ModelDownload.isPermanent(FetchError.status(code)), "\(code)")
        }
        for code in [408, 429, 500, 502, 503, 504] {
            #expect(!ModelDownload.isPermanent(FetchError.status(code)), "\(code)")
        }
        #expect(ModelDownload.isPermanent(FetchError.tooLong))
        #expect(ModelDownload.isPermanent(FetchError.unexpectedRange("bytes 0-1/2")))
        #expect(ModelDownload.isPermanent(FetchError.empty))
        #expect(!ModelDownload.isPermanent(FetchError.incomplete))
        #expect(!ModelDownload.isPermanent(URLError(.timedOut)))

        #expect(ModelDownload.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        #expect(ModelDownload.isOutOfSpace(POSIXError(.ENOSPC)))
        #expect(ModelDownload.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))))
        #expect(ModelDownload.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])))
        #expect(!ModelDownload.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
    }

    @Test func contentRangeMustStartAtTheOffsetAndEndInsideTheFile() {
        #expect(RangeReceiver.rangeIsUsable("bytes 100-7187/7188", offset: 100, size: 7_188))
        // A shorter range is fine.
        #expect(RangeReceiver.rangeIsUsable("bytes 100-199/7188", offset: 100, size: 7_188))
        #expect(!RangeReceiver.rangeIsUsable("bytes 0-7187/7188", offset: 100, size: 7_188))
        #expect(!RangeReceiver.rangeIsUsable("bytes 100-7188/7188", offset: 100, size: 7_188))
        #expect(!RangeReceiver.rangeIsUsable("bytes 100-7187/9999", offset: 100, size: 7_188))
        #expect(!RangeReceiver.rangeIsUsable("bytes 100-7187/*", offset: 100, size: 7_188))
        #expect(!RangeReceiver.rangeIsUsable("bytes */7188", offset: 100, size: 7_188))
        #expect(!RangeReceiver.rangeIsUsable("100-7187/7188", offset: 100, size: 7_188))
        #expect(!RangeReceiver.rangeIsUsable(nil, offset: 100, size: 7_188))
    }
}
