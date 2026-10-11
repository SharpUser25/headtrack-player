import Foundation

/// Counts events per second over a sliding window and averages a
/// per-event duration (e.g. Vision time per frame).
public struct RateMeter: Sendable {
    public var window: Double
    private var times: [Double] = []
    private var durations: [Double] = []

    public init(window: Double = 1.0) { self.window = window }

    public mutating func record(at t: Double, duration: Double? = nil) {
        times.append(t)
        durations.append(duration ?? .nan)
        prune(now: t)
    }

    public mutating func prune(now: Double) {
        while let first = times.first, now - first > window {
            times.removeFirst()
            durations.removeFirst()
        }
    }

    public func rate(now: Double) -> Double {
        let n = times.filter { now - $0 <= window }.count
        return Double(n) / window
    }

    /// Mean of the recorded durations within the window (NaN-free), or nil.
    public var meanDuration: Double? {
        let d = durations.filter { !$0.isNaN }
        guard !d.isEmpty else { return nil }
        return d.reduce(0, +) / Double(d.count)
    }
}
