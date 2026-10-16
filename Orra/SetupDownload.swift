import Foundation
import Observation

/// Whether the welcome window's download includes the cleanup model for a new user, who
/// is not asked: the button names the size of both models, and starting it turns cleanup on.
///
/// Only a new user gets it: one whose speech model is not on this Mac yet and who never
/// saved a choice for cleanup. A saved choice, on or off, always wins, so an existing
/// user's setting never flips. On a Mac with less memory than `minimumMemory` cleanup stays
/// off, and the welcome window says why.
nonisolated enum CleanupDefault {
    /// 16 GB. The cleanup model holds about 4 GB while it is loaded, next to the speech
    /// model's 3 to 5 GB, see README.md and docs/asr-baseline.md. That leaves too little to
    /// the user's own apps on an 8 GB Mac.
    static let minimumMemory: UInt64 = 16 << 30

    static func proposes(savedChoice: Bool?, speechModelInstalled: Bool, physicalMemory: UInt64) -> Bool {
        savedChoice == nil && !speechModelInstalled && hasEnoughMemory(physicalMemory)
    }

    static func hasEnoughMemory(_ physicalMemory: UInt64) -> Bool {
        physicalMemory >= minimumMemory
    }

    /// The memory in whole gigabytes, as About This Mac shows it: 8, 16, 24.
    static func gigabytes(_ physicalMemory: UInt64) -> Int64 {
        Int64((physicalMemory + (1 << 29)) >> 30)
    }
}

/// The welcome window's one download: the speech model, then the cleanup model when cleanup
/// is on, one after the other behind one progress bar. Dictation works as soon as the
/// speech model is in place, while the cleanup model goes on downloading.
///
/// It drives the two installers and starts nothing on its own: only Download, Resume
/// Download and Try Again in the welcome window go online. Its button names the size first.
/// AppDelegate tells it when the speech model is in place, see `speechInstalled()`.
@Observable
final class SetupDownload {
    nonisolated enum Part: Equatable, Sendable {
        case speech
        case cleanup
    }

    let speech: ModelInstaller
    let cleanup: TextCleanup
    /// True while the welcome window's download includes the cleanup model for a new user,
    /// see CleanupDefault. Nothing is saved until the user starts the download.
    private(set) var proposesCleanup = false
    /// True from a download started with cleanup on until the speech model is in place,
    /// when the cleanup model's download starts.
    private(set) var queuesCleanup = false
    /// Whether the speech model's bytes count in the progress bar. False when it was in
    /// place at launch, so a cleanup model download after that shows the cleanup model alone.
    private(set) var includesSpeech = true

    @ObservationIgnored private let physicalMemory: UInt64
    @ObservationIgnored private let savedChoice: () -> Bool?

    /// - Parameters:
    ///   - physicalMemory: This Mac's memory. Tests pass other sizes.
    ///   - savedChoice: The cleanup setting as saved, nil when the user never chose.
    init(
        speech: ModelInstaller,
        cleanup: TextCleanup,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        savedChoice: @escaping () -> Bool? = { CleanupPreference.saved() }
    ) {
        self.speech = speech
        self.cleanup = cleanup
        self.physicalMemory = physicalMemory
        self.savedChoice = savedChoice
    }

    /// This Mac's memory in whole gigabytes while cleanup stays off only because of it: no
    /// saved choice and less than `CleanupDefault.minimumMemory`. Nil otherwise, also once
    /// the user turned cleanup on in Settings.
    var memoryKeepsCleanupOff: Int64? {
        guard !cleanup.isOn, savedChoice() == nil, !CleanupDefault.hasEnoughMemory(physicalMemory) else { return nil }
        return CleanupDefault.gigabytes(physicalMemory)
    }

    /// At launch, once the installers looked at the files on disk: whether the download
    /// includes the cleanup model, and whether the bar counts the speech model.
    func lookAtLaunch() {
        let installed = speech.state.isInstalled
        includesSpeech = !installed
        proposesCleanup = CleanupDefault.proposes(savedChoice: savedChoice(), speechModelInstalled: installed, physicalMemory: physicalMemory)
    }

