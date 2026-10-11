import Foundation

/// Turns decoded audio into the two mono streams fed to the left and right
/// virtual speakers. Samples are copied bit-exactly: no gain, no mixing.
public enum ChannelSplitter {
    /// - Parameter channels: non-interleaved channel data, all the same length.
    /// - Returns: mono files go to both sides at unity gain (no pan law);
    ///   files with more than two channels use only the first two.
    public static func split(channels: [[Float]]) -> (left: [Float], right: [Float]) {
        switch channels.count {
        case 0: return ([], [])
        case 1: return (channels[0], channels[0])
        default:
            let n = min(channels[0].count, channels[1].count)
            return (Array(channels[0].prefix(n)), Array(channels[1].prefix(n)))
        }
    }

    /// Same, for interleaved data (frame-major: L R L R ...).
    public static func split(interleaved: [Float], channelCount: Int) -> (left: [Float], right: [Float]) {
        guard channelCount > 0 else { return ([], []) }
        let frames = interleaved.count / channelCount
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        let rOffset = channelCount > 1 ? 1 : 0
        for i in 0..<frames {
            left[i] = interleaved[i * channelCount]
            right[i] = interleaved[i * channelCount + rOffset]
        }
        return (left, right)
    }

    /// Splits a long stream into chunks of `chunkFrames` (last one shorter).
    public static func chunkRanges(totalFrames: Int, chunkFrames: Int) -> [Range<Int>] {
        guard totalFrames > 0, chunkFrames > 0 else { return [] }
        return stride(from: 0, to: totalFrames, by: chunkFrames).map {
            $0..<min($0 + chunkFrames, totalFrames)
        }
    }

    /// Frames per ~1 s chunk at the file's own sample rate.
    public static func chunkFrames(sampleRate: Double, seconds: Double = 1.0) -> Int {
        max(1, Int((sampleRate * seconds).rounded()))
    }
}
