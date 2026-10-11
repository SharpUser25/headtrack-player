import Foundation

public enum AngleMath {
    public static func degrees(fromRadians r: Double) -> Double { r * 180 / .pi }
    public static func radians(fromDegrees d: Double) -> Double { d * .pi / 180 }

    /// Wraps an angle into [-180, 180).
    public static func wrapDegrees(_ a: Double) -> Double {
        guard a.isFinite else { return 0 }
        var r = (a + 180).truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        return r - 180
    }

    /// Shortest signed difference `to - from`, in [-180, 180).
    public static func shortestDelta(from: Double, to: Double) -> Double {
        wrapDegrees(to - from)
    }

    public static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
        min(max(v, lo), hi)
    }

    /// Hermite smoothstep on [0, 1].
    public static func smoothstep(_ t: Double) -> Double {
        let x = clamp(t, 0, 1)
        return x * x * (3 - 2 * x)
    }

    /// Position of a speaker in AVAudio3D listener space: listener at the
    /// origin facing -Z, +X to the right, +Y up. `azimuthDegrees` is
    /// clockwise from straight ahead (negative = left).
    public static func speakerPosition(azimuthDegrees: Double, distance: Double)
        -> (x: Double, y: Double, z: Double)
    {
        let a = radians(fromDegrees: azimuthDegrees)
        return (x: distance * sin(a), y: 0, z: -distance * cos(a))
    }
}

public enum Gain {
    public static func linear(fromDecibels db: Double) -> Double { pow(10, db / 20) }
    public static func decibels(fromLinear g: Double) -> Double {
        g > 0 ? 20 * log10(g) : -.infinity
    }

    /// Level-match trim for the A/B switch. Positive trim makes the plain
    /// stereo path louder relative to the spatial path. Implemented by
    /// attenuating the other path so no gain stage ever exceeds 1.0.
    public static func abTrimGains(trimDecibels: Double) -> (stereo: Double, spatial: Double) {
        if trimDecibels >= 0 {
            return (1, linear(fromDecibels: -trimDecibels))
        } else {
            return (linear(fromDecibels: trimDecibels), 1)
        }
    }
}
