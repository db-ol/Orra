import Foundation
import os
import Synchronization

/// Why a server's answer was not used.
nonisolated enum FetchError: Error, Equatable {
    /// The server answered with this HTTP status.
    case status(Int)
    /// A 206 answer for other bytes than asked for, a 206 nobody asked for, or a 200 answer
    /// that names a range. The header's value, or "none".
    case unexpectedRange(String)
    /// The server sent more bytes than the pinned size.
    case tooLong
    /// A 200 answer ended without an error but short of the pinned size. modelscope.cn
    /// answers a Range request on a small file like this, with a body that starts at the
    /// asked offset instead of byte 0.
    case incomplete
    /// A range answer ended without an error and without a single byte.
    case empty
}

/// Writing the download to disk failed. Kept apart from the server's failures, so a full
/// disk is reported as such instead of moving on to the next server.
nonisolated struct FileWriteError: Error {
    let underlying: any Error
}

/// Fetches one file over HTTP into a file on disk. A closure, so tests can pass a stand in.
/// The live version is the only network code in Orra.
nonisolated struct FileFetch: Sendable {
    /// Writes the file at `url`, from byte `offset` on, into `destination`, which must
    /// exist. It first cuts `destination` to `offset` bytes. Asks for a range only when
    /// `offset` is above zero. Gives up when no data arrives for `idleTimeout` seconds.
    /// Calls `progress` with the length on disk, at most every 0.25 s.
    var fetch: @Sendable (_ url: URL, _ destination: URL, _ offset: Int64, _ size: Int64, _ idleTimeout: TimeInterval, _ progress: @escaping @Sendable (Int64) -> Void) async throws -> Void

    /// One URLSession per request, with no cache, no cookies and no credentials. Tests pass
    /// a configuration that routes every request to a local stand in.
    static func live(configuration base: URLSessionConfiguration = .ephemeral) -> FileFetch {
        FileFetch { url, destination, offset, size, idleTimeout, progress in
            let configuration = base.copy() as! URLSessionConfiguration
            // The idle timeout restarts whenever data arrives. The total time stays at its
            // default of 7 days, so a slow connection can take as long as it needs.
            configuration.timeoutIntervalForRequest = idleTimeout
            configuration.waitsForConnectivity = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            var request = URLRequest(url: url)
            request.timeoutInterval = idleTimeout
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: destination)
                try handle.truncate(atOffset: UInt64(offset))
            } catch {
                throw FileWriteError(underlying: error)
            }
            let receiver = RangeReceiver(handle: handle, offset: offset, size: size, progress: progress)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
            defer { session.finishTasksAndInvalidate() }
            let task = session.dataTask(with: request)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    receiver.start(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }
    }
}

