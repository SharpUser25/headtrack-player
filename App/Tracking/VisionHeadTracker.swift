import AVFoundation
import CoreMedia
import HeadTrackCore
import OSLog
import Vision

/// Built-in camera at 1280x720 (highest frame rate available at that size)
/// -> VNDetectFaceRectanglesRequest revision 3 -> yaw/pitch/roll in degrees.
final class VisionHeadTracker: NSObject, HeadTracker, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onSample: ((HeadPoseSample) -> Void)?
    var onStats: ((TrackerStats) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "HeadTrackPlayer.capture.session")
    private let captureQueue = DispatchQueue(label: "HeadTrackPlayer.capture.frames", qos: .userInteractive)
    private let visionQueue = DispatchQueue(label: "HeadTrackPlayer.vision", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let log = Logger(subsystem: "local.headtrack.HeadTrackPlayer", category: "camera")

    // Touched only on sessionQueue.
    private var configured = false
    private var device: AVCaptureDevice?
    private var wantedFormat: AVCaptureDevice.Format?
    private var wantedFrameDuration = CMTime.invalid

    // Guarded by busyLock.
    private var busy = false
    private let busyLock = NSLock()
    // Touched only on visionQueue.
    private var meter = RateMeter(window: 1.0)
    private var dropped = 0
    private var lastStatsTime: Double = 0
    private var lastBufferSize: (width: Int, height: Int)?
    private var firstFrameTime: Double?
    private var loggedEffectiveRate = false

    static let width: Int32 = 1280
    static let height: Int32 = 720

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.startSession() } else { self?.onError?("Camera access was denied.") }
            }
        default:
            onError?("Camera access is off. Enable it in System Settings > Privacy & Security > Camera.")
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                do {
                    try self.configure()
                    self.configured = true
                } catch {
                    self.onError?(error.localizedDescription)
                    return
                }
            }
            guard !self.session.isRunning else { return }
            self.startRunningWithLockedFormat()
        }
    }

    /// Apple's macOS recipe for keeping a chosen format: lock the device, set
    /// activeFormat and the frame durations, call startRunning, and only then
    /// unlock. If the device is unlocked before startRunning, the session can
    /// reconfigure the format on its own.
    private func startRunningWithLockedFormat() {
        resetFrameLogging()
        let frameDuration = wantedFrameDuration
        guard let device, let format = wantedFormat else {
            session.startRunning()
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            log.error("lockForConfiguration failed: \(error.localizedDescription, privacy: .public); starting with the session's own format")
            session.startRunning()
            return
        }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        session.startRunning()
        device.unlockForConfiguration()
        log.notice("Requested \(Self.describe(format), privacy: .public) at \(Self.fps(frameDuration), format: .fixed(precision: 2)) fps; after startRunning activeFormat is \(Self.describe(device.activeFormat), privacy: .public), frame duration min \(Self.fps(device.activeVideoMinFrameDuration), format: .fixed(precision: 2)) fps / max \(Self.fps(device.activeVideoMaxFrameDuration), format: .fixed(precision: 2)) fps")
    }

    private func resetFrameLogging() {
        visionQueue.async { [weak self] in
            self?.lastBufferSize = nil
            self?.firstFrameTime = nil
            self?.loggedEffectiveRate = false
        }
    }

    static func describe(_ format: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return "\(d.width)x\(d.height) (up to \(String(format: "%.2f", maxRate)) fps)"
    }

    static func fps(_ duration: CMTime) -> Double {
        let s = duration.seconds
        return s.isFinite && s > 0 ? 1 / s : 0
    }

    private struct TrackerError: LocalizedError {
        let errorDescription: String?
    }

    static func builtInCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        return discovery.devices.first
    }

    /// The 1280x720 format with the highest max frame rate.
    static func bestFormat(for device: AVCaptureDevice) -> (AVCaptureDevice.Format, AVFrameRateRange)? {
        var best: (AVCaptureDevice.Format, AVFrameRateRange)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == width, dims.height == height else { continue }
            for range in format.videoSupportedFrameRateRanges
            where best == nil || range.maxFrameRate > best!.1.maxFrameRate {
                best = (format, range)
            }
        }
        return best
    }

    private func configure() throws {
        guard let device = Self.builtInCamera() else {
            throw TrackerError(errorDescription: "No built-in camera found.")
        }
        guard let best = Self.bestFormat(for: device) else {
            throw TrackerError(errorDescription: "The camera has no 1280x720 format.")
        }
        let (format, range) = best
        self.device = device
        wantedFormat = format
        wantedFrameDuration = range.minFrameDuration

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw TrackerError(errorDescription: "Cannot add the camera to the capture session.")
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw TrackerError(errorDescription: "Cannot add the video output.")
        }
        session.addOutput(output)
        // activeFormat is applied in startRunningWithLockedFormat().
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        busyLock.lock()
        if busy {
            dropped += 1
            busyLock.unlock()
            return
        }
        busy = true
        busyLock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            setIdle()
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let device = (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device
        // The pixel buffer is retained by the closure until Vision is done.
        visionQueue.async { [weak self] in
            self?.analyze(pixelBuffer, timestamp: timestamp, device: device)
            self?.setIdle()
        }
    }

    private func setIdle() {
        busyLock.lock()
        busy = false
        busyLock.unlock()
    }

    private func analyze(_ pixelBuffer: CVPixelBuffer, timestamp: Double, device: AVCaptureDevice?) {
        let request = VNDetectFaceRectanglesRequest()
        // Revision 3 reports continuous yaw/pitch/roll; earlier revisions
        // quantize yaw and do not report pitch.
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let t0 = ProcessInfo.processInfo.systemUptime
        var pose: HeadPose?
        do {
            try handler.perform([request])
            let faces = request.results ?? []
            let areas = faces.map { Double($0.boundingBox.width * $0.boundingBox.height) }
            if let i = FaceSelection.indexOfLargest(areas: areas) {
                let face = faces[i]
                if let yaw = face.yaw?.doubleValue {
                    pose = HeadPose(
                        yaw: AngleMath.degrees(fromRadians: yaw),
                        pitch: AngleMath.degrees(fromRadians: face.pitch?.doubleValue ?? 0),
                        roll: AngleMath.degrees(fromRadians: face.roll?.doubleValue ?? 0))
                }
            }
        } catch {
            onError?("Vision failed: \(error.localizedDescription)")
        }
        let t1 = ProcessInfo.processInfo.systemUptime

        onSample?(HeadPoseSample(timestamp: timestamp, pose: pose))

        meter.record(at: t1, duration: t1 - t0)
        logFormatInEffect(pixelBuffer, device: device, now: t1)
        if t1 - lastStatsTime >= 0.5 {
            lastStatsTime = t1
            busyLock.lock()
            let d = dropped
            busyLock.unlock()
            onStats?(TrackerStats(framesPerSecond: meter.rate(now: t1),
                                  processingMilliseconds: meter.meanDuration.map { $0 * 1000 },
                                  droppedFrames: d,
                                  frameWidth: lastBufferSize?.width,
                                  frameHeight: lastBufferSize?.height))
        }
    }

    /// Logs what the camera is really delivering: the buffer size whenever
    /// it changes, and once, after two seconds of frames, the measured rate
    /// alongside the device's active format and frame durations.
    private func logFormatInEffect(_ pixelBuffer: CVPixelBuffer, device: AVCaptureDevice?, now: Double) {
        let size = (width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if lastBufferSize == nil || lastBufferSize! != size {
            lastBufferSize = size
            log.notice("Frames arriving at \(size.width)x\(size.height)")
        }
        if firstFrameTime == nil { firstFrameTime = now }
        guard !loggedEffectiveRate, let first = firstFrameTime, now - first >= 2, let device else { return }
        loggedEffectiveRate = true
        log.notice("In effect: buffers \(size.width)x\(size.height), activeFormat \(Self.describe(device.activeFormat), privacy: .public), active frame duration \(Self.fps(device.activeVideoMinFrameDuration), format: .fixed(precision: 2)) fps, measured \(self.meter.rate(now: now), format: .fixed(precision: 1)) fps analysed")
    }
}
