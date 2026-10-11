import XCTest
@testable import HeadTrackCore

final class FaceLostEaserTests: XCTestCase {
    func testNeverSeenIsZero() {
        XCTAssertEqual(FaceLostEaser().weight(at: 5), 0)
    }

    func testRampsInOnFirstSighting() {
        var e = FaceLostEaser(holdTime: 1, easeTime: 0.5)
        e.faceSeen(at: 0)
        XCTAssertEqual(e.weight(at: 0), 0)
        XCTAssertEqual(e.weight(at: 0.25), 0.5, accuracy: 1e-12)
        XCTAssertEqual(e.weight(at: 0.5), 1)
    }

    func testHoldsThenEasesToCenter() {
        var e = FaceLostEaser(holdTime: 1, easeTime: 0.5)
        for i in 0...30 { e.faceSeen(at: Double(i) / 30) } // seen until t=1
        XCTAssertEqual(e.weight(at: 1.9), 1)     // within 1 s hold
        XCTAssertEqual(e.weight(at: 2.0), 1)
        XCTAssertEqual(e.weight(at: 2.25), 0.5, accuracy: 1e-12)
        XCTAssertEqual(e.weight(at: 2.5), 0)
        XCTAssertTrue(e.isFaceLost(at: 2.1))
        XCTAssertFalse(e.isFaceLost(at: 1.9))
    }

    func testWeightIsContinuousAndMonotonicDuringEase() {
        var e = FaceLostEaser(holdTime: 1, easeTime: 0.5)
        for i in 0...30 { e.faceSeen(at: Double(i) / 30) }
        var prev = e.weight(at: 2.0)
        var t = 2.0
        while t < 2.6 {
            t += 0.01
            let w = e.weight(at: t)
            XCTAssertLessThanOrEqual(w, prev + 1e-12)
            XCTAssertLessThan(prev - w, 0.05)
            prev = w
        }
    }

    func testReacquireMidEaseHasNoJump() {
        var e = FaceLostEaser(holdTime: 1, easeTime: 0.5)
        for i in 0...30 { e.faceSeen(at: Double(i) / 30) }
        let before = e.weight(at: 2.25)
        e.faceSeen(at: 2.25)
        XCTAssertEqual(e.weight(at: 2.25), before, accuracy: 1e-12)
        XCTAssertEqual(e.weight(at: 3.0), 1)
    }
}

final class PoseInterpolatorTests: XCTestCase {
    func testLinearRamp() {
        var p = PoseInterpolator()
        p.setTarget(HeadPose(yaw: 30), at: 0, duration: 0.03)
        XCTAssertEqual(p.value(at: 0).yaw, 0)
        XCTAssertEqual(p.value(at: 0.015).yaw, 15, accuracy: 1e-9)
        XCTAssertEqual(p.value(at: 0.03).yaw, 30, accuracy: 1e-9)
        XCTAssertEqual(p.value(at: 1).yaw, 30, accuracy: 1e-9)
    }

    func testRetargetStartsFromCurrentValue() {
        var p = PoseInterpolator()
        p.setTarget(HeadPose(yaw: 30), at: 0, duration: 0.1)
        p.setTarget(HeadPose(yaw: 0), at: 0.05, duration: 0.1)
        XCTAssertEqual(p.value(at: 0.05).yaw, 15, accuracy: 1e-9)
        XCTAssertEqual(p.value(at: 0.10).yaw, 7.5, accuracy: 1e-9)
    }

    func testShortestPathAcrossWrap() {
        var p = PoseInterpolator()
        p.setTarget(HeadPose(yaw: 170), at: 0, duration: 0)
        p.setTarget(HeadPose(yaw: -170), at: 0, duration: 1)
        let mid = p.value(at: 0.5).yaw
        XCTAssertEqual(AngleMath.wrapDegrees(mid), -180, accuracy: 1e-9)
    }

    func test100HzTicksBetween30HzFrames() {
        var p = PoseInterpolator()
        let frame = 1.0 / 30
        var outputs: [Double] = []
        for f in 0..<3 {
            p.setTarget(HeadPose(yaw: Double(f + 1) * 10), at: Double(f) * frame, duration: frame)
        }
        // Reset and sample at 100 Hz over a single ramp.
        p = PoseInterpolator()
        p.setTarget(HeadPose(yaw: 10), at: 0, duration: frame)
        for i in 0...4 { outputs.append(p.value(at: Double(i) / 100).yaw) }
        XCTAssertEqual(outputs, outputs.sorted())
        XCTAssertEqual(outputs.last!, 10, accuracy: 1e-9)
        XCTAssertGreaterThan(outputs[1], 0)
        XCTAssertLessThan(outputs[1], 10)
    }

    func testIntervalEstimator() {
        var e = IntervalEstimator(initial: 0.1, smoothing: 0.5)
        for i in 0..<50 { e.tick(Double(i) / 30) }
        XCTAssertEqual(e.interval, 1.0 / 30, accuracy: 1e-6)
    }
}
