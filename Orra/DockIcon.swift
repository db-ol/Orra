import AppKit
import Observation

/// Whether Orra shows in the Dock and the app switcher, besides the menu bar. On until the
/// user turns it off in Settings, like Wispr Flow. While it is off, Orra still shows there
/// as long as one of its windows is open, such as Settings or the welcome window, so a
/// window behind other apps can be found again.
@Observable
final class DockIcon {
    static let defaultsKey = "showsInDock"

    var showsInDock: Bool {
        didSet {
            guard showsInDock != oldValue else { return }
            save(showsInDock)
            update()
        }
    }

    @ObservationIgnored private let save: (Bool) -> Void
    @ObservationIgnored private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    @ObservationIgnored private let hasOpenWindow: () -> Bool
    @ObservationIgnored private var policy: NSApplication.ActivationPolicy?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    /// - Parameters:
    ///   - showsInDock: The saved choice.
    ///   - save: Saves the choice after a change.
    ///   - setPolicy: Sets the app's activation policy. Tests pass a fake.
    ///   - hasOpenWindow: Whether one of Orra's windows is open, not counting panels such
    ///     as the recording indicator.
    init(
        showsInDock: Bool,
        save: @escaping (Bool) -> Void,
        setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void,
        hasOpenWindow: @escaping () -> Bool
    ) {
        self.showsInDock = showsInDock
        self.save = save
        self.setPolicy = setPolicy
        self.hasOpenWindow = hasOpenWindow
    }

    static func live(defaults: UserDefaults = .standard) -> DockIcon {
        DockIcon(
            showsInDock: defaults.object(forKey: defaultsKey) as? Bool ?? true,
            save: { defaults.set($0, forKey: defaultsKey) },
            setPolicy: { NSApplication.shared.setActivationPolicy($0) },
            hasOpenWindow: {
                NSApplication.shared.windows.contains { window in
                    window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
                }
            }
        )
    }

    /// Shows or hides the Dock icon for the choice and the open windows.
    func update() {
        let wanted: NSApplication.ActivationPolicy = showsInDock || hasOpenWindow() ? .regular : .accessory
        guard wanted != policy else { return }
        policy = wanted
        setPolicy(wanted)
    }

    /// Updates whenever one of Orra's windows opens or closes.
    func followWindows() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            // The closing window still counts as open until it is gone.
            DispatchQueue.main.async {
                self?.update()
            }
        })
    }

    /// Opens the settings window from AppKit, such as for a click on the Dock icon. Uses the
    /// Settings… item in the app menu, since only SwiftUI views can call openWindow.
    static func openSettings() {
        NSApplication.shared.activate()
        guard let appMenu = NSApplication.shared.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return }
        appMenu.performActionForItem(at: index)
    }
}
