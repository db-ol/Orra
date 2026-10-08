import Foundation
import Testing
@testable import Orra

/// The steps of the welcome window, and when launch shows it.
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
        #expect(checklist(modelState: .unavailable("The speech model could not be loaded")).model == .todo)
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
        #expect(!checklist(modelState: .unavailable("The speech model is not on this Mac")).isComplete)
    }

    /// Decides whether launch opens the welcome window and the menu offers Setup Guide.
    @Test func aModelThatIsStillLoadingNeedsNothingFromTheUser() {
        #expect(!checklist().needsUser)
        #expect(!checklist(modelState: .notLoaded).needsUser)
        #expect(!checklist(modelState: .loading).needsUser)
        #expect(checklist(modelState: .unavailable("The speech model could not be loaded")).needsUser)
        #expect(checklist(installer: .checking).needsUser)
        #expect(checklist(installer: .downloading(bytes: 10, source: nil)).needsUser)
        #expect(checklist(installer: .missing(bytesPresent: 0)).needsUser)
        #expect(checklist(installer: .failed(.offline)).needsUser)
        #expect(checklist(microphone: .denied).needsUser)
        #expect(checklist(hotkeyActive: false).needsUser)
    }
}
