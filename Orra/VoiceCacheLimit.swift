import Foundation
import MLX
import Synchronization

/// Lowers a limit the whole process shares, such as MLX's buffer cache limit, while one or
/// more pieces are spoken, and gives back the value from before the first of them once the
/// last one ends. Pieces can overlap for a moment after a stop, because a streamed piece
/// always runs to its end while the next one starts. If each piece put back the value it
/// found, the second would find the lowered value and leave it in place for good.
nonisolated struct SharedLimitCap {
    let cap: Int
    private var saved: Int?
    private var holders = 0

    init(cap: Int) {
        self.cap = cap
    }

    /// Call as a piece starts, with the limit in effect now. Returns the limit to set.
    mutating func begin(current: Int) -> Int {
        if holders == 0 {
            saved = current
        }
        holders += 1
        return min(saved ?? current, cap)
    }

    /// Call as a piece ends. Returns the limit to put back once no piece holds the cap,
    /// nil while another piece still does.
    mutating func end() -> Int? {
        guard holders > 0 else { return nil }
        holders -= 1
        guard holders == 0 else { return nil }
        defer { saved = nil }
        return saved
    }
}

/// MLX's buffer cache limit while a voice model speaks. The cache is one for the whole
/// process, and the speech model sets its limit when it loads (4 GB at most). The voice
/// lowers it only while it speaks and puts it back after, so the speech and cleanup models
/// keep their own limit. A piece waits while the user dictates, so they rarely run during
/// one. When one does, it only has fewer cached buffers to reuse for that moment.
///
/// One for the process, like the limit, so a piece of one voice model that is still running
/// after a stop or a change of model shares the cap with the next piece, see SharedLimitCap.
nonisolated enum VoiceCacheLimit {
    /// The most of MLX's buffer cache the voice may leave behind while it speaks. Without
    /// a cap the scratch benchmark's process grew to 11 to 27 GB, and with 1 GB it stayed
    /// at 4.6 to 6.4 GB.
    static let cap = 1 << 30

    private static let state = Mutex(SharedLimitCap(cap: cap))

    /// Call as a piece starts.
    static func begin() {
        state.withLock { holder in
            Memory.cacheLimit = holder.begin(current: Memory.cacheLimit)
        }
    }

    /// Call as a piece ends.
    static func end() {
        state.withLock { holder in
            if let limit = holder.end() {
                Memory.cacheLimit = limit
            }
        }
    }
}
