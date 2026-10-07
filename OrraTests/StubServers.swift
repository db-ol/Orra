import Foundation
import Synchronization
@testable import Orra

/// How one stand in server answers.
struct StubBehavior: Sendable {
    /// Fails every request as if this Mac had no network.
    var offline = false
    /// Fails every request as if the server could not be reached.
    var unreachable = false
    /// Answers every request with this status and no body.
    var status: Int?
    /// Answers every request that carries a Range header with this status and no body.
    var rangeStatus: Int?
    /// Answers a Range request with 200 and the whole file.
    var ignoresRange = false
    /// Answers a Range request with 200, no Content-Range and the whole file's length, then
    /// sends the file from the asked offset on and ends early. modelscope.cn answered Range
    /// requests on its small files like this.
    var shiftsRanges = false
    /// Puts a Content-Range header on its 200 answers.
    var contentRangeOn200 = false
    /// Answers a Range request with 206 and a Content-Range for other bytes.
    var wrongContentRange = false
    /// Flips the first byte of every file it sends.
    var corrupt = false
    /// Sends this many bytes more than the file holds.
    var extraBytes = 0
    /// Drops the connection once, after this many body bytes, on the first file longer than
    /// that.
    var dropAfter: Int?
    /// Waits this long before each piece of 64 KiB.
    var chunkDelay: Duration = .zero
}

/// Stand ins for the three servers. Requests reach them through a URLProtocol named in the
/// session configuration, so the real URLSession code runs and nothing goes to the network.
/// Each test makes its own, and a header in its configuration routes requests to it, so
/// tests can run in parallel.
final class StubServers: Sendable {
    struct Request: Sendable, Equatable {
        let host: String
        let file: String
        let range: String?
    }

    /// What one request gets.
    enum Answer {
        case failure(URLError)
        case response(status: Int, headers: [String: String], body: Data, dropAfter: Int?, chunkDelay: Duration)
    }

    private struct State {
        var files: [String: Data]
        var behaviors: [String: StubBehavior]
        var requests: [Request] = []
        var onRequest: (@Sendable (Request) -> Void)?
    }

    static let header = "X-Orra-Test-Servers"
    private static let registry = Mutex<[String: StubServers]>([:])

    let id = UUID().uuidString
    private let state: Mutex<State>

    init(files: [String: Data] = TestModel.contents, behaviors: [ModelSource: StubBehavior] = [:]) {
        state = Mutex(State(files: files, behaviors: Dictionary(uniqueKeysWithValues: behaviors.map { ($0.key.rawValue, $0.value) })))
        Self.registry.withLock { $0[id] = self }
    }

    /// Takes the servers out of the routing table. Requests made afterwards fail.
    func close() {
        Self.registry.withLock { $0[id] = nil }
    }

