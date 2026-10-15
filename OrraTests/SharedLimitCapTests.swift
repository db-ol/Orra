import Testing
@testable import Orra

/// The voice lowers MLX's cache limit while it speaks and puts the old one back after.
struct SharedLimitCapTests {
    static let gigabyte = 1 << 30

    @Test func oneSpokenPieceGivesBackTheLimitItFound() {
        var cap = SharedLimitCap(cap: Self.gigabyte)
        #expect(cap.begin(current: 4 * Self.gigabyte) == Self.gigabyte)
        #expect(cap.end() == 4 * Self.gigabyte)
    }

    @Test func aLimitBelowTheCapStays() {
        var cap = SharedLimitCap(cap: Self.gigabyte)
        #expect(cap.begin(current: 512) == 512)
        #expect(cap.end() == 512)
    }

    /// After a stop the old piece still streams while the next one starts. The next one
    /// finds the lowered limit, and still the limit from before both comes back, once the
    /// last of them ends, whichever ends first.
    @Test func overlappingPiecesGiveBackTheLimitFromBeforeTheFirst() {
        var cap = SharedLimitCap(cap: Self.gigabyte)
        let first = cap.begin(current: 4 * Self.gigabyte)
        #expect(cap.begin(current: first) == Self.gigabyte)
        #expect(cap.end() == nil)
        #expect(cap.end() == 4 * Self.gigabyte)

        // And the next piece starts afresh from what is in effect then.
        #expect(cap.begin(current: 3 * Self.gigabyte) == Self.gigabyte)
        #expect(cap.end() == 3 * Self.gigabyte)
    }

    @Test func anEndWithoutABeginChangesNothing() {
        var cap = SharedLimitCap(cap: Self.gigabyte)
        #expect(cap.end() == nil)
        #expect(cap.begin(current: 2 * Self.gigabyte) == Self.gigabyte)
        #expect(cap.end() == 2 * Self.gigabyte)
    }
}
