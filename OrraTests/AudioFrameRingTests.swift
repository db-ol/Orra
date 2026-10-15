import AVFoundation
import Foundation
import Testing
@testable import Orra

/// The ring between the capture's real time IO block and the conversion queue.
struct AudioFrameRingTests {
    /// A ring of one Float per frame and plane.
    private func makeRing(planes: Int = 1, capacity: Int) -> AudioFrameRing {
        AudioFrameRing(planes: planes, bytesPerFrame: MemoryLayout<Float>.size, capacity: capacity)
    }

    @discardableResult
    private func write(_ ring: AudioFrameRing, planes: [[Float]]) -> Bool {
        let frames = planes[0].count
        let copies = planes.map { plane in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(plane.count, 1))
            pointer.initialize(from: plane, count: plane.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        return ring.write(frames: frames) { UnsafeRawPointer(copies[$0]) }
    }

    @discardableResult
    private func write(_ ring: AudioFrameRing, _ samples: [Float]) -> Bool {
        write(ring, planes: [samples])
    }

    private func readPlanes(_ ring: AudioFrameRing, max: Int = .max) -> [[Float]] {
        let room = min(max, ring.capacity)
        let targets = (0..<ring.planes).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: room) }
        defer { targets.forEach { $0.deallocate() } }
        let frames = ring.read(maxFrames: room) { UnsafeMutableRawPointer(targets[$0]) }
        return targets.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }

    private func read(_ ring: AudioFrameRing, max: Int = .max) -> [Float] {
        readPlanes(ring, max: max)[0]
    }

    @Test func framesComeOutInTheOrderTheyWentIn() {
        let ring = makeRing(capacity: 16)
        #expect(write(ring, [1, 2, 3]))
        #expect(write(ring, [4, 5]))
        #expect(ring.available == 5)
        #expect(read(ring) == [1, 2, 3, 4, 5])
        #expect(ring.available == 0)
        #expect(read(ring) == [])
    }

    @Test func aReadTakesAtMostWhatItAsksForAndLeavesTheRest() {
        let ring = makeRing(capacity: 16)
        write(ring, [1, 2, 3, 4, 5])
        #expect(read(ring, max: 2) == [1, 2])
        #expect(read(ring, max: 2) == [3, 4])
        #expect(read(ring) == [5])
    }

    @Test func writesAndReadsWrapAroundTheEnd() {
        let ring = makeRing(capacity: 8)
        #expect(write(ring, [1, 2, 3, 4, 5, 6]))
        #expect(read(ring, max: 5) == [1, 2, 3, 4, 5])
        // Starts at index 6 of 8, so it wraps after two frames.
        #expect(write(ring, [7, 8, 9, 10, 11]))
        #expect(ring.available == 6)
        // The read wraps too.
        #expect(read(ring) == [6, 7, 8, 9, 10, 11])
        // Many times around.
        var next: Float = 12
        for _ in 0..<50 {
            let block = (0..<5).map { next + Float($0) }
            next += 5
            #expect(write(ring, block))
            #expect(read(ring) == block)
        }
        #expect(ring.dropped == 0)
    }

    @Test func aWriteThatDoesNotFitIsDroppedAndCounted() {
        let ring = makeRing(capacity: 8)
        #expect(write(ring, [1, 2, 3, 4, 5, 6]))
        // Three more do not fit beside six: the newest are dropped, the oldest kept.
        #expect(!write(ring, [7, 8, 9]))
        #expect(ring.dropped == 3)
        #expect(write(ring, [10, 11]))
        #expect(!write(ring, [12]))
        #expect(ring.dropped == 4)
        #expect(read(ring) == [1, 2, 3, 4, 5, 6, 10, 11])
        // Room again once read.
        #expect(write(ring, [13, 14, 15]))
        #expect(read(ring) == [13, 14, 15])
        #expect(ring.dropped == 4)
    }

    @Test func aWriteLargerThanTheRingIsDropped() {
        let ring = makeRing(capacity: 4)
        #expect(!write(ring, [1, 2, 3, 4, 5]))
        #expect(ring.dropped == 5)
        #expect(ring.available == 0)
        #expect(write(ring, [6, 7, 8, 9]))
        #expect(read(ring) == [6, 7, 8, 9])
    }

    @Test func eachPlaneKeepsItsOwnFrames() {
        let ring = makeRing(planes: 2, capacity: 4)
        write(ring, planes: [[1, 2, 3], [-1, -2, -3]])
        #expect(readPlanes(ring, max: 2) == [[1, 2], [-1, -2]])
        write(ring, planes: [[4, 5], [-4, -5]])
        #expect(readPlanes(ring) == [[3, 4, 5], [-3, -4, -5]])
    }

    @Test func aMissingPlaneIsWrittenAsSilence() {
        let ring = makeRing(capacity: 4)
        let wrote = ring.write(frames: 3) { _ in nil }
        #expect(wrote)
        #expect(read(ring) == [0, 0, 0])
    }

    /// One thread writes a counting sequence in blocks while another reads it. Every value
    /// comes out once and in order, and the only gaps are whole dropped blocks.
    @Test func aWriterAndAReaderOnTwoThreadsKeepTheOrder() async {
        let ring = makeRing(capacity: 512)
        let blocks = 4_000
        let blockSize = 37
        let writer = Task.detached {
            let block = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
            defer { block.deallocate() }
            var next = 0
            for index in 0..<blocks {
                for offset in 0..<blockSize {
                    block[offset] = Float(next + offset)
                }
                next += blockSize
                ring.write(frames: blockSize) { _ in UnsafeRawPointer(block) }
                if index % 64 == 0 {
                    await Task.yield()
                }
            }
        }
        let reader = Task.detached { () -> [Float] in
            var all: [Float] = []
            let target = UnsafeMutablePointer<Float>.allocate(capacity: 100)
            defer { target.deallocate() }
            let total = blocks * blockSize
            while all.count + ring.dropped < total {
                let frames = ring.read(maxFrames: 100) { _ in UnsafeMutableRawPointer(target) }
                all.append(contentsOf: UnsafeBufferPointer(start: target, count: frames))
                if frames == 0 {
                    await Task.yield()
                }
            }
            return all
        }
        await writer.value
        let all = await reader.value
        #expect(all.count + ring.dropped == blocks * blockSize)
        var previous: Float = -1
        var inOrder = true
        var gapsAreWholeBlocks = true
        for value in all {
            if value <= previous {
                inOrder = false
            }
            if value != previous + 1 {
                // A gap starts at a block's first value.
                if Int(value) % blockSize != 0 {
                    gapsAreWholeBlocks = false
                }
            }
            previous = value
        }
        #expect(inOrder)
        #expect(gapsAreWholeBlocks)
        #expect(ring.dropped % blockSize == 0)
    }
}

