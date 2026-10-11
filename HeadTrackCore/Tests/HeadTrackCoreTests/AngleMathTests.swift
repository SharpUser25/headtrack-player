import XCTest
@testable import HeadTrackCore

final class AngleMathTests: XCTestCase {
    func testWrap() {
        XCTAssertEqual(AngleMath.wrapDegrees(0), 0)
        XCTAssertEqual(AngleMath.wrapDegrees(190), -170, accuracy: 1e-12)
        XCTAssertEqual(AngleMath.wrapDegrees(-190), 170, accuracy: 1e-12)
        XCTAssertEqual(AngleMath.wrapDegrees(180), -180, accuracy: 1e-12)
        XCTAssertEqual(AngleMath.wrapDegrees(720 + 45), 45, accuracy: 1e-12)
        XCTAssertEqual(AngleMath.wrapDegrees(.nan), 0)
    }

    func testShortestDelta() {
        XCTAssertEqual(AngleMath.shortestDelta(from: 170, to: -170), 20, accuracy: 1e-12)
        XCTAssertEqual(AngleMath.shortestDelta(from: -170, to: 170), -20, accuracy: 1e-12)
        XCTAssertEqual(AngleMath.shortestDelta(from: 10, to: 30), 20, accuracy: 1e-12)
    }

    func testRadians() {
        XCTAssertEqual(AngleMath.degrees(fromRadians: .pi / 2), 90, accuracy: 1e-12)
        XCTAssertEqual(AngleMath.radians(fromDegrees: 180), .pi, accuracy: 1e-12)
    }

    func testSpeakerPositions() {
        let r = AngleMath.speakerPosition(azimuthDegrees: 30, distance: 2)
        XCTAssertEqual(r.x, 1, accuracy: 1e-12)
        XCTAssertEqual(r.z, -sqrt(3), accuracy: 1e-12)
        let l = AngleMath.speakerPosition(azimuthDegrees: -30, distance: 2)
        XCTAssertEqual(l.x, -1, accuracy: 1e-12)
        XCTAssertEqual((l.x * l.x + l.y * l.y + l.z * l.z).squareRoot(), 2, accuracy: 1e-12)
        let front = AngleMath.speakerPosition(azimuthDegrees: 0, distance: 2)
        XCTAssertEqual(front.x, 0, accuracy: 1e-12)
        XCTAssertEqual(front.z, -2, accuracy: 1e-12)
    }

    func testSmoothstep() {
        XCTAssertEqual(AngleMath.smoothstep(-1), 0)
        XCTAssertEqual(AngleMath.smoothstep(0.5), 0.5)
        XCTAssertEqual(AngleMath.smoothstep(2), 1)
    }

    func testGain() {
        XCTAssertEqual(Gain.linear(fromDecibels: 0), 1)
        XCTAssertEqual(Gain.linear(fromDecibels: -6), 0.501187, accuracy: 1e-6)
        XCTAssertEqual(Gain.decibels(fromLinear: 1), 0)
        let zero = Gain.abTrimGains(trimDecibels: 0)
        XCTAssertEqual(zero.stereo, 1); XCTAssertEqual(zero.spatial, 1)
        let up = Gain.abTrimGains(trimDecibels: 6)
        XCTAssertEqual(up.stereo, 1)
        XCTAssertEqual(up.spatial, Gain.linear(fromDecibels: -6), accuracy: 1e-12)
        let down = Gain.abTrimGains(trimDecibels: -3)
        XCTAssertEqual(down.stereo, Gain.linear(fromDecibels: -3), accuracy: 1e-12)
        XCTAssertEqual(down.spatial, 1)
    }

    func testAxisConfig() {
        let p = HeadPose(yaw: 10, pitch: 20, roll: 30)
        XCTAssertEqual(AxisConfig().apply(to: p), HeadPose(yaw: 10, pitch: 0, roll: 0))
        let all = AxisConfig(yawEnabled: true, pitchEnabled: true, rollEnabled: true,
                             invertYaw: true, invertPitch: false, invertRoll: true)
        XCTAssertEqual(all.apply(to: p), HeadPose(yaw: -10, pitch: 20, roll: -30))
    }

    func testLargestFace() {
        XCTAssertNil(FaceSelection.indexOfLargest(areas: []))
        XCTAssertEqual(FaceSelection.indexOfLargest(areas: [0.1, 0.4, 0.2]), 1)
    }
}
