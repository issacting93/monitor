# OP-XY Multitrack

The eight-track overdub recorder from the product plan, as a Swift package.

## Run it

```
cd OPXYMultitrack
swift run
```

If the build can't find the SDK, use the same prefix as your `monitor_ui.swift` build:
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run`.
To work in Xcode instead, open `Package.swift`. `swift test` needs full Xcode (XCTest isn't in the Command Line Tools).

Run from Terminal, the app uses Terminal's microphone permission, as `monitor_ui` did.

## State of this code

**It has not been compiled.** It was written without access to a Swift toolchain. Every file passes a
syntax parse, and the edit logic was traced by hand against the tests, but the type checker has not
seen it. Expect a first build to surface some errors; they should be small and local. Work through
them in this order, since each layer only depends on the ones above it:

1. `Model/` and `Tests/` (pure Foundation)
2. `Persistence/`, `Audio/CoreAudioDevices.swift`, `Audio/PeakCache.swift`
3. `Effects/`
4. `Audio/MixGraph.swift`, `Audio/AudioFiles.swift`, `Audio/AudioEngine.swift`
5. `Store/`, then `Views/`, then `App/`

Least certain at run time, most worth testing first:

- `Effects/EffectAudioUnit.swift` — the audio unit that hosts kernels. Add a Tape effect to a track and listen.
- Recording alignment in `AudioEngine.handleInput`. Run `Tools/latency_test.swift`, then record a click against the metronome and look at where it lands.
- Add-on bundle loading (`EffectRegistry.scanPlugins`, `PluginExample/`). The build recipe there is a starting point.

## What's here, by build-order step

| Step | Where |
|---|---|
| 1 Dry recording | `AudioEngine.record` taps the input before any effect or fader |
| 2 Model and project file | `Model/Project.swift`, `Persistence/ProjectPackage.swift` |
| 3 Playback engine | `Audio/MixGraph.swift`, `AudioEngine.play` (one start time for every player) |
| 4 Timeline | `Views/TimelineView.swift` |
| 5 Record to track | arm, metronome, count-in, latency offset in `AudioEngine` |
| 6 Editing, undo, fades | `Model/EditOps.swift`, `ProjectStore.perform`, fades in `MixGraph.schedule` |
| 7 Mixer, Apple effects, limiter | `MixGraph`, `Effects/AppleEffects.swift` |
| 8 Kernel effects | `Effects/EffectAudioUnit.swift`, `Effects/CharacterEffects.swift` |
| 9 Cycle, export, import | `AudioEngine.play`, `Audio/AudioFiles.swift` |

Step 10 (polish, credits) is not done.

## Decisions made while writing it

- **Changing a chain rebuilds that track's chain.** This was the open question. Rebuilding is the simple
  option; it works while playing but that track drops out for a moment. Parameter and bypass changes are live.
- **The four character effects are original, simple DSP, not ports.** They prove the plugin path. The
  Airwindows and EffeTune ports replace the body of `process()` in `CharacterEffects.swift`; keep the
  identifiers and saved projects pick up the new sound. Add their MIT notices when you do.
- **Clips are positioned in seconds.** The grid, snapping and metronome follow the tempo; recorded audio
  does not move if you change BPM afterwards.
- **A new take replaces what was under it** on the same track (`EditOps.clearRange`). Undo brings it back.
- **Monitoring is on by default only for an OP-XY input**, so a laptop mic can't feed back through speakers.
- **Autosave writes `project.json` two seconds after any change.** Audio files are written once.
- All audio in a project is stored as stereo 32-bit float WAV at the project's sample rate (48 kHz by
  default); imports are converted on the way in.

## Keys

Space play/stop · Return to start · R record / punch out · C cycle · M mute · S solo · I inspector ·
Delete remove · ⌘Z / ⇧⌘Z undo/redo · ⌘D duplicate · ⌘T split at playhead · ⌘+ / ⌘− zoom ·
⌘S save · ⌘O open · ⌘N new · ⌘E export WAV

Mouse: drag a clip to move it (up/down changes track), drag its edges to trim, drag the repeat icon in
its top-right corner to loop it. Hold ⌘ while dragging to ignore the grid. Click the ruler to move the
playhead, Option-drag the ruler to set the cycle range. Scroll to move along the timeline, ⌘-scroll to
zoom. Drop audio files on a lane to import. Double-click a knob to reset it.

## Not built yet

Takes and comping, automation, MIDI clock to the OP-XY, markers, time signatures other than 4/4 in the
UI, the node-patch view, parameter smoothing in the character effects, an aggregate device (the app
still switches the Mac's default input and restores it on quit), and a `.xyproj` document type (without
an app bundle, Finder shows a project as a folder).
