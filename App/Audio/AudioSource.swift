import AVFoundation

/// One block of audio as two mono buffers at the source's sample rate,
/// ready to schedule on the left and right player nodes.
struct StereoChunk {
    let left: AVAudioPCMBuffer
    let right: AVAudioPCMBuffer
    /// Frame position of the first sample within the source.
    let startFrame: AVAudioFramePosition
    var frameLength: AVAudioFrameCount { left.frameLength }
}

/// Something that delivers left and right mono streams to the
/// environment node. Only `FileAudioSource` exists today; a live-input
/// source can implement the same protocol (blocking in `readChunk` until
/// data arrives, and reporting `isSeekable == false`).
protocol AudioSource: AnyObject {
    /// Sample rate of the delivered mono streams. The graph is connected at
    /// exactly this rate; nothing is forced to 44.1 or 48 kHz.
    var sampleRate: Double { get }
    var displayName: String { get }
    /// Total length in frames, or nil for an unbounded live stream.
    var lengthFrames: AVAudioFramePosition? { get }
    var isSeekable: Bool { get }
    /// Next block of up to `maxFrames` frames, or nil at end of stream.
    func readChunk(maxFrames: AVAudioFrameCount) throws -> StereoChunk?
    func seek(toFrame frame: AVAudioFramePosition) throws
}

extension AudioSource {
    var monoFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }
    var stereoFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }
}
