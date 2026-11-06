import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Audio and video files the tests of Transcribe File make for themselves, in a temporary
/// folder each test removes: made up sound, speech from a system voice, and movies with or
/// without sound.
enum TestMedia {
    /// A new empty folder in the temporary folder.
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orra-transcribe-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Silence of `seconds` with a tone in each of `bursts`, start and end in seconds, loud
    /// enough to count as speech.
    static func bursts(_ bursts: [(start: Double, end: Double)], seconds: Double, rate: Double, level: Float = 0.1) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        for burst in bursts {
            let first = Int(burst.start * rate)
            let last = min(Int(burst.end * rate), samples.count)
            for index in first..<last {
                // Two tones, so a frame never lands on a quiet part of one.
                let time = Float(index) / Float(rate)
                samples[index] = level * (0.6 * sin(2 * .pi * 220 * time) + 0.4 * sin(2 * .pi * 330 * time))
            }
        }
        return samples
    }

    /// Writes mono samples to an audio file whose type follows the extension of `url`:
    /// AAC for .m4a, 16 bit PCM for .wav, .aif and .caf. With `channels` of 2, the
    /// samples go to the left channel only and the right one stays silent.
    static func writeAudio(_ samples: [Float], rate: Double, channels: Int = 1, to url: URL) throws {
        let settings: [String: Any] = switch url.pathExtension {
        case "m4a":
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        default:
            [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: url.pathExtension == "aif"]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 8_192
        var start = 0
        while start < samples.count {
            let count = min(chunk, samples.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels {
                let data = buffer.floatChannelData![channel]
                for index in 0..<count {
                    data[index] = channel == 0 ? samples[start + index] : 0
                }
            }
            try file.write(from: buffer)
            start += count
        }
    }

    /// A movie this Mac could not write, such as a virtual machine without a video encoder.
    struct MovieNotWritten: Error {
        var underlying: (any Error)?
    }

    /// Whether this Mac is a virtual machine, such as the runner of CI. A run of CI stopped
    /// making progress, every test at once, while the tests that write H.264 movies ran, and
    /// a video encoder that holds its threads in a virtual machine is the likely cause, so
    /// those tests leave the movies out there.
    static var isVirtualMachine: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Writes an MPEG-4 or QuickTime movie, by the extension of `url`, with a small H.264
    /// picture at 2 frames a second when `video`, and an AAC track of `samples` when they
    /// are given, `seconds` long. Throws MovieNotWritten when the writer fails, so a test
    /// can tell a Mac that cannot write video from a problem of the code it tests.
    static func writeMovie(_ samples: [Float]?, rate: Double, seconds: Double, video: Bool, to url: URL) async throws {
        do {
            try await writeMovieOrThrow(samples, rate: rate, seconds: seconds, video: video, to: url)
        } catch {
            throw MovieNotWritten(underlying: error)
        }
    }

    private static func writeMovieOrThrow(_ samples: [Float]?, rate: Double, seconds: Double, video: Bool, to url: URL) async throws {
        let type: AVFileType = url.pathExtension == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        var picture: (input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor)?
        if video {
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ])
            writer.add(input)
            picture = (input, adaptor)
        }
        var sound: AVAssetWriterInput?
        if samples != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            sound = input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        // Waits until `input` takes more, and throws when the writer failed or does not take
        // it for 30 s, such as on a Mac without the encoder, rather than wait for good.
        func ready(_ input: AVAssetWriterInput) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    writer.cancelWriting()
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        // Half a second of each track at a time, so the writer can interleave them.
        let step = 0.5
        var time = 0.0
        var written = 0
        while time < seconds {
            if let picture {
                try await ready(picture.input)
                guard picture.adaptor.append(try pixelBuffer(), withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
            }
            if let sound, let samples {
                let end = min(Int((time + step) * rate), samples.count)
                if end > written {
                    try await ready(sound)
                    guard sound.append(try sampleBuffer(samples[written..<end], rate: rate, at: written)) else {
                        throw writer.error ?? CocoaError(.fileWriteUnknown)
                    }
                    written = end
                }
            }
            time += step
        }
        picture?.input.markAsFinished()
        sound?.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status != .completed {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    private static func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0x60, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func sampleBuffer(_ samples: ArraySlice<Float>, rate: Double, at frame: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let bytes = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let format, let block else { throw CocoaError(.fileWriteUnknown) }
        _ = samples.withUnsafeBytes { pointer in
            CMBlockBufferReplaceDataBytes(with: pointer.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate)),
            packetDescriptions: nil,
            sampleBufferOut: &buffer
        )
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        return buffer
    }

    // MARK: Speech

    /// A system voice of `language`, such as en-US or zh-CN, nil when this Mac has none.
    static func voice(_ language: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().first { $0.language == language && $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// `text` spoken by `voice`, as mono samples and their rate. Nothing plays: the
    /// synthesizer writes into buffers.
    static func speak(_ text: String, voice: AVSpeechSynthesisVoice) async throws -> (samples: [Float], rate: Double) {
        let collector = SpeechCollector()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        return try await withCheckedThrowingContinuation { continuation in
            collector.start(utterance, continuation)
        }
    }

    /// Gathers the buffers the synthesizer writes, which it calls from a queue of its own,
    /// and keeps the synthesizer until the last one. A lock guards the state.
    private final class SpeechCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var synthesizer: AVSpeechSynthesizer?
        private var samples: [Float] = []
        private var rate = 0.0
        private var continuation: CheckedContinuation<(samples: [Float], rate: Double), any Error>?

        func start(_ utterance: AVSpeechUtterance, _ continuation: CheckedContinuation<(samples: [Float], rate: Double), any Error>) {
            let synthesizer = AVSpeechSynthesizer()
            lock.withLock {
                self.synthesizer = synthesizer
                self.continuation = continuation
            }
            synthesizer.write(utterance) { [self] buffer in
                guard let buffer = buffer as? AVAudioPCMBuffer else { return }
                guard buffer.frameLength > 0 else {
                    finish()
                    return
                }
                let samples = Self.samples(of: buffer)
                lock.withLock {
                    self.samples += samples
                    rate = buffer.format.sampleRate
                }
            }
        }

        private func finish() {
            let (continuation, samples, rate) = lock.withLock {
                defer {
                    self.continuation = nil
                    synthesizer = nil
                }
                return (self.continuation, self.samples, self.rate)
            }
            guard let continuation else { return }
            if samples.isEmpty {
                continuation.resume(throwing: CocoaError(.fileReadUnknown))
            } else {
                continuation.resume(returning: (samples, rate))
            }
        }

        /// The first channel of a buffer of floats or of 16 bit integers.
        private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
            let frames = Int(buffer.frameLength)
            if let data = buffer.floatChannelData {
                return Array(UnsafeBufferPointer(start: data[0], count: frames))
            }
            if let data = buffer.int16ChannelData {
                return UnsafeBufferPointer(start: data[0], count: frames).map { Float($0) / 32_768 }
            }
            if let data = buffer.int32ChannelData {
                return UnsafeBufferPointer(start: data[0], count: frames).map { Float($0) / 2_147_483_648 }
            }
            return []
        }
    }
}