/// The capture's path without Core Audio: tap buffers as the IO block gets them, through
/// the ring, converted to 16 kHz mono and cut into chunks.
struct TapConversionTests {
    private final class Chunks: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [[Float]] = []

        func append(_ chunk: [Float]) {
            lock.withLock { list.append(chunk) }
        }

        var all: [[Float]] {
            lock.withLock { list }
        }
    }

    /// Feeds `seconds` of 48 kHz stereo, the left channel a 440 Hz tone and the right one
    /// silent, in blocks of 512 frames. `micBuffers` buffers of a loud constant come first
    /// in each list, like the microphone of a headset in the aggregate device.
    private func convert(interleaved: Bool, micBuffers: Int = 0, seconds: Double = 1) throws -> (chunks: [[Float]], dropped: Int) {
        let rate = 48_000.0
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: interleaved))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(RecordingLimits.sampleRate), channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        converter.downmix = true
        let planes = interleaved ? 1 : 2
        let ring = AudioFrameRing(planes: planes, bytesPerFrame: Int(input.streamDescription.pointee.mBytesPerFrame), capacity: Int(rate * 2))
        let writer = TapWriter(ring: ring)
        let chunks = Chunks()
        let chunker = Chunker(writer: writer, converter: converter, input: input, output: output, deliver: { chunks.append($0) })

        let block = 512
        let mic = UnsafeMutablePointer<Float>.allocate(capacity: block)
        mic.initialize(repeating: 0.9, count: block)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        right.initialize(repeating: 0, count: block)
        let list = AudioBufferList.allocate(maximumBuffers: micBuffers + planes)
        defer {
            mic.deallocate()
            left.deallocate()
            right.deallocate()
            free(list.unsafeMutablePointer)
        }
        let byteSize = UInt32(block * MemoryLayout<Float>.size)
        for index in 0..<micBuffers {
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: mic)
        }
        if interleaved {
            list[micBuffers] = AudioBuffer(mNumberChannels: 2, mDataByteSize: byteSize * 2, mData: left)
        } else {
            list[micBuffers] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: left)
            list[micBuffers + 1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: right)
        }
        var frame = 0
        let blocks = Int(rate * seconds) / block
        for index in 0..<blocks {
            for offset in 0..<block {
                let tone = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame + offset) / rate))
                if interleaved {
                    left[offset * 2] = tone
                    left[offset * 2 + 1] = 0
                } else {
                    left[offset] = tone
                }
            }
            frame += block
            writer.write(UnsafePointer(list.unsafePointer))
            // The timer drains every few IO cycles.
            if index % 2 == 1 {
                chunker.drain()
            }
        }
        chunker.drain()
        return (chunks.all, ring.dropped)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    @Test(arguments: [false, true])
    func stereoBecomes16kHzMonoInChunksOf100ms(interleaved: Bool) throws {
        let (chunks, dropped) = try convert(interleaved: interleaved)
        #expect(dropped == 0)
        let samples = chunks.flatMap { $0 }
        // 1 s less what waits for the next chunk.
        #expect(samples.count > 16_000 - 1_600 - 200)
        #expect(samples.count <= 16_000)
        #expect(chunks.allSatisfy { $0.count >= 1_600 && $0.count < 3_200 })
        // The average of a 0.5 tone and silence: a 0.25 tone, RMS about 0.177.
        let level = rms(samples[2_000..<12_000])
        #expect(abs(level - 0.177) < 0.01)
    }

    @Test(arguments: [false, true])
    func buffersBeforeTheTapsAreNeverRead(interleaved: Bool) throws {
        let (chunks, _) = try convert(interleaved: interleaved, micBuffers: 2)
        let samples = chunks.flatMap { $0 }
        #expect(samples.count > 16_000 - 1_600 - 200)
        // Only the tone, nothing of the loud constant before it.
        let level = rms(samples[2_000..<12_000])
        #expect(abs(level - 0.177) < 0.01)
        let mean = samples[2_000..<12_000].reduce(0, +) / 10_000
        #expect(abs(mean) < 0.01)
    }
}