    /// A session configuration that sends every request to these servers.
    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id]
        return configuration
    }

    /// The real fetch, talking to these servers.
    var fetch: FileFetch {
        .live(configuration: configuration)
    }

    /// Every request so far, as "host file range", with "-" for no range.
    var log: [String] {
        state.withLock { $0.requests.map { "\($0.host) \($0.file) \($0.range ?? "-")" } }
    }

    func set(_ behavior: StubBehavior, for source: ModelSource) {
        state.withLock { $0.behaviors[source.rawValue] = behavior }
    }

    func setAll(_ behavior: StubBehavior) {
        state.withLock { state in
            for source in ModelSource.allCases {
                state.behaviors[source.rawValue] = behavior
            }
        }
    }

    /// Called as each request arrives, before it is answered.
    func onRequest(_ observe: @escaping @Sendable (Request) -> Void) {
        state.withLock { $0.onRequest = observe }
    }

    static func find(_ request: URLRequest) -> StubServers? {
        guard let id = request.value(forHTTPHeaderField: header) else { return nil }
        return registry.withLock { $0[id] }
    }

    /// Logs the request and decides the answer.
    func answer(_ request: URLRequest) -> Answer {
        let url = request.url!
        let entry = Request(host: url.host ?? "", file: url.lastPathComponent, range: request.value(forHTTPHeaderField: "Range"))
        let (file, behavior, observe): (Data?, StubBehavior, (@Sendable (Request) -> Void)?) = state.withLock { state in
            state.requests.append(entry)
            var behavior = state.behaviors[entry.host] ?? StubBehavior()
            let file = state.files[entry.file]
            if let drop = behavior.dropAfter {
                if let file, file.count > drop {
                    // Only once, on the first file that is long enough.
                    var once = behavior
                    once.dropAfter = nil
                    state.behaviors[entry.host] = once
                } else {
                    behavior.dropAfter = nil
                }
            }
            return (file, behavior, state.onRequest)
        }
        observe?(entry)
        if behavior.offline { return .failure(URLError(.notConnectedToInternet)) }
        if behavior.unreachable { return .failure(URLError(.cannotConnectToHost)) }
        func plain(_ status: Int) -> Answer {
            .response(status: status, headers: [:], body: Data(), dropAfter: nil, chunkDelay: .zero)
        }
        guard var body = file else { return plain(404) }
        if let status = behavior.status { return plain(status) }
        if entry.range != nil, let status = behavior.rangeStatus { return plain(status) }
        if behavior.corrupt, !body.isEmpty {
            body[body.startIndex] ^= 0xFF
        }
        if behavior.extraBytes > 0 {
            body.append(Data(repeating: 0x2A, count: behavior.extraBytes))
        }
        let size = body.count
        func send(_ status: Int, _ headers: [String: String], _ data: Data) -> Answer {
            .response(status: status, headers: headers, body: data, dropAfter: behavior.dropAfter, chunkDelay: behavior.chunkDelay)
        }
        let fullRange = ["Content-Range": "bytes 0-\(size - 1)/\(size)"]
        guard let range = entry.range, range.hasPrefix("bytes="), range.hasSuffix("-"),
              let start = Int(range.dropFirst(6).dropLast()), start < size else {
            return send(200, behavior.contentRangeOn200 ? fullRange : [:], body)
        }
        if behavior.shiftsRanges {
            return send(200, ["Content-Length": String(size)], body.subdata(in: start..<size))
        }
        if behavior.ignoresRange {
            return send(200, [:], body)
        }
        if behavior.contentRangeOn200 {
            return send(200, fullRange, body)
        }
        if behavior.wrongContentRange {
            return send(206, ["Content-Range": "bytes 0-\(size - start - 1)/\(size)"], body.subdata(in: start..<size))
        }
        return send(206, ["Content-Range": "bytes \(start)-\(size - 1)/\(size)"], body.subdata(in: start..<size))
    }
}

/// Runs blocks on the run loop of the thread that started loading, where URLProtocol must
/// talk to its client.
struct RunLoopBox: @unchecked Sendable {
    let loop: CFRunLoop

    func perform(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(loop)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // A request without the test's servers fails here. It never reaches the network.
        guard let servers = StubServers.find(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch servers.answer(request) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let headers, let body, let dropAfter, let chunkDelay):
            var all = headers
            if all["Content-Length"] == nil {
                all["Content-Length"] = String(body.count)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let limit = dropAfter.map { min($0, body.count) } ?? body.count
            send(body, from: 0, limit: limit, delay: chunkDelay, box: RunLoopBox(loop: CFRunLoopGetCurrent()))
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private func send(_ body: Data, from start: Int, limit: Int, delay: Duration, box: RunLoopBox) {
        if stopped.withLock({ $0 }) { return }
        guard start < limit else {
            if limit < body.count {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        let end = min(start + 64 * 1024, limit)
        client?.urlProtocol(self, didLoad: body.subdata(in: start..<end))
        let next: @Sendable () -> Void = { [self] in
            send(body, from: end, limit: limit, delay: delay, box: box)
        }
        if delay > .zero {
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { box.perform(next) }
        } else {
            box.perform(next)
        }
    }
}
