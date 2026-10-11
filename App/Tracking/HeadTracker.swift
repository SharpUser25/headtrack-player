import Foundation
import HeadTrackCore

struct TrackerStats {
    /// Frames actually analysed per second (dropped frames excluded).
    var framesPerSecond: Double = 0
    /// Mean time spent in Vision per analysed frame, milliseconds.
    var processingMilliseconds: Double?
    /// Frames dropped because the previous one was still being analysed.
    var droppedFrames: Int = 0
}

/// Anything that can report head orientation. Swap in a different
/// implementation (AirPods motion, an IMU, a different face model) without
/// touching the audio side.
protocol HeadTracker: AnyObject {
    /// Called on the tracker's own queue for every analysed frame,
    /// including frames with no face (pose == nil).
    var onSample: ((HeadPoseSample) -> Void)? { get set }
    var onStats: ((TrackerStats) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start()
    func stop()
}
