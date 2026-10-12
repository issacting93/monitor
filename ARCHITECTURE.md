# TAPE 08 — Functionality & System Architecture

An app for monitoring, recording and looping the **Teenage Engineering OP-XY** over USB audio, with a
multitrack tape-style looper and a modular effects chain. Runs on **macOS** and **iPad** from one
shared audio core.

- **Platforms:** macOS 14.0+ (arm64); iPadOS 17.0+ (iPad only)
- **UI:** SwiftUI (separate macOS and iPad view layers)
- **Audio:** AVFoundation (`AVAudioEngine`) + CoreAudio HAL / `AVAudioSession` (device layer) +
  CoreMIDI (track follow)
- **Source:** 25 files in `Sources/`, ~8,530 lines (shared core + both UIs)
- **Build paths:** `package.sh` (macOS, head-less `swiftc`), `Tape08/` (macOS Xcode project),
  `Tape08iPad/` (iPad Xcode project)

This document describes *what the app does* and *how it is built*, as it exists today. The
developer-facing "how do I build/run it" lives in [README.md](README.md); review findings and
open work live in [to_fix.md](to_fix.md); product intent lives in
[`OP-XY Monitor multitrack product plan.md`](OP-XY%20Monitor%20multitrack%20product%20plan.md).

---

## 1. Feature inventory

### 1.1 Device I/O and monitoring
- Enumerates all CoreAudio input/output devices (name + channel counts), auto-selects a device
  whose name contains "XY"/"OP" as the default input, and the current system output as default out.
- Live monitoring: input is routed through the effect chain to the output with input/output gain
  and a master peak limiter.
- The engine points its own input AUHAL at the selected device **without** changing the system
  default input, so other apps keep their input.
- Warns about feedback when the built-in mic and built-in speakers are both in play.

### 1.2 Metering
- Post-FX stereo RMS meter with smoothing, peak-hold, and a dB readout.
- A 200-bucket scrolling waveform for the Monitor view.
- Per-track level meters (8 tracks).
- Metering is render-thread safe: taps publish raw levels into a lock-guarded snapshot; all
  smoothing/peak-hold happens on a 60 Hz main-thread timer.

### 1.3 Multitrack looper
- **8 tracks**, each an ordered list of **clips** ("takes"); multiple takes layer per track.
- Per track: play/stop, volume, pan, mute, solo, level meter.
- **Loop** playback (repeat forever) or **one-shot** (play once, stop) — toggled globally.
- Play-all / stop-all, per-track loop, selected-track model (drives FX chain, recording, edits).
- **Seek** — dragging the bar ruler places playback at that fraction of each track's own clip;
  while stopped the position is parked and PLAY starts from it. Stop returns to the start.
- Playhead progress per track, driving the timeline playhead and scroll-follow.

### 1.4 Recording
- Captures the **dry** (pre-FX) signal to a WAV under the save location.
- Optional **count-in** (0 / 1 / 2 / 4 bars) before recording starts. Pressing REC again re-arms it
  from bar 1; STOP aborts it.
- Elapsed-time display; on stop the take becomes a new clip on the selected track.
- Recording/f FX: takes are dry by design; effects are heard live but not printed.

### 1.5 Metronome & tempo
- Sample-accurate click scheduling (queued ~2 s ahead by frame, not by timer).
- Accent on every 4th beat; independent click volume; enable toggle.
- **Tap tempo** (8-tap average, 40–300 BPM clamp); manual ± 1 BPM.

### 1.6 Clip editing & export
- **Trim** editor with draggable in/out handles and a waveform preview.
- **Split at playhead**, **duplicate clip**, **clear all**.
- **Import** (file panel + drag-and-drop onto a lane) and **export** a track to WAV.
- **Mixdown** ("bounce") of all audible tracks to a single WAV (equal-power pan, tanh soft-clip).
- **Undo/redo**, 30 deep, with gesture debouncing for slider drags.

### 1.7 Timeline
- Zoom 0.5×–4×, playhead follow, bar ruler, and a loop-region indicator.

