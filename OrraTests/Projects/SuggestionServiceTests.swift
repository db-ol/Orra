import Foundation
import Testing
@testable import Orra

/// Suggested Projects with fake lookups and a fake model: what is asked, when, and what the
/// window shows. The people, companies and mail are made up for these tests.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SuggestionServiceTests {
    static let me = "me@studio.example"
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func mail(_ id: String, from: String, subject: String, day: Double) -> ProjectSuggestions.Mail {
        ProjectSuggestions.Mail(
            messageID: id, date: start.addingTimeInterval(day * 86_400),
            sender: ProjectSuggestions.Person(address: from),
            recipients: [ProjectSuggestions.Person(address: me)],
            subject: subject, threadRoot: id)
    }

    /// Three clients: harbor with four mails, kiln with three, quay with three.
    static let mail: [ProjectSuggestions.Mail] = (0..<4).map { mail("h\($0)", from: "mei@harbor.example", subject: "Lobby \($0)", day: Double($0)) }
        + (0..<3).map { mail("k\($0)", from: "kai@kiln.example", subject: "Tiles \($0)", day: Double($0)) }
        + (0..<3).map { mail("q\($0)", from: "ola@quay.example", subject: "Newsletter \($0)", day: Double($0)) }

    /// The model's answers, by the domain the prompt names, and what was asked.
    final class Model {
        var answers: [String: Result<String, any Error>] = [:]
        var asked: [ProjectsModelRequest] = []
        var isOpen = true

        func ask(_ request: ProjectsModelRequest) throws -> String {
            asked.append(request)
            guard let domain = answers.keys.first(where: { request.prompt.contains("Domains: " + $0) }) else {
                throw RewriteError.notLoaded
            }
            return try answers[domain]!.get()
        }
    }

    static func service(_ model: Model, mail: [ProjectSuggestions.Mail] = mail, dismissed: Set<String> = []) -> SuggestionService {
        SuggestionService(
            lookups: SuggestionService.Lookups(
                mail: { mail },
                projects: { [] },
                owner: { SortingService.Owner(addresses: [me], name: "Lin") },
                dismissed: { dismissed }
            ),
            ask: { try model.ask($0) },
            windowIsOpen: { model.isOpen })
    }

    @Test func groupsShowOnceTheModelNamedThem() async {
        let model = Model()
        model.answers = [
            "harbor.example": .success(#"Harbor lobby", "description": "Renovation of the harbor office lobby."}"#),
            "kiln.example": .success(#"Kiln tiles", "description": ""}"#),
            "quay.example": .success(#"none", "description": ""}"#),
        ]
        let service = Self.service(model)
        await service.refresh()
        await service.untilNamed()
        #expect(service.suggestions.map(\.name) == ["Harbor lobby", "Kiln tiles"])
        #expect(service.suggestions.map(\.isNamed) == [true, true])
        #expect(service.suggestions.first?.description == "Renovation of the harbor office lobby.")
        #expect(service.suggestions.first?.group.takes.count == 4)
        #expect(!service.isNaming)
        // One background request for each group, the largest first, with the answer's limit.
        #expect(model.asked.count == 3)
        #expect(model.asked.allSatisfy { $0.priority == .background && $0.maximumTokens == SuggestionPrompt.maximumTokens })
        #expect(model.asked.first?.prompt.contains("Domains: harbor.example") == true)

        // A refresh keeps the names and asks nothing again.
        await service.refresh()
        await service.untilNamed()
        #expect(model.asked.count == 3)
        #expect(service.suggestions.map(\.name) == ["Harbor lobby", "Kiln tiles"])
    }

    @Test func withoutTheModelGroupsShowTheirNamesInCode() async {
        let model = Model()
        let service = Self.service(model)
        await service.refresh()
        await service.untilNamed()
        #expect(service.suggestions.map(\.name) == ["harbor.example", "kiln.example", "quay.example"])
        #expect(service.suggestions.allSatisfy { !$0.isNamed && $0.description.isEmpty })
        // It stops at the first missing model.
        #expect(model.asked.count == 1)

        // The model arrived: the next refresh names them.
        model.answers = ["harbor.example": .success(#"Harbor lobby"}"#), "kiln.example": .success("not JSON"), "quay.example": .failure(RewriteError.promptTooLong)]
        await service.refresh()
        await service.untilNamed()
        #expect(service.suggestions.map(\.name) == ["Harbor lobby", "kiln.example", "quay.example"])
        #expect(service.suggestions.map(\.isNamed) == [true, false, false])
    }

    @Test func nothingIsAskedWhileTheWindowIsClosed() async {
        let model = Model()
        model.isOpen = false
        model.answers = ["harbor.example": .success(#"Harbor lobby"}"#)]
        let service = Self.service(model)
        await service.refresh()
        await service.untilNamed()
        #expect(model.asked.isEmpty)
        #expect(service.suggestions.isEmpty)

        // The window closed while a request ran, which ends background work.
        model.isOpen = true
        model.answers = ["harbor.example": .failure(CancellationError())]
        await service.refresh()
        await service.untilNamed()
        #expect(model.asked.count == 1)
        #expect(service.suggestions.isEmpty)
    }

    @Test func aDismissedSuggestionGoesAndIsNotAskedAbout() async {
        let model = Model()
        model.answers = [
            "harbor.example": .success(#"Harbor lobby"}"#),
            "kiln.example": .success(#"Kiln tiles"}"#),
            "quay.example": .success(#"Quay"}"#),
        ]
        let dismissed: Set<String> = [ProjectSuggestions.dismissalKey(.domain("quay.example"))]
        let service = Self.service(model, dismissed: dismissed)
        await service.refresh()
        await service.untilNamed()
        #expect(service.suggestions.map(\.name) == ["Harbor lobby", "Kiln tiles"])
        #expect(!model.asked.contains { $0.prompt.contains("quay.example") })

        service.dismiss("domain:kiln.example")
        #expect(service.suggestions.map(\.name) == ["Harbor lobby"])
        await service.refresh()
        #expect(service.suggestions.map(\.name) == ["Harbor lobby"])
    }

    /// Refreshes that come while one reads the mail make one more run after it, not one
    /// each.
    @Test func refreshesDuringARunGroupOnceMore() async {
        final class Reads {
            var count = 0
            var service: SuggestionService?
        }
        let model = Model()
        let reads = Reads()
        let service = SuggestionService(
            lookups: SuggestionService.Lookups(
                mail: {
                    reads.count += 1
                    if reads.count == 1 {
                        for _ in 0..<2 {
                            Task { await reads.service?.refresh() }
                        }
                        for _ in 0..<5 {
                            await Task.yield()
                        }
                    }
                    return Self.mail
                },
                projects: { [] },
                owner: { SortingService.Owner(addresses: [Self.me]) },
                dismissed: { [] }
            ),
            ask: { try model.ask($0) },
            windowIsOpen: { true })
        reads.service = service
        await service.refresh()
        #expect(reads.count == 2)
        await service.untilNamed()
    }
}
