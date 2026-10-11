# HeadTrack Player

A macOS 14+ player for local audio files. It plays them through two virtual speakers using Apple's HRTF renderer, and uses the webcam to track your head so the speakers stay put in the room when you turn. It's meant for wired headphones and personal use.

```
file ─ AVAudioFile (1 s chunks, Float32, file's own rate)
     ─ split into L / R mono ─┬─ leftPlayer  (mono) ─┐
                              ├─ rightPlayer (mono) ─┴─ AVAudioEnvironmentNode (HRTFHQ, headphones) ─┐
                              └─ stereoPlayer (bypass, for A/B) ──────────────────────────────────────┴─ mainMixer ─ output
camera 1280x720 ─ Vision face rectangles rev. 3 (yaw/pitch/roll) ─ One Euro ─ recenter ─ axes
     ─ 100 Hz interpolation ─ listenerAngularOrientation
```

## Build and run

You need Xcode 15 or newer and Homebrew.

1. Install XcodeGen:
   ```sh
   brew install xcodegen
   ```
2. Generate the project. Run this from the repo root, and again whenever `project.yml` changes:
   ```sh
   xcodegen generate
   ```
   This writes `HeadTrackPlayer.xcodeproj`, `App/Info.plist` and `App/HeadTrackPlayer.entitlements`. All three are generated and git-ignored; edit `project.yml` instead.
3. Open the project:
   ```sh
   open HeadTrackPlayer.xcodeproj
   ```
4. Select the **HeadTrackPlayer** target, open **Signing & Capabilities**, and set **Team** to your personal team. Keep "Automatically manage signing" on. If the bundle ID `local.headtrack.HeadTrackPlayer` is rejected, change it to something unique.
5. Choose the **HeadTrackPlayer** scheme and **My Mac**, then press **⌘R**. Allow camera access when asked.

The app runs with App Sandbox off, and with the hardened runtime plus the camera entitlement (`com.apple.security.device.camera`).

Tests:
```sh
swift test --package-path HeadTrackCore          # pure logic, also runs on Linux
xcodebuild test -project HeadTrackPlayer.xcodeproj -scheme HeadTrackPlayer \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
The app tests render the real AVAudioEngine graph offline, so no audio device is needed. They print the measured HRTF level and L/R balance.

## First-run listening checklist

Use wired headphones, with **Spatial** on and **Tracking** off.

1. **Left/right.** Play a track with an obvious hard-panned part, or a left-only test tone. It should come from front-left. If it comes from the right, your headphones are on backwards. The app keeps left as left: the left speaker sits at negative x, and the CI test checks that a left-only signal is louder in the left ear.
2. **Level-match before judging.** Flip **Spatial** on and off. Move **A/B trim** until both settings sound equally loud; a meter is better if you have one. Louder always sounds "better", so judge only after matching. Trim only lowers one of the two paths and never adds gain.
3. **Speaker angle.** Start at ±30°, which is a standard stereo triangle. Widen it if the image feels narrow, narrow it if the center gets hollow.
4. **Yaw sign.** Turn **Tracking** on, look straight at the screen, and press **Recenter** (or **⌃⌥⌘C** from any app). Turn your head about 45° to the **left** and hold it. The speakers should stay where they were in the room, so the music should move toward your **right** ear. If it moves with your head and stays centred on your nose, flip **Yaw → Invert**. Check again by turning right.
5. **Pitch and roll**, if you want them. Enable one at a time and set the sign the same way. Nodding down should make the speakers seem to rise; tilting your head toward one shoulder should not drag the image with it. Most people leave these off, because Vision is much noisier on pitch and roll than on yaw.
6. **Sample rates.** The window shows the file's sample rate and the output device's. If they differ, Core Audio resamples at the mixer. To avoid that, set the device to the file's rate in Audio MIDI Setup; the app follows the change.

### If the image lags or wobbles

- The **Tracker** line shows the frame size actually arriving, for example `1280×720 · 30.0 fps`. For details, run this in Terminal:
  ```sh
  log stream --level info --predicate 'subsystem == "local.headtrack.HeadTrackPlayer" AND category == "camera"'
  ```
  It prints the format the app requested and the `activeFormat` after `startRunning`. Once frames arrive, it prints the buffer size, and after 2 s the active frame duration and measured rate. If the size isn't 1280x720 or the rate is lower than requested, the session overrode the format.
- Look at **Tracker fps** and **Vision ms/frame**. You want close to 30 fps, and Vision time well under 33 ms. If fps is low, give the camera more light: in dim rooms macOS lowers the frame rate to lengthen exposure.
- Lower **Smoothing**. Smoothing sets the One Euro minimum cutoff, which the slider shows in Hz. Lower smoothing means less lag and more jitter. Try going down until the image starts to shimmer while you hold still, then back off a little.
- The 100 Hz interpolation ramps toward each new camera pose over one frame interval, about 33 ms. That buys smoothness at the cost of up to one frame of extra lag.
- Close other apps that use the camera or the Neural Engine.
- If the image drifts after you move your chair, press **⌃⌥⌘C** to recenter.

## Signal path and sound quality

- Nothing is resampled on purpose. Players are connected with mono and stereo formats at the **file's** rate, and the environment node outputs at the **device** rate. Any conversion happens only where those two rates differ.
- Gains along the path are exactly 1.0, except for the master **Volume**, the A/B trim, and the HRTF itself. Mono files go to both speakers at unity, with no pan law. Files with more than two channels use the first two.
- Reverb is off (`reverbParameters.enable = false`, `reverbBlend = 0`). Distance attenuation uses the inverse model with `referenceDistance = 2 m`, so the speakers at 2 m play at unity gain.
- The plain-stereo bypass is checked in CI: rendered output must match the file within 1e-6. The measured maximum difference was 4.9e-7 (about −126 dBFS), so the path is not bit-exact but is far below audibility.
- CI also measures the HRTF render. A 1 kHz tone from the left speaker at −30° came out at −1.0 dB in the left ear and −9.2 dB in the right ear, relative to the input. That's why the A/B trim usually needs to be only about 1 dB.
- Audio-side yaw convention, also measured in CI: setting `listenerAngularOrientation.yaw` to +60 moves the left speaker further left (L/R balance +9.1 dB), and −60 swings it to the right (−8.7 dB). Positive listener yaw therefore means the head turned **right**. The Vision sign is the part you still set by ear (checklist step 4).
- Pause stops all players and resumes from the same frame on one shared start time, so the left, right and bypass players can never drift apart.

## Code layout

| Path | What |
|---|---|
| `HeadTrackCore/` | Swift package that imports only Foundation: One Euro filter, angle math, recentering, face-lost easing, pose interpolation, stereo→mono split, settings. Tested with `swift test`. |
| `App/Audio/AudioSource.swift` | `AudioSource` protocol that delivers L/R mono streams. Add a live-input source here later. |
| `App/Audio/FileAudioSource.swift` | AVAudioFile reader in 1 s chunks. |
| `App/Audio/SpatialAudioEngine.swift` | The AVAudioEngine graph, scheduling, transport, device-change handling. |
| `App/Tracking/HeadTracker.swift` | `HeadTracker` protocol. |
| `App/Tracking/VisionHeadTracker.swift` | AVCaptureSession and Vision implementation. |
| `App/Tracking/TrackingController.swift` | Pipeline lock and the 100 Hz listener timer. |
| `App/Support/GlobalHotKey.swift` | Carbon `RegisterEventHotKey`, so no Accessibility permission is needed. |

Settings are saved as one JSON value under `HeadTrackPlayer.settings.v1` in UserDefaults.
