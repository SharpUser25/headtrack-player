import XCTest
@testable import HeadTrackCore

final class ChannelSplitterTests: XCTestCase {
    func testStereoIsBitExact() {
        let l: [Float] = [0.1, -0.5, 1.0, -1.0, .leastNonzeroMagnitude]
        let r: [Float] = [0.9, 0.0, -0.25, 0.75, -.leastNonzeroMagnitude]
        let s = ChannelSplitter.split(channels: [l, r])
        XCTAssertEqual(s.left, l)
        XCTAssertEqual(s.right, r)
    }

    func testMonoGoesToBothAtUnity() {
        let m: [Float] = [0.3, -0.7, 1.0]
        let s = ChannelSplitter.split(channels: [m])
        XCTAssertEqual(s.left, m)
        XCTAssertEqual(s.right, m)
    }

    func testMultichannelUsesFirstTwo() {
        let s = ChannelSplitter.split(channels: [[1, 2], [3, 4], [5, 6]])
        XCTAssertEqual(s.left, [1, 2])
        XCTAssertEqual(s.right, [3, 4])
    }

    func testEmpty() {
        let s = ChannelSplitter.split(channels: [])
        XCTAssertTrue(s.left.isEmpty && s.right.isEmpty)
    }

    func testInterleaved() {
        let s = ChannelSplitter.split(interleaved: [1, 2, 3, 4, 5, 6], channelCount: 2)
        XCTAssertEqual(s.left, [1, 3, 5])
        XCTAssertEqual(s.right, [2, 4, 6])
        let m = ChannelSplitter.split(interleaved: [1, 2, 3], channelCount: 1)
        XCTAssertEqual(m.left, [1, 2, 3])
        XCTAssertEqual(m.right, [1, 2, 3])
        let six = ChannelSplitter.split(interleaved: Array(0..<12).map(Float.init), channelCount: 6)
        XCTAssertEqual(six.left, [0, 6])
        XCTAssertEqual(six.right, [1, 7])
    }

    func testChunking() {
        XCTAssertEqual(ChannelSplitter.chunkFrames(sampleRate: 96_000), 96_000)
        XCTAssertEqual(ChannelSplitter.chunkFrames(sampleRate: 44_100), 44_100)
        let r = ChannelSplitter.chunkRanges(totalFrames: 100_000, chunkFrames: 44_100)
        XCTAssertEqual(r, [0..<44_100, 44_100..<88_200, 88_200..<100_000])
        // Chunks rejoin into the original stream with no gaps or overlaps.
        let signal = (0..<1000).map { Float($0) }
        let rejoined = ChannelSplitter.chunkRanges(totalFrames: 1000, chunkFrames: 300)
            .flatMap { signal[$0] }
        XCTAssertEqual(rejoined, signal)
    }
}

final class SettingsAndMeterTests: XCTestCase {
    func testDefaults() {
        let s = PlayerSettings()
        XCTAssertEqual(s.speakerAngle, 30)
        XCTAssertTrue(s.axes.yawEnabled)
        XCTAssertFalse(s.axes.pitchEnabled)
        XCTAssertFalse(s.axes.rollEnabled)
    }

    func testRoundTripAndClamp() {
        var s = PlayerSettings()
        s.speakerAngle = 90
        s.abTrim = -40
        s.axes.invertYaw = true
        let back = PlayerSettings.decode(s.encoded())
        XCTAssertEqual(back.speakerAngle, 60)
        XCTAssertEqual(back.abTrim, -12)
        XCTAssertTrue(back.axes.invertYaw)
    }

    func testMissingKeysUseDefaults() {
        let s = PlayerSettings.decode(#"{"speakerAngle": 45}"#.data(using: .utf8))
        XCTAssertEqual(s.speakerAngle, 45)
        XCTAssertEqual(s.volume, PlayerSettings().volume)
        XCTAssertEqual(PlayerSettings.decode(nil), PlayerSettings())
        XCTAssertEqual(PlayerSettings.decode(Data("junk".utf8)), PlayerSettings())
    }

    func testRateMeter() {
        var m = RateMeter(window: 1)
        for i in 0..<60 { m.record(at: Double(i) / 30, duration: 0.004) }
        XCTAssertEqual(m.rate(now: 59.0 / 30), 30, accuracy: 1.01)
        XCTAssertEqual(m.meanDuration!, 0.004, accuracy: 1e-12)
        XCTAssertNil(RateMeter().meanDuration)
    }
}
