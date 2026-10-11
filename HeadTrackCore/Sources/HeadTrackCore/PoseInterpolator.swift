import Foundation

/// Bridges ~30 Hz tracker updates to a faster (100 Hz) audio update by
/// ramping linearly from the current output to each new target over
/// roughly one frame interval.
public struct PoseInterpolator: Sendable {
    private var from = HeadPose.zero
    private var to = HeadPose.zero
    private var start: Double = 0
    private var duration: Double = 0

    public init() {}

    public var target: HeadPose { to }

    public func value(at t: Double) -> HeadPose {
        guard duration > 0 else { return to }
        let u = AngleMath.clamp((t - start) / duration, 0, 1)
        return HeadPose(
            yaw: from.yaw + AngleMath.shortestDelta(from: from.yaw, to: to.yaw) * u,
            pitch: from.pitch + AngleMath.shortestDelta(from: from.pitch, to: to.pitch) * u,
            roll: from.roll + AngleMath.shortestDelta(from: from.roll, to: to.roll) * u
        )
    }

    public mutating func setTarget(_ p: HeadPose, at t: Double, duration d: Double) {
        let current = value(at: t)
        from = HeadPose(yaw: AngleMath.wrapDegrees(current.yaw),
                        pitch: AngleMath.wrapDegrees(current.pitch),
                        roll: AngleMath.wrapDegrees(current.roll))
        to = p
        start = t
        duration = max(0, d)
    }

    public mutating func reset(to p: HeadPose = .zero) {
        from = p
        to = p
        duration = 0
    }
}

/// Exponential moving average of the interval between events, for
/// estimating the tracker frame period.
public struct IntervalEstimator: Sendable {
    public var smoothing: Double
    public private(set) var interval: Double
    private var last: Double?

    public init(initial: Double = 1.0 / 30, smoothing: Double = 0.1) {
        interval = initial
        self.smoothing = smoothing
    }

    public mutating func tick(_ t: Double) {
        defer { last = t }
        guard let l = last else { return }
        let dt = t - l
        guard dt > 0, dt < 0.5 else { return }
        interval += smoothing * (dt - interval)
    }
}
