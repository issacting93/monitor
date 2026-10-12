# TAPE 08

A **USB-audio monitor, multitrack looper and effects rack** for the
[Teenage Engineering OP-XY](https://teenage.engineering/) (works with any audio input, but the
workflow is built around the OP-XY). Runs on **macOS** and **iPad**.

Plug the OP-XY in over USB, monitor it with a live effect chain, loop-record takes onto an 8-track
tape grid, and bounce a mixdown — with a retro hardware aesthetic.

![TAPE 08](UI%20Ideas/06-transport-header-reel-knobs.png)

---

## Requirements

- **macOS** 14.0 or later (arm64)
- **iPad** running iPadOS 17.0 or later (iPad only), with the iOS platform installed in Xcode
- An audio input device (the OP-XY appears as a USB audio device)
- Full Xcode (for the iPad target); `swiftc` from the command-line tools is enough for macOS

## Build & run — macOS

```bash
# Build the app bundle (./Tape 08.app) and sign it ad-hoc
./package.sh

# Launch
open "Tape 08.app"
```

`package.sh` compiles every file in `Sources/` into a single binary, assembles
`Tape 08.app` (Info.plist, generated icon, microphone entitlement) and codesigns it.

Prefer Xcode? Open `Tape08/Tape08.xcodeproj` and build the **Tape08** scheme. The project uses a
synchronized folder group pointing at `../Sources`, so both builds compile the same files.

## Build & run — iPad

Open `Tape08iPad/Tape08iPad.xcodeproj` in Xcode, set your signing team, and run the **Tape08iPad**
scheme on an iPad or the Simulator (if Xcode asks, install the iOS platform first). Bundle id
`com.tape08.app.ipad`, deployment target iPadOS 17.0, iPad only.

Both apps compile the **same** `Sources/` tree; the platform-specific code is selected with
`#if os(macOS)` / `#if os(iOS)`.

### First run

macOS (and iPadOS) will ask for **microphone access** — grant it.

- **macOS**: pick your OP-XY under **IN** and your speakers/headphones under **OUT**. Use headphones
  if you monitor a built-in mic, or you'll get feedback.
- **iPad**: the output route is chosen by the system (no OUT picker — it shows a read-only label);
  the OP-XY appears as an input automatically when connected over USB-C.

---

## Quick start

1. **Monitor** — press the headphone button (or it auto-starts on launch). The OP-XY's audio now
   flows through the effect chain to your output.
2. **Shape the sound** — open **FX** in the top bar, add/remove/reorder modules, and turn the knobs.
   Presets (`Clean`, `Warm`, `Ambient`, `Lo-Fi`) are in the preset bar.
3. **Loop-record** — select a track (**1–8**), pick a tempo (or tap it), press **REC** (**R**).
   Takes are captured **dry** (effects are monitored, not printed).
4. **Edit** — trim, split (**⌘T**) and duplicate (**⌘D**) takes; drag an audio file onto a lane to
   import.
5. **Export** — **MIXDOWN** bounces all audible tracks to one WAV; **⌘E** exports a single track.
6. **Save** — **⌘S** writes a portable `.xyproj` package.

---

## Features

- **Device I/O** — enumerate/select CoreAudio devices; monitor without hijacking the system input.
- **Live metering** — stereo RMS + peak-hold + dB, a scrolling waveform, and per-track meters.
- **Multitrack looper** — 8 tracks, multiple takes per track, per-track volume/pan/mute/solo,
  loop or one-shot playback, play-all.
- **Recording** — dry capture with an optional 1/2/4-bar **count-in**.
- **Metronome** — sample-accurate click with accents, volume control, and **tap tempo** (40–300 BPM).
- **Effects chain** — 13 built-in modules (EQ, Reverb, Delay, Tape Saturation, Gain, Distortion,
  Chorus, Compressor, Flanger, Phaser, Tremolo, Bitcrusher, Noise Gate) with saveable presets.
- **Editing** — trim, split at playhead, duplicate, import (panel or drag-and-drop), export,
  mixdown, undo/redo.
