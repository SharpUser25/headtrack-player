import XCTest
@testable import HeadTrackCore

final class OneEuroFilterTests: XCTestCase {
    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.filter(12.5, timestamp: 1.0), 12.5)
    }

    func testConstantInputStaysConstant() {
        var f = OneEuroFilter()
        for i in 0..<100 {
            XCTAssertEqual(f.filter(7, timestamp: Double(i) / 30), 7, accuracy: 1e-12)
        }
    }

    func testConvergesToStep() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0)
        f.filter(0, timestamp: 0)
        var y = 0.0
        for i in 1...300 { y = f.filter(10, timestamp: Double(i) / 30) }
        XCTAssertEqual(y, 10, accuracy: 1e-6)
    }

    func testStepResponseMatchesAlpha() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0)
        f.filter(0, timestamp: 0)
        let dt = 1.0 / 30
        let y = f.filter(10, timestamp: dt)
        let tau = 1 / (2 * Double.pi)
        XCTAssertEqual(y, 10 / (1 + tau / dt), accuracy: 1e-12)
    }

    func testUsesTimestampsForDt() {
        // A longer gap between samples lets more of the step through.
        var a = OneEuroFilter(minCutoff: 1, beta: 0)
        var b = OneEuroFilter(minCutoff: 1, beta: 0)
        a.filter(0, timestamp: 0); b.filter(0, timestamp: 0)
        let ya = a.filter(10, timestamp: 0.01)
        let yb = b.filter(10, timestamp: 0.1)
        XCTAssertLessThan(ya, yb)
    }

    func testBetaReducesLagWhenMoving() {
        var slow = OneEuroFilter(minCutoff: 0.5, beta: 0)
        var fast = OneEuroFilter(minCutoff: 0.5, beta: 0.5)
        var ys = 0.0, yf = 0.0
        for i in 0..<30 {
            let t = Double(i) / 30
            ys = slow.filter(t * 90, timestamp: t)
            yf = fast.filter(t * 90, timestamp: t)
        }
        let truth = 29.0 / 30 * 90
        XCTAssertLessThan(abs(truth - yf), abs(truth - ys))
    }

    func testNonIncreasingTimestampIgnored() {
        var f = OneEuroFilter()
        f.filter(0, timestamp: 1)
        XCTAssertEqual(f.filter(50, timestamp: 1), 0)
        XCTAssertEqual(f.filter(50, timestamp: 0.5), 0)
    }

    func testLongGapResets() {
        var f = OneEuroFilter(resetGap: 0.5)
        f.filter(0, timestamp: 0)
        XCTAssertEqual(f.filter(40, timestamp: 2), 40)
    }

    func testSmoothingMapping() {
        XCTAssertEqual(OneEuroFilter.minCutoff(forSmoothing: 0), 8, accuracy: 1e-9)
        XCTAssertEqual(OneEuroFilter.minCutoff(forSmoothing: 1), 0.2, accuracy: 1e-9)
        XCTAssertGreaterThan(OneEuroFilter.minCutoff(forSmoothing: 0.3),
                             OneEuroFilter.minCutoff(forSmoothing: 0.7))
        XCTAssertEqual(OneEuroFilter.minCutoff(forSmoothing: -5), 8, accuracy: 1e-9)
    }
}
