import Foundation
import Observation
import Synchronization
import Testing
@testable import Orra

/// Records every state an installer passes through. Observation reports a change before it
/// happens, so each report records the state being left, and the current state comes last.
@MainActor
final class InstallerStates {
    private let installer: ModelInstaller
    private var left: [ModelInstaller.State] = []

    init(_ installer: ModelInstaller) {
        self.installer = installer
        watch()
    }

    var all: [ModelInstaller.State] {
        left + [installer.state]
    }

    /// The kinds of state in order, each repeat folded into one.
    var kinds: [String] {
        all.map { state in
            switch state {
            case .checking: "checking"
            case .missing: "missing"
            case .downloading: "downloading"
            case .verifying: "verifying"
            case .failed: "failed"
            case .installed: "installed"
            }
        }.reduce(into: []) { kinds, kind in
            if kinds.last != kind { kinds.append(kind) }
        }
    }

    private func watch() {
        withObservationTracking {
            _ = installer.state
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.left.append(self.installer.state)
                self.watch()
            }
        }
    }
}

/// The installer as the menu drives it, with stand in servers and temporary folders.
@MainActor
struct ModelInstallerTests {
    let temporary = TemporaryModelFolders()

    private func makeInstaller(_ servers: StubServers, fetch: FileFetch? = nil, freeSpace: Int64? = 100_000_000_000) -> ModelInstaller {
        ModelInstaller(
            manifest: temporary.manifest,
            folders: temporary.folders,
            environment: ModelDownload.Environment(
                fetch: fetch ?? servers.fetch,
                freeSpace: { _ in freeSpace },
                sleep: { _ in }
            )
        )
    }