### 1.8 Modular effects chain
- A **global chain** applied to the live input signal, built from `EffectModule` descriptors.
- 13 built-in modules:

  | Module | Kind | Category |
  |--------|------|----------|
  | EQ (3-band shelf/peak) | Apple `AVAudioUnitEQ` | EQ & Filter |
  | Reverb | Apple `AVAudioUnitReverb` | Space |
  | Delay | Apple `AVAudioUnitDelay` | Time |
  | Tape Saturation | custom kernel (Airwindows ToTape6 port) | Saturation |
  | Gain | custom kernel | Utility |
  | Distortion | custom kernel (tanh + tone) | Saturation |
  | Chorus | custom kernel (LFO delay) | Modulation |
  | Compressor | custom kernel (env follower) | Dynamics |
  | Flanger | custom kernel (short delay + feedback) | Modulation |
  | Phaser | custom kernel (6-stage all-pass) | Modulation |
  | Tremolo | custom kernel (LFO amplitude) | Modulation |
  | Bitcrusher | custom kernel | Lo-fi |
  | Noise Gate | custom kernel | Dynamics |

- Add / remove / reorder / bypass; each module's parameters auto-render as knobs.
- **Presets**: built-in (`Clean`, `Warm`, `Ambient`, `Lo-Fi`) plus user presets, stored as JSON in
  `~/Library/Application Support/Tape08/Presets/`.

### 1.9 Project persistence
- `.xyproj` **directory package**: `project.json` manifest + `Audio/Track NN/*.wav` copies.
- Saves session state: BPM, metronome, quantize, count-in, loop, master/input volume, selected
  track, per-track clips/volume/pan/mute/solo, the effect chain, and limiter state.
- Relative clip paths; missing files are reported but non-fatal.

### 1.10 Keyboard shortcuts

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| Space | Play / stop all | ⌘Z / ⌘⇧Z | Undo / Redo |
| R | Record selected track | ⌘S / ⌘⇧S | Save / Save As |
| M / S | Mute / Solo selected | ⌘O | Open project |
| 1–8 | Select track | ⌘E | Export selected track |
| , | Toggle metronome | ⌘T | Split clip at playhead |
| Tab | Arrange ⇄ Monitor view | ⌘D | Duplicate the selected clip |
| F | Toggle playhead follow | ⌘+ / ⌘− | Timeline zoom in / out |
| Return | Stop all | ⌘1–⌘8 | Select take N on that track |

---

## 2. Architecture

### 2.1 Process & UI spine

```
@main MonitorApp (App.swift)
 └─ ContentView                      @StateObject AudioManager
     ├─ TopBar                        brand · view tabs · status · device pickers · FX/Settings
     ├─ HStack
     │   ├─ SettingsPanel   (optional, w 260)
     │   ├─ SideEffectsPanelView (optional, w 400)   ← FX chain editor
     │   └─ ArrangeView  ── ArrangeHeadUnit + LoopGridView (+ TrimEditorView)
     │       or MonitorView
     └─ TransportBar                  transport · tempo · count-in · IN/OUT · limiter
      · KeyboardShortcutMonitor (NSEvent local monitor)
      · AppDelegate (quit on last window close)
```

`KeyboardShortcutMonitor` installs a local key-down monitor (ignored while a text field is focused)
and dispatches to `AudioManager` on the main queue.

### 2.2 The facade pattern (the core design)

`AudioManager` is the single `ObservableObject` the whole UI talks to.

- It **owns every `@Published` property** and every one-line forwarder the views call.
- Behaviour lives in eight **cohesive controllers**, each a plain `final class` (not `Observable`)
  holding a private `unowned let manager: AudioManager`.
- Controllers mutate published state **through** `manager`, so `objectWillChange` fires exactly as
  it did when this was a single ~5,700-line file.
- **Star topology**: controllers never reference each other directly — only via `manager.<peer>`.
- `AudioManager.init` force-touches every controller (`_ = metronome; …`) so none can lazily
  initialise from a timer or the audio thread.