    /// Whether the welcome window's download includes the cleanup model: cleanup is on, or
    /// it is a new user's download, see CleanupDefault. The new user's case counts only
    /// while a start in the window can still act on it. During a speech model download
    /// started from the menu, it does not, as the cleanup model would not follow.
    var wantsCleanup: Bool {
        cleanup.isOn || (proposesCleanup && !speech.state.isBusy)
    }

    /// Whether step 1 names both models: the download includes the cleanup model, unless
    /// only the speech model is left to download as the cleanup model is already in place.
    var namesBothModels: Bool {
        wantsCleanup && (speech.state.isInstalled || !cleanup.models.state.isInstalled)
    }

    /// Download, Resume Download or Try Again in the welcome window. A new user's download
    /// turns cleanup on here, since the button names the size with the cleanup model.
    func start() {
        if proposesCleanup {
            proposesCleanup = false
            cleanup.agreeToDownload()
        }
        switch Self.next(speech: speech.state, wantsCleanup: cleanup.isOn, cleanup: cleanup.models.state) {
        case .speech:
            includesSpeech = true
            queuesCleanup = cleanup.isOn
            speech.download()
        case .cleanup:
            cleanup.download()
        case nil:
            break
        }
    }

    /// Cancel Download in the welcome window. The bytes on disk stay for Resume Download.
    /// During the speech model, cleanup stays on and waits for the next start. During the
    /// cleanup model, it works as Cancel Download in Settings, which turns cleanup off.
    func cancel() {
        queuesCleanup = false
        switch Self.active(speech: speech.state, wantsCleanup: wantsCleanup, cleanup: cleanup.models.state) {
        case .speech:
            speech.cancel()
        case .cleanup:
            cleanup.cancelDownload()
        case nil:
            break
        }
    }

    /// The speech model is in place: at launch, after a download, or after Try Again.
    /// Starts the cleanup model's download when one was queued. A new user's download that
    /// was never started ends here, as the speech model came from the menu instead, and
    /// cleanup stays off.
    func speechInstalled() {
        proposesCleanup = false
        guard queuesCleanup else { return }
        queuesCleanup = false
        cleanup.download()
    }

    /// Which download a start begins: the speech model until it is in place, then the
    /// cleanup model when cleanup is on. Nil while one runs or when nothing is left.
    nonisolated static func next(speech: ModelInstaller.State, wantsCleanup: Bool, cleanup: ModelInstaller.State) -> Part? {
        switch speech {
        case .missing, .failed:
            return .speech
        case .checking, .downloading, .verifying:
            return nil
        case .installed:
            guard wantsCleanup else { return nil }
            switch cleanup {
            case .missing, .failed: return .cleanup
            case .checking, .downloading, .verifying, .installed: return nil
            }
        }
    }

    /// The part the welcome window's step is about: the speech model until it is in place,
    /// then the cleanup model while cleanup is wanted and not in place. Nil when both are.
    nonisolated static func active(speech: ModelInstaller.State, wantsCleanup: Bool, cleanup: ModelInstaller.State) -> Part? {
        if !speech.isInstalled { return .speech }
        if wantsCleanup, !cleanup.isInstalled { return .cleanup }
        return nil
    }

    /// The step's text, button and progress now.
    func summary(locale: Locale = .interface) -> DownloadSummary {
        DownloadSummary(
            speech: speech.state,
            speechTotal: speech.manifest.totalBytes,
            cleanup: cleanup.models.state,
            cleanupTotal: cleanup.models.manifest.totalBytes,
            wantsCleanup: wantsCleanup,
            queuesCleanup: queuesCleanup,
            includesSpeech: includesSpeech,
            memoryKeepsCleanupOff: memoryKeepsCleanupOff,
            locale: locale
        )
    }
}

