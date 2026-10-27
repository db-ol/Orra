import Foundation
import os

/// The files of a reply, as the email view asks the runtime for them: the files a request
/// of an explanation may mean, a file the user ticks or adds, the check of a ticked file
/// right before it goes to Mail, the projects for the lines about people outside a file's
/// project, and the folder Add File… starts in. Nothing runs while Projects is off, and
/// the log holds counts, times and error kinds only.
extension ProjectsRuntime {
    /// The files a request of an explanation may mean, best first, see RequestedFiles, in the
    /// folders of the projects of `scope`, or of every project when nil. It first waits while
    /// a dictation is under way, looking again every 100 ms as the folder index does, so the
    /// search never holds up a dictation. Empty while Projects is off, and when the search
    /// fails.
    func requestedFiles(for request: FileRequest, emailProject: UUID?, scope: [UUID]?) async -> [RequestedFile] {
        guard running != nil else { return [] }
        while dependencies.isDictating() {
            try? await Task.sleep(for: Self.dictationCheck)
            guard !Task.isCancelled else { return [] }
        }
        guard projects.isOn, !projects.isDeleting, let running else { return [] }
        let started = ContinuousClock.now
        do {
            let files = try await RequestedFiles.find(
                request, emailProject: emailProject, scope: scope,
                names: FileNameSearch(database: running.database), chunks: running.search)
            let own = files.filter { $0.project == emailProject }.count
            Logger.projects.notice("Requested files: \(files.count, privacy: .public) files, \(own, privacy: .public) of the email's project, for a request of \(request.documentKinds.count, privacy: .public) kinds in \(Self.milliseconds(started.duration(to: .now)), privacy: .public) ms")
            return files
        } catch {
            Logger.projects.notice("Requested files: the search ended by \(String(reflecting: type(of: error)), privacy: .public) after \(Self.milliseconds(started.duration(to: .now)), privacy: .public) ms")
            return []
        }
    }

    /// The file at a URL the user ticked, chose with Add File… or dropped, when it may go
    /// into a reply: a regular file on this Mac, not a folder or a package, in a folder a
    /// project holds now, and one the index holds, so a file Projects never read in such a
    /// folder is refused too. `first` is the email's project, which comes first among the
    /// file's projects. It reads the file's metadata only.
    func replyFile(at url: URL, first: UUID?) async -> Result<ReplyFile, ReplyFileProblem> {
        guard projects.isOn, !projects.isDeleting, running != nil else { return .failure(.notInAddedFolder) }
        let result = await ReplyFiles.file(at: url, roots: { [weak self] in await self?.replyRoots() ?? [:] }, first: first)
        guard case .success(let file) = result else { return result }
        guard let running else { return .failure(.notInAddedFolder) }
        let rows = (try? await FileNameSearch(database: running.database).files(atPath: file.url.path)) ?? []
        return rows.isEmpty ? .failure(.notInAddedFolder) : .success(file)
    }

    /// A ticked file checked again right before its attach event, see ReplyFiles.recheck,
    /// with the folders the projects hold at that moment. Refused while Projects is off.
    func recheck(_ file: ReplyFile) async -> Result<ReplyFile, ReplyFileProblem> {
        guard projects.isOn, !projects.isDeleting, running != nil else { return .failure(.notInAddedFolder) }
        return await ReplyFiles.recheck(file, roots: { [weak self] in await self?.replyRoots() ?? [:] })
    }

    /// The real paths of the folders of every project, by project, as
    /// `folderRoots(of:)` reads them now. A project whose folders cannot be read now holds
    /// none, so its files are refused.
    func replyRoots() async -> [UUID: [URL]] {
        var roots: [UUID: [URL]] = [:]
        for project in projectList {
            if let found = await folderRoots(of: project.id) {
                roots[project.id] = found.folders
            }
        }
        return roots
    }

    /// The projects as an explanation knows them, for the people a reply reaches outside a
    /// file's project.
    func replyProjects() -> [ExplainService.Project] {
        projectList.map(\.forExplanation)
    }

    /// The first folder of a project that is there now, where Add File… starts, nil for no
    /// project or none.
    func defaultFolder(of project: UUID?) async -> URL? {
        guard let project else { return nil }
        return await folderRoots(of: project)?.folders.first
    }

    /// How often the search for requested files looks whether a dictation ended.
    nonisolated static let dictationCheck: Duration = .milliseconds(100)

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }
}
