import AppKit
import Observation
import Sparkle

/// Updates Orra from inside the app, through Sparkle. The feed is appcast.xml on the
/// latest GitHub release (SUFeedURL in Info.plist). Sparkle installs an update only when
/// the feed and the DMG carry signatures from the team's update key (SUPublicEDKey).
///
/// Orra never checks on its own until the user allows it: Sparkle asks at the second
/// launch, and Settings has the choice. A check sends no information about the Mac, since
/// SUEnableSystemProfiling is off. Check for Updates… in the menu checks at any time.
@Observable
final class AppUpdater: NSObject {
    /// False while a check or an update runs, when the menu item does nothing.
    private(set) var canCheckForUpdates = false
    /// The version of an update found by a scheduled check that the user has not looked at
    /// yet, for the menu. Sparkle shows its window behind other apps then, see
    /// standardUserDriverShouldHandleShowingScheduledUpdate.
    private(set) var waitingUpdate: String?

    var checksAutomatically = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Starts Sparkle. AppDelegate calls it at launch, never when Xcode hosts the tests.
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        // Sparkle changes both on its own, such as when the user answers its question
        // about automatic checks.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.checksAutomatically = updater.automaticallyChecksForUpdates
                }
            },
        ]
    }

    /// Checks now and shows the result, also when Orra is up to date.
    func checkForUpdates() {
        NSApplication.shared.activate()
        controller?.checkForUpdates(nil)
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows a scheduled update itself, behind other apps when the user is busy,
    /// so a dictation is never interrupted. The menu then offers it too.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !state.userInitiated {
            waitingUpdate = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        waitingUpdate = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        waitingUpdate = nil
    }
}
