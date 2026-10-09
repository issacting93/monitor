# Project: Mac Audio Workstation Prototype  
**Working title:** Monitor++  
**Status:** Draft concept / technical planning document

## 1. Summary

We are building a lightweight macOS audio tool that starts as a USB audio pass-through utility and grows into a minimal DAW-like application for live monitoring, effects, looping, playback, and multitrack recording.

The original script, `monitor.swift`, lets a USB audio input such as an OP-XY play through the Mac’s current output while showing a live level meter. The long-term goal is to turn that foundation into a small, hackable music workstation inspired by the core workflows of GarageBand and Ableton Live — without trying to replace them.

## 2. Background

The current `monitor.swift` script:

- Finds a USB audio input device by name.
- Sets it as the Mac’s default input while running.
- Restores the previous default input on exit.
- Routes the input through `AVAudioEngine` to the current output.
- Displays a live peak level meter.
- Handles Ctrl+C cleanly.

It works as a focused utility. The next step is to expand the audio graph so the same engine can support effects, looping, playback, and recording.

## 3. Vision

Create a small, low-latency macOS audio workstation for solo musicians, tinkerers, and hardware users who want to:

- Monitor a USB instrument through the Mac.
- Add real-time effects.
- Capture loops quickly.
- Layer and overdub tracks.
- Play back a simple multi-track project.
- Package the result as a normal Mac `.app`.

The tool should feel immediate and live-oriented, not like a full production DAW.

## 4. Goals

### Primary Goals

1. **Pass-through monitoring** — Keep the original USB input → Mac output behavior.
2. **Real-time effects** — Insert EQ, reverb, delay, distortion, compression, etc.
3. **Looping** — Record a phrase and loop it immediately.
4. **Playback** — Play back recorded or imported audio.
5. **Multitrack recording** — Record multiple tracks, typically through overdubbing.
6. **Simple control surface** — Start with CLI/keyboard controls, later add SwiftUI.
7. **Packaging** — Ship as a macOS `.app` bundle.

### Secondary Goals

- Export mixed audio.
- Import common audio formats.
- Save and load projects.
- Basic metronome.
- MIDI clock or sync support later.
- Optional cross-platform path via Rust.

## 5. Non-Goals

- Replacing Ableton Live, Logic Pro, or GarageBand.
- Full VST/AU plugin hosting in the first version.
- Advanced MIDI sequencing and notation.
- Cloud collaboration.
- Mobile or web versions.
- Professional mastering tools.

## 6. Current State

The existing `monitor.swift` is a single-chain graph:

```
USB Input → AVAudioEngine inputNode → mainMixerNode → outputNode
```

It does not yet support:

- Effects insertion.
- Recording to disk.
- Looping.
- Multiple tracks.
- Playback.
- A GUI.

## 7. Target Feature Set by Version

### v0.1 — Stabilized Monitor

- Pass-through audio.
- Level meter.
- Default input switching.
- Clean shutdown and restore.
- Packaged as `.app`.

### v0.2 — Effects Chain

- Insert Apple `AVAudioUnitEffect` nodes.
- Example chain: input → EQ → reverb → delay → output.
- Live parameter control later.

### v0.3 — Loop Station

- Record a phrase into an `AVAudioPCMBuffer`.
- Loop it with `AVAudioPlayerNode`.
- Overdub a second loop.
- Start/stop loop playback.

### v0.4 — Multitrack Recorder

- Multiple track objects.
- Per-track mixer node.
- Record live input to a track.
- Play back existing tracks while recording a new one.
- Basic track volume and pan.

### v1.0 — Minimal DAW

- Project save/load.
- Simple SwiftUI interface.
- Track list, transport controls, waveform view.
- Export mixdown.

## 8. Architecture Overview

### Core Signal Graph

```
Live Input ──> Input FX ──> Live Mixer ──┐
                                        │
Track 1 Player ──> Track 1 FX ──> Mixer 1 ──> Main Mixer ──> Output
Track 2 Player ──> Track 2 FX ──> Mixer 2 ──> Main Mixer ──> Output
Track 3 Player ──> Track 3 FX ──> Mixer 3 ──> Main Mixer ──> Output
```

Each track owns:

