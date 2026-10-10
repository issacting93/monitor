# Project Brief: Monitor++

## A Lightweight macOS Audio Workstation for Live Performance and Multitrack Recording

---

## 1. Executive Summary

**Monitor++** is a macOS audio application designed to bridge the gap between simple pass-through monitoring utilities and full-featured digital audio workstations. Starting as a USB audio pass-through tool, it evolves into a compact, hackable music workstation that enables musicians, tinkerers, and hardware enthusiasts to monitor, process, loop, layer, and record audio in real time.

The application prioritizes immediacy and live workflow over comprehensive production features, targeting solo performers who want the essential capabilities of GarageBand or Ableton Live—multitrack recording, real-time effects, loop-based composition, and playback—without the complexity, resource overhead, or learning curve of professional DAWs.

**Working Title:** Monitor++  
**Platform:** macOS  
**Primary Language:** Swift  
**Audio Framework:** AVFoundation / AVAudioEngine  
**Status:** Technical Planning / Prototype Phase

---

## 2. Product Vision

### 2.1 Core Concept

Monitor++ transforms a Mac into a focused, low-latency audio hub for hardware musicians. Users connect a USB instrument (such as the teenage engineering OP-XY, OP-1, or any class-compliant audio interface), and the application immediately routes audio through the Mac with optional effects processing, recording, and loop playback.

The application is designed around three fundamental workflows:

1. **Live Monitoring** — Hear your instrument through the Mac with minimal latency, optionally processed through effects.
2. **Loop-Based Composition** — Capture musical phrases, loop them instantly, and overdub additional layers.
3. **Multitrack Recording** — Build songs by recording tracks sequentially while monitoring previously recorded material.

### 2.2 Design Philosophy

| Principle | Description |
|-----------|-------------|
| **Immediate** | Audio flows within milliseconds of launching the app. No project setup required. |
| **Live-Oriented** | Optimized for real-time performance, not studio production. |
| **Hackable** | Clean, modular codebase that invites modification and extension. |
| **Focused** | Does a few things exceptionally well rather than everything adequately. |
| **Native** | Built entirely with Apple frameworks for reliability and performance. |

---

## 3. Target User

### 3.1 Primary Persona: The Hardware Musician

A solo artist who composes and performs with hardware synthesizers, samplers, and grooveboxes. They want to:

- Monitor their hardware through studio monitors or headphones connected to their Mac.
- Add reverb, delay, or other effects without external gear.
- Capture ideas quickly as loops or multitrack recordings.
- Build arrangements by layering performances.

They are comfortable with technology but prefer tools that stay out of the way. They value immediacy over feature completeness.

### 3.2 Secondary Persona: The Technical Tinkerer

A developer or audio enthusiast who wants a lightweight, modifiable audio tool they can understand completely. They appreciate clean architecture, minimal dependencies, and the ability to extend functionality through code.

---

## 4. Feature Specification

### 4.1 Version 0.1 — Stabilized Monitor

**Objective:** Refactor the existing `monitor.swift` script into a robust, reusable foundation.

| Feature | Description | Priority |
|---------|-------------|----------|
| USB Audio Pass-Through | Route audio from a named USB input device to the Mac's current output. | P0 |
| Default Input Switching | Temporarily set the USB device as the system default input while running. | P0 |
| Input Restoration | Restore the previous default input device on exit. | P0 |
| Live Level Meter | Display real-time peak levels in the terminal. | P0 |
| Clean Shutdown | Handle Ctrl+C gracefully, releasing audio resources properly. | P0 |
| Error Handling | Provide clear error messages for device not found, permission denied, etc. | P1 |
| App Bundle Packaging | Distribute as a standard macOS `.app`. | P2 |

**Technical Deliverables:**
- `AudioEngine` class encapsulating AVAudioEngine setup and teardown.
- `DeviceManager` class for CoreAudio device enumeration and switching.
- `LevelMeter` utility for peak detection and display.
- SwiftPM package structure with build scripts for `.app` generation.

---

### 4.2 Version 0.2 — Effects Chain

**Objective:** Insert real-time audio effects into the signal path.

