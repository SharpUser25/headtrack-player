import Foundation

/// Produces a 0...1 weight that is multiplied into the recentered pose.
/// After `holdTime` seconds without a face it eases to 0 (center) over
/// `easeTime`; when the face comes back it eases up again from wherever it
/// was, so neither event causes a jump.
public struct FaceLostEaser: Sendable {
    public var holdTime: Double
    public var easeTime: Double

    private var lastSeen: Double?
    private var rampStart: Double = 0
    private var rampFrom: Double = 0

    public init(holdTime: Double = 1.0, easeTime: Double = 0.5) {
        self.holdTime = holdTime
        self.easeTime = easeTime
    }

    public mutating func faceSeen(at t: Double) {
        if let last = lastSeen, t - last <= holdTime {
            lastSeen = t
            return
        }
        // First sighting, or reacquired after the face was lost.
        rampFrom = weight(at: t)
        rampStart = t
        lastSeen = t
    }

    public mutating func reset() {
        lastSeen = nil
        rampStart = 0
        rampFrom = 0
    }

    public func isFaceLost(at t: Double) -> Bool {
        guard let last = lastSeen else { return true }
        return t - last > holdTime
    }

    private func rampIn(at t: Double) -> Double {
        let duration = easeTime * (1 - rampFrom)
        guard duration > 0 else { return 1 }
        return rampFrom + (1 - rampFrom) * AngleMath.smoothstep((t - rampStart) / duration)
    }

    public func weight(at t: Double) -> Double {
        guard let last = lastSeen else { return 0 }
        let lostAt = last + holdTime
        if t <= lostAt { return rampIn(at: t) }
        let w0 = rampIn(at: lostAt)
        guard easeTime > 0 else { return 0 }
        return w0 * (1 - AngleMath.smoothstep((t - lostAt) / easeTime))
    }
}
