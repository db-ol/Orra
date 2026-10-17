import Foundation
import Testing
@testable import Orra

/// The steps of the welcome window, when launch shows it and what the menu calls it.
struct SetupChecklistTests {
    private let folder = URL(fileURLWithPath: "/nonexistent/Models/qwen3")

    private func checklist(
        installer: ModelInstaller.State? = nil,
        modelState: PushToTalkController.ModelState = .ready,
        microphone: MicrophoneAccess = .authorized,
        hotkeyActive: Bool = true
    ) -> SetupChecklist {
        SetupChecklist(installer: installer ?? .installed(folder), modelState: modelState, microphone: microphone, hotkeyActive: hotkeyActive)
    }

    @Test func theModelStepFollowsTheInstaller() {
        #expect(checklist(installer: .checking).model == .inProgress)
        #expect(checklist(installer: .downloading(bytes: 10, source: nil)).model == .inProgress)
        #expect(checklist(installer: .verifying).model == .inProgress)
        #expect(checklist(installer: .missing(bytesPresent: 0)).model == .todo)
        #expect(checklist(installer: .missing(bytesPresent: 1_000)).model == .todo)
        #expect(checklist(installer: .failed(.offline)).model == .todo)
    }

    @Test func anInstalledModelIsDoneOnceItHasLoaded() {
        #expect(checklist(modelState: .notLoaded).model == .inProgress)
        #expect(checklist(modelState: .loading).model == .inProgress)
        #expect(checklist(modelState: .ready).model == .done)
        #expect(checklist(modelState: .unavailable(.failedToLoad)).model == .todo)
    }

    @Test func onlyGrantedMicrophoneAccessCompletesItsStep() {
        #expect(checklist(microphone: .authorized).microphone == .done)
        for access in [MicrophoneAccess.notDetermined, .denied, .notConfigured] {
            #expect(checklist(microphone: access).microphone == .todo)
        }
    }

    @Test func theAccessibilityStepIsDoneOnceTheTalkKeyWorks() {
        #expect(checklist(hotkeyActive: true).accessibility == .done)
        #expect(checklist(hotkeyActive: false).accessibility == .todo)
    }

    @Test func setupIsCompleteOnlyWithAllThreeStepsAndTheModelLoaded() {
        #expect(checklist().isComplete)
        #expect(!checklist(modelState: .loading).isComplete)
        #expect(!checklist(installer: .downloading(bytes: 10, source: nil)).isComplete)
        #expect(!checklist(microphone: .notDetermined).isComplete)
        #expect(!checklist(hotkeyActive: false).isComplete)
        #expect(!checklist(modelState: .unavailable(.missing)).isComplete)
    }

    /// Decides whether launch opens the welcome window and what a click on the Dock icon
    /// opens.
    @Test func aModelThatIsStillLoadingNeedsNothingFromTheUser() {
        #expect(!checklist().needsUser)
        #expect(!checklist(modelState: .notLoaded).needsUser)
        #expect(!checklist(modelState: .loading).needsUser)
        #expect(checklist(modelState: .unavailable(.failedToLoad)).needsUser)
        #expect(checklist(installer: .checking).needsUser)
        #expect(checklist(installer: .downloading(bytes: 10, source: nil)).needsUser)
        #expect(checklist(installer: .missing(bytesPresent: 0)).needsUser)
        #expect(checklist(installer: .failed(.offline)).needsUser)
        #expect(checklist(microphone: .denied).needsUser)
        #expect(checklist(hotkeyActive: false).needsUser)
    }

    /// The menu always has the item that opens the welcome window. Getting Started waits
    /// for the loaded model, because only then does the window show Orra is ready and Try
    /// next. Meeting Interpretation's sheet names Setup Guide when microphone access is
    /// missing, so that title must hold then.
    @Test func theMenuItemReadsGettingStartedOnceSetupIsComplete() {
        #expect(checklist().menuTitle() == "Getting Started…")
        #expect(checklist(modelState: .notLoaded).menuTitle() == "Setup Guide…")
        #expect(checklist(modelState: .loading).menuTitle() == "Setup Guide…")
        #expect(checklist(installer: .downloading(bytes: 10, source: nil)).menuTitle() == "Setup Guide…")
        #expect(checklist(modelState: .unavailable(.failedToLoad)).menuTitle() == "Setup Guide…")
        #expect(checklist(hotkeyActive: false).menuTitle() == "Setup Guide…")
        for access in [MicrophoneAccess.notDetermined, .denied, .notConfigured] {
            #expect(checklist(microphone: access).menuTitle() == "Setup Guide…")
        }
        let chinese = Locale(identifier: "zh-Hans")
        #expect(checklist().menuTitle(locale: chinese) == "入门指南…")
        #expect(checklist(hotkeyActive: false).menuTitle(locale: chinese) == "设置向导…")
    }
}
