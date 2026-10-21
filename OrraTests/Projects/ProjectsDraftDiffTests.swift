import Foundation
import Testing
@testable import Orra

/// The highlight of a new version of a draft: what stayed, came new and went, by word in
/// Latin text and by character in Chinese.
struct ProjectsDraftDiffTests {
    typealias Segment = ProjectsDraftDiff.Segment

    @Test func aChangedWordIsMarkedAndTheRestStays() {
        let segments = ProjectsDraftDiff.segments(
            from: "The lamps arrive on Friday. Thanks!",
            to: "The lamps arrive on Monday. Thanks!")
        #expect(segments == [
            Segment(kind: .same, text: "The lamps arrive on "),
            Segment(kind: .removed, text: "Friday"),
            Segment(kind: .added, text: "Monday"),
            Segment(kind: .same, text: ". Thanks!"),
        ])
        #expect(ProjectsDraftDiff.hasChanges(segments))
    }

    @Test func chineseIsComparedByCharacter() {
        let segments = ProjectsDraftDiff.segments(from: "交期是11月15日。", to: "交期改到11月22日。")
        #expect(segments.filter { $0.kind == .removed }.map(\.text) == ["是", "15"])
        #expect(segments.filter { $0.kind == .added }.map(\.text) == ["改到", "22"])
        #expect(segments.filter { $0.kind != .removed }.map(\.text).joined() == "交期改到11月22日。")
        #expect(segments.filter { $0.kind != .added }.map(\.text).joined() == "交期是11月15日。")
    }

    @Test func addedAndRemovedLinesKeepTheirOrder() {
        let before = "Hi Mei,\n\nThe plan is attached.\n\nLin"
        let after = "Dear Mei,\n\nThe plan is attached. The lamps arrive on 22 November.\n\nKind regards,\nLin"
        let segments = ProjectsDraftDiff.segments(from: before, to: after)
        #expect(segments.filter { $0.kind != .removed }.map(\.text).joined() == after)
        #expect(segments.filter { $0.kind != .added }.map(\.text).joined() == before)
        #expect(segments.first == Segment(kind: .removed, text: "Hi"))
    }

    @Test func theSameTextHasNoChanges() {
        #expect(ProjectsDraftDiff.segments(from: "Thanks, Mei.", to: "Thanks, Mei.") == [Segment(kind: .same, text: "Thanks, Mei.")])
        #expect(!ProjectsDraftDiff.hasChanges(ProjectsDraftDiff.segments(from: "Same", to: "Same")))
        #expect(ProjectsDraftDiff.segments(from: "", to: "").isEmpty)
        #expect(ProjectsDraftDiff.segments(from: "", to: "New") == [Segment(kind: .added, text: "New")])
        #expect(ProjectsDraftDiff.segments(from: "Old", to: "") == [Segment(kind: .removed, text: "Old")])
    }

    /// A draft past the limit shows as one change instead of a slow comparison.
    @Test func aVeryLongDraftShowsAsOneChange() async {
        // Two tokens for each word and its space.
        let long = String(repeating: "word ", count: ProjectsDraftDiff.maximumTokens / 2 + 1)
        let segments = ProjectsDraftDiff.segments(from: long, to: long + "end")
        #expect(segments == [Segment(kind: .removed, text: long), Segment(kind: .added, text: long + "end")])
        // Within the limit it is compared.
        let shorter = String(repeating: "word ", count: ProjectsDraftDiff.maximumTokens / 2 - 1)
        #expect(await ProjectsDraftDiff.highlight(from: shorter, to: shorter + "end") == [Segment(kind: .same, text: shorter), Segment(kind: .added, text: "end")])
    }

    @Test func tokensSplitWordsSpacesAndCharacters() {
        #expect(ProjectsDraftDiff.tokens("Hi Mei, 好的。") == ["Hi", " ", "Mei", ",", " ", "好", "的", "。"])
        #expect(ProjectsDraftDiff.tokens("¥58,600") == ["¥", "58", ",", "600"])
    }
}
