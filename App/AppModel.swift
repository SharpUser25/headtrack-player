import AppKit
import Foundation
import HeadTrackCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    // Persisted settings. Every change is pushed to the engine/tracker and saved.
    var settings: PlayerSettings {
        didSet {
            guard settings != oldValue else { return }
            apply(old: oldValue)
            store.save(settings)
        }
    }

    // Transport / display state.
    private(set) var status = SpatialAudioEngine.Status()
    private(set) var pose = HeadPose.zero
    private(set) var rawPose: HeadPose?
    private(set) var faceLost = true
    private(set) var trackerStats = TrackerStats()
    var errorMessage: String?
    /// While dragging the seek bar we stop overwriting the slider value.
    var isScrubbing = false
    var scrubPosition: Double = 0

    private let store = SettingsStore()
    private let audio = SpatialAudioEngine()
    private let tracking: TrackingController
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var statusTimer: Timer?

    init() {
        let loaded = SettingsStore().load()
        settings = loaded
        tracking = TrackingController(tracker: VisionHeadTracker(), config: loaded.tracking)

        audio.onEngineError = { [weak self] msg in
            DispatchQueue.main.async { self?.errorMessage = msg }
        }
        tracking.applyOrientation = Self.orientationSink(for: audio)
        tracking.onDisplay = { [weak self] out, raw, lost in
            self?.pose = out
            self?.rawPose = raw
            self?.faceLost = lost
        }
        tracking.onStats = { [weak self] s in self?.trackerStats = s }
        tracking.onError = { [weak self] e in self?.errorMessage = e }

        audio.setSpeakerAngle(loaded.speakerAngle)
        audio.setSpatialEnabled(loaded.spatialEnabled)
        audio.setTrim(decibels: loaded.abTrim)
        audio.setVolume(loaded.volume)
        tracking.setEnabled(loaded.trackingEnabled)

        hotKey = GlobalHotKey { [weak self] in self?.recenter() }
        if hotKey == nil {
            errorMessage = "Could not register the \(GlobalHotKey.defaultDescription) hotkey (another app may own it)."
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        refreshStatus()
    }

    /// Built outside the main actor: it runs on the 100 Hz timer queue.
    nonisolated private static func orientationSink(for audio: SpatialAudioEngine) -> (HeadPose) -> Void {
        { pose in audio.setListenerOrientation(pose) }
    }

    private func apply(old: PlayerSettings) {
        if settings.speakerAngle != old.speakerAngle { audio.setSpeakerAngle(settings.speakerAngle) }
        if settings.spatialEnabled != old.spatialEnabled { audio.setSpatialEnabled(settings.spatialEnabled) }
        if settings.abTrim != old.abTrim { audio.setTrim(decibels: settings.abTrim) }
        if settings.volume != old.volume { audio.setVolume(settings.volume) }
        if settings.tracking != old.tracking { tracking.setConfig(settings.tracking) }
        if settings.trackingEnabled != old.trackingEnabled { tracking.setEnabled(settings.trackingEnabled) }
    }

    private func refreshStatus() {
        status = audio.status()
        if !isScrubbing { scrubPosition = status.positionSeconds }
    }

    // MARK: Actions

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func load(url: URL) {
        do {
            let source = try FileAudioSource(url: url)
            try audio.load(source: source)
            errorMessage = nil
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
        refreshStatus()
    }

    func togglePlay() {
        if status.isPlaying { audio.pause() } else { audio.play() }
        refreshStatus()
    }

    func commitSeek() {
        audio.seek(toSeconds: scrubPosition)
        isScrubbing = false
        refreshStatus()
    }

    func recenter() { tracking.recenter() }
}