| Feature | Description | Priority |
|---------|-------------|----------|
| Effect Node Insertion | Support `AVAudioUnitEffect` nodes in the signal chain. | P0 |
| Default Effect Chain | Configurable chain: Input → EQ → Reverb → Delay → Output. | P0 |
| Effect Bypass | Enable/disable individual effects without removing them. | P1 |
| Parameter Control | Adjust effect parameters via keyboard commands (CLI) or UI. | P1 |
| CPU Monitoring | Display real-time CPU usage for the audio graph. | P2 |
| Latency Reporting | Show round-trip latency in milliseconds. | P2 |

**Supported Effects (Initial):**

| Effect | AVAudioUnit Class | Parameters |
|--------|-------------------|------------|
| EQ | `AVAudioUnitEQ` | Low/mid/high gain, frequency |
| Reverb | `AVAudioUnitReverb` | Preset selection, wet/dry mix |
| Delay | `AVAudioUnitDelay` | Delay time, feedback, wet/dry |
| Distortion | `AVAudioUnitDistortion` | Preset selection, wet/dry |
| Compression | `AVAudioUnitEffect` (via AudioUnit) | Threshold, ratio, attack, release |

**Signal Graph (v0.2):**
```
USB Input → Input Node → EQ → Reverb → Delay → Main Mixer → Output Node
```

---

### 4.3 Version 0.3 — Loop Station

**Objective:** Enable phrase looping and overdubbing.

| Feature | Description | Priority |
|---------|-------------|----------|
| Loop Recording | Capture input audio into an `AVAudioPCMBuffer`. | P0 |
| Loop Playback | Schedule buffer with `.loops` option on `AVAudioPlayerNode`. | P0 |
| Loop Start/Stop | Keyboard or UI controls to begin/end loop playback. | P0 |
| Overdub | Record a new loop while the previous loop plays. | P1 |
| Loop Length Detection | Automatically detect loop length or use fixed bars. | P1 |
| Metronome | Optional click track for timing reference. | P2 |
| Loop Clearing | Delete individual loops or clear all. | P2 |

**Loop Workflow:**
1. User presses **Record** to begin capturing audio.
2. User presses **Record** again to stop; buffer is retained.
3. Buffer is scheduled for infinite playback via `AVAudioPlayerNode`.
4. User enables **Overdub** to layer additional audio.
5. New recording is mixed with existing loop playback.

**Technical Implementation:**
```swift
// Pseudocode: Loop recording and playback
func startLoopRecording() {
    let format = engine.inputNode.outputFormat(forBus: 0)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames)
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { audioBuffer, time in
        // Append audioBuffer to recording buffer
    }
}

func playLoop(buffer: AVAudioPCMBuffer) {
    playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    playerNode.play()
}
```

---

### 4.4 Version 0.4 — Multitrack Recorder

**Objective:** Support multiple tracks with independent recording, playback, and mixing.

| Feature | Description | Priority |
|---------|-------------|----------|
| Track Abstraction | `Track` class encapsulating player, mixer, effects, and file reference. | P0 |
| Multiple Tracks | Support at least 4 simultaneous tracks. | P0 |
| Per-Track Mixer | Independent volume and pan via `AVAudioMixerNode`. | P0 |
| Per-Track Effects | Optional effect chain per track. | P1 |
| Overdub Recording | Record new track while existing tracks play back. | P0 |
| Track Muting | Mute individual tracks during playback. | P1 |
| Track Solo | Solo individual tracks. | P1 |
| Recording to Disk | Write recorded audio to `AVAudioFile` for persistence. | P0 |
| Track Deletion | Remove tracks and free resources. | P2 |

**Track Architecture:**
```
┌─────────────────────────────────────────────────────────────┐
│                         Track                                │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐ │
│  │ Player Node  │ → │ Effects Chain │ → │ Track Mixer Node │ │
│  │ (Playback)   │   │ (Optional)    │   │ (Vol/Pan)        │ │
│  └──────────────┘   └──────────────┘   └──────────────────┘ │
│                                                              │
│  ┌──────────────┐                                           │
│  │ Audio File   │ ← Recording destination                    │
│  │ Reference    │                                           │
│  └──────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
```

**Full Signal Graph (v0.4):**
```
Live Input ──> Input FX ──> Live Mixer ──────────────────────┐
                                                             │
Track 1 Player ──> Track 1 FX ──> Track 1 Mixer ────────────┤
                                                             │
Track 2 Player ──> Track 2 FX ──> Track 2 Mixer ────────────┼──> Main Mixer ──> Output
                                                             │
Track 3 Player ──> Track 3 FX ──> Track 3 Mixer ────────────┤
                                                             │
Track 4 Player ──> Track 4 FX ──> Track 4 Mixer ────────────┘
```