```
                         AudioManager  (ObservableObject, @Published state, forwarders)
                         ▲   ▲   ▲   ▲   ▲   ▲   ▲   ▲
        unowned back-ref │   │   │   │   │   │   │   │
   ┌──────────┬──────────┴───┴───┴───┴───┴───┴───┴───┴──────────┐
   │          │          │       │        │        │      │      │
Metronome  Device   EffectsChain Transport Meter Recording Project Engine
```

| Controller | Owns (private state) | Published state it writes |
|------------|----------------------|---------------------------|
| `MetronomeController` | click buffers, player/mixer nodes, refill timer, tap history | `metronome*`, `tapTempoFlash` |
| `DeviceController` | CoreAudio listeners, CoreMIDI client/port | `inputDevices`, `outputDevices`, `selectedInputID/OutputID`, `selectedTrack` (MIDI) |
| `EffectsChainController` | instantiated chain nodes, preset dir | `liveChain`, `presetNames`, `showPresetSave`, `presetSaveName`, `status` |
| `TransportController` | player/mixer nodes, decoded buffers, play generations & seek offsets, undo/redo stacks | `tracks`, `isPlaying`, `seekFraction`, `projectDirty`, trim state, `bounceStatus` |
| `MeterController` | locked meter snapshot, display timer, taps, smoothing state | `live.meters.*`, `live.trackMeters.levels`, `live.playhead.trackProgress` |
| `RecordingController` | `AVAudioFile` handle, dry tap, count-in/take timers | `isRecording`, `countingIn`, `recordingDuration`, `recordings`, `tracks` |
| `ProjectController` | — | `projectURL`, `projectName`, `projectDirty`, `status` |
| `EngineController` | `AVAudioEngine`, every node it builds, async-insert machinery | `isMonitoring`, `status`, `sampleRateString` |

### 2.3 Audio graph (`EngineController`)

Built fresh on every `startMonitoring()`:

```
inputNode ──▶ mainMixer (inputVolume) ──▶ dryTap ──▶ [Apple chain nodes] ──▶ [async kernel nodes] ──▶ liveMix ──▶ master ──▶ limiter ──▶ outputNode
   (pinned to                                        │                                                     │
    selected device)                                 │ (pre-FX tap → recording, dry)                       │ (post-FX tap → metering)
                                                     │
   track 1..8:  playerN ──▶ trackMixN ──▶ master     │
   metronome:   metPlayer ─▶ metMix ────▶ master     │
```

- **`dryTap`** is the pre-FX recording point — takes are captured without effects.
- **`liveMix`** is the post-FX metering point — meters show the effected output.
- **`master`** applies `volume × 0.6` (headroom), then the **limiter** (Apple `kAudioUnitSubType_PeakLimiter`,
  pre-gain 0, 12 ms attack, 50 ms decay) sits before the output.
- Per-track `playerN → trackMixN → master` provide per-track volume/pan/metering/playback.
- The metronome has its own `metPlayer → metMix → master`.
- **Device routing** (`AudioDeviceProviding.applyEngineDevices(input:output:to:)`): the engine has a
  single shared AUHAL, so it takes **one** device. On macOS, when the selected input and output
  differ, the provider builds a **private aggregate device** (input + output, input as clock master)
  and pins the AUHAL to that — pinning it straight at a mic-only input would leave no usable output
  (silence). A routing failure is returned as a reason string and shown in the top bar.
  `releaseEngineDevice()` tears the aggregate down on `stop()`, *after* `engine.stop()`, so it is
  never destroyed under a running unit. On iPad the `AVAudioSession` is configured + activated
  **first** (`prepareForEngineStart()`, at the top of `start()`), then the session's preferred input
  is set — the session must be active before `inputNode.inputFormat` is read, or the format is
  0 Hz / 0 channels.

