import AppKit
import SwiftUI

/// Where a new user stands with the three things Orra needs before the first dictation:
/// the speech model, microphone access and Accessibility access.
nonisolated struct SetupChecklist: Equatable, Sendable {
    nonisolated enum Status: Equatable, Sendable {
        case todo
        case inProgress
        case done
    }

    /// Done once the model is loaded. An installed model that is still loading is in
    /// progress.
    var model: Status
    var microphone: Status
    var accessibility: Status
    /// Whether the model is installed and has not failed to load. It may still be loading.
    var modelInPlace: Bool

    init(installer: ModelInstaller.State, modelState: PushToTalkController.ModelState, microphone: MicrophoneAccess, hotkeyActive: Bool) {
        switch installer {
        case .installed:
            switch modelState {
            case .ready:
                model = .done
                modelInPlace = true
            case .notLoaded, .loading:
                model = .inProgress
                modelInPlace = true
            case .unavailable:
                model = .todo
                modelInPlace = false
            }
        case .checking, .downloading, .verifying:
            model = .inProgress
            modelInPlace = false
        case .missing, .failed:
            model = .todo
            modelInPlace = false
        }
        self.microphone = microphone == .authorized ? .done : .todo
        accessibility = hotkeyActive ? .done : .todo
    }

    @MainActor
    init(_ pushToTalk: PushToTalkController, _ models: ModelInstaller) {
        self.init(installer: models.state, modelState: pushToTalk.modelState, microphone: pushToTalk.microphoneAccess, hotkeyActive: pushToTalk.isHotkeyActive)
    }

    /// Every step is done and the model is loaded, so the next hold dictates.
    var isComplete: Bool {
        model == .done && microphone == .done && accessibility == .done
    }

    /// Whether the user still has something to do. An installed model that is still
    /// loading needs nothing from the user, so launch does not open the welcome window for
    /// it.
    var needsUser: Bool {
        !modelInPlace || microphone != .done || accessibility != .done
    }

    /// The title of the menu item that opens the welcome window, in the language of
    /// `locale`. Getting Started once setup is complete, when the window shows Orra is
    /// ready and Try next. Setup Guide until then, also while the model loads.
    func menuTitle(locale: Locale = .interface) -> String {
        if isComplete {
            String(localized: LocalizedStringResource("Getting Started…", locale: locale))
        } else {
            String(localized: LocalizedStringResource("Setup Guide…", locale: locale))
        }
    }
}

/// The welcome window. AppDelegate shows it at launch until Orra has its model and both
/// permissions, and the menu's Setup Guide, or Getting Started once setup is complete, shows
/// it again. AppKit, because an accessory app cannot open a SwiftUI window at launch.
///
/// The window switches to a language picked in it at once. The menu, Settings and the
/// indicator show the language macOS loaded at launch, so Orra restarts when the window
/// closes with setup complete after a language was picked in it, see `restartsOnClose`.
final class WelcomeWindow {
    private let pushToTalk: PushToTalkController
    private let setup: SetupDownload
    /// The Projects switch, for its row in Try next.
    private let projects: ProjectsSwitch
    /// Called before the window shows, see DockIcon.willShowWindow().
    private let willShow: () -> Void
    private var window: NSWindow?
    private var refresh: Task<Void, Never>?
    private var closeObserver: (any NSObjectProtocol)?
    /// The language last picked in this window, nil until the user picks one here.
    private var pickedHere: AppLanguage?
    /// The card beside System Settings after a button here opened it. Closed with the
    /// window.
    private let settingsGuide = SettingsGuidePanel()
    /// Called after the window closed.
    var onClose: () -> Void = {}

    /// Whether the window is on screen.
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    init(pushToTalk: PushToTalkController, setup: SetupDownload, projects: ProjectsSwitch, willShow: @escaping () -> Void) {
        self.pushToTalk = pushToTalk
        self.setup = setup
        self.projects = projects
        self.willShow = willShow
    }

