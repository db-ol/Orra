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
    /// it, and the menu shows no Setup Guide.
    var needsUser: Bool {
        !modelInPlace || microphone != .done || accessibility != .done
    }
}

/// The welcome window. AppDelegate shows it at launch until Orra has its model and both
/// permissions, and the menu's Setup Guide shows it again. AppKit, because an accessory
/// app cannot open a SwiftUI window at launch.
///
/// The window switches to a language picked in it at once. The menu, Settings and the
/// indicator show the language macOS loaded at launch, so Orra restarts when the window
/// closes with setup complete, see `restartsOnClose`.
final class WelcomeWindow {
    private let pushToTalk: PushToTalkController
    private let models: ModelInstaller
    private var window: NSWindow?
    private var refresh: Task<Void, Never>?
    private var closeObserver: (any NSObjectProtocol)?

    init(pushToTalk: PushToTalkController, models: ModelInstaller) {
        self.pushToTalk = pushToTalk
        self.models = models
    }

    /// Brings the window to the front, from behind the app the user is in too.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        // macOS may decline the activation, for example at login, and the window still
        // comes to the front.
        window.orderFrontRegardless()
        watchMicrophoneAccess()
    }

    private func makeWindow() -> NSWindow {
        let language = AppLanguage.load()
        let view = WelcomeView(pushToTalk: pushToTalk, models: models, language: language) { [weak self] in
            self?.window?.close()
        } localizationChanged: { [weak self] localization in
            self?.window?.title = Self.title(in: localization)
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
                self?.restartForLanguage()
            }
        }
        return window
    }

    static func title(in localization: String) -> String {
        String(localized: LocalizedStringResource("Welcome to Orra", locale: Locale(identifier: localization)))
    }

    /// Restarts Orra after the window closes when a language picked in it differs from the
    /// one Orra started with, so the menu and Settings show it too.
    private func restartForLanguage() {
        let restarts = Self.restartsOnClose(
            setupComplete: SetupChecklist(pushToTalk, models).isComplete,
            dictating: pushToTalk.state != .idle,
            picked: AppLanguage.load().localization(),
            launched: AppLanguage.launchLocalization
        )
        guard restarts else { return }
        // After the close has finished.
        DispatchQueue.main.async {
            AppLanguage.restart()
        }
    }

    /// Whether closing the window restarts Orra. Only with setup complete, when a restart
    /// interrupts nothing: the model is installed, so no download runs, and the talk key
    /// and the language are saved the moment they are chosen. The window does not come
    /// back at the next launch then. With steps left, as after Not Now, Orra goes on, a
    /// download included, and shows the picked language at its next launch. Never during a
    /// dictation.
    nonisolated static func restartsOnClose(setupComplete: Bool, dictating: Bool, picked: String, launched: String) -> Bool {
        setupComplete && !dictating && picked != launched
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