/// The session delegate for one fetch. URLSession calls it on a serial background queue.
/// It checks the answer before any byte is written, never writes past the pinned size, and
/// hands the result to the waiting fetch.
nonisolated final class RangeReceiver: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var length: Int64
        /// The answer was a 200, so its body must be the whole file.
        var wholeFile = false
        var lastReport = ContinuousClock.now
        var failure: (any Error)?
        var continuation: CheckedContinuation<Void, any Error>?
        /// The result of a task that ended before `start(_:)` stored the continuation. A
        /// task cancelled before it was resumed ends that way, when Cancel lands just
        /// before a request starts.
        var outcome: Result<Void, any Error>?
    }

    private let handle: FileHandle
    private let offset: Int64
    private let size: Int64
    private let progress: @Sendable (Int64) -> Void
    private let state: Mutex<State>

    init(handle: FileHandle, offset: Int64, size: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.offset = offset
        self.size = size
        self.progress = progress
        state = Mutex(State(length: offset))
    }

    /// Whichever comes second, this or the end of the task, resumes the fetch.
    func start(_ continuation: CheckedContinuation<Void, any Error>) {
        let early: Result<Void, any Error>? = state.withLock { state in
            guard let outcome = state.outcome else {
                state.continuation = continuation
                return nil
            }
            state.outcome = nil
            return outcome
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    /// Whether a Content-Range value describes bytes from `offset` to at most the end of a
    /// file of `size` bytes, such as "bytes 1000-2463307540/2463307541".
    static func rangeIsUsable(_ value: String?, offset: Int64, size: Int64) -> Bool {
        guard let value, value.hasPrefix("bytes ") else { return false }
        let parts = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, Int64(parts[1]) == size else { return false }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]) else { return false }
        return first == offset && last >= first && last < size
    }

    private func fail(_ error: any Error) {
        state.withLock { state in
            if state.failure == nil {
                state.failure = error
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let contentRange = http?.value(forHTTPHeaderField: "Content-Range")
        switch status {
        case 206:
            // A shorter range is fine: the download asks again for the rest.
            guard offset > 0, Self.rangeIsUsable(contentRange, offset: offset, size: size) else {
                fail(FetchError.unexpectedRange(contentRange ?? "none"))
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        case 200 where contentRange == nil:
            // The whole file: no range was asked for, or the server ignored it. Start over.
            do {
                try handle.truncate(atOffset: 0)
                state.withLock { state in
                    state.length = 0
                    state.wholeFile = true
                }
                completionHandler(.allow)
            } catch {
                fail(FileWriteError(underlying: error))
                completionHandler(.cancel)
            }
        case 200:
            fail(FetchError.unexpectedRange(contentRange ?? "none"))
            completionHandler(.cancel)
        default:
            fail(FetchError.status(status))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (start, failed) = state.withLock { ($0.length, $0.failure != nil) }
        guard !failed else { return }
        let length = start + Int64(data.count)
        guard length <= size else {
            fail(FetchError.tooLong)
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(FileWriteError(underlying: error))
            dataTask.cancel()
            return
        }
        let report: Bool = state.withLock { state in
            state.length = length
            let now = ContinuousClock.now
            guard state.lastReport.duration(to: now) >= .milliseconds(250) else { return false }
            state.lastReport = now
            return true
        }
        if report {
            progress(length)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle.close()
        let size = size
        let ready: (CheckedContinuation<Void, any Error>, Result<Void, any Error>)? = state.withLock { state in
            let result: Result<Void, any Error>
            if let failure = state.failure ?? error {
                result = .failure(failure)
            } else if state.wholeFile, state.length != size {
                result = .failure(FetchError.incomplete)
            } else {
                result = .success(())
            }
            guard let continuation = state.continuation else {
                state.outcome = result
                return nil
            }
            state.continuation = nil
            return (continuation, result)
        }
        if let (continuation, result) = ready {
            continuation.resume(with: result)
        }
    }
}

/// Downloads the pinned files into the staging folder, checks each against its hash, and
/// installs the folder. The only caller is the menu's Download, Resume Download and Try
/// Again, through ModelInstaller. Launch never comes here.
nonisolated enum ModelDownload {
    /// The first request to a server must see data within this time, so a server that
    /// cannot be reached, as Hugging Face from mainland China, costs seconds, not minutes.
    static let firstRequestTimeout: TimeInterval = 8
    /// Once a server has sent data, it may pause this long.
    static let idleTimeout: TimeInterval = 30
    /// Pauses before asking a server again that was sending and failed. A third failure in
    /// a row moves on to the next server. Only a try of the weights that gets past the most
    /// bytes this server delivered resets the count. The small files start over every time
    /// and never reset it.
    static let retryPauses: [Duration] = [.seconds(2), .seconds(10)]

    enum Failure: Error, Equatable, Sendable {
        /// This Mac has no network connection.
        case offline
        /// No server delivered the files.
        case unreachable
        /// The files of the last server did not match their hashes.
        case damaged
        /// The files could not be written.
        case couldNotSave
        /// The free space on the disk does not cover the rest of the download and the margin.
        case notEnoughSpace(needed: Int64, available: Int64)
    }

    enum Event: Sendable, Equatable {
        /// Bytes of the model on disk, and the server being asked.
        case progress(bytes: Int64, source: ModelSource)
        case verifying
    }

    /// What the download needs from the system. Closures, so tests run without a network,
    /// a real disk check or real pauses.
    struct Environment: Sendable {
        var fetch: FileFetch
        var freeSpace: @Sendable (URL) -> Int64?
        var sleep: @Sendable (Duration) async throws -> Void

        static var live: Environment {
            Environment(
                fetch: .live(),
                freeSpace: { ModelDisk.freeSpace(at: $0) },
                sleep: { try await Task.sleep(for: $0) }
            )
        }
    }

    /// Which server is in use, and which ones have sent bytes during this download.
    private struct Servers {
        let sources: [ModelSource]
        var index = 0
        var sending: Set<ModelSource> = []

        var current: ModelSource? {
            index < sources.count ? sources[index] : nil
        }
    }

    /// Fetches what is missing, server by server, then installs. Keeps every byte on disk
    /// when it fails or is cancelled, for the next try. Throws `Failure`, or
    /// `CancellationError` when cancelled.
    @concurrent
    static func run(_ manifest: ModelManifest, _ folders: ModelFolders, sources: [ModelSource], environment: Environment, events: @escaping @Sendable (Event) -> Void) async throws -> URL {
        let log = Logger.modelDownload
        let staging: URL
        do {
            staging = try ModelDisk.makeStaging(manifest, folders)
        } catch {
            log.error("Could not create the download folder: \(describe(error), privacy: .public)")
            throw Failure.couldNotSave
        }
        // Before any request: the rest of the download and the margin must fit.
        let present = ModelDisk.bytesPresent(staging, manifest)
        let needed = manifest.totalBytes - present + ModelDisk.spaceMargin
        if let available = environment.freeSpace(staging), available < needed {
            log.error("Not enough space: \(needed, privacy: .public) bytes needed, \(available, privacy: .public) free")
            throw Failure.notEnoughSpace(needed: needed, available: available)
        }
        log.notice("Download started with \(present, privacy: .public) of \(manifest.totalBytes, privacy: .public) bytes on disk")
        var servers = Servers(sources: sources)
        while true {
            for file in manifest.files {
                try await fetch(file, manifest, staging, &servers, environment, events)
            }
            events(.verifying)
            let damaged: [String]
            do {
                damaged = try ModelDisk.verifyAndInstall(manifest, folders)
            } catch {
                log.error("Checking or installing the files failed: \(describe(error), privacy: .public)")
                throw Failure.couldNotSave
            }
            if damaged.isEmpty {
                ModelDisk.removeLeftovers(manifest, folders)
                return folders.installed(manifest)
            }
            // The deleted files come from the next server.
            servers.index += 1
            guard servers.current != nil else { throw Failure.damaged }
        }
    }

    /// Fetches one file until it is on disk at its pinned size, moving through the servers
    /// as they fail.
    private static func fetch(_ file: ModelFile, _ manifest: ModelManifest, _ staging: URL, _ servers: inout Servers, _ environment: Environment, _ events: @escaping @Sendable (Event) -> Void) async throws {
        let log = Logger.modelDownload
        let destination = staging.appendingPathComponent(file.name)
        // Failures in a row on the current server. For the weights, getting past the most
        // bytes this server delivered resets it.
        var failures = 0
        // The most bytes of this file on disk while the current server sent it. A server
        // makes progress only by going past it, so a server that keeps starting the file
        // over cannot keep the download going forever.
        var best: Int64 = 0
        var bestServer = -1
        while true {
            try Task.checkCancellation()
            let length = ModelDisk.size(destination)
            if length == file.size { return }
            guard let source = servers.current else { throw Failure.unreachable }
            if length == nil {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    log.error("Could not create \(file.name, privacy: .public)")
                    throw Failure.couldNotSave
                }
            }
            // Only the weights continue from the bytes on disk. Every other file, and a
            // file longer than its pinned size, starts over.
            let start = file.resumable && (length ?? 0) < file.size ? length ?? 0 : 0
            if bestServer != servers.index {
                bestServer = servers.index
                best = start
                failures = 0
            }
            let others = ModelDisk.bytesPresent(staging, manifest) - ModelDisk.keptBytes(file, length: length)
            let timeout = servers.sending.contains(source) ? idleTimeout : firstRequestTimeout
            events(.progress(bytes: others + start, source: source))
            log.notice("Fetching \(file.name, privacy: .public) from \(source.rawValue, privacy: .public) at byte \(start, privacy: .public)")
            var failure: (any Error)?
            do {
                try await environment.fetch.fetch(source.url(for: file, in: manifest), destination, start, file.size, timeout) { fileLength in
                    events(.progress(bytes: others + fileLength, source: source))
                }
            } catch {
                failure = error
            }
            if Task.isCancelled { throw CancellationError() }
            let after = ModelDisk.size(destination) ?? 0
            events(.progress(bytes: others + ModelDisk.keptBytes(file, length: after), source: source))
            if failure == nil || (after > 0 && after != start) {
                servers.sending.insert(source)
            }
            let error: any Error
            if let failure {
                error = failure
            } else if after == file.size {
                continue
            } else if after > start {
                // A shorter range than asked for. Ask again for the rest at once, as long
                // as bytes keep coming.
                best = max(best, after)
                failures = 0
                continue
            } else {
                error = FetchError.empty
            }
            if isOffline(error) {
                log.error("This Mac is offline")
                throw Failure.offline
            }
            if let write = error as? FileWriteError {
                log.error("Writing \(file.name, privacy: .public) failed: \(describe(write.underlying), privacy: .public)")
                if isOutOfSpace(write.underlying) {
                    let needed = manifest.totalBytes - ModelDisk.bytesPresent(staging, manifest) + ModelDisk.spaceMargin
                    throw Failure.notEnoughSpace(needed: needed, available: environment.freeSpace(staging) ?? 0)
                }
                throw Failure.couldNotSave
            }
            log.error("\(source.rawValue, privacy: .public) failed on \(file.name, privacy: .public) with \(after, privacy: .public) bytes on disk: \(describe(error), privacy: .public)")
            // A server that never sent bytes, or answered no, is left at once. One that was
            // sending gets a short pause and another try from where it stopped.
            var moveOn = isPermanent(error) || !servers.sending.contains(source)
            if (error as? FetchError) == .incomplete, start > 0 {
                // A 200 answer to a range request that ended short may have started anywhere
                // in the file, as modelscope.cn's do. Its bytes are dropped.
                try? FileManager.default.removeItem(at: destination)
                moveOn = true
            }
            let progressed = file.resumable && after > best
            if progressed {
                best = after
            }
            failures = progressed ? 1 : failures + 1
            if moveOn || failures > retryPauses.count {
                servers.index += 1
                if let next = servers.current {
                    log.notice("Moving on to \(next.rawValue, privacy: .public)")
                }
            } else {
                log.notice("Asking \(source.rawValue, privacy: .public) again after \(retryPauses[failures - 1], privacy: .public)")
                try await environment.sleep(retryPauses[failures - 1])
            }
        }
    }

    /// The system says there is no network connection at all, so another server cannot help.
    static func isOffline(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
    }

    /// The server answered, and asking it again will not change the answer: a 4xx status
    /// other than 408 and 429, or bytes that do not fit the request. A short body counts
    /// like a dropped connection.
    static func isPermanent(_ error: any Error) -> Bool {
        switch error as? FetchError {
        case .status(let code):
            !(500...599).contains(code) && code != 408 && code != 429
        case .unexpectedRange, .tooLong, .empty:
            true
        case .incomplete, nil:
            false
        }
    }

    /// The disk or the user's quota is full.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) || error.code == Int(EDQUOT) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            return isOutOfSpace(underlying)
        }
        return false
    }

    /// An error for the log, without paths: its domain and code, or the fetch error.
    static func describe(_ error: any Error) -> String {
        if let error = error as? FetchError {
            return String(describing: error)
        }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
