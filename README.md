# TAPE 08

A macOS **USB-audio monitor, multitrack looper and effects rack** for the
[Teenage Engineering OP-XY](https://teenage.engineering/) (works with any CoreAudio input, but the
workflow is built around the OP-XY).

Plug the OP-XY in over USB, monitor it with a live effect chain, loop-record takes onto an 8-track
tape grid, and bounce a mixdown — all in one window with a retro hardware aesthetic.

![TAPE 08](UI%20Ideas/06-transport-header-reel-knobs.png)

---

## Requirements

- macOS **14.0** or later (arm64)
- An audio input device (the OP-XY appears as a USB audio device)
- Xcode command-line tools (for `swiftc`) — full Xcode is recommended

## Build & run

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

### First run

macOS will ask for **microphone access** — grant it (System Settings ▸ Privacy & Security ▸
Microphone). Pick your OP-XY under **IN** in the top bar and your speakers/headphones under **OUT**.
Use headphones if you monitor a built-in mic, or you'll get feedback.

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

## Keyboard shortcuts

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

```
~/Desktop/OP-XY Monitor/Tracks/Track NN/   recorded takes (default; change in Settings)
~/Library/Application Support/Tape08/Presets/   effect-chain presets (JSON)
<project>.xyproj/                          project package (project.json + Audio/)
```

---

## Repository layout

```
Sources/                     all Swift source (17 files) — the app
package.sh                   builds and signs "Tape 08.app"
Tape08/                      Xcode project (Tape08.xcodeproj)
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
