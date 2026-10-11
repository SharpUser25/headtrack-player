import Foundation

/// One Euro filter (Casiez, Roussel, Vogel, CHI 2012) for a single scalar.
/// dt comes from sample timestamps, not from wall-clock arrival.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double
    /// A gap longer than this (seconds) resets the filter instead of
    /// smoothing across it.
    public var resetGap: Double

    private var lastTime: Double?
    private var lastValue: Double = 0
    private var lastDerivative: Double = 0

    public init(minCutoff: Double = 1.0, beta: Double = 0.02,
                derivativeCutoff: Double = 1.0, resetGap: Double = 0.5) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
        self.resetGap = resetGap
    }

    public var value: Double? { lastTime == nil ? nil : lastValue }

    public mutating func reset() {
        lastTime = nil
        lastValue = 0
        lastDerivative = 0
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    @discardableResult
    public mutating func filter(_ x: Double, timestamp t: Double) -> Double {
        guard let t0 = lastTime else {
            lastTime = t
            lastValue = x
            lastDerivative = 0
            return x
        }
        let dt = t - t0
        if dt <= 0 {
            // Duplicate or out-of-order timestamp: keep the current estimate.
            return lastValue
        }
        if dt > resetGap {
            lastTime = t
            lastValue = x
            lastDerivative = 0
            return x
        }
        let dx = (x - lastValue) / dt
        let aD = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        let edx = lastDerivative + aD * (dx - lastDerivative)
        let cutoff = minCutoff + beta * abs(edx)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let y = lastValue + a * (x - lastValue)
        lastTime = t
        lastValue = y
        lastDerivative = edx
        return y
    }

    /// Maps a 0...1 "smoothing" slider to a minimum cutoff in Hz,
    /// log-spaced from 8 Hz (0, almost raw) down to 0.2 Hz (1, very smooth).
    public static func minCutoff(forSmoothing s: Double) -> Double {
        let x = AngleMath.clamp(s, 0, 1)
        let hi = log(8.0), lo = log(0.2)
        return exp(hi + (lo - hi) * x)
    }
}

/// One Euro filters for all three axes.
public struct PoseFilter: Sendable {
    public private(set) var yaw = OneEuroFilter()
    public private(set) var pitch = OneEuroFilter()
    public private(set) var roll = OneEuroFilter()

    public init(smoothing: Double = 0.5) { setSmoothing(smoothing) }

    public mutating func setSmoothing(_ s: Double) {
        let c = OneEuroFilter.minCutoff(forSmoothing: s)
        yaw.minCutoff = c
        pitch.minCutoff = c
        roll.minCutoff = c
    }

    public mutating func reset() {
        yaw.reset(); pitch.reset(); roll.reset()
    }

    public mutating func filter(_ p: HeadPose, timestamp t: Double) -> HeadPose {
        HeadPose(yaw: yaw.filter(p.yaw, timestamp: t),
                 pitch: pitch.filter(p.pitch, timestamp: t),
                 roll: roll.filter(p.roll, timestamp: t))
    }
}