**Recording Workflow:**
1. User selects an empty track for recording.
2. User presses **Record**; input is routed to the selected track's recording file.
3. Existing tracks continue playback through their respective mixer nodes.
4. User presses **Stop**; recorded file is finalized and assigned to the track's player node.
5. Track can now be played back alongside others.

---

### 4.5 Version 1.0 — Minimal DAW

**Objective:** Provide a complete, packaged application with project persistence and a graphical interface.

| Feature | Description | Priority |
|---------|-------------|----------|
| Project Save | Serialize track data, effects settings, and file references to disk. | P0 |
| Project Load | Restore a saved project with all tracks and settings. | P0 |
| SwiftUI Interface | Native macOS UI with track list, transport, and mixer. | P0 |
| Transport Controls | Play, stop, record, rewind, and loop toggle. | P0 |
| Waveform Display | Visual representation of recorded audio per track. | P1 |
| Mixdown Export | Render all tracks to a single stereo audio file. | P1 |
| Audio Import | Load external audio files into tracks. | P1 |
| Preferences | Configure default devices, buffer size, and sample rate. | P2 |

**Project File Format (Proposed):**
```json
{
  "version": "1.0",
  "sampleRate": 48000,
  "tracks": [
    {
      "id": "track-1",
      "name": "Lead Synth",
      "audioFile": "tracks/track-1.wav",
      "volume": 0.8,
      "pan": 0.0,
      "muted": false,
      "solo": false,
      "effects": [
        { "type": "reverb", "preset": "mediumHall", "wetDryMix": 30 }
      ]
    }
  ],
  "masterVolume": 1.0
}
```

---

## 5. Technical Architecture

### 5.1 Core Components

| Component | Responsibility |
|-----------|----------------|
| `AudioEngine` | Manages AVAudioEngine lifecycle, graph construction, and real-time audio flow. |
| `DeviceManager` | Enumerates CoreAudio devices, switches default input, restores on exit. |
| `Track` | Encapsulates player node, mixer node, effects chain, and audio file reference. |
| `LoopRecorder` | Captures input to buffer, manages loop scheduling and overdubbing. |
| `TrackRecorder` | Writes input audio to disk via AVAudioFile with deferred I/O. |
| `EffectsChain` | Constructs and manages AVAudioUnitEffect nodes. |
| `LevelMeter` | Computes peak/RMS levels from audio buffers for display. |
| `ProjectManager` | Serializes and deserializes project state. |
| `TransportController` | Coordinates play, stop, record, and loop states across tracks. |

### 5.2 Key Audio APIs

| Feature | API | Notes |
|---------|-----|-------|
| Engine Graph | `AVAudioEngine` | Central audio graph manager. |
| Input Capture | `installTap(onBus:bufferSize:format:block:)` | Real-time input tap. |
| Playback | `AVAudioPlayerNode` | Sample-accurate playback. |
| Looping | `scheduleBuffer(_:at:options:completionHandler:)` | Use `.loops` option. |
| Recording | `AVAudioFile` | Write PCM data to disk. |
| Effects | `AVAudioUnitEffect` | Base class for Apple effects. |
| EQ | `AVAudioUnitEQ` | Multi-band equalizer. |
| Reverb | `AVAudioUnitReverb` | Preset-based reverb. |
| Delay | `AVAudioUnitDelay` | Configurable delay. |
| Mixing | `AVAudioMixerNode` | Volume, pan, and routing. |
| Device Control | CoreAudio `AudioObjectSetPropertyData` | Switch default devices. |

### 5.3 Real-Time Safety Requirements

Audio callbacks operate on a high-priority thread with strict constraints:

| Constraint | Rationale |
|------------|-----------|
| No Memory Allocation | Allocation can block, causing dropouts. |
| No File I/O | Disk access is unpredictable and slow. |
| No Locks or Semaphores | Blocking on a mutex can stall the audio thread. |
| No Objective-C Messaging | Dynamic dispatch overhead is unacceptable. |
| Pre-Allocated Buffers | All buffers must be allocated before audio starts. |

