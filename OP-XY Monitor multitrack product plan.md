# OP-XY Monitor: multitrack product plan

Oct 9, 2026 · @Zac · Updated Oct 9, 2026

The monitor becomes an eight-track modular looper for the OP-XY: record dry, arrange clips on a bar grid, shape each track through a chain of swappable effect modules — Apple built-ins, ported open-source DSP, or custom — then export. The module system is the spine: every audio process is a module, every track is a small graph of them, and the node-patch view is how you see and rewire that graph.

## Scope

Five decisions keep this a single-screen instrument instead of a small Logic.

- **Audio only, one stereo input.** Every track is an overdub take from the OP-XY, so only one track is armed at a time. No input routing, MIDI editing, or software instruments.
- **Eight tracks, fixed.** Matches the OP-XY's eight instrument tracks and fits one screen without vertical scrolling.
- **Musical timeline.** BPM, bars, and snap-to-grid, with snap toggleable.
- **Non-destructive.** Record the dry input; apply effects and volume at playback. The current app records after effects and volume, so this changes first.
- **Modular by default.** Every audio process — EQ, reverb, saturation, the player itself — is a module conforming to one protocol. Tracks are graphs of modules. This means the same architecture hosts an Apple built-in, a ported Airwindows effect, or something you write from scratch. No special cases.

## Experience

The core loop: plug in, arm a track, record while hearing earlier tracks, then move, trim, or loop the new clip, shape it with effects, balance, and export.

| Zone | Contents |
| --- | --- |
| Top bar | Return-to-start, play/stop, record, cycle toggle, position (bars and time), BPM, tap tempo, metronome, count-in, input meter, master meter, export |
| Left column | Track headers: colour, name, arm, mute, solo, volume, pan, mini meter |
| Centre | Ruler with cycle brace, clip lanes with waveforms, playhead |
| Bottom inspector | Selected track's effect chain (list or node-patch view), or selected clip's gain, fades, and loop count |
| Footer | Status, sample rate, disk space |

**Interactions**

- **Selection.** Clicking a header selects the track. Clicking a clip selects the clip and its track. The inspector follows.
- **Clip editing.** Drag to move, including across tracks. Drag edges to trim. Drag the top-right corner to loop. Split at playhead, duplicate, delete.
- **Two kinds of loop.** Looping a clip repeats it N times. Cycling the transport replays a bar range. They get different names and controls.
- **Recording states.** Armed, count-in, recording with the waveform drawing live, then stopped with the new clip selected.
- **Navigation.** Horizontal zoom, scroll, click the ruler to seek, optional playhead follow.
- **Keyboard.** Space, R, Return, ⌘Z, ⌘S, ⌘D, ⌘T to split, M and S for mute and solo, ⌘+ and ⌘− to zoom.
- **Resizing.** Header column is draggable, the timeline flexes, the inspector collapses. Window frame, zoom, and scroll save with the project.

**Edge states to design:** empty project, OP-XY unplugged mid-take (keep the take), output set to the OP-XY (feedback), disk full, missing audio files on open.

## Engineering

The engine is built once and kept running; today it is rebuilt on every start.