**Why the two-phase chain build.** Apple effect nodes (`makeAudioNode`) are attached synchronously
during graph construction. Custom-kernel modules cannot be: `AVAudioUnit.instantiate` is
asynchronous, and an `AUAudioUnit` subclass cannot receive init arguments. So their factory and
sample rate are passed through process-wide statics (`EffectAudioUnit.pendingKernelFactory` /
`pendingSampleRate`) and instantiated one at a time **after** `eng.start()`. At most one
instantiation is ever in flight process-wide, and each graph build carries an epoch so a completion
from a torn-down or restarted graph is discarded (guarded by `pumpKernelQueue` — see
`to_fix.md` §8.9).

### 2.4 Modular effect system (`EffectsCore.swift`, `EffectsKernels.swift`)

```
EffectModule  ── descriptor: identifier, displayName, category, parameters[],
   │                          makeKernel(Double)->AudioEffectKernel     (custom DSP)
   │                          makeAudioNode()->AVAudioNode             (Apple AU)
   │                          applyParameter(AVAudioNode, id, Float)   (set a param)
   ▼
EffectRegistry (singleton)  ── id → EffectModule; registerBuiltIns()

ChainSlot { id: UUID, moduleID, enabled, parameters:[String:Float] }

AudioEffectKernel (protocol)  ── init(sampleRate:) · process([Float*], frames:) ·
                                 setParameter(id, value:) · reset()

EffectAudioUnit : AUAudioUnit  ── hosts one kernel as an in-process AU; its
                                 internalRenderBlock pulls input then calls
                                 kernel.process(...) on the render buffers
```

- The chain is a **fixed linear list** (`liveChain`) of `ChainSlot`s, processed in order. There is
  no port/node graph.
- Each module's `parameters` drive the UI automatically: the FX panel builds one `ArcKnob` per
  `EffectParameter`, and writes go through `EffectsChainController.paramBinding`.
- Presets serialise the chain to `[ProjectChainSlotData]` (module id + enabled + params) and back.

### 2.5 Threading model

| Thread | Responsibilities |
|--------|------------------|
| **Main** | All SwiftUI, all controller logic, engine build/teardown, **all `@Published` writes**, the 60 Hz meter/display timer, `saveLocation`/panels |
| **Render (audio)** | Meter taps (RMS into the locked snapshot), recording tap (`AVAudioFile.write`), and each `EffectAudioUnit.internalRenderBlock` → `kernel.process` |
| **Background (`.userInitiated`)** | Track buffer decode (`TransportController.loadTrackBuffer`), project clip peak decode (`ProjectController.performLoad`) |

Synchronisation today: one `OSAllocatedUnfairLock`-guarded meter snapshot (`MeterController`).
Everything else that crosses threads — kernel parameters, the pending-instantiation statics — is
**unsynchronised** (called out in the review).

### 2.6 Persistence & files on disk

Roots come from `PlatformPaths` (`tracksRoot`, `presetsDir`). On macOS the live takes root is
`AudioManager.saveLocation`, which starts at `PlatformPaths.initialSaveLocation =
SaveLocation.restore() ?? tracksRoot`, and is re-pointed whenever the user picks a folder:

```
saveLocation / tracksRoot       macOS: <user-chosen folder>/Tracks
 └─ Track NN/                          (fallback: <container>/Documents/OP-XY Monitor/Tracks)
                                iOS:  <container>/Documents/OP-XY Monitor/Tracks
      take_YYYY-MM-DD_HH-mm-ss.wav, trim_…, split_A/B_…, <imported>

presetsDir                      macOS: ~/Library/Application Support/Tape08/Presets
                                iOS:  <container>/Library/Application Support/Tape08/Presets
      *.json (chain presets)

<project>.xyproj/               (a directory package — macOS only for now)
 ├─ project.json                ProjectData (Codable)
 └─ Audio/Track NN/<clip>.wav   copies of referenced clips
```

**Sandbox & the save folder.** The macOS Xcode build is sandboxed (Mac App Store requirement), so
it cannot write a hardcoded `~/Desktop` path. `SaveLocation` (`SaveLocation.swift`, macOS-only)
handles this: a first-run sheet asks the user to choose a folder, the choice is persisted as a
**security-scoped bookmark** in `UserDefaults` (`saveLocationBookmark`) and re-resolved +
`startAccessingSecurityScopedResource()`-ed on every launch. The prompt is gated on
`SaveLocation.isSandboxed` (env `APP_SANDBOX_CONTAINER_ID`), so the unsandboxed `package.sh` build
skips it. Declining leaves the container `Documents` fallback. Project save/load and export use
`NSSavePanel`/`NSOpenPanel` (Powerbox grants access), so they need no bookmark.