- **Timeline** — zoom (0.5×–4×), playhead follow, bar ruler, loop region.
- **Projects** — `.xyproj` packages (manifest + copied audio) with save/save-as/open.

## Platforms

One shared audio core (`Sources/`) powers both apps. The iPad build is a first **MVP** — the rest is
in progress.

| Capability | macOS | iPad (MVP) |
|---|---|---|
| Live monitoring, meters, waveform, in/out gain | ✅ | ✅ |
| 8-track loop record / play, mute / solo, volume | ✅ | ✅ |
| 13-effect chain (add/remove/reorder/bypass, knobs) | ✅ | ✅ |
| Metronome + tap tempo, undo / redo | ✅ | ✅ |
| MIDI track-follow | ✅ | ✅ |
| Trim / split / duplicate | ✅ | ⏸ deferred |
| Project save / load, export, mixdown | ✅ | ⏸ deferred |
| Output-device selection | ✅ picker | ➖ read-only label (iOS has no API) |
| Keyboard shortcuts | ✅ | ➖ touch UI instead |

Deferred features currently show a status message on iPad rather than a file panel. See
[ARCHITECTURE.md](ARCHITECTURE.md) for how the platform seam works.

## Keyboard shortcuts

*(macOS — the iPad build is touch-only.)*

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `Space` | Play / stop all | `⌘Z` / `⌘⇧Z` | Undo / Redo |
| `R` | Record selected track | `⌘S` / `⌘⇧S` | Save / Save As |
| `M` / `S` | Mute / Solo selected track | `⌘O` | Open project |
| `1`–`8` | Select track | `⌘E` | Export selected track |
| `,` | Toggle metronome | `⌘T` | Split clip at playhead |
| `Tab` | Switch Arrange ⇄ Monitor | `⌘D` | Duplicate last clip |
| `F` | Toggle playhead follow | `⌘+` / `⌘−` | Zoom timeline |
| `Return` | Stop all | | |

## Files it writes

**macOS**

```
~/Desktop/OP-XY Monitor/Tracks/Track NN/        recorded takes (default; change in Settings)
~/Library/Application Support/Tape08/Presets/   effect-chain presets (JSON)
<project>.xyproj/                               project package (project.json + Audio/)
```

**iPad** (inside the app's container; visible in the Files app via `UIFileSharingEnabled`)

```
Documents/OP-XY Monitor/Tracks/Track NN/        recorded takes
Library/Application Support/Tape08/Presets/     effect-chain presets (JSON)
```

---

## Repository layout

```
Sources/                     all Swift source (23 files) — shared core + both UIs
package.sh                   builds and signs the macOS "Tape 08.app"
Tape08/                      macOS Xcode project (Tape08.xcodeproj)
Tape08iPad/                  iPad Xcode project (Tape08iPad.xcodeproj) + Info.plist
UI Ideas/                    design references / screenshots
archive/                     earlier prototypes (not built)
deep-claude/                 vendored tooling (not part of the app)
ARCHITECTURE.md              functionality + system architecture
to_fix.md                    bug list, plan, and the code-review findings
project_brief.md             original brief
OP-XY Monitor multitrack product plan.md   product plan
```

## Documentation

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — what the app does and how it is built (facade design,
  audio graph, effects system, threading, persistence).
- **[to_fix.md](to_fix.md)** — bug list, prioritised plan, and the current code-review findings.

## Troubleshooting

- **No sound / "No input device selected"** — pick an input under **IN**; re-grant mic permission in
  System Settings.
- **Feedback** — you're monitoring a built-in mic through built-in speakers. Use headphones.
- **Crackles** — try a larger buffer/another output device; heavy effect chains on an old machine can
  strain the render thread.
- **Exported `.xyproj` opens with "missing files"** — the project moved away from its `Audio/`
  folder; keep the package folder intact.

## License / attribution

Tape Saturation is ported from **Airwindows ToTape6** by Chris Johnson (MIT). See the source comment
in `Sources/EffectsKernels.swift`.
