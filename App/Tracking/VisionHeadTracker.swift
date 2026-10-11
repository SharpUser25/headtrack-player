import AVFoundation
import CoreMedia
import HeadTrackCore
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
    private var configured = false

    // Guarded by busyLock.
    private var busy = false
    private let busyLock = NSLock()
    // Touched only on visionQueue.
    private var meter = RateMeter(window: 1.0)
    private var dropped = 0
    private var lastStatsTime: Double = 0

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
            if !self.session.isRunning { self.session.startRunning() }
        }
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
        guard let (format, range) = Self.bestFormat(for: device) else {
            throw TrackerError(errorDescription: "The camera has no 1280x720 format.")
        }

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

        // Set the format after adding the input; the session otherwise
        // applies its preset and overrides activeFormat.
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = range.minFrameDuration
        device.activeVideoMaxFrameDuration = range.minFrameDuration
        device.unlockForConfiguration()
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
        // The pixel buffer is retained by the closure until Vision is done.
        visionQueue.async { [weak self] in
            self?.analyze(pixelBuffer, timestamp: timestamp)
            self?.setIdle()
        }
    }

    private func setIdle() {
        busyLock.lock()
        busy = false
        busyLock.unlock()
    }

    private func analyze(_ pixelBuffer: CVPixelBuffer, timestamp: Double) {
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
        if t1 - lastStatsTime >= 0.5 {
            lastStatsTime = t1
            busyLock.lock()
            let d = dropped
            busyLock.unlock()
            onStats?(TrackerStats(framesPerSecond: meter.rate(now: t1),
                                  processingMilliseconds: meter.meanDuration.map { $0 * 1000 },
                                  droppedFrames: d))
        }
    }
}
