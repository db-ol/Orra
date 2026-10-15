import Foundation
import Synchronization

/// A ring of audio frames between one writer on Core Audio's real time thread and one
/// reader on another queue. The memory is set aside and touched up front, so writing only
/// copies: no allocation, no lock, no logging.
///
/// Frames are stored in planes, one per buffer of the stream (one for interleaved audio,
/// one per channel otherwise), each `bytesPerFrame` wide, so any PCM layout passes
/// through unchanged.
///
/// The writer and the reader each own one count and publish it with an atomic store, so
/// each side sees only frames the other has finished with. When a write does not fit,
/// the whole write is dropped and counted: the writer never moves the reader's count, so
/// the oldest frames are the ones kept.
nonisolated final class AudioFrameRing: @unchecked Sendable {
    let planes: Int
    let bytesPerFrame: Int
    /// Frames each plane holds.
    let capacity: Int
    private let storage: UnsafeMutableRawPointer
    /// Frames written and read since the start. They only grow, and an Int does not run
    /// out in the life of a process.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)

    init(planes: Int, bytesPerFrame: Int, capacity: Int) {
        self.planes = max(planes, 1)
        self.bytesPerFrame = max(bytesPerFrame, 1)
        self.capacity = max(capacity, 1)
        let bytes = self.planes * self.capacity * self.bytesPerFrame
        storage = .allocate(byteCount: bytes, alignment: 16)
        // Touching every page now keeps page faults off the real time thread.
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    }

    deinit {
        storage.deallocate()
    }

    /// Frames dropped since the start because the reader fell behind.
    var dropped: Int {
        droppedFrames.load(ordering: .relaxed)
    }

    /// Frames waiting to be read. Exact on the reader's side.
    var available: Int {
        written.load(ordering: .acquiring) - read.load(ordering: .relaxed)
    }

    private func plane(_ index: Int) -> UnsafeMutableRawPointer {
        storage + index * capacity * bytesPerFrame
    }

    /// Writer side. Copies `frames` frames, `source(plane)` giving each plane's start, or
    /// nil for silence. Returns false, and counts the frames as dropped, when they do not
    /// fit.
    @discardableResult
    func write(frames: Int, from source: (Int) -> UnsafeRawPointer?) -> Bool {
        guard frames > 0 else { return true }
        let writeCount = written.load(ordering: .relaxed)
        let free = capacity - (writeCount - read.load(ordering: .acquiring))
        guard frames <= free else {
            droppedFrames.wrappingAdd(frames, ordering: .relaxed)
            return false
        }
        let start = writeCount % capacity
        let first = min(frames, capacity - start)
        let rest = frames - first
        for index in 0..<planes {
            let target = plane(index)
            if let from = source(index) {
                (target + start * bytesPerFrame).copyMemory(from: from, byteCount: first * bytesPerFrame)
                if rest > 0 {
                    target.copyMemory(from: from + first * bytesPerFrame, byteCount: rest * bytesPerFrame)
                }
            } else {
                (target + start * bytesPerFrame).initializeMemory(as: UInt8.self, repeating: 0, count: first * bytesPerFrame)
                if rest > 0 {
                    target.initializeMemory(as: UInt8.self, repeating: 0, count: rest * bytesPerFrame)
                }
            }
        }
        written.store(writeCount + frames, ordering: .releasing)
        return true
    }

    /// Reader side. Copies up to `maxFrames` of the oldest frames, `destination(plane)`
    /// giving where each plane goes, and returns how many it copied.
    func read(maxFrames: Int, into destination: (Int) -> UnsafeMutableRawPointer) -> Int {
        let readCount = read.load(ordering: .relaxed)
        let frames = min(maxFrames, written.load(ordering: .acquiring) - readCount)
        guard frames > 0 else { return 0 }
        let start = readCount % capacity
        let first = min(frames, capacity - start)
        let rest = frames - first
        for index in 0..<planes {
            let source = plane(index)
            let target = destination(index)
            target.copyMemory(from: source + start * bytesPerFrame, byteCount: first * bytesPerFrame)
            if rest > 0 {
                (target + first * bytesPerFrame).copyMemory(from: source, byteCount: rest * bytesPerFrame)
            }
        }
        read.store(readCount + frames, ordering: .releasing)
        return frames
    }
}
