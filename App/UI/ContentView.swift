import HeadTrackCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            fileSection
            transportSection
            spatialSection
            trackingSection
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }

    // MARK: File

    private var fileSection: some View {
        Section("File") {
            HStack {
                Text(model.status.fileName ?? "No file loaded")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Open…") { model.openFile() }
            }
            LabeledContent("File sample rate", value: rateText(model.status.fileSampleRate))
            LabeledContent("Output device sample rate", value: rateText(model.status.outputSampleRate))
        }
    }

    // MARK: Transport

    private var transportSection: some View {
        Section("Transport") {
            HStack(spacing: 12) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.status.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.status.fileName == nil)

                Slider(value: $model.scrubPosition,
                       in: 0...max(model.status.durationSeconds, 0.001),
                       onEditingChanged: { editing in
                           if editing { model.isScrubbing = true } else { model.commitSeek() }
                       })
                .disabled(model.status.fileName == nil)

                Text("\(timeText(model.scrubPosition)) / \(timeText(model.status.durationSeconds))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledSlider(title: "Volume", value: $model.settings.volume, range: 0...1) {
                $0 <= 0 ? "−∞ dB" : String(format: "%.1f dB", Gain.decibels(fromLinear: $0))
            }
        }
    }

    // MARK: Spatial

    private var spatialSection: some View {
        Section("Spatial audio") {
            Toggle("Spatial (HRTF)", isOn: $model.settings.spatialEnabled)
            LabeledSlider(title: "A/B trim", value: $model.settings.abTrim,
                          range: PlayerSettings.trimRange, step: 0.1) {
                String(format: "%+.1f dB", $0)
            }
            Text("Positive trim makes plain stereo louder relative to spatial. Match levels before judging.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledSlider(title: "Speaker angle", value: $model.settings.speakerAngle,
                          range: PlayerSettings.speakerAngleRange, step: 1) {
                String(format: "±%.0f°", $0)
            }
        }
    }

    // MARK: Tracking

    private var trackingSection: some View {
        Section("Head tracking") {
            HStack {
                Toggle("Tracking", isOn: $model.settings.trackingEnabled)
                Spacer()
                Button("Recenter") { model.recenter() }
                Text(GlobalHotKey.defaultDescription)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                poseReadout("Yaw", model.pose.yaw, raw: model.rawPose?.yaw)
                poseReadout("Pitch", model.pose.pitch, raw: model.rawPose?.pitch)
                poseReadout("Roll", model.pose.roll, raw: model.rawPose?.roll)
                Spacer()
                if model.settings.trackingEnabled {
                    Label(model.faceLost ? "No face" : "Face",
                          systemImage: model.faceLost ? "person.fill.questionmark" : "person.fill.checkmark")
                        .foregroundStyle(model.faceLost ? Color.orange : Color.green)
                }
            }
            HStack(spacing: 16) {
                LabeledContent("Tracker", value: trackerText(model.trackerStats))
                LabeledContent("Vision", value: model.trackerStats.processingMilliseconds
                    .map { String(format: "%.1f ms/frame", $0) } ?? "—")
            }
            .monospacedDigit()
            LabeledSlider(title: "Smoothing", value: $model.settings.smoothing, range: 0...1) {
                String(format: "%.2f (%.2f Hz)", $0, OneEuroFilter.minCutoff(forSmoothing: $0))
            }
            Grid(alignment: .leading, horizontalSpacing: 16) {
                GridRow {
                    Text("")
                    Text("Enabled").font(.caption)
                    Text("Invert").font(.caption)
                }
                axisRow("Yaw", enabled: $model.settings.axes.yawEnabled, invert: $model.settings.axes.invertYaw)
                axisRow("Pitch", enabled: $model.settings.axes.pitchEnabled, invert: $model.settings.axes.invertPitch)
                axisRow("Roll", enabled: $model.settings.axes.rollEnabled, invert: $model.settings.axes.invertRoll)
            }
        }
    }

    private func axisRow(_ name: String, enabled: Binding<Bool>, invert: Binding<Bool>) -> some View {
        GridRow {
            Text(name)
            Toggle("", isOn: enabled).labelsHidden()
            Toggle("", isOn: invert).labelsHidden()
        }
    }

    private func poseReadout(_ name: String, _ value: Double, raw: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%+6.1f°", value)).font(.title3.monospacedDigit())
            Text(raw.map { String(format: "raw %+6.1f°", $0) } ?? "raw —")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func trackerText(_ s: TrackerStats) -> String {
        let fps = String(format: "%.1f fps", s.framesPerSecond)
        guard let w = s.frameWidth, let h = s.frameHeight else { return fps }
        return "\(w)×\(h) · \(fps)"
    }

    private func rateText(_ hz: Double?) -> String {
        guard let hz, hz > 0 else { return "—" }
        return String(format: "%.1f kHz", hz / 1000)
    }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(format(value))
                .monospacedDigit()
                .frame(width: 120, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}