    /// Brings the window to the front, from behind the app the user is in too.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        willShow()
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        // macOS may decline the activation, for example at login, and the window still
        // comes to the front.
        window.orderFrontRegardless()
        watchMicrophoneAccess()
    }

    private func makeWindow() -> NSWindow {
        let language = AppLanguage.load()
        let view = WelcomeView(pushToTalk: pushToTalk, setup: setup, language: language, projects: projects) { [weak self] in
            self?.window?.close()
        } localizationChanged: { [weak self] localization in
            self?.window?.title = Self.title(in: localization)
        } languagePicked: { [weak self] language in
            self?.pickedHere = language
        } guideSettings: { [weak self] kind in
            self?.guideSettings(kind)
        }
        let controller = NSHostingController(rootView: view)
        // The window grows when a step shows more, such as the download's progress.
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = Self.title(in: language.localization())
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh?.cancel()
                self?.refresh = nil
                self?.settingsGuide.dismiss()
                self?.restartForLanguage()
                // After the close has finished, so the window no longer counts as visible.
                DispatchQueue.main.async {
                    self?.onClose()
                }
            }
        }
        return window
    }

    /// Shows the card beside System Settings, in the window's language, until the
    /// permission is given. Microphone access is read every second while the window is
    /// open, and the controller follows Accessibility, see `watchMicrophoneAccess()`.
    private func guideSettings(_ kind: PermissionDemo.Kind) {
        settingsGuide.show(kind, localization: AppLanguage.load().localization()) { [pushToTalk] in
            switch kind {
            case .microphone: pushToTalk.microphoneAccess == .authorized
            case .accessibility: pushToTalk.isHotkeyActive
            }
        }
    }

    static func title(in localization: String) -> String {
        String(localized: LocalizedStringResource("Welcome to Orra", locale: Locale(identifier: localization)))
    }

    /// Restarts Orra after the window closes when a language picked in it differs from the
    /// one Orra started with, so the menu and Settings show it too.
    private func restartForLanguage() {
        let saved = AppLanguage.load()
        // Settings and Report a Problem are titled windows that may hold a choice or text
        // the user has not finished with. The indicator and the notices are untitled panels.
        let otherWindowOpen = NSApplication.shared.windows.contains {
            $0 !== window && $0.isVisible && $0.styleMask.contains(.titled)
        }
        let restarts = Self.restartsOnClose(
            setupComplete: SetupChecklist(pushToTalk, setup.speech).isComplete,
            dictating: pushToTalk.state != .idle,
            downloading: setup.speech.state.isBusy || setup.cleanup.models.state.isBusy,
            pickedHere: pickedHere == saved,
            otherWindowOpen: otherWindowOpen,
            picked: saved.localization(),
            launched: AppLanguage.launchLocalization
        )
        guard restarts else { return }
        // After the close has finished.
        DispatchQueue.main.async {
            AppLanguage.restart()
        }
    }

    /// Whether closing the window restarts Orra. Only with setup complete, when a restart
    /// interrupts nothing: the speech model is installed, the cleanup model is not
    /// downloading, and the talk key and the language are saved the moment they are chosen. The window does not come
    /// back at the next launch then. With steps left, as after Not Now, Orra goes on, a
    /// download included, and shows the picked language at its next launch. Never during a
    /// dictation, and only for a language picked in this window, so a choice made in
    /// Settings waits for its own Restart Orra button. Never while another window is open,
    /// such as Settings or an unsent problem report, since quitting would close it.
    nonisolated static func restartsOnClose(setupComplete: Bool, dictating: Bool, downloading: Bool, pickedHere: Bool, otherWindowOpen: Bool, picked: String, launched: String) -> Bool {
        setupComplete && !dictating && !downloading && pickedHere && !otherWindowOpen && picked != launched
    }

    /// While the window is open, microphone access is read every second, so a change in
    /// System Settings shows without a relaunch. Reading never shows a prompt.
    /// Accessibility is not read here: the controller watches it, see
    /// PushToTalkController.watchAccess().
    private func watchMicrophoneAccess() {
        guard refresh == nil else { return }
        refresh = Task { [pushToTalk] in
            while !Task.isCancelled {
                pushToTalk.refreshMicrophoneAccess()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
