import AVFoundation
import HeadTrackCore

/// AVAudioEngine graph:
///
///   leftPlayer  (mono @ file rate) ─┐
///                                    ├─ environment (HRTFHQ, headphones) ─┐
///   rightPlayer (mono @ file rate) ─┘                                     ├─ mainMixer ─ output
///   stereoPlayer (2ch @ file rate, bypass for A/B) ───────────────────────┘
///
/// All three players receive the same chunks and start at the same
/// AVAudioTime, so the Spatial switch is a pair of gain changes with no
/// timeline jump. Gains are only ever 1.0, 0.0, the A/B trim, or the
/// master volume.
final class SpatialAudioEngine {
    struct Status {
        var isPlaying = false
        var positionSeconds: Double = 0
        var durationSeconds: Double = 0
        var fileSampleRate: Double?
        var outputSampleRate: Double = 0
        var fileName: String?
        var reachedEnd = false
    }

    let engine = AVAudioEngine()
    let environment = AVAudioEnvironmentNode()
    private let leftPlayer = AVAudioPlayerNode()
    private let rightPlayer = AVAudioPlayerNode()
    private let stereoPlayer = AVAudioPlayerNode()

    /// All scheduling state lives on this queue.
    private let queue = DispatchQueue(label: "HeadTrackPlayer.audio.schedule", qos: .userInteractive)
    private var source: AudioSource?
    private var generation = 0
    private var queuedChunks = 0
    private var sourceExhausted = false
    private var playing = false
    /// Source frame at which the players' sample time 0 lies.
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var endReached = false
    private let maxQueuedChunks = 3

    // Settings mirrored here so they can be re-applied after a reconnect.
    private var speakerAngle: Double = 30
    private var spatialEnabled = true
    private var trimDecibels: Double = 0
    private var volume: Double = 0.8

    var onEngineError: ((String) -> Void)?

    /// - Parameter offlineFormat: when set, the engine runs in offline
    ///   manual-rendering mode (no audio device). Used by the tests.
    init(offlineFormat: AVAudioFormat? = nil) {
        if let offlineFormat {
            do {
                try engine.enableManualRenderingMode(.offline, format: offlineFormat, maximumFrameCount: 4096)
            } catch {
                assertionFailure("Manual rendering unavailable: \(error)")
            }
        }
        engine.attach(environment)
        engine.attach(leftPlayer)
        engine.attach(rightPlayer)
        engine.attach(stereoPlayer)
        configureEnvironment()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func configureEnvironment() {
        environment.outputType = .headphones
        environment.reverbParameters.enable = false
        // Inverse model: gain = ref / (ref + rolloff * (d - ref)) for d >= ref,
        // and 1.0 for d <= ref. With ref = 2 m the speakers at 2 m sit at unity.
        let d = environment.distanceAttenuationParameters
        d.distanceAttenuationModel = .inverse
        d.referenceDistance = Float(PlayerSettings.speakerDistance)
        d.maximumDistance = 100
        d.rolloffFactor = 1
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
    }

    private func configureSources() {
        for p in [leftPlayer, rightPlayer] {
            p.renderingAlgorithm = .HRTFHQ
            p.sourceMode = .spatializeIfMono
            p.reverbBlend = 0
            p.obstruction = 0
            p.occlusion = 0
        }
        applySpeakerPositions()
        applyGains()
    }

    private func applySpeakerPositions() {
        let dist = PlayerSettings.speakerDistance
        let l = AngleMath.speakerPosition(azimuthDegrees: -speakerAngle, distance: dist)
        let r = AngleMath.speakerPosition(azimuthDegrees: speakerAngle, distance: dist)
        leftPlayer.position = AVAudio3DPoint(x: Float(l.x), y: Float(l.y), z: Float(l.z))
        rightPlayer.position = AVAudio3DPoint(x: Float(r.x), y: Float(r.y), z: Float(r.z))
    }

    private func applyGains() {
        let g = Gain.abTrimGains(trimDecibels: trimDecibels)
        environment.outputVolume = spatialEnabled ? Float(g.spatial) : 0
        stereoPlayer.volume = spatialEnabled ? 0 : Float(g.stereo)
        engine.mainMixerNode.outputVolume = Float(volume)
    }

    // MARK: Settings

    func setSpeakerAngle(_ degrees: Double) {
        speakerAngle = degrees
        applySpeakerPositions()
    }

    func setSpatialEnabled(_ on: Bool) { spatialEnabled = on; applyGains() }
    func setTrim(decibels: Double) { trimDecibels = decibels; applyGains() }
    func setVolume(_ v: Double) { volume = v; applyGains() }

    /// Called from the 100 Hz tracking timer.
    func setListenerOrientation(_ p: HeadPose) {
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: Float(p.yaw), pitch: Float(p.pitch), roll: Float(p.roll))
    }