nonisolated extension ModelInstaller.State {
    var isInstalled: Bool {
        if case .installed = self { true } else { false }
    }

    /// True while a download or its check runs.
    var isBusy: Bool {
        switch self {
        case .downloading, .verifying: true
        case .checking, .missing, .failed, .installed: false
        }
    }
}

/// The bytes of the downloads in one bar: each model that is part of it counts with its
/// bytes on disk, and in full once it is checked or installed.
nonisolated struct CombinedProgress: Equatable, Sendable {
    var completed: Int64
    var total: Int64

    /// - Parameters: A nil state leaves that model out of the bar.
    init(speech: ModelInstaller.State?, speechTotal: Int64, cleanup: ModelInstaller.State?, cleanupTotal: Int64) {
        completed = 0
        total = 0
        if let speech {
            completed += Self.bytes(speech, total: speechTotal)
            total += speechTotal
        }
        if let cleanup {
            completed += Self.bytes(cleanup, total: cleanupTotal)
            total += cleanupTotal
        }
    }

    /// The bytes of one model that count. A failed download counts none, as its bytes on
    /// disk are not known until the next start.
    static func bytes(_ state: ModelInstaller.State, total: Int64) -> Int64 {
        switch state {
        case .installed, .verifying: total
        case .downloading(let bytes, _), .missing(let bytes): min(max(bytes, 0), total)
        case .checking, .failed: 0
        }
    }

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    var percent: Int64 {
        ModelInstaller.State.percent(completed, of: total)
    }
}