1. **Restructure.** Move from one `swiftc` file to an Xcode project with a real app bundle. Split into `Model`, `AudioEngine`, `Views`, `Persistence`. Take meters out of the main `ObservableObject`, which publishes about ten properties at 60 Hz.
2. **Data model.** Codable value types: `Project` (bpm, sample rate, tracks, cycle range, view state, version), `Track` (name, colour, volume, pan, mute, solo, effect chain, clips), `Clip` (asset, timeline start, offset and length into the file, loop count, gain). Undo is a project snapshot registered with `UndoManager`.
3. **Project file.** A package such as `Song.xyproj/` holding `project.json`, `Audio/`, and `Peaks/`. Untitled projects record to a temp folder and move on first save. Autosave, dirty indicator, recent files.
4. **Engine graph.** Each track is a small directed acyclic graph of modules: `player → [module] → [module] → ... → track mixer → main mixer → master chain → output`. The simplest graph is a linear chain; the graph can also branch for parallel processing (dry/wet splits, sidechain feeds). The engine builder walks each track's graph and wires `AVAudioNode`s to match. A separate input path monitors through the armed track's module graph.
5. **Transport.** One clock. All players start at the same `AVAudioTime`. Clips are scheduled with `scheduleSegment`; a seek or edit during playback stops, reschedules from the playhead, and restarts.
6. **Recording and latency.** Tap the dry input, timestamp the first buffer against transport start, and shift the clip earlier by input plus output latency. Add a manual offset setting, since reported latency is rarely exact.
7. **Waveforms.** Precomputed min/max peak files at two resolutions, drawn with `Canvas` for the visible range only, appended live while recording.
8. **Editing.** Move, trim, split, duplicate, loop, and delete are pure functions on `Project`, sharing one snapping helper.
9. **Mixing.** Volume, pan, and mute on the track mixer, with a meter tap per track. Solo is derived.
10. **Export.** Offline bounce through `AVAudioEngine` manual rendering to WAV or M4A, whole song or cycle range. Drag-in import with sample-rate conversion.
11. **Devices.** Handle `AVAudioEngineConfigurationChange` and hot-unplug. Setting the system default input stays for now; a private aggregate device is the durable fix.

## Effects

Apple's built-in units cover the clean, transparent effects; ported open-source DSP covers the character effects that give the app its lo-fi sound. Every effect — Apple or ported — is a module. The user sees them in one list and chains them freely.

### Effect catalogue

| Effect | Source | Category | Complexity |
| --- | --- | --- | --- |
| 3-band EQ | Apple `AVAudioUnitEQ` (already built) | Tone | Wrapped, done |
| Reverb | Apple `AVAudioUnitReverb` (already built) | Space | Wrapped, done |
| Delay | Apple `AVAudioUnitDelay` (already built) | Time | Wrapped, done |
| Master limiter | Apple `AVAudioUnitEffect` with system peak limiter | Dynamics | Wrap |
| Compressor | Apple `AVAudioUnitEffect` with system compressor | Dynamics | Wrap |
| Tape saturation | Port from Airwindows (`Tape` or `IronOxide5`) | Character | Small, first port |
| Bitcrusher | Port from Airwindows (`DeRez2`) or EffeTune | Character | Small |
| Wow and flutter | Port from EffeTune | Character | Medium (pitch mod) |
| Noise and hiss | Port from EffeTune | Character | Small |
| Chorus / flanger | Port from Airwindows (`Chorus` or `ChorusEnsemble`) | Modulation | Medium |
| Phaser | Port from Airwindows (`PhaseNudge`) | Modulation | Medium |
| Tremolo | Port from Airwindows (`Tremolo`) | Modulation | Small |
| Lo-fi / vinyl | Port from Airwindows (`Vinyl`) | Character | Small |
| Distortion / overdrive | Port from Airwindows (`Drive`) | Character | Small |
| Gate / expander | Port from Airwindows (`Gate`) | Dynamics | Small |
| Stereo width | Port from Airwindows (`StereoFX`) | Spatial | Small |
| Custom reverb | Later: EffeTune's FDN or Dattorro plate | Space | Large |

The first four ports (tape saturation, bitcrusher, wow & flutter, noise) establish the lo-fi signature. Everything after that widens the palette.

### Hosting a port

Each ported effect is one `AudioEffectKernel` conformer whose `process` function is a line-for-line translation of the open-source DSP. The shared `EffectAudioUnit` wrapper hosts any kernel as an `AVAudioUnit` in the engine graph. Build the wrapper once; every later port is just the kernel.

### Chain model

A track's effect chain is an ordered list of module slots, each `{ moduleID, parameter values, bypass }`, replacing the current three fixed EQ, reverb, and delay fields. The inspector shows the selected slot's knobs, auto-generated from the module's parameter declarations. The chain is also the data behind the node-patch view: same structure, richer editor.

### References and licences