    // MARK: Loading

    func load(source newSource: AudioSource) throws {
        try queue.sync {
            stopPlayersLocked()
            engine.stop()
            source = newSource
            segmentStartFrame = 0
            endReached = false
            try connectGraphLocked(for: newSource)
            try newSource.seek(toFrame: 0)
            refillLocked(generation: generation)
        }
    }

    private func connectGraphLocked(for src: AudioSource) throws {
        engine.disconnectNodeOutput(leftPlayer)
        engine.disconnectNodeOutput(rightPlayer)
        engine.disconnectNodeOutput(stereoPlayer)
        engine.disconnectNodeOutput(environment)

        // Mono at the file's own rate into the environment node.
        engine.connect(leftPlayer, to: environment, fromBus: 0, toBus: 0, format: src.monoFormat)
        engine.connect(rightPlayer, to: environment, fromBus: 0, toBus: 1, format: src.monoFormat)
        engine.connect(stereoPlayer, to: engine.mainMixerNode, format: src.stereoFormat)
        // Environment -> main mixer in stereo at the output device's rate, so
        // the only rate conversion is the one the hardware rate requires.
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let envOut = AVAudioFormat(standardFormatWithSampleRate: outRate > 0 ? outRate : src.sampleRate,
                                   channels: 2)
        engine.connect(environment, to: engine.mainMixerNode, format: envOut)
        configureSources()
        engine.prepare()
        try engine.start()
    }

    // MARK: Transport

    func play() {
        queue.sync {
            guard let src = source, !playing else { return }
            if endReached || segmentStartFrame >= (src.lengthFrames ?? .max) {
                try? seekLocked(to: 0)
            }
            do {
                if !engine.isRunning { try engine.start() }
            } catch {
                onEngineError?("Audio engine failed to start: \(error.localizedDescription)")
                return
            }
            startPlayersLocked()
        }
    }

    /// Pause is stop-and-remember: resuming reschedules from the same frame
    /// on all players at one start time, so they can never drift apart.
    func pause() {
        queue.sync {
            guard playing else { return }
            let pos = currentFrameLocked()
            playing = false
            stopPlayersLocked()
            try? seekLocked(to: pos)
        }
    }

    func seek(toSeconds seconds: Double) {
        queue.sync {
            guard let src = source, src.isSeekable else { return }
            let frame = AVAudioFramePosition((seconds * src.sampleRate).rounded())
            let wasPlaying = playing
            playing = false
            stopPlayersLocked()
            try? seekLocked(to: frame)
            if wasPlaying { startPlayersLocked() }
        }
    }

    private func seekLocked(to frame: AVAudioFramePosition) throws {
        guard let src = source else { return }
        let clamped = max(0, min(frame, src.lengthFrames ?? frame))
        try src.seek(toFrame: clamped)
        segmentStartFrame = clamped
        endReached = false
        sourceExhausted = false
        queuedChunks = 0
        refillLocked(generation: generation)
    }

    private func stopPlayersLocked() {
        // Bump the generation first so completion handlers fired by stop()
        // for the flushed buffers are ignored.
        generation += 1
        leftPlayer.stop()
        rightPlayer.stop()
        stereoPlayer.stop()
        queuedChunks = 0
        sourceExhausted = false
    }