    /// Launch and Try Again after a failed load look at local files only, whatever is on
    /// disk.
    @Test func launchNeverFetches() async throws {
        let calls = Mutex(0)
        let counting = FileFetch { _, _, _, _, _, _ in
            calls.withLock { $0 += 1 }
        }
        let setups: [(TemporaryModelFolders) throws -> Void] = [
            { _ in },
            { try $0.writeAll(to: $0.folders.oldCopies[0]) },
            { try $0.writeAll(to: $0.folders.oldCopies[1], damaging: ["vocab.json"]) },
            { try $0.writeAll(to: $0.staging) },
            { try $0.write(["config.json", "merges.txt"], to: $0.staging) },
            { try $0.writeAll(to: $0.installed) },
            { try $0.writeAll(to: $0.installed, damaging: ["model.safetensors"]) },
        ]
        for setup in setups {
            let temporary = TemporaryModelFolders()
            defer { temporary.remove() }
            try setup(temporary)
            let installer = ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: counting, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            )
            await installer.prepare()
            await installer.prepare(checkingHashes: true)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func stateSequence() async throws {
        defer { temporary.remove() }
        let servers = StubServers()
        defer { servers.close() }
        let installer = makeInstaller(servers)
        let states = InstallerStates(installer)
        #expect(installer.state == .checking)
        await installer.prepare()
        #expect(installer.state == .missing(bytesPresent: 0))
        installer.download()
        #expect(installer.state == .downloading(bytes: 0, source: nil))
        await installer.waitForDownload()
        #expect(installer.state == .installed(temporary.installed))
        #expect(states.kinds == ["checking", "missing", "downloading", "verifying", "installed"])
        // The download names the server once it asks one, and its bytes only grow.
        let downloads = states.all.compactMap { state -> (Int64, ModelSource?)? in
            if case .downloading(let bytes, let source) = state { (bytes, source) } else { nil }
        }
        #expect(downloads.first! == (0, nil))
        #expect(downloads.dropFirst().allSatisfy { $0.1 == .huggingFace })
        #expect(zip(downloads, downloads.dropFirst()).allSatisfy { $0.0 <= $1.0 })
        #expect(downloads.last!.0 == temporary.manifest.totalBytes)
    }

    @Test func onInstalledCalledOnce() async throws {
        defer { temporary.remove() }
        let servers = StubServers()
        defer { servers.close() }
        let installer = makeInstaller(servers)
        var installed: [URL] = []
        installer.onInstalled = { installed.append($0) }
        await installer.prepare()
        #expect(installed.isEmpty)
        installer.download()
        await installer.waitForDownload()
        #expect(installed == [temporary.installed])
        // The next launch finds it and loads it again.
        await installer.prepare()
        #expect(installed == [temporary.installed, temporary.installed])
    }

    @Test func downloadIgnoredWhileRunning() async throws {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(5))])
        defer { servers.close() }
        let installer = makeInstaller(servers)
        await installer.prepare()
        installer.download()
        installer.download()
        // Launch work waits too.
        await installer.prepare()
        #expect(installer.state != .checking)
        await installer.waitForDownload()
        #expect(installer.state == .installed(temporary.installed))
        #expect(servers.log.count == 6)
        // Once installed, Download does nothing.
        installer.download()
        #expect(installer.state == .installed(temporary.installed))
        #expect(servers.log.count == 6)
    }

    @Test func downloadIgnoredBeforeTheCheck() async {
        defer { temporary.remove() }
        let servers = StubServers()
        defer { servers.close() }
        let installer = makeInstaller(servers)
        installer.download()
        #expect(installer.state == .checking)
        await installer.waitForDownload()
        #expect(servers.log.isEmpty)
    }

    @Test func cancelReturnsToResumeWithTheBytesKept() async throws {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(20))])
        defer { servers.close() }
        let installer = makeInstaller(servers)
        await installer.prepare()
        installer.download()
        let smallFiles = temporary.manifest.totalBytes - TestModel.size("model.safetensors")
        for _ in 0..<1_000 where !Self.isDownloading(installer.state, pastBytes: smallFiles + 300_000) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(installer.isKeepingTheMacAwake)
        installer.cancel()
        await installer.waitForDownload()
        let kept = ModelDisk.bytesPresent(temporary.staging, temporary.manifest)
        #expect(kept >= smallFiles + 300_000 && kept < temporary.manifest.totalBytes)
        #expect(installer.state == .missing(bytesPresent: kept))
        #expect(installer.state.buttonTitle(total: temporary.manifest.totalBytes)?.hasPrefix("Resume Download (") == true)
        #expect(!installer.isKeepingTheMacAwake)

        // Resume continues where the download stopped.
        servers.set(StubBehavior(), for: .huggingFace)
        installer.download()
        await installer.waitForDownload()
        #expect(installer.state == .installed(temporary.installed))
        #expect(servers.log.last == "huggingface.co model.safetensors bytes=\(kept - smallFiles)-")
        #expect(temporary.isInstalled())
    }

    @Test func keepsTheMacAwakeOnlyWhileDownloading() async throws {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(5))])
        defer { servers.close() }
        let installer = makeInstaller(servers)
        await installer.prepare()
        #expect(!installer.isKeepingTheMacAwake)
        installer.download()
        #expect(installer.isKeepingTheMacAwake)
        await installer.waitForDownload()
        #expect(!installer.isKeepingTheMacAwake)
        #expect(installer.state == .installed(temporary.installed))
    }

    @Test func aFailedDownloadCanBeTriedAgain() async throws {
        defer { temporary.remove() }
        let servers = StubServers()
        servers.setAll(StubBehavior(offline: true))
        defer { servers.close() }
        let installer = makeInstaller(servers)
        var loads = 0
        installer.onInstalled = { _ in loads += 1 }
        await installer.prepare()
        installer.download()
        await installer.waitForDownload()
        #expect(installer.state == .failed(.offline))
        #expect(!installer.isKeepingTheMacAwake)
        #expect(loads == 0)
        // Back online, Try Again.
        servers.setAll(StubBehavior())
        installer.download()
        await installer.waitForDownload()
        #expect(installer.state == .installed(temporary.installed))
        #expect(loads == 1)
    }

    @Test func notEnoughSpaceIsShownWithoutARequest() async {
        defer { temporary.remove() }
        let servers = StubServers()
        defer { servers.close() }
        let installer = makeInstaller(servers, freeSpace: 1_000)
        await installer.prepare()
        installer.download()
        await installer.waitForDownload()
        #expect(installer.state == .failed(.notEnoughSpace(needed: temporary.manifest.totalBytes + ModelDisk.spaceMargin, available: 1_000)))
        #expect(servers.log.isEmpty)
    }

    /// After a failed load, Try Again hashes the installed files. A damaged one sends the
    /// model back to Download, which fetches only that file.
    @Test func tryAgainAfterAFailedLoadChecksTheHashes() async throws {
        defer { temporary.remove() }
        let servers = StubServers()
        defer { servers.close() }
        try temporary.writeAll(to: temporary.installed, damaging: ["merges.txt"])
        let installer = makeInstaller(servers)
        var loads = 0
        installer.onInstalled = { _ in loads += 1 }
        // Launch checks sizes only, so the load is tried, and in the app it fails.
        await installer.prepare()
        #expect(installer.state == .installed(temporary.installed))
        #expect(loads == 1)
        await installer.prepare(checkingHashes: true)
        #expect(installer.state == .missing(bytesPresent: temporary.manifest.totalBytes - TestModel.size("merges.txt")))
        #expect(loads == 1)
        installer.download()
        await installer.waitForDownload()
        #expect(servers.log == ["huggingface.co merges.txt -"])
        #expect(installer.state == .installed(temporary.installed))
        #expect(temporary.isInstalled())
        #expect(loads == 2)
    }

    @Test func menuTextForEveryState() {
        typealias State = ModelInstaller.State
        let total = ModelManifest.qwen3.totalBytes
        let needs = ["Orra needs its speech model to transcribe.", "The model comes from Hugging Face or a mirror. Your speech stays on this Mac."]
        #expect(State.checking.menuLines(total: total) == ["Preparing the speech model…"])
        #expect(State.checking.buttonTitle(total: total) == nil)
        #expect(State.missing(bytesPresent: 0).menuLines(total: total) == needs)
        #expect(State.missing(bytesPresent: 0).buttonTitle(total: total) == "Download Speech Model (2.47 GB)")
        #expect(State.missing(bytesPresent: total - 1_270_000_000).menuLines(total: total) == needs)
        #expect(State.missing(bytesPresent: total - 1_270_000_000).buttonTitle(total: total) == "Resume Download (1.27 GB left)")
        #expect(State.downloading(bytes: 0, source: nil).menuLines(total: total) == ["Downloading the speech model: 0% of 2.47 GB"])
        #expect(State.downloading(bytes: total * 48 / 100 + 1, source: .modelScope).menuLines(total: total)
            == ["Downloading the speech model: 48% of 2.47 GB", "From modelscope.cn"])
        #expect(State.downloading(bytes: total, source: .huggingFace).menuLines(total: total)
            == ["Downloading the speech model: 100% of 2.47 GB", "From huggingface.co"])
        #expect(State.downloading(bytes: 0, source: .hfMirror).buttonTitle(total: total) == "Cancel Download")
        #expect(State.verifying.menuLines(total: total) == ["Checking the downloaded files…"])
        #expect(State.verifying.buttonTitle(total: total) == nil)
        #expect(State.failed(.offline).menuLines(total: total) == ["This Mac is offline. Connect to the internet, then try again."])
        #expect(State.failed(.unreachable).menuLines(total: total) == ["Orra could not download the model from Hugging Face or its mirrors."])
        #expect(State.failed(.notEnoughSpace(needed: total + ModelDisk.spaceMargin, available: 1_100_000_000)).menuLines(total: total)
            == ["The download needs 2.97 GB of free space and 1.1 GB is free."])
        #expect(State.failed(.damaged).menuLines(total: total) == ["The downloaded files did not match the expected checksums."])
        #expect(State.failed(.couldNotSave).menuLines(total: total) == ["Orra could not save the model files."])
        for failure: ModelDownload.Failure in [.offline, .unreachable, .damaged, .couldNotSave, .notEnoughSpace(needed: 1, available: 0)] {
            #expect(State.failed(failure).buttonTitle(total: total) == "Try Again")
        }
        #expect(State.installed(URL(fileURLWithPath: "/tmp")).menuLines(total: total).isEmpty)
        #expect(State.installed(URL(fileURLWithPath: "/tmp")).buttonTitle(total: total) == nil)
    }

    @Test func menuBarSymbols() {
        typealias State = ModelInstaller.State
        #expect(State.checking.symbolName == "hourglass")
        #expect(State.missing(bytesPresent: 0).symbolName == "arrow.down.circle")
        #expect(State.missing(bytesPresent: 5).symbolName == "arrow.down.circle")
        #expect(State.downloading(bytes: 5, source: .huggingFace).symbolName == "hourglass")
        #expect(State.verifying.symbolName == "hourglass")
        #expect(State.failed(.offline).symbolName == "exclamationmark.triangle")
        // Once installed, the icon shows the talk key and the model's load as before.
        #expect(State.installed(URL(fileURLWithPath: "/tmp")).symbolName == nil)
    }

    private static func isDownloading(_ state: ModelInstaller.State, pastBytes bytes: Int64) -> Bool {
        if case .downloading(let current, _) = state { current > bytes } else { false }
    }
}
