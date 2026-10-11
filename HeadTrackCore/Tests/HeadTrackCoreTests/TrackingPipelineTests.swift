import XCTest
@testable import HeadTrackCore

final class TrackingPipelineTests: XCTestCase {
    private func feed(_ p: TrackingPipeline, yaw: Double, pitch: Double = 0, roll: Double = 0,
                      from t0: Double, seconds: Double) -> Double {
        var t = t0
        while t < t0 + seconds {
            p.ingest(HeadPoseSample(timestamp: t, pose: HeadPose(yaw: yaw, pitch: pitch, roll: roll)), now: t)
            t += 1.0 / 30
        }
        return t
    }

    func testSteadyHeadReachesTarget() {
        let p = TrackingPipeline()
        let t = feed(p, yaw: 20, from: 0, seconds: 2)
        XCTAssertEqual(p.output(at: t).yaw, 20, accuracy: 1e-6)
        XCTAssertEqual(p.output(at: t).pitch, 0) // pitch disabled by default
    }

    func testRecenter() {
        let p = TrackingPipeline()
        var t = feed(p, yaw: 25, pitch: 5, from: 0, seconds: 2)
        p.recenter(now: t)
        t = feed(p, yaw: 25, pitch: 5, from: t, seconds: 0.5)
        XCTAssertEqual(p.output(at: t).yaw, 0, accuracy: 1e-6)
        t = feed(p, yaw: 35, from: t, seconds: 3)
        XCTAssertEqual(p.output(at: t).yaw, 10, accuracy: 1e-3)
        XCTAssertEqual(p.recenterOffset.yaw, 25, accuracy: 1e-6)
    }

    func testRecenterWithoutFaceIsNoop() {
        let p = TrackingPipeline()
        p.recenter(now: 0)
        XCTAssertEqual(p.recenterOffset, .zero)
    }

    func testAxisEnableAndInvert() {
        var c = TrackingConfig()
        c.axes = AxisConfig(yawEnabled: true, pitchEnabled: true, rollEnabled: false,
                            invertYaw: true, invertPitch: false, invertRoll: false)
        let p = TrackingPipeline(config: c)
        let t = feed(p, yaw: 20, pitch: 10, roll: 5, from: 0, seconds: 2)
        let o = p.output(at: t)
        XCTAssertEqual(o.yaw, -20, accuracy: 1e-6)
        XCTAssertEqual(o.pitch, 10, accuracy: 1e-6)
        XCTAssertEqual(o.roll, 0)
    }

    func testFaceLostEasesToCenterThenReturns() {
        let p = TrackingPipeline()
        var t = feed(p, yaw: 30, from: 0, seconds: 2)
        let lastSeen = t - 1.0 / 30
        // No face for 2 s: tracker still sends frames with pose == nil.
        while t < lastSeen + 2 {
            p.ingest(HeadPoseSample(timestamp: t, pose: nil), now: t)
            t += 1.0 / 30
        }
        XCTAssertEqual(p.output(at: lastSeen + 0.9).yaw, 30, accuracy: 1e-6)
        XCTAssertEqual(p.output(at: lastSeen + 1.25).yaw, 15, accuracy: 1e-6)
        XCTAssertEqual(p.output(at: lastSeen + 1.6).yaw, 0, accuracy: 1e-9)
        // Face comes back: starts from center, no jump.
        p.ingest(HeadPoseSample(timestamp: t, pose: HeadPose(yaw: 30)), now: t)
        XCTAssertEqual(p.output(at: t).yaw, 0, accuracy: 1e-9)
        t = feed(p, yaw: 30, from: t + 1.0 / 30, seconds: 1)
        XCTAssertEqual(p.output(at: t).yaw, 30, accuracy: 1e-6)
    }

    func testOutputIsSmoothAt100Hz() {
        let p = TrackingPipeline(config: TrackingConfig(smoothing: 0))
        _ = feed(p, yaw: 0, from: 0, seconds: 1)
        // Head turns at 90 deg/s, frames at 30 Hz, audio ticks at 100 Hz.
        var maxStep = 0.0
        var prev = p.output(at: 1).yaw
        var nextFrame = 1.0
        var tick = 1.0
        while tick < 2 {
            while nextFrame <= tick {
                p.ingest(HeadPoseSample(timestamp: nextFrame, pose: HeadPose(yaw: (nextFrame - 1) * 90)),
                         now: nextFrame)
                nextFrame += 1.0 / 30
            }
            let y = p.output(at: tick).yaw
            maxStep = max(maxStep, abs(y - prev))
            prev = y
            tick += 0.01
        }
        // A raw 30 Hz staircase would step 3 deg; interpolation keeps ticks near 0.9 deg.
        XCTAssertLessThan(maxStep, 1.6)
    }

    func testSmoothingChangesFilter() {
        let smooth = TrackingPipeline(config: TrackingConfig(smoothing: 1))
        let raw = TrackingPipeline(config: TrackingConfig(smoothing: 0))
        for p in [smooth, raw] {
            _ = feed(p, yaw: 0, from: 0, seconds: 1)
            p.ingest(HeadPoseSample(timestamp: 1.0, pose: HeadPose(yaw: 30)), now: 1.0)
        }
        XCTAssertLessThan(smooth.lastFiltered!.yaw, raw.lastFiltered!.yaw)
    }
}