- An `AVAudioPlayerNode` for playback.
- An `AVAudioMixerNode` for volume and pan.
- Optional effect nodes.
- A recording file or buffer reference.

The live input can be routed directly to the main mixer or through its own effects chain.

### Key Audio APIs

| Feature | API |
|---|---|
| Engine graph | `AVAudioEngine` |
| Input capture | `installTap(onBus:)` |
| Playback | `AVAudioPlayerNode` |
| Looping | `scheduleBuffer(..., options: .loops)` |
| Recording | `AVAudioFile` + tap callback |
| Effects | `AVAudioUnitEffect`, AudioKit, SignalKit |
| Device control | CoreAudio `AudioObjectSetPropertyData` |

## 9. Technical Stack

### Preferred Prototype Stack

- **Language:** Swift
- **Audio:** AVFoundation / AVAudioEngine
- **UI:** CLI first, SwiftUI later
- **Effects:** Apple built-in effects first; AudioKit or SignalKit later
- **Packaging:** Platypus or SwiftPM + `.app` bundle script

### Optional Future Stack

- **Rust + `cpal` + `coreaudio-rs`** for cross-platform or low-level control.
- **AudioKit** for richer effects and synthesis.
- **SFBAudioEngine** for advanced file format support.

## 10. Key Technical Challenges

| Challenge | Description |
|---|---|
| Real-time safety | Audio callbacks must not allocate, lock, or perform file I/O. |
| Latency | Effects and buffering increase round-trip delay. |
| Clock sync | Input and output streams are not perfectly aligned. |
| Multi-device recording | AVFoundation cannot record multiple hardware inputs simultaneously without an Aggregate Device. |
| File writing | Recording taps must defer disk writes to a separate queue. |
| Permissions | Microphone access requires user approval. |
| Code signing | Distribution needs signing and notarization. |

## 11. Roadmap

### Phase 1 — Stabilize Monitor

- Refactor `monitor.swift` into reusable engine components.
- Add clean error handling.
- Package as `.app`.

### Phase 2 — Effects

- Insert Apple effect nodes.
- Add a simple effect chain configuration.
- Test CPU load and latency.

### Phase 3 — Looping

- Record input into a buffer.
- Schedule buffer with `.loops`.
- Add start/stop controls.

### Phase 4 — Multitrack

- Create `Track` abstraction.
- Add per-track mixer and player nodes.
- Record overdubs while playing existing tracks.
- Add basic mixing controls.

### Phase 5 — UI and Packaging

- Build a minimal SwiftUI interface.
- Add transport controls.
- Save/load projects.
- Export mixdown.

## 12. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Audio dropouts | Use lock-free buffers and real-time-safe callbacks. |
| Too much scope | Focus on live looping and overdubbing first. |
| Latency too high | Keep effect chains short; use low buffer sizes. |
| Multi-device limits | Use Aggregate Devices or record sequentially. |
| Dependency bloat | Start with Apple APIs before adding AudioKit. |
| Packaging complexity | Use Platypus for early builds, SwiftPM for release. |

## 13. Open Questions

1. Should the first UI be CLI, keyboard-driven, or SwiftUI?
2. Which effects are essential for v0.2?
3. Should looping be bar-synced with a metronome?
4. What audio file format should recordings use?
5. Is cross-platform support via Rust a real goal or optional?
6. Should the app host AU plugins, or only built-in effects?
7. How should projects be saved — JSON, plist, or a custom format?

## 14. Success Criteria

The project is successful when a user can:

- Plug in a USB instrument.
- Hear it through the Mac with low latency.
- Add at least two real-time effects.
- Record a loop and hear it repeat.
- Record a second track while the first plays.
- Save and reload a simple project.
- Launch the tool as a normal macOS `.app`.

## 15. Next Steps

1. Refactor `monitor.swift` into an `AudioEngine` class and a `Track` class.
2. Prototype a single loop using `AVAudioPlayerNode` and `AVAudioPCMBuffer`.
3. Add a recording tap that writes to an `AVAudioFile`.
4. Test overdubbing: play loop 1 while recording loop 2.
5. Evaluate AudioKit for effects and sequencing.
6. Package the first working version as a `.app`.