**Mitigation Strategies:**
- Use `os_unfair_lock` or lock-free ring buffers for inter-thread communication.
- Defer file writes to a separate dispatch queue.
- Pre-allocate all `AVAudioPCMBuffer` objects during setup.
- Use `AVAudioEngine`'s manual rendering mode for offline processing if needed.

### 5.4 Latency Considerations

| Source | Typical Latency | Mitigation |
|--------|-----------------|------------|
| Input Buffer | 128–512 samples | Use smallest stable buffer size. |
| Effect Processing | 0–10 ms | Limit effect chain length. |
| Output Buffer | 128–512 samples | Match input and output buffer sizes. |
| Total Round-Trip | 5–20 ms | Acceptable for live monitoring. |

**Target:** < 10 ms round-trip latency for live monitoring.

---

## 6. Technical Stack

### 6.1 Prototype Stack (v0.1–v0.4)

| Layer | Technology | Rationale |
|-------|------------|-----------|
| Language | Swift 5.9+ | Native macOS, modern concurrency, type safety. |
| Audio | AVFoundation / AVAudioEngine | High-level API, well-documented, Apple-supported. |
| UI (Early) | CLI / Keyboard | Rapid iteration, no UI overhead. |
| UI (Later) | SwiftUI | Native, declarative, modern. |
| Effects | Apple `AVAudioUnitEffect` | Built-in, no dependencies. |
| Packaging | SwiftPM + `.app` bundle script | Reproducible builds, standard distribution. |

### 6.2 Optional Future Stack

| Layer | Technology | Rationale |
|-------|------------|-----------|
| Effects | AudioKit | Richer effects, synthesis, sequencing. |
| File Formats | SFBAudioEngine | Advanced format support (FLAC, Ogg, etc.). |
| Cross-Platform | Rust + `cpal` + `coreaudio-rs` | Potential Windows/Linux support. |
| Plugin Hosting | AUv3 | Host third-party Audio Units. |

### 6.3 Development Environment

| Tool | Purpose |
|------|---------|
| Xcode 15+ | Primary IDE, debugging, profiling. |
| SwiftPM | Dependency management, build automation. |
| Instruments | CPU, memory, and audio profiling. |
| Git | Version control. |
| Platypus | Quick `.app` packaging for early builds. |

---

## 7. Development Roadmap

### Phase 1 — Stabilize Monitor (v0.1)

**Duration:** 1–2 weeks

| Task | Deliverable |
|------|-------------|
| Refactor `monitor.swift` into `AudioEngine` class | Reusable engine component |
| Extract device management into `DeviceManager` | Clean device switching |
| Implement `LevelMeter` utility | Peak level display |
| Add error handling and user feedback | Clear error messages |
| Create SwiftPM package structure | Buildable project |
| Write `.app` packaging script | Distributable application |

**Milestone:** A stable, packaged pass-through monitor with level metering.

---

### Phase 2 — Effects Chain (v0.2)

**Duration:** 2–3 weeks

| Task | Deliverable |
|------|-------------|
| Implement `EffectsChain` class | Modular effect insertion |
| Integrate `AVAudioUnitEQ` | 3-band EQ |
| Integrate `AVAudioUnitReverb` | Reverb with presets |
| Integrate `AVAudioUnitDelay` | Delay with feedback |
| Add keyboard controls for effect parameters | CLI parameter adjustment |
| Profile CPU usage and latency | Performance baseline |

**Milestone:** Real-time effects processing with configurable chain.

---

### Phase 3 — Loop Station (v0.3)

**Duration:** 2–3 weeks

| Task | Deliverable |
|------|-------------|
| Implement `LoopRecorder` class | Buffer-based loop capture |
| Schedule loops with `AVAudioPlayerNode` | Infinite loop playback |
| Add loop start/stop controls | Keyboard or CLI commands |
| Implement overdub mode | Layered loop recording |
| Add basic metronome | Timing reference |
| Test loop timing accuracy | Verify sample-accurate looping |

**Milestone:** Functional loop station with overdubbing.

---

### Phase 4 — Multitrack Recorder (v0.4)

**Duration:** 3–4 weeks

| Task | Deliverable |
|------|-------------|
| Implement `Track` class | Encapsulated track abstraction |
| Create `TrackRecorder` for disk writing | Persistent audio recording |
| Build multi-track signal graph | Independent track routing |
| Add per-track volume and pan | Basic mixing |
| Implement overdub recording | Record while playing existing tracks |
| Add track mute/solo | Mixing controls |
| Test multi-track playback | Verify synchronization |