    private func startPlayersLocked() {
        if engine.isInManualRenderingMode {
            // Offline: nothing renders until renderOffline is called, so
            // starting immediately is already sample-aligned.
            leftPlayer.play()
            rightPlayer.play()
            stereoPlayer.play()
            playing = true
            return
        }
        // One shared start time, a little in the future, for all players.
        let lead = AVAudioTime.hostTime(forSeconds: 0.05)
        let start = AVAudioTime(hostTime: mach_absolute_time() + lead)
        leftPlayer.play(at: start)
        rightPlayer.play(at: start)
        stereoPlayer.play(at: start)
        playing = true
    }

    private func refillLocked(generation gen: Int) {
        guard gen == generation, let src = source else { return }
        while queuedChunks < maxQueuedChunks && !sourceExhausted {
            let chunk: StereoChunk?
            do {
                chunk = try src.readChunk(maxFrames: AVAudioFrameCount(ChannelSplitter.chunkFrames(sampleRate: src.sampleRate)))
            } catch {
                onEngineError?("Read error: \(error.localizedDescription)")
                chunk = nil
            }
            guard let chunk,
                  let stereo = FileAudioSource.stereoBuffer(from: chunk, format: src.stereoFormat) else {
                sourceExhausted = true
                break
            }
            queuedChunks += 1
            // Same order on every player: buffers play back to back.
            leftPlayer.scheduleBuffer(chunk.left, completionCallbackType: .dataConsumed) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.chunkConsumedLocked(generation: gen) }
            }
            rightPlayer.scheduleBuffer(chunk.right, completionHandler: nil)
            stereoPlayer.scheduleBuffer(stereo, completionHandler: nil)
        }
        if sourceExhausted && queuedChunks == 0 && gen == generation {
            markEndLocked()
        }
    }

    private func chunkConsumedLocked(generation gen: Int) {
        guard gen == generation else { return }
        queuedChunks = max(0, queuedChunks - 1)
        refillLocked(generation: gen)
    }

    private func markEndLocked() {
        guard let src = source else { return }
        // .dataConsumed fires slightly before audio is heard; wait for the
        // tail to finish rendering before stopping.
        let gen = generation
        let tail = max(0, Double((src.lengthFrames ?? 0) - currentFrameLocked()) / src.sampleRate)
        queue.asyncAfter(deadline: .now() + tail + 0.1) { [weak self] in
            guard let self, gen == self.generation, self.playing else { return }
            self.playing = false
            self.stopPlayersLocked()
            self.endReached = true
            self.segmentStartFrame = src.lengthFrames ?? 0
        }
    }

    private func currentFrameLocked() -> AVAudioFramePosition {
        guard playing,
              let nodeTime = leftPlayer.lastRenderTime,
              let playerTime = leftPlayer.playerTime(forNodeTime: nodeTime) else {
            return segmentStartFrame
        }
        let frame = segmentStartFrame + max(0, playerTime.sampleTime)
        return min(frame, source?.lengthFrames ?? frame)
    }

    func status() -> Status {
        queue.sync {
            var s = Status()
            s.isPlaying = playing
            s.outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            s.reachedEnd = endReached
            if let src = source {
                s.fileSampleRate = src.sampleRate
                s.fileName = src.displayName
                s.durationSeconds = Double(src.lengthFrames ?? 0) / src.sampleRate
                s.positionSeconds = Double(currentFrameLocked()) / src.sampleRate
            }
            return s
        }
    }

    // MARK: Device changes

    @objc private func configurationChanged(_ note: Notification) {
        // The engine stops itself when the output device or its rate
        // changes. Rebuild at the new rate and resume from where we were.
        queue.async { [weak self] in
            guard let self, let src = self.source else { return }
            let wasPlaying = self.playing
            let pos = self.currentFrameLocked()
            self.playing = false
            self.stopPlayersLocked()
            do {
                try self.connectGraphLocked(for: src)
                try self.seekLocked(to: pos)
                if wasPlaying { self.startPlayersLocked() }
            } catch {
                self.onEngineError?("Audio device changed and the engine could not restart: \(error.localizedDescription)")
            }
        }
    }
}
