import Foundation

/// Everything persisted between launches. Decoding tolerates missing keys
/// so adding a setting never wipes the others.
public struct PlayerSettings: Equatable, Codable, Sendable {
    public static let speakerAngleRange: ClosedRange<Double> = 10...60
    public static let trimRange: ClosedRange<Double> = -12...12
    public static let speakerDistance: Double = 2.0

    public var speakerAngle: Double = 30
    public var smoothing: Double = 0.5
    public var volume: Double = 0.8
    public var spatialEnabled: Bool = true
    public var trackingEnabled: Bool = true
    /// dB, positive = plain stereo louder relative to spatial.
    public var abTrim: Double = 0
    public var axes = AxisConfig()

    public init() {}

    public var tracking: TrackingConfig { TrackingConfig(axes: axes, smoothing: smoothing) }

    public func clamped() -> PlayerSettings {
        var s = self
        s.speakerAngle = AngleMath.clamp(s.speakerAngle.isFinite ? s.speakerAngle : 30,
                                         Self.speakerAngleRange.lowerBound, Self.speakerAngleRange.upperBound)
        s.smoothing = AngleMath.clamp(s.smoothing.isFinite ? s.smoothing : 0.5, 0, 1)
        s.volume = AngleMath.clamp(s.volume.isFinite ? s.volume : 0.8, 0, 1)
        s.abTrim = AngleMath.clamp(s.abTrim.isFinite ? s.abTrim : 0,
                                   Self.trimRange.lowerBound, Self.trimRange.upperBound)
        return s
    }

    enum CodingKeys: String, CodingKey {
        case speakerAngle, smoothing, volume, spatialEnabled, trackingEnabled, abTrim, axes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlayerSettings()
        speakerAngle = try c.decodeIfPresent(Double.self, forKey: .speakerAngle) ?? d.speakerAngle
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
        spatialEnabled = try c.decodeIfPresent(Bool.self, forKey: .spatialEnabled) ?? d.spatialEnabled
        trackingEnabled = try c.decodeIfPresent(Bool.self, forKey: .trackingEnabled) ?? d.trackingEnabled
        abTrim = try c.decodeIfPresent(Double.self, forKey: .abTrim) ?? d.abTrim
        axes = try c.decodeIfPresent(AxisConfig.self, forKey: .axes) ?? d.axes
        self = clamped()
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data?) -> PlayerSettings {
        guard let data, let s = try? JSONDecoder().decode(PlayerSettings.self, from: data) else {
            return PlayerSettings()
        }
        return s
    }
}

/// Picks the largest face. Areas are width*height of normalized boxes.
public enum FaceSelection {
    public static func indexOfLargest(areas: [Double]) -> Int? {
        areas.indices.max { areas[$0] < areas[$1] }
    }
}