/// What the welcome window's download step shows, kept apart so tests can read it. While
/// a download runs, the step shows one line with its percent and size. For both models it
/// does not say which one is downloading, and where the files come from is left to the
/// menu and Settings.
nonisolated struct DownloadSummary: Equatable, Sendable {
    /// The part the step is about, nil once every wanted model is in place.
    var active: SetupDownload.Part?
    /// The bar, while a part downloads or is checked.
    var progress: CombinedProgress?
    /// The lines above the button, in the language of the locale.
    var lines: [String] = []
    /// The button, nil when there is none.
    var button: String?
    /// Whether the button cancels.
    var cancels = false

    /// - Parameters:
    ///   - queuesCleanup: Whether the cleanup model follows the speech model's download
    ///     under way. A speech model download started from the menu leaves it out, also
    ///     for a new user whose download would include it.
    ///   - memoryKeepsCleanupOff: This Mac's memory in gigabytes when cleanup stays off
    ///     only because of it, see `SetupDownload.memoryKeepsCleanupOff`.
    init(speech: ModelInstaller.State, speechTotal: Int64, cleanup: ModelInstaller.State, cleanupTotal: Int64, wantsCleanup: Bool, queuesCleanup: Bool, includesSpeech: Bool, memoryKeepsCleanupOff: Int64? = nil, locale: Locale = .interface) {
        let active = SetupDownload.active(speech: speech, wantsCleanup: wantsCleanup, cleanup: cleanup)
        self.active = active
        // While the speech model downloads, the cleanup model counts only when it follows.
        let countsCleanup = speech.isBusy ? queuesCleanup : wantsCleanup
        let combined = CombinedProgress(
            speech: includesSpeech || !speech.isInstalled ? speech : nil,
            speechTotal: speechTotal,
            cleanup: countsCleanup ? cleanup : nil,
            cleanupTotal: cleanupTotal
        )
        let size = ModelInstaller.State.size(combined.total)
        func text(_ resource: LocalizedStringResource) -> String {
            var resource = resource
            resource.locale = locale
            return String(localized: resource)
        }
        // Both models, in one bar.
        let downloadingBoth = text("Downloading the models: \(combined.percent)% of \(size)")
        switch active {
        case nil:
            break
        case .speech:
            switch speech {
            case .downloading where queuesCleanup:
                progress = combined
                lines = [downloadingBoth]
                button = speech.buttonTitle(total: speechTotal, locale: locale)
            case .downloading:
                progress = combined
                lines = Array(speech.menuLines(total: speechTotal, locale: locale).prefix(1))
                button = speech.buttonTitle(total: speechTotal, locale: locale)
            case .verifying:
                progress = combined
                lines = speech.menuLines(total: speechTotal, locale: locale)
            case .missing where wantsCleanup && !cleanup.isInstalled:
                lines = [text("Once downloaded, everything runs on this Mac. What you say is never sent anywhere.")]
                if combined.completed > 0 {
                    button = text("Resume Download (\(ModelInstaller.State.size(combined.total - combined.completed)) left)")
                } else {
                    button = text("Download Models (\(size))")
                }
            case .missing:
                if let gigabytes = memoryKeepsCleanupOff {
                    lines = [text("Cleanup stays off on this Mac because it has \(gigabytes) GB of memory. You can turn it on later in Settings, General.")]
                } else {
                    lines = Array(speech.menuLines(total: speechTotal, locale: locale).prefix(1))
                }
                button = speech.buttonTitle(total: speechTotal, locale: locale)
            case .failed where wantsCleanup && !queuesCleanup && !cleanup.isInstalled:
                // A speech model download from the menu failed, so a start here would also
                // queue the cleanup model. The button names the size of both.
                lines = speech.menuLines(total: speechTotal, locale: locale)
                button = text("Download Models (\(size))")
            default:
                lines = speech.menuLines(total: speechTotal, locale: locale)
                button = speech.buttonTitle(total: speechTotal, locale: locale)
            }
            if case .downloading = speech {
                cancels = true
            }
        case .cleanup:
            switch cleanup {
            case .downloading:
                progress = combined
                // The line stays as it was while the speech model downloaded. With the
                // speech model in place at launch, the cleanup model is all there is.
                lines = [includesSpeech ? downloadingBoth : text("Downloading the cleanup model: \(combined.percent)% of \(size)")]
                button = text("Cancel Download")
                cancels = true
            case .verifying:
                progress = combined
                lines = cleanup.menuLines(total: cleanupTotal, locale: locale)
            case .checking:
                break
            case .missing(let bytes):
                lines = [text("The cleanup model is not on this Mac yet. Until it is, Orra pastes the text without cleanup.")]
                if bytes > 0 {
                    button = text("Resume Download (\(ModelInstaller.State.size(cleanupTotal - bytes)) left)")
                } else {
                    button = text("Download Cleanup Model (\(ModelInstaller.State.size(cleanupTotal)))")
                }
            case .failed:
                lines = cleanup.menuLines(total: cleanupTotal, locale: locale)
                button = text("Try Again")
            case .installed:
                break
            }
        }
    }
}

/// The step the guide in the welcome window talks about, and the line it says for it.
nonisolated enum GuideStep: Equatable, Sendable, CaseIterable {
    case download
    case microphone
    case accessibility
    case talkKey
    case downloading
    case ready

    /// The first step left, in the window's order. While a download runs the guide moves on
    /// to the permissions and the talk key, and only then waits for the download.
    static func current(checklist: SetupChecklist, talkKeyChosen: Bool, downloadingCleanup: Bool) -> GuideStep {
        if checklist.model == .todo { return .download }
        if checklist.microphone != .done { return .microphone }
        if checklist.accessibility != .done { return .accessibility }
        if !talkKeyChosen { return .talkKey }
        if checklist.model != .done || downloadingCleanup { return .downloading }
        return .ready
    }

    func line(locale: Locale = .interface) -> String {
        var resource: LocalizedStringResource = switch self {
        case .download: "Hi, I’m Orra. First, let me download what I need. It happens once."
        case .microphone: "Let me hear you. Allow the microphone."
        case .accessibility: "Now let me type for you. Allow Accessibility."
        case .talkKey: "Pick the key you hold to talk."
        case .downloading: "Still downloading. It goes on if you close this window."
        case .ready: "All set! Hold the talk key and say hello."
        }
        resource.locale = locale
        return String(localized: resource)
    }
}
