import Foundation

/// Head orientation in degrees. Axis meaning follows whatever produced it;
/// signs are corrected per axis via `AxisConfig.inverted`.
public struct HeadPose: Equatable, Codable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    public static let zero = HeadPose()

    public static func * (lhs: HeadPose, rhs: Double) -> HeadPose {
        HeadPose(yaw: lhs.yaw * rhs, pitch: lhs.pitch * rhs, roll: lhs.roll * rhs)
    }
}

/// One measurement from a head tracker.
public struct HeadPoseSample: Sendable {
    /// Capture timestamp of the camera frame, in seconds (used for filter dt).
    public var timestamp: Double
    /// Detected pose in degrees, or nil if no face was found in this frame.
    public var pose: HeadPose?

    public init(timestamp: Double, pose: HeadPose?) {
        self.timestamp = timestamp
        self.pose = pose
    }
}

/// Which axes are applied and with which sign.
public struct AxisConfig: Equatable, Codable, Sendable {
    public var yawEnabled: Bool
    public var pitchEnabled: Bool
    public var rollEnabled: Bool
    public var invertYaw: Bool
    public var invertPitch: Bool
    public var invertRoll: Bool

    public init(yawEnabled: Bool = true, pitchEnabled: Bool = false, rollEnabled: Bool = false,
                invertYaw: Bool = false, invertPitch: Bool = false, invertRoll: Bool = false) {
        self.yawEnabled = yawEnabled
        self.pitchEnabled = pitchEnabled
        self.rollEnabled = rollEnabled
        self.invertYaw = invertYaw
        self.invertPitch = invertPitch
        self.invertRoll = invertRoll
    }

    /// Zeroes disabled axes and flips inverted ones.
    public func apply(to pose: HeadPose) -> HeadPose {
        HeadPose(
            yaw: yawEnabled ? (invertYaw ? -pose.yaw : pose.yaw) : 0,
            pitch: pitchEnabled ? (invertPitch ? -pose.pitch : pose.pitch) : 0,
            roll: rollEnabled ? (invertRoll ? -pose.roll : pose.roll) : 0
        )
    }
}
