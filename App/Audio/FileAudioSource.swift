import AVFoundation
import HeadTrackCore

enum AudioSourceError: LocalizedError {
    case bufferAllocationFailed
    case noChannels

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: return "Could not allocate an audio buffer."
        case .noChannels: return "The file has no audio channels."
        }
    }
}

/// Streams a local file (FLAC/WAV/MP3/M4A — anything AVAudioFile opens)
/// in ~1 s chunks. Decoding is to 32-bit float at the file's own rate.
final class FileAudioSource: AudioSource {
    let url: URL
    private let file: AVAudioFile
    private let readBuffer: AVAudioPCMBuffer
    private let mono: AVAudioFormat

    let sampleRate: Double
    let channelCount: AVAudioChannelCount

    var displayName: String { url.lastPathComponent }
    var lengthFrames: AVAudioFramePosition? { file.length }
    var isSeekable: Bool { true }
    /// Frames per chunk: one second at the file's rate.
    let chunkFrames: AVAudioFrameCount

    init(url: URL) throws {
        self.url = url
        // processingFormat is deinterleaved Float32 at the file's sample rate.
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        guard channelCount > 0 else { throw AudioSourceError.noChannels }
        chunkFrames = AVAudioFrameCount(ChannelSplitter.chunkFrames(sampleRate: sampleRate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioSourceError.bufferAllocationFailed
        }
        readBuffer = buf
        mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    func seek(toFrame frame: AVAudioFramePosition) throws {
        file.framePosition = max(0, min(frame, file.length))
    }

    func readChunk(maxFrames: AVAudioFrameCount) throws -> StereoChunk? {
        let start = file.framePosition
        guard start < file.length else { return nil }
        let want = min(maxFrames, chunkFrames, AVAudioFrameCount(file.length - start))
        readBuffer.frameLength = 0
        try file.read(into: readBuffer, frameCount: want)
        let n = Int(readBuffer.frameLength)
        guard n > 0, let data = readBuffer.floatChannelData else { return nil }

        var channels: [[Float]] = []
        for c in 0..<min(Int(channelCount), 2) {
            channels.append(Array(UnsafeBufferPointer(start: data[c], count: n)))
        }
        let split = ChannelSplitter.split(channels: channels)
        guard let l = Self.makeBuffer(split.left, format: mono),
              let r = Self.makeBuffer(split.right, format: mono) else {
            throw AudioSourceError.bufferAllocationFailed
        }
        return StereoChunk(left: l, right: r, startFrame: start)
    }

    static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            dst[0].update(from: src.baseAddress!, count: samples.count)
        }
        return b
    }

    /// Re-joins a chunk into one 2-channel buffer for the plain-stereo path.
    static func stereoBuffer(from chunk: StereoChunk, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = Int(chunk.frameLength)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk.frameLength),
              let dst = b.floatChannelData,
              let l = chunk.left.floatChannelData, let r = chunk.right.floatChannelData else { return nil }
        b.frameLength = chunk.frameLength
        dst[0].update(from: l[0], count: n)
        dst[1].update(from: r[0], count: n)
        return b
    }
}