**Milestone:** Multitrack recording and playback with overdubbing.

---

### Phase 5 — UI and Packaging (v1.0)

**Duration:** 4–6 weeks

| Task | Deliverable |
|------|-------------|
| Design SwiftUI interface | Native macOS UI |
| Implement transport controls | Play, stop, record, loop |
| Add track list view | Track management |
| Add mixer view | Volume, pan, mute, solo |
| Implement waveform display | Visual audio representation |
| Build project save/load | JSON-based persistence |
| Implement mixdown export | Stereo file rendering |
| Add audio import | Load external files |
| Code signing and notarization | Distribution-ready `.app` |

**Milestone:** Complete, packaged application with GUI.

---

## 8. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Audio dropouts | Medium | High | Real-time-safe callbacks, pre-allocated buffers, lock-free communication. |
| Scope creep | High | Medium | Strict adherence to version milestones; defer non-essential features. |
| Latency too high | Medium | High | Minimize effect chains, use small buffer sizes, profile regularly. |
| Multi-device limitations | Medium | Medium | Document Aggregate Device requirement; support sequential recording. |
| Dependency bloat | Low | Medium | Start with Apple APIs; add AudioKit only when necessary. |
| Packaging complexity | Low | Low | Use Platypus for early builds; SwiftPM for release. |
| Permission issues | Medium | Low | Clear documentation; prompt for microphone access early. |
| Code signing issues | Medium | Medium | Automate signing; test notarization early. |

---

## 9. Success Criteria

The project is considered successful when a user can:

1. **Connect** a USB audio instrument to their Mac.
2. **Hear** the instrument through the Mac with less than 10 ms latency.
3. **Add** at least two real-time effects (e.g., reverb and delay).
4. **Record** a loop and hear it repeat seamlessly.
5. **Overdub** a second layer while the first loop plays.
6. **Record** a second track while the first plays back.
7. **Mix** tracks with independent volume and pan controls.
8. **Save** a project and reload it with all settings intact.
9. **Export** a stereo mixdown of the project.
10. **Launch** the application as a standard macOS `.app`.

---

## 10. Open Questions

| # | Question | Decision Needed By |
|---|----------|-------------------|
| 1 | Should the first UI be CLI, keyboard-driven, or SwiftUI? | Phase 1 |
| 2 | Which effects are essential for v0.2? | Phase 2 |
| 3 | Should looping be bar-synced with a metronome? | Phase 3 |
| 4 | What audio file format should recordings use? (WAV, AIFF, CAF) | Phase 3 |
| 5 | Is cross-platform support via Rust a real goal or optional? | Phase 5 |
| 6 | Should the app host AU plugins, or only built-in effects? | Phase 5 |
| 7 | How should projects be saved — JSON, plist, or custom format? | Phase 5 |
| 8 | Should the app support MIDI clock or sync? | Post-v1.0 |

---

## 11. Appendices

### Appendix A: Existing `monitor.swift` Capabilities

The current script provides:

- USB audio input device discovery by name.
- Default input device switching (with restoration on exit).
- Audio routing via `AVAudioEngine`: input → main mixer → output.
- Live peak level meter display.
- Clean Ctrl+C handling.

### Appendix B: Glossary

| Term | Definition |
|------|------------|
| **AVAudioEngine** | Apple's high-level audio graph API. |
| **AVAudioPlayerNode** | Node for sample-accurate audio playback. |
| **AVAudioPCMBuffer** | In-memory buffer for PCM audio data. |
| **AVAudioFile** | File reference for reading/writing audio. |
| **AVAudioUnitEffect** | Base class for audio effect nodes. |
| **Aggregate Device** | CoreAudio feature combining multiple audio devices. |
| **Overdub** | Recording new audio while existing audio plays. |
| **Round-Trip Latency** | Time from input capture to output playback. |

### Appendix C: Reference Materials

- Apple Developer Documentation: [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- Apple Developer Documentation: [AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode)
- Apple Developer Documentation: [Core Audio](https://developer.apple.com/documentation/coreaudio)
- AudioKit: [audiokit.io](https://audiokit.io)
- SFBAudioEngine: [github.com/sbooth/SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine)

---

**Document Version:** 1.0  
**Last Updated:** [Current Date]  
**Author:** [Project Lead]  
**Status:** Draft — Ready for Technical Review