| Project | Licence | Use | Notes |
| --- | --- | --- | --- |
| [Airwindows](https://github.com/airwindows/airwindows) | MIT | Port directly | C++, one small plugin per effect. ~300 plugins, most under 200 lines of DSP. The richest source for character effects |
| [EffeTune](https://github.com/Frieve-A/effetune) | MIT | Port directly | JavaScript → Swift translation. Strong on tape/vinyl simulation |
| [Audio-Effects](https://github.com/juandagilc/Audio-Effects) | GPL-3 | Theory reference only | Copying code would GPL the app |
| [DPF (DISTRHO Plugin Framework)](https://github.com/DISTRHO/DPF) | ISC/MIT | Reference for plugin hosting patterns | C++, good model for how a host wraps a kernel |
| [Faust](https://github.com/grame-cncm/faust) | GPL-2 | Generate DSP code | Faust programs compile to C++; could generate kernels from `.dsp` files. Licence applies to the compiler, not the generated code |

MIT ports need the original copyright notice kept in the app's credits.

### Module porting pipeline

A repeatable process for turning an open-source effect into a module:

1. **Pick the source.** Find the `processReplacing` (C++) or `process` (JS) function. Read it. Understand every parameter and every state variable.
2. **Translate to Swift.** One file, one class conforming to `AudioEffectKernel`. Translate the inner loop faithfully; do not optimise yet. Name the file `{EffectName}Kernel.swift`.
3. **Declare the module.** One struct conforming to `AudioEffectModule` listing the identifier, display name, version, parameters, and kernel factory.
4. **Test.** Feed a known signal (sine, impulse, silence) through the kernel and compare output against the original. Write a unit test that runs the kernel offline and checks RMS or peak values against a reference.
5. **Register.** Add the module type to the registry's built-in list, or drop it into the add-on bundles folder.
6. **Credit.** Add the original author and licence to `CREDITS.md`.

## Standard-kit gaps

Metronome is done. Count-in, tap tempo, the module system, and a master limiter move into the first release; the rest waits.

| Feature | When | Note |
| --- | --- | --- |
| Metronome | Done | BPM control, accent on beat 1, starts with playback |
| Per-track loop playback | Done | Independent start/stop per track |
| Module protocol and registry | First release | The foundation everything else builds on |
| Chain inspector UI | First release | Add, remove, reorder, bypass modules per track |
| First ported effects (tape sat, bitcrusher) | First release | Proves the module pipeline end-to-end |
| Count-in | First release | Needed before overdubbing works |
| Tap tempo | First release | Small |
| Master channel with limiter | First release | Protects the export |
| Clip fades | First release | Hides clicks at clip edges |
| Node-patch view | Second release | Visual graph editor per track |
| Cross-track routing | Second release | Sidechain, send/return between tracks |
| Add-on module bundles | Second release | User-installed effects from a folder |
| Time signature | Later | 4/4 only at first |
| Takes and comping | Later | Needs loop-record |
| Automation | Later | Volume and pan over time |
| Markers | Later | Label song sections |
| Tuner | Not planned | The OP-XY is already in tune |
| Loop library, MIDI editing, track freeze | Not planned | Outside the scope above |

## Build order

The modular architecture is load-bearing, so it goes in early — before the timeline, not after. Steps 3 and 5 carry the most risk (sync, latency), so prototype them before investing in the visual timeline.

1. **Module foundation.** Define `AudioEffectKernel`, `AudioEffectModule`, `EffectParameter` protocols. Build `EffectAudioUnit` wrapper. Build `EffectRegistry`. Wrap the three existing Apple effects (EQ, reverb, delay) as modules. Port tape saturation from Airwindows as the first custom module. Test all four in isolation.
2. **Graph model and chain engine.** Define `ModuleNode`, `ModuleWire`, `ModuleGraph`. Build the engine graph builder that topologically sorts a track's graph and wires `AVAudioNode`s. Replace the current fixed EQ→reverb→delay pipeline with a dynamic chain driven by each track's `ModuleGraph`. Chain inspector UI: add, remove, reorder, bypass modules.
3. **Restructure and dry recording.** Move the tap point before effects so recordings are dry. Split the single file into `Model`, `AudioEngine`, `Views`, `Persistence`. Build once, keep running.
4. **Model and project file.** Codable `Project`, `Track` (with `ModuleGraph`), `Clip`. Package format `Song.xyproj/`. Save, load, autosave.
5. **Playback engine and latency.** Two WAVs on two tracks play in sync. Latency calibration with the impulse test. `scheduleSegment` for clips.
6. **Timeline, read-only.** Headers, lanes, waveforms, ruler, playhead, zoom, resizing.
7. **Record to track.** Arm, metronome, count-in, overdub. Test by recording the click back in.
8. **Editing and undo.** Move, trim, split, duplicate, loop, snap, fades.
9. **More ported effects.** Bitcrusher, wow and flutter, noise and hiss, chorus, distortion. Follow the porting pipeline.
10. **Node-patch view prototype.** Build the canvas, node rendering, wire dragging as a standalone toy with mock data. Then connect it to the real graph model so it drives the engine.
11. **Cycle, export, import.** Offline bounce, drag-in import, sample-rate conversion.
12. **Polish.** Menus, shortcuts, preferences, error states, `CREDITS.md` with open-source attributions.

**After that:** cross-track routing in the node graph, MIDI clock and start to the OP-XY, loop-record takes, automation, hosting third-party Audio Unit plugins, add-on bundles folder for user-installed modules.

## Musician's priorities

A musician judges this on feel, not features. These reorder some of the plan above.

- **Invisible capture.** No friction between "ready" and "recording." Punch in and keep looping without touching the keyboard between passes; stopping to re-arm turns a player into an operator.
- **Comping is closer to core than "later."** You rarely nail a part first try. Loop a bar, play it ten times, keep the best pass. This is what makes it a tool you finish ideas on, not just a sketchpad. Pull loop-record and take-keeping earlier than the standard-kit table suggests.
- **Playable character effects.** The lo-fi effects should be performed, not just applied after the fact. Push wow and flutter or saturation live while recording, and let them be assigned to the sample engine's LFO. That turns the app from a cleanup tool into an instrument. The modular chain makes this natural: put the character modules before the recorder tap to print them, or after to keep the take dry.
- **The patch as instrument.** The node-patch view is not just for power users configuring routing. It is a performance surface. Seeing signal flow through the nodes — meters pulsing, wires glowing — turns mixing into something you watch and play, not just configure. The draw is visual and tactile, closer to a pedalboard than a settings panel.
- **Quantize-free timing.** The source is already a sequencer, so let takes stay loose. Snap for arranging clips; never force the performance onto the grid.
- **Trust the ears.** Elaborate metering matters less than it looks. The tuner stays cut.

## Node-patch direction

The timeline answers *what happens when*; the node patch answers *what a track sounds like*. Each track can open into its own node graph, in the spirit of TouchDesigner or Blender's node editor. Same engine underneath, a freer and better-looking way to wire it.

### Why this works

The chain model already planned is a degenerate graph: a list is a graph with no branches. The node patch unfreezes it. The clip player is the input node, the speaker is the output node, and effect modules are patched between them. Because the data model is already a graph of module slots, the chain view and the node-patch view are two renderings of the same structure. No data migration, no second engine.

### What a node is

Every node is a module instance. Nodes have typed ports:

| Port type | Direction | Meaning |
| --- | --- | --- |
| Audio In | Input | Receives a stereo audio stream |
| Audio Out | Output | Sends a stereo audio stream |
| Sidechain In | Input | Receives audio for analysis (compressor key input, ducking trigger) |
| Control | Input | Receives a modulation signal (LFO, envelope follower) mapped to a parameter |

A wire connects one output port to one input port. The graph must be acyclic. Cycles are rejected at wire-creation time, not at render time.

### Node categories

| Category | Examples | Notes |
| --- | --- | --- |
| Source | Clip Player, Live Input, Test Tone, Noise | One source per track by default; a second source enables layering |
| Effect | Every module in the effect catalogue | Any `AudioEffectModule` becomes a node |
| Routing | Splitter, Merger, Dry/Wet Mix, Crossfader | Enables parallel processing: split → [reverb, delay] → merge |
| Analysis | Level Meter, Spectrum, Envelope Follower | Taps the signal without altering it; feeds data to the UI or to Control ports |
| Utility | Gain, Pan, Phase Invert, Mono Sum | Simple but needed for patching |
| Output | Track Output, Recorder | The terminal node; routes to the track mixer |

### The three views of the same data

1. **Chain view (inspector).** A vertical list of effect slots. Add, remove, reorder, bypass. This is the fast editor. It reads and writes the same graph data, constrained to a linear topology.
2. **Node-patch view (expanded inspector or dedicated panel).** The full graph with draggable nodes and wires. Enables branching, parallel paths, sidechain routing. This is the expressive editor.
3. **Compact view (track header).** A row of small icons showing the active modules. Click one to select it in the inspector. This is the at-a-glance summary.

Switching between chain and node-patch does not change the underlying data. If the graph happens to be linear, the chain view is a perfect representation. If the user adds a branch in the node view, the chain view shows a simplified version (the main path) with a badge indicating "graph mode."

### Build path

1. **Ship the chain first.** The inspector shows a linear list of module slots. This is the minimum viable effect system and is fully useful on its own.
2. **Prototype the node editor as a standalone toy.** Build the canvas, node rendering, wire dragging, and port snapping without the audio engine. Use mock data. This is mostly UI work and should not block the audio features.
3. **Connect the node editor to the engine.** When a track opens its node view, the graph data drives the `AVAudioEngine` wiring. Changes in the graph rebuild the relevant subgraph.
4. **Cross-track routing (later).** Allow one track's output to feed another track's sidechain or input. This turns the eight-track looper into a small modular mixer.

### Depth decision

Whole effects as nodes (a reverb node, a delay node) is the right grain. It gives nearly all of the visual and creative payoff and maps directly to `AVAudioNode` instances. Going deeper — oscillators, filters, and envelopes as individual nodes — is building a synthesiser, which is outside scope. If sub-effect granularity is ever wanted, a single module could internally be a sub-graph, but the track graph never sees below the module boundary.

## Modular architecture

The module system is the core abstraction. Every audio process in the app — Apple built-in, open-source port, or custom — conforms to one protocol and plugs into the same graph. The architecture has five parts: the **protocol** (what a module is), the **registry** (how modules are found and loaded), the **engine wrapper** (how a module becomes a node in `AVAudioEngine`), the **graph model** (how modules connect), and the **auto-generated UI** (how controls draw themselves without per-effect code).

**1. The protocol.** Every effect declares its parameters and provides a DSP core that processes audio buffers. Parameters are data, so the UI and the saved project can read them without knowing the effect.

```swift
// The DSP core — pure audio, no UI. Ported Airwindows/EffeTune code lives here.
protocol AudioEffectKernel: AnyObject {
    init(sampleRate: Double)
    // Process one block in place. frames = samples per channel.
    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int)
    func setParameter(_ id: String, value: Float)
    func reset()
}

// The module: identity + parameter list + a factory for its kernel.
protocol AudioEffectModule {
    static var identifier: String { get }   // "com.you.tape-saturation"
    static var displayName: String { get }  // "Tape Saturation"
    static var version: Int { get }
    static var parameters: [EffectParameter] { get }
    static func makeKernel(sampleRate: Double) -> AudioEffectKernel
}

struct EffectParameter: Codable {
    let id: String          // "drive"
    let name: String        // "Drive"
    let min: Float
    let max: Float
    let defaultValue: Float
    let unit: String        // "dB", "%", "ms"
}
```

**2. The registry.** On launch the app scans a bundled folder and a user Application Support folder, so downloaded modules land in the second one. Each module registers under its identifier; a saved project refers to effects by that string, which is why versioning lives in the protocol.

```swift
final class EffectRegistry {
    static let shared = EffectRegistry()
    private(set) var modules: [String: AudioEffectModule.Type] = [:]

    func register(_ type: AudioEffectModule.Type) {
        modules[type.identifier] = type
    }

    // Built-ins are registered directly; add-ons are loaded from bundles.
    func loadAddOns(from folder: URL) {
        let bundles = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in bundles where url.pathExtension == "bundle" {
            guard let bundle = Bundle(url: url), bundle.load(),
                  let principal = bundle.principalClass as? AudioEffectModule.Type
            else { continue }
            register(principal)
        }
    }

    func makeKernel(for id: String, sampleRate: Double) -> AudioEffectKernel? {
        modules[id]?.makeKernel(sampleRate: sampleRate)
    }
}
```

**3. The engine wrapper.** One `AUAudioUnit` subclass hosts any kernel, so a module author never touches Core Audio. Its render block calls the kernel. This wrapper is written once; every module reuses it.

```swift
final class EffectAudioUnit: AUAudioUnit {
    private let kernel: AudioEffectKernel

    init(kernel: AudioEffectKernel,
         componentDescription: AudioComponentDescription) throws {
        self.kernel = kernel
        try super.init(componentDescription: componentDescription, options: [])
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        { _, _, frameCount, _, outputData, _, pullInput in
            // pull upstream audio into outputData, then:
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let ptrs = abl.map { $0.mData!.assumingMemoryBound(to: Float.self) }
            self.kernel.process(ptrs, frames: Int(frameCount))
            return noErr
        }
    }
}
```

**4. Auto-generated UI.** Because parameters are data, one SwiftUI view renders the controls for any module. A downloaded effect gets a working panel with no UI code of its own.

```swift
struct EffectInspector: View {
    let module: AudioEffectModule.Type
    @ObservedObject var state: EffectState   // holds live param values

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(module.displayName).font(.headline)
            ForEach(module.parameters, id: \.id) { p in
                KnobView(
                    value: state.binding(for: p.id),
                    range: p.min...p.max,
                    label: p.name,
                    unit: p.unit
                )
            }
        }
    }
}
```

**5. The graph model.** A track's processing is a directed acyclic graph of module instances. The chain view is a linear graph; the node-patch view is the general case. The same data structure supports both.

```swift
// One node in the graph: a module instance with its state.
struct ModuleNode: Codable, Identifiable {
    let id: UUID
    let moduleID: String                  // registry key, e.g. "com.opxy.tape-saturation"
    var parameters: [String: Float]       // current param values
    var bypass: Bool = false
    var position: CGPoint = .zero         // for node-patch layout; ignored by chain view
}

// A wire between two nodes.
struct ModuleWire: Codable, Identifiable {
    let id: UUID
    let sourceNodeID: UUID
    let sourcePort: String                // "audioOut", "sidechainOut"
    let destNodeID: UUID
    let destPort: String                  // "audioIn", "sidechainIn", "controlIn"
}

// The full graph for one track.
struct ModuleGraph: Codable {
    var nodes: [ModuleNode] = []
    var wires: [ModuleWire] = []
    let sourceNodeID: UUID                // the clip player / live input
    let outputNodeID: UUID                // the track output

    // Topological sort for engine wiring. Returns nil if cyclic.
    func sortedNodes() -> [ModuleNode]? {
        // standard Kahn's algorithm on the wire adjacency
        // ...
    }

    // Convenience: build a linear chain from a list of module IDs.
    static func linearChain(_ moduleIDs: [String]) -> ModuleGraph {
        // Creates nodes, wires them source → m1 → m2 → ... → output
        // ...
    }
}
```

The engine builder topologically sorts the graph, creates an `AVAudioNode` for each module (using the `EffectAudioUnit` wrapper for custom kernels, or the native `AVAudioUnit` for Apple built-ins), and connects them with `AVAudioEngine.connect`. When the user edits the graph — adding a node, dragging a wire — the engine disconnects the affected subgraph, rebuilds it, and reconnects, without stopping playback if possible.

**How a track uses it.** Each `Track` holds a `ModuleGraph`. Saving serialises the graph's nodes and wires as JSON. Loading asks the registry to rebuild each kernel from the `moduleID`. The chain view reads and writes the same graph, constrained to linear topology. The node-patch view is the unrestricted editor.

At load time a downloaded bundle is registered and its kernel built; at play time that kernel is one node in the track graph, beside Apple's built-in nodes.

**6. Apple built-in wrappers.** Apple's `AVAudioUnitEQ`, `AVAudioUnitReverb`, and `AVAudioUnitDelay` are not custom kernels but they are modules. Each gets a thin `AudioEffectModule` conformer that declares its parameters and wraps the Apple class. The registry treats them identically to ported effects. This means the user can chain two reverbs, or put an EQ after a delay, or any other combination — the fixed ordering is gone.

```swift
// Example: wrapping Apple's reverb as a module.
struct AppleReverbModule: AudioEffectModule {
    static let identifier = "com.apple.reverb"
    static let displayName = "Reverb"
    static let version = 1
    static let parameters: [EffectParameter] = [
        EffectParameter(id: "wetDryMix", name: "Mix", min: 0, max: 100,
                        defaultValue: 40, unit: "%"),
        EffectParameter(id: "preset", name: "Preset", min: 0, max: 8,
                        defaultValue: 3, unit: ""),
    ]
    // Instead of makeKernel, Apple wrappers provide makeAudioUnit directly.
    static func makeAudioNode(sampleRate: Double) -> AVAudioNode {
        let r = AVAudioUnitReverb()
        r.loadFactoryPreset(.mediumHall)
        r.wetDryMix = 40
        return r
    }
}
```

The protocol may need a second path: `makeKernel` for custom DSP, `makeAudioNode` for Apple wrappers. The registry abstracts this so the graph builder does not care which kind it is.

## Latency test

Build this before the timeline. It is the single experiment that de-risks the whole DAW: if overdubs will not line up, nothing above matters.

**The idea.** Play one sharp click at a known `AVAudioTime` while recording the input. The click travels out to the speakers, through the loopback path (OP-XY or a cable), and back in a little later. Find where the click lands in the recorded buffer, subtract when it was scheduled, and the gap is round-trip latency. Divide by the sample rate for milliseconds. Subtract that from every overdub's start and takes line up; keep a manual trim knob on top, since the real world is never exact.

**To run it.** Route the output back to the input (a short cable, or monitor the OP-XY so its output feeds the Mac). Then `swift latency_test.swift`. Do it a few times and average.

```swift
// latency_test.swift - measure round-trip latency with an impulse.
// Route output -> input (cable or OP-XY loopback) before running.
import AVFoundation

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)

let fmt = engine.inputNode.inputFormat(forBus: 0)
let sr = fmt.sampleRate
engine.connect(player, to: engine.mainMixerNode, format: fmt)
engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)

// A one-sample impulse in a short buffer.
let clickFrames: AVAudioFrameCount = 64
let click = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: clickFrames)!
click.frameLength = clickFrames
for ch in 0..<Int(fmt.channelCount) { click.floatChannelData![ch][0] = 1.0 }

var captured = [Float]()
var scheduledSample: Int64 = -1
var framesSeen: Int64 = 0
let lock = NSLock()

engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
    let n = Int(buf.frameLength)
    let ch0 = buf.floatChannelData![0]
    lock.lock()
    for i in 0..<n { captured.append(ch0[i]) }
    framesSeen += Int64(n)
    lock.unlock()
}

try! engine.start()

// Schedule the click a quarter second out, on the shared clock.
let startSample = (player.lastRenderTime?.sampleTime ?? 0) + Int64(sr * 0.25)
scheduledSample = startSample
player.scheduleBuffer(click, at: AVAudioTime(sampleTime: startSample, atRate: sr))
player.play()

// Let it come back, then find the impulse.
Thread.sleep(forTimeInterval: 1.0)
engine.inputNode.removeTap(onBus: 0)
engine.stop()

lock.lock(); let rec = captured; lock.unlock()
let threshold: Float = 0.1
if let arrival = rec.firstIndex(where: { abs($0) > threshold }) {
    // arrival is an index into the captured stream; the tap began at engine start,
    // so compare against the scheduled offset from that same start.
    let latencyFrames = Double(arrival) - (Double(scheduledSample))
    let ms = abs(latencyFrames) / sr * 1000.0
    print(String(format: "Round-trip latency: %.2f ms (%.0f samples at %.0f Hz)",
                 ms, abs(latencyFrames), sr))
} else {
    print("No click found - check the loopback routing and input gain.")
}
```

**Reading the result.** A typical USB round trip is a few milliseconds to a few tens. What matters is that it is stable across runs; a steady number is one you can compensate for. If it jumps around, the fix is an aggregate device, not a constant offset. Calibrate against the real signal path you will record through, since the OP-XY's own conversion adds to it.
