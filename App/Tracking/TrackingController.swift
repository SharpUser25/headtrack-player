import Foundation
import HeadTrackCore

/// Owns the tracking pipeline and the 100 Hz timer that pushes the
/// interpolated pose into the audio engine.
final class TrackingController {
    private let pipeline: TrackingPipeline
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "HeadTrackPlayer.listener.timer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var tracker: HeadTracker
    private var enabled = false
    private var tickCount = 0

    /// Receives the listener orientation at 100 Hz (on the timer queue).
    var applyOrientation: ((HeadPose) -> Void)?
    /// Receives UI snapshots at ~20 Hz (on the main queue).
    var onDisplay: ((_ output: HeadPose, _ raw: HeadPose?, _ faceLost: Bool) -> Void)?
    var onStats: ((TrackerStats) -> Void)?
    var onError: ((String) -> Void)?

    init(tracker: HeadTracker, config: TrackingConfig) {
        self.tracker = tracker
        pipeline = TrackingPipeline(config: config)
        wire(tracker)
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func wire(_ t: HeadTracker) {
        t.onSample = { [weak self] sample in
            guard let self else { return }
            self.lock.lock()
            self.pipeline.ingest(sample, now: Self.now())
            self.lock.unlock()
        }
        t.onStats = { [weak self] s in DispatchQueue.main.async { self?.onStats?(s) } }
        t.onError = { [weak self] e in DispatchQueue.main.async { self?.onError?(e) } }
    }

    /// Replace the tracker implementation at runtime.
    func setTracker(_ t: HeadTracker) {
        let wasEnabled = enabled
        setEnabled(false)
        tracker = t
        wire(t)
        if wasEnabled { setEnabled(true) }
    }

    func setConfig(_ c: TrackingConfig) {
        lock.lock()
        pipeline.setConfig(c)
        lock.unlock()
    }

    func recenter() {
        lock.lock()
        pipeline.recenter(now: Self.now())
        lock.unlock()
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            lock.lock(); pipeline.reset(); lock.unlock()
            tracker.start()
            startTimer()
        } else {
            tracker.stop()
            stopTimer()
            applyOrientation?(.zero)
            DispatchQueue.main.async { [weak self] in self?.onDisplay?(.zero, nil, true) }
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = Self.now()
        lock.lock()
        let pose = pipeline.output(at: now)
        let raw = pipeline.lastRaw
        let lost = pipeline.isFaceLost(at: now)
        lock.unlock()
        applyOrientation?(pose)
        tickCount += 1
        if tickCount % 5 == 0 {
            DispatchQueue.main.async { [weak self] in self?.onDisplay?(pose, raw, lost) }
        }
    }
}
