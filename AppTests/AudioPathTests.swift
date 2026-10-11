import AVFoundation
import HeadTrackCore
import Vision
import XCTest

/// These run on the macOS CI runner against the real Apple frameworks.
/// The engine runs in offline manual-rendering mode, so no audio device
/// is needed.
final class AudioPathTests: XCTestCase {
    private let rate = 96_000.0

    private func writeFloatWav(left: [Float], right: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
            buf.frameLength = AVAudioFrameCount(left.count)
            left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
            right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }
            try file.write(from: buf)
        } // file closes on deinit
        return url
    }

    private func sine(_ hz: Double, amp: Float, frames: Int) -> [Float] {
        (0..<frames).map { amp * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    // MARK: File source

    func testFileSourceChunksAreBitExactAtFileRate() throws {
        let frames = Int(rate * 2.5)
        let l = sine(440, amp: 0.5, frames: frames)
        let r = sine(660, amp: 0.25, frames: frames)
        let src = try FileAudioSource(url: try writeFloatWav(left: l, right: r))
        XCTAssertEqual(src.sampleRate, rate)
        XCTAssertEqual(src.lengthFrames, AVAudioFramePosition(frames))
        XCTAssertEqual(src.monoFormat.channelCount, 1)
        XCTAssertEqual(src.monoFormat.sampleRate, rate)

        var gotL: [Float] = [], gotR: [Float] = []
        var sizes: [AVAudioFrameCount] = []
        while let c = try src.readChunk(maxFrames: .max) {
            XCTAssertEqual(c.startFrame, AVAudioFramePosition(gotL.count))
            sizes.append(c.frameLength)
            gotL += Array(UnsafeBufferPointer(start: c.left.floatChannelData![0], count: Int(c.frameLength)))
            gotR += Array(UnsafeBufferPointer(start: c.right.floatChannelData![0], count: Int(c.frameLength)))
        }
        XCTAssertEqual(sizes, [96_000, 96_000, 48_000])
        XCTAssertEqual(gotL, l)
        XCTAssertEqual(gotR, r)

        try src.seek(toFrame: 150_000)
        let c = try XCTUnwrap(src.readChunk(maxFrames: 10))
        XCTAssertEqual(c.startFrame, 150_000)
        XCTAssertEqual(c.left.floatChannelData![0][0], l[150_000])
    }

    // MARK: Engine graph (offline render)

    private func render(_ engine: SpatialAudioEngine, seconds: Double) throws -> (l: [Float], r: [Float]) {
        let e = engine.engine
        let buf = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat,
                                   frameCapacity: e.manualRenderingMaximumFrameCount)!
        var outL: [Float] = [], outR: [Float] = []
        let total = Int(seconds * e.manualRenderingFormat.sampleRate)
        while outL.count < total {
            let n = min(AVAudioFrameCount(total - outL.count), buf.frameCapacity)
            let status = try e.renderOffline(n, to: buf)
            XCTAssertEqual(status, .success)
            let ch = buf.floatChannelData!
            outL += Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            outR += Array(UnsafeBufferPointer(start: ch[1], count: Int(buf.frameLength)))
            // Let chunk-refill callbacks run.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        return (outL, outR)
    }

    private func makeEngine(file: URL, spatial: Bool) throws -> SpatialAudioEngine {
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let engine = SpatialAudioEngine(offlineFormat: outFormat)
        engine.setVolume(1)
        engine.setTrim(decibels: 0)
        engine.setSpatialEnabled(spatial)
        try engine.load(source: try FileAudioSource(url: file))
        engine.play()
        return engine
    }

    func testBypassPathIsBitExact() throws {
        let frames = Int(rate * 2)
        let l = sine(440, amp: 0.5, frames: frames)
        let r = sine(660, amp: 0.25, frames: frames)
        let engine = try makeEngine(file: try writeFloatWav(left: l, right: r), spatial: false)
        let out = try render(engine, seconds: 1.5)
        var maxErr: Float = 0
        for i in 0..<out.l.count {
            maxErr = max(maxErr, abs(out.l[i] - l[i]), abs(out.r[i] - r[i]))
        }
        print("Bypass path max abs error vs. file: \(maxErr)")
        XCTAssertLessThanOrEqual(maxErr, 1e-6)
    }

    func testSpatialPathLevelAndLeftRight() throws {
        let frames = Int(rate * 2)
        // Signal on the left channel only.
        let l = sine(1000, amp: 0.5, frames: frames)
        let r = [Float](repeating: 0, count: frames)
        let url = try writeFloatWav(left: l, right: r)

        let engine = try makeEngine(file: url, spatial: true)
        let out = try render(engine, seconds: 1.5)
        let skip = Int(rate * 0.2) // ignore HRTF onset
        let rmsL = rms(out.l[skip...]), rmsR = rms(out.r[skip...])
        let inRms = rms(l[skip..<out.l.count])
        let dbL = Gain.decibels(fromLinear: rmsL / inRms)
        let dbR = Gain.decibels(fromLinear: rmsR / inRms)
        print(String(format: "HRTF, left speaker at -30°, 1 kHz: left ear %+.2f dB, right ear %+.2f dB re. input", dbL, dbR))
        XCTAssertGreaterThan(rmsL, rmsR, "Left source should be louder in the left ear")
        XCTAssertGreaterThan(rmsL, 0)
        XCTAssertLessThan(abs(dbL), 20, "Spatial level is far from unity; check distance attenuation")
    }

    func testListenerYawMovesTheImage() throws {
        let frames = Int(rate * 2)
        let l = sine(1000, amp: 0.5, frames: frames)
        let r = [Float](repeating: 0, count: frames)
        let url = try writeFloatWav(left: l, right: r)
        var balances: [Double: Double] = [:]
        for yaw in [-60.0, 0, 60] {
            let engine = try makeEngine(file: url, spatial: true)
            engine.setListenerOrientation(HeadPose(yaw: yaw))
            let out = try render(engine, seconds: 1.0)
            let skip = Int(rate * 0.2)
            balances[yaw] = Gain.decibels(fromLinear: rms(out.l[skip...]) / max(rms(out.r[skip...]), 1e-12))
        }
        print(String(format: "L/R balance for left speaker: yaw -60 → %.1f dB, 0 → %.1f dB, +60 → %.1f dB",
                     balances[-60]!, balances[0]!, balances[60]!))
        XCTAssertNotEqual(balances[-60]!, balances[60]!, accuracy: 1.0,
                          "listenerAngularOrientation yaw had no audible effect")
    }

    // MARK: Vision

    func testVisionRevision3IsSupported() throws {
        XCTAssertTrue(VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision3))
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
        let handler = VNImageRequestHandler(cvPixelBuffer: try XCTUnwrap(pb), orientation: .up, options: [:])
        try handler.perform([request])
        XCTAssertEqual(request.results?.count ?? 0, 0) // blank frame: no faces, no error
    }
}
