import Foundation

public struct TrackingConfig: Equatable, Codable, Sendable {
    public var axes: AxisConfig
    /// 0 = minimal smoothing, 1 = heavy smoothing.
    public var smoothing: Double

    public init(axes: AxisConfig = AxisConfig(), smoothing: Double = 0.5) {
        self.axes = axes
        self.smoothing = smoothing
    }
}

/// Raw tracker samples in, listener orientation out.
///
///   raw pose -> One Euro (frame timestamps) -> minus recenter offset
///   -> axis enable/invert -> interpolator target
///   output(t) = interpolator(t) * face-lost weight(t)
///
/// Not thread-safe; callers serialize access.
public final class TrackingPipeline {
    public private(set) var config: TrackingConfig
    public private(set) var recenterOffset = HeadPose.zero
    public private(set) var lastRaw: HeadPose?
    public private(set) var lastFiltered: HeadPose?

    private var filter: PoseFilter
    private var interpolator = PoseInterpolator()
    private var easer = FaceLostEaser()
    private var frameInterval = IntervalEstimator()

    /// Bounds for the interpolation ramp, seconds.
    public var minRamp = 0.010
    public var maxRamp = 0.100

    public init(config: TrackingConfig = TrackingConfig()) {
        self.config = config
        filter = PoseFilter(smoothing: config.smoothing)
    }

    public func setConfig(_ c: TrackingConfig) {
        if c.smoothing != config.smoothing { filter.setSmoothing(c.smoothing) }
        config = c
        if let f = lastFiltered {
            // Axis toggles take effect on the current target without waiting
            // for the next frame.
            let target = config.axes.apply(to: centered(f))
            let now = interpolator.target
            if target != now {
                interpolator.setTarget(target, at: lastIngestTime, duration: 0)
            }
        }
    }

    private var lastIngestTime: Double = 0

    private func centered(_ p: HeadPose) -> HeadPose {
        HeadPose(yaw: AngleMath.wrapDegrees(p.yaw - recenterOffset.yaw),
                 pitch: AngleMath.wrapDegrees(p.pitch - recenterOffset.pitch),
                 roll: AngleMath.wrapDegrees(p.roll - recenterOffset.roll))
    }

    /// - Parameters:
    ///   - sample: tracker output; `sample.timestamp` drives the filter.
    ///   - now: monotonic time of arrival, same clock as `output(at:)`.
    public func ingest(_ sample: HeadPoseSample, now: Double) {
        lastIngestTime = now
        guard let raw = sample.pose else { return }
        if easer.isFaceLost(at: now) {
            // Don't smooth across a dropout.
            filter.reset()
        }
        frameInterval.tick(now)
        lastRaw = raw
        let f = filter.filter(raw, timestamp: sample.timestamp)
        lastFiltered = f
        easer.faceSeen(at: now)
        let target = config.axes.apply(to: centered(f))
        let ramp = AngleMath.clamp(frameInterval.interval, minRamp, maxRamp)
        interpolator.setTarget(target, at: now, duration: ramp)
    }

    /// Makes the current head direction the new "straight ahead".
    public func recenter(now: Double) {
        guard let f = lastFiltered else { return }
        recenterOffset = f
        interpolator.setTarget(config.axes.apply(to: centered(f)), at: now,
                               duration: AngleMath.clamp(frameInterval.interval, minRamp, maxRamp))
    }

    public func output(at t: Double) -> HeadPose {
        interpolator.value(at: t) * easer.weight(at: t)
    }

    public func isFaceLost(at t: Double) -> Bool { easer.isFaceLost(at: t) }

    public func reset() {
        filter.reset()
        interpolator.reset()
        easer.reset()
        lastRaw = nil
        lastFiltered = nil
    }
}