`ProjectData` (`Models.swift`) is the versioned manifest (v1). Clip paths are stored **relative** to
the package so a project is portable. On iPad the container is exposed to the Files app
(`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).

### 2.7 Data model (`Models.swift`)

- `AudioDevice` — id + name.
- `TrackClip` — url, duration, peaks, fade in/out (fades currently unused — see review).
- `TrackInfo` — id, clips, volume, pan, muted, solo, isPlaying, loopProgress.
- `Recording` — a saved take's metadata (currently unread — see review).
- `ProjectClipData` / `ProjectTrackData` / `ProjectChainSlotData` / `ProjectData` — persistence DTOs.

### 2.8 Platform seam (macOS / iPad)

Everything platform-specific sits behind `#if os(...)` so the same `Sources/` compiles for both:

- **`AudioDeviceProviding`** (`AudioDeviceProviding.swift`) — the device-I/O interface:
  `prepareForEngineStart()`, `loadDevices()`, `applyEngineDevices(input:output:to:)`,
  `releaseEngineDevice()`, `currentOutputName`, `outputSelectionSupported`, and `startObserving(_:)`
  (emits `DeviceChange`). Two implementations:
  **`CoreAudioDeviceProvider`** (`DeviceIO_macOS.swift`, wrapping the `CoreAudioDevices` HAL helpers)
  and **`AVAudioSessionDeviceProvider`** (`DeviceIO_iOS.swift`, wrapping `AVAudioSession` plus
  route-change / interruption / media-services notifications). `DeviceController` holds the correct
  one in `io`; `EngineController` and the views reach it via `manager.device.io`.
- **`DeviceID`** (`Models.swift`) — `AudioDeviceID` on macOS, a synthetic `UInt32` (index into
  `availableInputs`) on iPad, so the rest of the code stays agnostic.
- **`PlatformPaths`** (`PlatformPaths.swift`) — `tracksRoot` / `presetsDir` (Desktop vs Documents /
  Application Support), plus `initialSaveLocation` (= `SaveLocation.restore() ?? tracksRoot` on
  macOS, else `tracksRoot`).
- **`SaveLocation`** (`SaveLocation.swift`, `[mac]`) — the sandboxed save-folder: `isSandboxed`,
  `needsSelection` (drives the first-run sheet), `restore()` / `remember(_:)` (security-scoped
  bookmark round-trip), and `fallback` (container `Documents`). See §2.6.
- **Entry + UI**: `App.swift` and `Views.swift` are `#if os(macOS)`; `App_iOS.swift` and
  `Views_iOS.swift` are `#if os(iOS)`. The shared view *primitives* (`ArcKnob`, `TrackFader`,
  `TempoControl`, `VerticalMeter`, `DotGridBackground`, `RetroButtonStyle`) stay unguarded in
  `Views.swift` and are reused by both UIs.
- **Deferred on iPad** (guarded macOS features that degrade to a status no-op): trim / split /
  duplicate, project save/load, export, mixdown, and output-device selection (iOS exposes no such
  API).

---

## 3. Build system

All three builds compile the **same** `Sources/` tree; the `#if os(...)` guards select what each
platform sees.

1. **`package.sh`** — compiles `Sources/*.swift` with `swiftc -O -parse-as-library` for
   `arm64-apple-macosx14.0`, then assembles `Tape 08.app` (Info.plist, generated `.icns` icon, and
   an `audio-input` entitlement) and ad-hoc codesigns it. This is the everyday macOS build.
2. **`Tape08/Tape08.xcodeproj`** — the macOS Xcode project (`PBXFileSystemSynchronizedRootGroup`
   pointed at `../Sources`); scheme `Tape08`, bundle id `com.tape08.app`. This is the **sandboxed**
   build: `Tape08/Tape08.entitlements` enables `app-sandbox`, `device.audio-input`,
   `files.user-selected.read-write`, `files.bookmarks.app-scope`; the AppIcon comes from
   `Assets.xcassets` (rendered by `Tools/make_icon.sh`).
3. **`Tape08iPad/Tape08iPad.xcodeproj`** — the iPad Xcode project (its own synchronized group at
   `../Sources`); scheme `Tape08iPad`, `TARGETED_DEVICE_FAMILY=2`, iOS 17.0, bundle id
   `com.tape08.app.ipad`, with `Tape08iPad/Info.plist` (mic usage, `UIBackgroundModes=[audio]`,
   Files sharing).

**Mac App Store pipeline.** `Tools/package-appstore.sh <TEAM_ID>` runs `xcodebuild … archive`
(`-destination generic/platform=macOS`) then `-exportArchive` with `ExportOptions.plist`
(`method = app-store-connect`, automatic signing); it needs a real Team ID / enrolled developer
account, so it is separate from the ad-hoc `package.sh`. Note `Tools/make_icon.sh` must render into
an exact-pixel `NSBitmapImageRep` (not `NSImage.lockFocus()`, which on a Retina Mac produces
2×-sized PNGs that actool then silently drops, leaving the app with no `Assets.car`).

Checks used throughout: `swiftc -typecheck -parse-as-library Sources/*.swift` for both
`arm64-apple-macosx14.0` and `arm64-apple-ios17.0-simulator`, plus `xcodebuild … -scheme Tape08
build` (macOS). Building the iPad target needs the iOS platform installed in Xcode.

---

## 4. File map

25 files. `[shared]` compiles on both platforms; `[mac]`/`[iOS]` are guarded.

| File | Lines | Platform | Responsibility |
|------|------:|----------|----------------|
| `Views.swift` | 2519 | shared primitives + `[mac]` screens | macOS SwiftUI views _and_ the shared view primitives |
| `TransportController.swift` | 1194 | shared | Playback, seek, undo/redo, clip editing & selection, mixdown |
| `EffectsKernels.swift` | 763 | shared | Custom DSP kernels |
| `EffectsCore.swift` | 503 | shared | Module/registry/chain/AU-host core + Apple module defs |
| `Views_iOS.swift` | 446 | `[iOS]` | iPad UI (top bar, track grid, monitor, transport, FX sheet) |
| `AudioManager.swift` | 358 | shared | The `ObservableObject` facade: published state + forwarders |
| `EngineController.swift` | 326 | shared | `AVAudioEngine` graph spine + async kernel insert |
| `ProjectController.swift` | 281 | shared (`[mac]` panels) | `.xyproj` save/load |
| `RecordingController.swift` | 286 | shared | Count-in + dry capture |
| `App.swift` | 248 | `[mac]` | macOS entry, `ContentView`, keyboard monitor, `AppDelegate` |
| `CoreAudioDevices.swift` | 217 | `[mac]` | CoreAudio HAL enumeration/selection helpers + the aggregate device for clock-master I/O |
| `MetronomeController.swift` | 198 | shared | Click scheduling + tap tempo |
| `EffectsChainController.swift` | 193 | shared | Chain mutations + presets |
| `MeterController.swift` | 168 | shared | Meter taps + display smoothing |
| `DeviceController.swift` | 132 | shared | Device discovery + MIDI track follow (delegates to `io`) |
| `Models.swift` | 131 | shared | Value types + `Codable` DTOs + `DeviceID` |
| `DeviceIO_iOS.swift` | 104 | `[iOS]` | `AVAudioSession` provider + route/interruption observers |
| `Support.swift` | 97 | shared | `UnfairLock`, `computePeaks`, unique filename stems, off-main helper |
| `DeviceIO_macOS.swift` | 87 | `[mac]` | `CoreAudioDeviceProvider` |
| `SaveLocation.swift` | 76 | `[mac]` | Sandboxed save-folder: security-scoped bookmark round-trip, first-run prompt state |
| `Theme.swift` | 49 | shared | Palette + layout constants |
| `AudioDeviceProviding.swift` | 47 | shared | The device-I/O protocol + `DeviceChange` |
| `PlatformPaths.swift` | 46 | shared | `tracksRoot` / `presetsDir` / `initialSaveLocation` per platform |
| `LiveState.swift` | 45 | shared | 60 Hz display state: the `MeterState` / `TrackMeterState` / `PlayheadState` publishers kept out of `@Published` |
| `App_iOS.swift` | 16 | `[iOS]` | iPad `@main` entry |

---

## 5. Known limitations & risks

Full detail and severities are in [to_fix.md §8](to_fix.md). Highest-impact **open** items:

- **UI-1** — the tape timeline clips when the settings + FX panels are open (fixed-width panels).
- **U1** — count-in is timed by a `Timer`, not aligned to the metronome grid.
- **U2** — only a track's **last** clip is decoded and played, so trim/duplicate/split on an earlier
  take are silent. Since 2026-10-12 a ruler drag parks a playhead that a *stopped* take can be split
  at, but it is placed on the ruler's span, not inside a lane, and is per-track-normalised.
- **H5** — a multichannel input interface meets a stereo graph on connect (no explicit downmix).
- **H6** — project load builds file paths from `project.json` without sanitising them.

Resolved on 2026-10-11 (see `to_fix.md` §8.9): **C1** (param/render race), **C2** (async-insert
epoch), **C3** (render-thread file writes), **C5** (double-engine leak on start-while-monitoring).
Remaining audio-thread note: the recording tap copies into a lock-guarded ring rather than a truly
lock-free one.

Resolved on 2026-10-12: **P1** (the 60 Hz display tick re-rendered the whole view tree — the display
state is now three focused publishers, `MeterState` / `TrackMeterState` / `PlayheadState`, and each
view observes only the one it draws; the grid's own body no longer re-evaluates on the tick).

Also resolved on 2026-10-12: **H1** (clip fades are applied), **H3** (session-created audio files are
swept once nothing references them, exempting anything an in-flight edit has written), **H4**
(built-in presets are seeded only when absent), **C4** (trim / split / duplicate / import /
record-stop / export / mixdown / project-save now run their file work off the main thread and apply
on it, guarded by an edit epoch and a trim-editor session token so superseded work is dropped rather
than landing on newer state) and **H2** (a take can be selected by clicking it in the timeline or
with ⌘1–⌘8, and TRIM / DUP / IMPORT / EXPORT act on the selection rather than always the last take;
`editTargetIndex` resolves it at use time and falls back to the last take, every surface that names
the current take resolves through it, and a selection the user moves mid-edit is not overwritten
when the edit lands. SPLIT stays confined to the last take — see **U2**).

Fixed after the first hardware run (2026-10-12), all three reported together and all three transport
lifecycle faults the compiler could not have caught: **STOP** stopped playback and the metronome but
not the recorder, so a pending count-in outlived the stop and began recording afterwards;
**REC** therefore found `countingIn` still set and fell straight through its count-in branch; and
there was **no seek control at all**. See `to_fix.md` §8.7 for the fix table — the seek is new
behaviour rather than a repair and is the one item still carrying unverified risk.

Stage 0d's clock-master change for aggregate I/O has **not** been run on hardware.

**iPad MVP:** monitoring, metering, loop recording, the effect chain, metronome and undo/redo work;
trim/split/duplicate, project save/load, export and mixdown are deferred (status no-op), and
output-device selection is a read-only label. The shared core is verified by compile **and link**
against the macOS and iOS SDKs, but the iPad app has **not** been run on hardware yet.

## 6. Glossary

- **Take / Clip** — one recorded or imported audio region on a track.
- **Chain slot** — one `EffectModule` instance in the global effect chain.
- **Kernel** — a custom DSP `AudioEffectKernel`; hosted as an in-process AU by `EffectAudioUnit`.
- **Dry** — pre-effects signal (what recording captures).
- **Bounce / Mixdown** — offline render of all audible tracks to one WAV.
