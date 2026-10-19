import SwiftUI

/// Projects, a page of Settings shown only in builds that show Projects: the switch with what
/// Projects reads, keeps and never does, the model it works with, and what it keeps on this
/// Mac with a way to delete it.
///
/// The page sits outside Orra/Projects, since it is the one place where Projects may link to
/// the privacy page and to System Settings. Code in Orra/Projects never opens a URL. The page
/// is compiled in every build, so Xcode keeps its strings in the catalog.
struct ProjectsSettings: View {
    let projects: ProjectsSwitch
    let cleanup: TextCleanup
    @State private var isConfirmingDelete = false
    @State private var isAskingKeepOrDelete = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { projects.isOn },
                    set: { $0 ? projects.turnOn() : turnOff() }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Projects")
                                PreviewLabel()
                            }
                            Group {
                                Text("Reads the mailboxes you choose in Mail and the folders you add. What it keeps stays on this Mac.")
                                Text("It never sends, moves or deletes mail, and never sends your mail or files anywhere.")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "briefcase")
                    }
                }
                .disabled(!projects.isOn && !projects.canTurnOn)
                if !projects.hasEnoughMemory {
                    Text("Projects needs \(CleanupDefault.gigabytes(CleanupDefault.minimumMemory)) GB of memory or more. This Mac has \(projects.memoryGigabytes) GB.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link("Privacy details", destination: Self.privacyPage(for: Bundle.main.preferredLocalizations.first))
            } header: {
                Text("Sorts your mail into projects and explains each email with the files of its project.")
                    .font(.subheadline)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent {
                    Text(verbatim: Self.modelStatus(cleanup.models.state))
                        .foregroundStyle(.secondary)
                } label: {
                    DescribedLabel(
                        title: "Cleanup model",
                        detail: "Projects works with the local model of Clean Up Text, on this Mac.",
                        systemImage: "wand.and.sparkles"
                    )
                }
            } header: {
                Text("Model")
            }
            Section {
                LabeledContent {
                    Text(verbatim: Self.stored(projects.storedBytes))
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Stored on this Mac", systemImage: "internaldrive")
                }
                if projects.deleteFailed {
                    Text("Some Projects data could not be deleted. Try again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Delete All Projects Data…", role: .destructive) {
                    isConfirmingDelete = true
                }
            } header: {
                Text("Data")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Projects")
        .task {
            await projects.measureStorage()
        }
        .alert("Delete all Projects data?", isPresented: $isConfirmingDelete) {
            Button("Delete All", role: .destructive) {
                Task { await projects.deleteAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your projects with their index, mail text and drafts from this Mac. Your mail in Mail and the files in your folders stay as they are.")
        }
        .alert("Turn off Projects?", isPresented: $isAskingKeepOrDelete) {
            Button("Keep Data") {
                Task { await projects.turnOff(keepingData: true) }
            }
            Button("Delete Data", role: .destructive) {
                Task { await projects.turnOff(keepingData: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep your projects with their index, mail text and drafts on this Mac for when you turn Projects on again, or delete them now. Your mail in Mail and the files in your folders stay as they are.")
        }
    }

    /// Turning the switch off asks whether to keep or delete what Projects keeps on this Mac,
    /// and only when it keeps something.
    private func turnOff() {
        Task {
            await projects.measureStorage()
            if projects.holdsData {
                isAskingKeepOrDelete = true
            } else {
                await projects.turnOff(keepingData: true)
            }
        }
    }

    /// Where the cleanup model stands, in the words of this page.
    static func modelStatus(_ state: ModelInstaller.State) -> String {
        switch state {
        case .installed: String(localized: "On this Mac")
        case .checking, .verifying: String(localized: "Checking…")
        case .downloading: String(localized: "Downloading…")
        case .missing, .failed: String(localized: "Not on this Mac yet")
        }
    }

    /// What Projects keeps, in the units Finder shows, or Nothing.
    static func stored(_ bytes: Int64?) -> String {
        guard let bytes else { return String(localized: "Checking…") }
        guard bytes > 0 else { return String(localized: "Nothing") }
        return ModelInstaller.State.size(bytes)
    }

    /// The privacy page in the language of Orra's interface, English for any other.
    static func privacyPage(for localization: String?) -> URL {
        let name = switch localization {
        case "zh-Hans": "privacy.zh-CN.md"
        case "ja": "privacy.ja.md"
        case "es-419": "privacy.es.md"
        default: "privacy.md"
        }
        return URL(string: "https://github.com/db-ol/Orra/blob/main/docs/\(name)")!
    }

    /// The word Preview in a thin capsule beside the name of Projects, since Projects may
    /// still change. The sidebar shows it under the name.
    private struct PreviewLabel: View {
        var body: some View {
            Text("Preview")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
        }
    }
}
