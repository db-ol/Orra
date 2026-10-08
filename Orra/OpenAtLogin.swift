import AppKit
import Observation
import os
import ServiceManagement

/// Whether Orra opens when the user logs in. The app itself is the login item, through
/// SMAppService, so no helper app is needed. The system calls are closures, so tests never
/// touch the real login items.
@Observable
final class OpenAtLogin {
    nonisolated enum Status: Equatable, Sendable {
        case on
        case off
        /// Registered, but the user still has to allow Orra in System Settings > General >
        /// Login Items & Extensions.
        case needsApproval
    }

    /// The status as last read from the system. The user can also change it in System
    /// Settings, so it is read again whenever a menu opens and after every change here.
    private(set) var status: Status
    /// The latest failure, shown in the menu until a change succeeds or the status matches
    /// what the user asked for.
    private(set) var problem: String?

    @ObservationIgnored private let readStatus: () -> Status
    @ObservationIgnored private let register: (Bool) throws -> Void
    @ObservationIgnored private let openLoginItemsSettings: () -> Void
    @ObservationIgnored private var requested: Bool?
    @ObservationIgnored private var menuObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "login-item")

    init(
        readStatus: @escaping () -> Status,
        register: @escaping (Bool) throws -> Void,
        openLoginItemsSettings: @escaping () -> Void
    ) {
        self.readStatus = readStatus
        self.register = register
        self.openLoginItemsSettings = openLoginItemsSettings
        status = readStatus()
    }

    static func live() -> OpenAtLogin {
        OpenAtLogin(
            readStatus: {
                switch SMAppService.mainApp.status {
                case .enabled: .on
                case .requiresApproval: .needsApproval
                case .notRegistered, .notFound: .off
                @unknown default: .off
                }
            },
            register: { on in
                if on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            },
            openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }

    /// The menu shows a check mark for this. A login item that waits for approval counts as
    /// on, because the user asked for it.
    var isOn: Bool {
        status != .off
    }

    /// The menu then offers to open System Settings, where only the user can approve Orra.
    var needsApproval: Bool {
        status == .needsApproval
    }

    /// Reads the status again each time a menu opens, Orra's menu bar menu included. The
    /// menu shows the new value while it is open.
    func refreshWhenMenusOpen() {
        guard menuObserver == nil else { return }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func refresh() {
        status = readStatus()
        if problem != nil, let requested, isOn == requested {
            problem = nil
        }
    }

    func setOn(_ on: Bool) {
        requested = on
        do {
            try register(on)
            problem = nil
        } catch {
            problem = on ? String(localized: "Orra could not add itself to Login Items") : String(localized: "Orra could not remove itself from Login Items")
            logger.error("Changing the login item failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func openSettings() {
        openLoginItemsSettings()
    }
}
