# Development TODO & Modular Effects Plan

This document consolidates the current bug list, UI/UX improvements, and a new initiative to build a **modular sound effects system** with custom guitar-pedal-style effects (chorus, distortion, etc.). It is intended to be appended to the existing project TODO.

---

## 1. Immediate Bug Fixes & UI/UX Issues

These items are blocking or degrading the current experience and should be addressed first.

| ID | Issue | Description | Suggested Fix |
|----|-------|-------------|---------------|
| UI-1 | **Tape UI does not resize when left panels are added** | When the mixer/effects panel is shown, the tape area keeps its original width, causing clipping or overlapping. | Use a responsive layout (e.g., `HSplitView` in SwiftUI or Auto Layout constraints) so the tape area shrinks proportionally. |
| UI-2 | **No count‑in option** | Users cannot get a count‑in before recording starts. | Add a toggle and a numeric field (e.g., 1–4 bars) in the transport bar. When armed, play a click for the specified duration before recording begins. |
| UI-3 | **Cannot split a recorded track** | Once recorded, the audio region cannot be divided into smaller segments. | Implement a “Split at Playhead” command. Store regions as references to the original audio file with start/end offsets. |
| UI-4 | **Neural amp does nothing and creates noise** | The neural amp feature is non-functional and introduces unwanted artifacts. | **Remove the neural amp completely** – delete its UI, code, and any related assets. |
| UI-5 | **Touch zone for buttons is too small** | Buttons are hard to tap on touch devices. | Increase the hit area to at least 44×44 points (Apple HIG). Use transparent padding if visual size must remain small. |
| UI-6 | **Dials UI looks weird** | The rotary controls appear inconsistent, possibly with odd angles or poor visual feedback. | Redesign dials: use a consistent 270° sweep, clear value indicator, and a modern flat style. Consider using a custom `NSView`/`UIView` subclass with Core Graphics. |
| UI-7 | **L and R levels on top right are too far apart** | The left/right level meters are separated by too much space. | Reduce the horizontal spacing between L and R meters. Group them tightly, perhaps with a single container and minimal padding. |
| UI-8 | **Input and Position not aligned; Output and Loop not aligned** | Labels/controls for Input/Position and Output/Loop are misaligned. | Use a grid layout (e.g., `LazyVGrid` or `NSGridView`) to align labels and controls in columns. Ensure consistent widths. |
| CL-1 | **Unused code** | Dead code increases maintenance burden. | Run a static analyzer (SwiftLint, `-warn-unused`), identify unused functions, classes, and assets, and remove them. Document any removals in the commit message. |

---

## 2. Modular Sound Effects System (New Feature)

### 2.1 Goal
Allow the app to host **custom audio effects** as loadable bundles, and let users connect them in a **node graph** (like a modular synth or guitar pedalboard). Effects can be written in Swift or C++ and loaded at runtime.

### 2.2 Architecture Overview

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Source     │───▶│  Effect 1   │───▶│  Output     │
│  (Track)    │    │  (Chorus)   │    │  (Master)   │
└─────────────┘    └─────────────┘    └─────────────┘
```

- **Nodes**: Each node is either a source (audio track, oscillator), an effect (gain, chorus, distortion), or a sink (output).
- **Ports**: Nodes have input and output ports. A port carries one or more audio channels.
- **Graph**: Holds nodes and connections. Computes a topological order to process nodes efficiently.

### 2.3 Plugin Protocol (existing `XYEffectPlugin`)

We already have `XYEffectPlugin` and `XYEffectPluginKernel` in `ExampleEffect.swift`. We will:

1. **Formalise the protocol** – move it to a shared header or Swift package so host and plugins agree.
2. **Create a bundle loader** – scan `~/Library/Application Support/OPXYMultitrack/Effects/` for `.bundle` files, load the principal class, and instantiate the plugin.
3. **Wrap kernels in graph nodes** – an `EffectNode` owns an `XYEffectPluginKernel` and manages its audio buffers.

### 2.4 Graph Implementation (Swift)

```swift
protocol AudioGraphNode: AnyObject {
    var inputs: [UnsafeMutablePointer<Float>] { get set }
    var outputs: [UnsafeMutablePointer<Float>] { get set }
    func prepare(sampleRate: Double, maxFrames: Int)
    func process(frameCount: Int)
    func reset()
}

final class EffectNode: AudioGraphNode {
    private let kernel: XYEffectPluginKernel
    // buffers, AudioBufferList, etc.
}

final class AudioGraph {
    private var nodes: [AudioGraphNode] = []
    private var connections: [(src: Int, srcPort: Int, dst: Int, dstPort: Int)] = []
    private var order: [Int] = []  // topological order

    func addNode(_ node: AudioGraphNode) -> Int
    func connect(src: Int, srcPort: Int, dst: Int, dstPort: Int)
    func rebuildOrder() // Kahn's algorithm
    func process(frameCount: Int)
}
```

### 2.5 C++ for DSP (Optional but Recommended)

For performance-critical effects, implement the kernel in C++ and expose a C API:

```cpp
extern "C" {
    typedef struct {
        void* (*create)(double sampleRate, int channelCount);
        void (*destroy)(void* instance);
        void (*process)(void* instance, float** buffers, int numChannels, int frameCount);
        void (*setParameter)(void* instance, const char* id, float value);
    } XYEffectDescriptor;
}
```

Swift can then call these functions via a bridging header. This keeps the graph and UI in Swift while the heavy DSP runs in C++.

### 2.6 Implementation Steps

1. **Refactor `ExampleEffect.swift`** – fix interleaved buffer bug, add proper `Info.plist`.
2. **Create `AudioGraph` class** – nodes, connections, topological sort, buffer management.
3. **Implement `EffectNode`** – wraps a kernel, copies inputs to an `AudioBufferList`, calls `process`, copies back.
4. **Build a plugin loader** – `Bundle` loading, protocol conformance check, instantiation.
5. **Design a graph editor UI** – a canvas where users drag nodes and connect ports. Start with a simple list-based connection UI for MVP.
6. **Integrate with tape tracks** – each track can have an effect chain (a linear graph) or send to a shared graph.

---

## 3. Custom Sound Effects (Guitar Pedals & Chorus)

We want to ship a library of built-in effects. Each can be implemented as a kernel (Swift or C++) and optionally exposed as a plugin.

### 3.1 DSP Building Blocks

| Block | Used For |
|-------|----------|
| **Waveshaping** | Distortion, overdrive, fuzz |
| **Delay Line** | Chorus, flanger, delay, reverb |
| **Filters** (one-pole, biquad) | Wah, tone controls, EQ |
| **LFO** | Modulation for chorus, flanger, phaser |
| **Envelope Follower** | Auto-wah, compressor |

### 3.2 Effects to Implement (Priority Order)

| Effect | Algorithm | Parameters |
|--------|-----------|------------|
| **Gain** | Multiply by linear gain | Gain (dB) |
| **Distortion** | `tanh` or soft clipping | Drive, Tone, Level |
| **Chorus** | Modulated delay (LFO) + mix | Rate, Depth, Mix |
| **Flanger** | Short modulated delay + feedback | Rate, Depth, Feedback, Mix |
| **Phaser** | Cascaded all-pass filters modulated by LFO | Rate, Depth, Feedback, Mix |
| **Delay** | Delay line with feedback | Time, Feedback, Mix |
| **Reverb** | Schroeder reverb (comb + all-pass) | Size, Damping, Mix |
| **EQ** | Biquad filters (low shelf, peak, high shelf) | Low, Mid, High |
| **Compressor** | Envelope follower + gain reduction | Threshold, Ratio, Attack, Release |

### 3.3 Example: Chorus Implementation (Swift)

```swift
final class ChorusKernel: NSObject, XYEffectPluginKernel {
    private var delayBuffer: [Float] = []
    private var writeIndex = 0
    private var lfoPhase: Float = 0
    private var sampleRate: Float = 48000
    private var rate: Float = 0.5      // Hz
    private var depth: Float = 0.5     // 0..1
    private var mix: Float = 0.5       // 0..1

    func prepare(sampleRate: Double, maxFrames: Int) {
        self.sampleRate = Float(sampleRate)
        delayBuffer = [Float](repeating: 0, count: Int(sampleRate * 0.05)) // 50ms max
    }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "rate": rate = value
        case "depth": depth = value
        case "mix": mix = value
        default: break
        }
    }

    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let bufferSize = delayBuffer.count

        for i in 0..<frameCount {
            // LFO
            lfoPhase += rate / sampleRate
            if lfoPhase > 1 { lfoPhase -= 1 }
            let lfo = sin(2 * .pi * lfoPhase)

            // Modulated delay
            let delaySamples = depth * 0.02 * sampleRate * (0.5 + 0.5 * lfo) // 0..20ms
            let readPos = Float(writeIndex) - delaySamples
            let readIndex = Int(readPos) % bufferSize
            let frac = readPos - floor(readPos)

            // Linear interpolation
            let a = delayBuffer[readIndex]
            let b = delayBuffer[(readIndex + 1) % bufferSize]
            let delayed = a + (b - a) * frac

            // Mix
            let dry = data[i]
            data[i] = dry * (1 - mix) + delayed * mix

            // Write to delay buffer
            delayBuffer[writeIndex] = dry
            writeIndex = (writeIndex + 1) % bufferSize
        }
    }

    func reset() {
        delayBuffer = [Float](repeating: 0, count: delayBuffer.count)
        writeIndex = 0
        lfoPhase = 0
    }
}
```

---

## 4. UI/UX for Effects

- **Effect Rack**: A panel that shows the current effect chain for a track. Users can add, remove, reorder effects.
- **Parameter Controls**: Each effect exposes its parameters via `parameterSpecs`. Generate sliders/dials automatically.
- **Graph Editor (future)**: A canvas with draggable nodes and connection lines. Start with a simple list of connections for MVP.
- **Preset Management**: Save/load effect chains as presets.

---

## 5. Technical Debt & Cleanup

- **Remove Neural Amp**: Delete all code, UI, and resources related to the neural amp.
- **Remove Unused Code**: Run `swiftlint` with `unused_import`, `unused_declaration`, and manually review. Remove dead classes, functions, and assets.
- **Refactor Audio Engine**: Ensure the audio graph is thread-safe and lock-free where possible. Use a ring buffer for parameter changes.
- **Documentation**: Add comments to the graph and plugin protocols. Write a short guide for creating custom effects.

---

## 6. Prioritised TODO List

| Priority | Task | Notes |
|----------|------|-------|
| P0 | Fix tape UI resizing | Blocking layout |
| P0 | Remove neural amp | Causes noise |
| P0 | Fix touch zones | Usability |
| P1 | Add count-in | Recording workflow |
| P1 | Implement track splitting | Editing workflow |
| P1 | Align L/R levels, Input/Position, Output/Loop | UI polish |
| P1 | Redesign dials | Visual consistency |
| P2 | Build AudioGraph core | Foundation for effects |
| P2 | Implement plugin loader | Load custom bundles |
| P2 | Create EffectNode wrapper | Integrate kernels |
| P2 | Implement Gain, Distortion, Chorus | First effects |
| P3 | Add Delay, Reverb, EQ, Compressor | Expand library |
| P3 | Graph editor UI | Advanced feature |
| P3 | Remove unused code | Maintenance |
| P3 | C++ DSP bridge | Performance |

---

## 7. Next Steps

1. **Sprint 1 (1 week)**: Fix P0 items – tape UI, neural amp removal, touch zones.
2. **Sprint 2 (1 week)**: P1 items – count-in, track splitting, UI alignment, dial redesign.
3. **Sprint 3 (2 weeks)**: Start modular effects – implement `AudioGraph`, `EffectNode`, plugin loader, and the Gain/Distortion/Chorus effects.
4. **Sprint 4 (2 weeks)**: Integrate effects into the track UI, add presets, and begin work on the graph editor.
5. **Continuous**: Remove unused code, write tests for DSP kernels, document the plugin API.

This document should be treated as a living plan. Update it as tasks are completed and new requirements emerge.

 TAPE 08 — Work Summary                                                                
                                                                                        
  What the project is                                                                   
                                                                                        
  A single-file SwiftUI macOS app (~5,700-line monitor.swift): a USB-audio monitor for  
  the OP‑XY, with a multitrack looper and a modular effects chain. Built two ways —     
  package.sh (swiftc) and an Xcode project — targeting macOS 14.0 (arm64).              
                                                                                        
  ---                                                                                 
  Phase 1 — Code review
                       
  Reviewed the whole project and produced a prioritized findings list covering
  correctness bugs, thread-safety, and structural issues. The top items were:           
  render‑thread/main‑thread races on meter state, main‑thread audio file I/O, metronome
  tempo drift, the app hijacking the system default input device, loopEnabled not       
  actually wired to playback, per‑sample copy‑on‑write in delay lines, a god‑object   
  (AudioManager), and repo hygiene.                                                   

  ---
  Phase 2 — Review‑driven fixes — commit a06ac96
                                                                                        
  - Meter races — render‑thread taps now publish raw levels into an
  OSAllocatedUnfairLock snapshot; the 60 Hz main‑thread display timer owns all          
  smoothing/peak‑hold.                                                                
  - Off‑main clip I/O — clip buffers and project peak decoding moved off the main       
  thread.                                                                               
  - Metronome drift — replaced the per‑beat Timer with sample‑accurate AVAudioTime    
  scheduling plus a coarse queue‑refill timer.                                          
  - Input‑device hijack — the engine's input AUHAL is pointed at the selected device  
  instead of changing the system default input (which affected every other app).        
  - loopEnabled wired up — one‑shot vs. loop playback, with a generation guard so a   
  stale completion handler can't stop a later playback.                                 
  - Delay‑line COW — removed per‑sample copy‑on‑write in Chorus/Flanger.              
  - Dead code / hygiene — removed tracksBaseURL, ScreenBezel, HeaderBar; added          
  .gitignore for build outputs.                                                         
                                                                                        
  ---                                                                                   
  Phase 3 — God‑object split (Stages 0–16)                                            
                                                                                        
  Goal: decompose AudioManager into cohesive types across multiple .swift files with no 
  behaviour change and no view churn.                                                   
                                                                                      
  Approach (facade pattern): AudioManager stays the single ObservableObject; every      
  @Published property stays physically on it. Each subsystem is a plain final class (not
   Observable) holding private unowned let manager: AudioManager, owning behaviour +    
  private engine/algorithm state, and mutating published state through that reference so
   objectWillChange fires exactly as before. Controllers never reference each other   
  directly — only via manager.<other> (star topology). Controllers are lazy var … =
  X(manager: self) and force‑touched in init so none can lazily initialize from a timer
  or audio thread.

  ┌───────┬─────────────────┬────────────────────────────────────────────────────────┐  
  │ Stage │     Commit      │                       Extracted                        │
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤  
  │ 0     │ 1c970ae         │ Multi‑file skeleton: monitor.swift → Sources/, build   │
  │       │                 │ wiring (package.sh, Xcode synchronized group)          │
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤  
  │ 1–7   │ e02af1e…ddb383f │ Pure moves: Theme, Models, Support, CoreAudioDevices,  │
  │       │                 │ EffectsCore+EffectsKernels, Views, App                 │  
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤
  │ 8     │ f1ec084         │ MetronomeController — click player, refill timer, tap  │  
  │       │                 │ tempo                                                  │  
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤
  │ 9     │ 8458ab5         │ DeviceController — device discovery, hardware          │  
  │       │                 │ listeners, CoreMIDI track‑follow                       │  
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤
  │ 10    │ 8fca8ef         │ EffectsChainController — chain nodes,                  │  
  │       │                 │ add/remove/reorder, bypass, params, presets            │  
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤
  │ 11    │ d068f3e         │ TransportController — playback, undo/redo, clip        │  
  │       │                 │ editing, mixdown                                       │  
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤
  │ 12    │ ac1492d         │ MeterController — lock‑guarded snapshot, taps, display │  
  │       │                 │  timer, smoothing                                      │  
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤
  │ 13    │ 4200336         │ RecordingController — dry take capture, count‑in,      │  
  │       │                 │ timers                                                 │  
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤
  │ 14    │ 488985d         │ ProjectController — .xyproj save/load                  │  
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤  
  │ 15    │ 8d470ad         │ EngineController — AVAudioEngine graph spine + async   │
  │       │                 │ kernel insert                                          │  
  ├───────┼─────────────────┼────────────────────────────────────────────────────────┤
  │ 16    │ 12baca5         │ Facade cleanup — header/imports trimmed                │  
  └───────┴─────────────────┴────────────────────────────────────────────────────────┘  
                                                                                      
  Invariants preserved verbatim during the split: the process‑wide                      
  pendingKernelFactory/pendingSampleRate statics and the serialized one‑at‑a‑time     
  instantiateKernels recursion; the lock‑guarded meter snapshot with main‑thread‑only   
  smoothing; the never‑removed hardware listeners; the isMonitoring lifecycle.        
                                                                                      
  ---
  Final structure
                                                                                        
  Sources/ — 17 files, 6,233 lines total:
                                                                                        
  AudioManager.swift   273   facade (was ~5,700 in one file)                            
  Views.swift          2266                                                             
  EffectsKernels.swift  763                                                             
  TransportController   624                                                             
  EffectsCore.swift     493                                                             
  EngineController      262                                                             
  ProjectController     255                                                             
  MeterController       163 · RecordingController 128 · DeviceController 110            
  MetronomeController   198 · EffectsChainController 195                                
  App.swift 227 · Models 123 · CoreAudioDevices 69 · Theme 49 · Support 35              
                                                                                        
  AudioManager now holds only published state, the lazy controller refs, one‑line       
  forwarders, init/deinit, quantizeLabels, and canUndo/canRedo.                         
                                                                                        
  ---                                                                                   
  Verification                                                                        
                                                                                        
  - swiftc -typecheck -parse-as-library Sources/*.swift → EXIT=0 after every stage.   
  - ./package.sh → builds and signs after every stage.                                  
  - xcodebuild … -scheme Tape08 build → BUILD SUCCEEDED.                                
  - Each stage is one self‑contained, compiling commit; rollback is git revert <sha>.   
  - The 39 pre‑existing unstaged deletions elsewhere in the repo were left untouched    
  (committed only refactor files).                                                      
                                                                                        
  Not verified (needs the audio interface)                                              
                                                                                      
  Real USB capture, audible DSP, and the sample‑rate string. The manual smoke matrix —  
  lifecycle, record→play→loop, metronome/count‑in, metering, effects slot             
  add/reorder/bypass + presets, project round‑trip, undo/redo, trim/split/duplicate,    
  export/import/bounce, keyboard shortcuts — still needs a run on hardware (open "Tape 
  08.app").

---

# 8. Code Review — 2026-10-11 (`Sources/`)

Review of the current `Sources/` tree (17 files, 6,233 lines) after the Stage 0–16 facade split.
`swiftc -typecheck -parse-as-library Sources/*.swift` is clean (EXIT=0, zero warnings), and the
structure is coherent. Findings below are ordered by severity, each with a `file:line` anchor and a
concrete action. **Nothing here has been run against the audio interface** — the "verify" items are
the ones that only a real USB run can settle.

## 8.0 Reconciliation — what in Sections 1–7 is already done

The plan was written against the older `OPXYMultitrack` (`XYEffectPlugin` / bundle / node-graph)
codebase. The shipped app is different: a fixed linear **effect chain** of `EffectModule`s (Apple AUs
+ custom kernels), no bundles, no graph. Status of the Section 1 bugs:

| ID | Plan item | Status in current code | Where |
|----|-----------|------------------------|-------|
| UI-1 | Tape UI doesn't resize when panels shown | **Still valid** — `LoopGridView` reserves fixed `headerW 200 + controlsW 410 + hPad 56`; `SideEffectsPanelView` and `SettingsPanel` have their own fixed widths. Both panels open needs ≈1426 pt; window `minWidth` is 1060 → the lanes clip/compress. | `LoopGridView` `Views.swift:756` (constants `:775-777`), `SideEffectsPanelView` `:998`, `SettingsPanel` `:2200`, `App.swift:238` |
| UI-2 | No count-in | **Done** — `countInBars` + transport "CIN" cycle (`Views.swift:1455`) + `RecordingController` count-in timer. (Timing concern below, U1.) | `RecordingController.swift:151` (count-in `:156-161`) |
| UI-3 | Cannot split a recorded track | **Done** — `splitClipAtPlayhead` (⌘T). Limited: only the last take, only while playing (U2). | `TransportController.swift:588` |
| UI-4 | Remove neural amp | **Already absent** — no NAM/amp code anywhere. Nothing to do. | — |
| UI-5 | Touch zones too small | **Partially** — many hit areas are 18–28 pt (zoom, move/delete, track M/S/play). If touch/pointer is a target, raise to ≥44 pt with transparent padding. | `Views.swift` (`VerticalMeter` `:430`, `TrackControlsView` `:617`, lane controls) |
| UI-6 | Dials look weird | **Done** — `ArcKnob` is a 270° sweep from 135°, indicator dot, value readout. Needs a visual re-check only. | `Views.swift:48` |
| UI-7 | L/R levels too far apart | **Done** — Arrange `VerticalMeter`s are `HStack(spacing: 4)`. | `Views.swift:430`, `:1556` |
| UI-8 | Input/Position, Output/Loop misaligned | **Done** — aligned 2×2 grid with a fixed 100 pt first column. | `Views.swift:1556` |
| CL-1 | Unused code | **Valid** — see §8.5 for the concrete list. | — |

**Section 2 (modular plugin bundles / `AudioGraph` / C++ bridge) does not describe the shipped
design.** The app already has a working modular effect system — just not the bundle/graph one.
Recommend rebaselining (§8.6) rather than building Section 2 as written.

## 8.1 Correctness & concurrency (address before trusting a live run)

**C1 — Effect parameters race the audio render thread. ✅ FIXED** `EffectAudioUnit.setKernelParameter`
(`EffectsCore.swift:163`) is called from the main thread and writes plain `var` fields on the
kernel, while `internalRenderBlock` (`EffectsCore.swift:148`) calls `kernel.process(...)` on the
render thread and reads those same fields. No atomics, no lock. Individually word-sized `Float`s, so
mostly benign in practice, but it is a genuine data race and multi-field updates (e.g.
`TapeSaturationKernel`) can tear.
→ **Fixed by:** `EffectAudioUnit` gained a `renderLock` (`UnfairLock`, `Support.swift`) that both
`setKernelParameter` and the render block's `kernel.process` take, so a knob move can't tear a value
the DSP is reading. See §8.9.

**C2 — Async kernel insert is not cancelled by stop/start. ✅ FIXED** The kernel insert was an async
recursion sharing the *process-wide* statics `EffectAudioUnit.pendingKernelFactory` /
`pendingSampleRate` (`EffectsCore.swift:123`, `:126`), so a chain edit's `rebuildChain()`
(`EffectsChainController.swift:100`) → `stopMonitoring()`/`startMonitoring()` could start a second
recursion whose completion attached to a *different* engine at a *different* sample rate.
→ **Fixed by:** the insert now goes through `enqueueKernels` → `pumpKernelQueue`
(`EngineController.swift:216`, `:228`), which allows **at most one instantiation in flight
process-wide**, and each graph build carries a `kernelEpoch` (`:28`) so a completion from a
torn-down or restarted graph is discarded. See §8.9.

**C3 — Recording writes to disk from the render thread. ✅ FIXED** The dry tap closure
(`RecordingController.swift:60`) called `AVAudioFile.write` inside `installTap`, i.e. on the audio
thread. File I/O and allocation there is a classic drop-out source.
→ **Fixed by:** the tap now copies frames into a fixed interleaved ring (no I/O, no per-call
allocation on the render thread) that a background queue drains to disk. See §8.9.

**C4 — Heavy I/O still on the main thread in edit/export paths. ✅ FIXED** `computePeaks` was called
synchronously on main in `applyTrim`, `splitClipAtPlayhead`, `duplicateClip`, `importAudioFile` and
`RecordingController.stop`; `bounceMixdown` mixed every clip on main; project save copied audio on
main. On long takes this stalled the UI.
→ **Do:** route all of these through the existing off-main pattern (`loadTrackBuffer`) and hop back
to main to publish.
→ **Fixed by:** every one of those paths now captures what its work needs by value, runs the file
work on `DispatchQueue.global(qos: .userInitiated)`, and applies back on main through
`AudioManager.runOffMain(busy:work:apply:)`. Undo history is unchanged — `pushUndo()` still runs on
main against pre-mutation state, immediately before the mutation — and each apply re-resolves its
target by clip id and re-checks an edit epoch, so work superseded by undo/redo/clear/load is dropped
and the file it wrote is abandoned rather than leaked. `busyEdit` publishes while work is in flight
and the views disable the controls that start edits; its depth is reference-counted so overlapping
edits can't clear it early.

**C5 — `start()` while already monitoring built a second engine. ✅ FIXED.** `EngineController.start()`
(`EngineController.swift:39`) built a fresh `AVAudioEngine` on every call; the Monitor view's input
picker calls `startMonitoring()` without stopping first (`Views.swift:1949`), leaking the running
engine and leaving **two live graphs (doubled audio)**. Fixed by tearing down first when already
monitoring (top of `start()`).

## 8.2 Robustness & data integrity

**H1 — Non-functional clip fades. ✅ FIXED** `TrackClip.fadeIn/fadeOut` (`Models.swift`) were
stored, copied on duplicate, and never applied — playback and mixdown ignored them, so entries and
exits could still click.
→ **Do:** apply the fades in `bounceMixdown` and at schedule time, or delete the fields.
→ **Fixed by:** `applyClipFades` (`Support.swift:61`) is applied both at schedule time
(`loadTrackBuffer`, `TransportController.swift:1036`, call at `:1056`) and in `bounceMixdown` (`:898`,
call at `:924`), so playback and export agree.

**H2 — Edits only ever touch the last clip. ✅ FIXED** `openTrimEditor`/`applyTrim`,
`splitClipAtPlayhead`, `duplicateClip` and `exportTrack` all used `clips.last`, and there was no clip
selection in the UI, so a track with several takes could only edit the most recent.
→ **Do:** add clip selection (or per-clip actions), or document the last-clip-only rule.
→ **Fixed by:** `AudioManager.selectedClipID` (a `UUID`, deliberately outside `tracks` so selecting
a take is never an undo step) is set by clicking a clip in the timeline or with ⌘1–⌘8, and
`editTargetIndex(on:)` resolves it at use time, falling back to the last take when it doesn't — the
behaviour every edit had before selection existed. TRIM, DUP, IMPORT and EXPORT now act on the
selection; every surface that names the current take (lane highlight, track header, transport bar,
FX header, trim header, Monitor's selected-track readout) resolves through the same function, so
none can contradict the edit keys. The selection is re-pointed when an op installs a clip, but only
while the user hasn't moved it since that op was dispatched (these applies run off-main), and it is
cleared on `clearAll` and project load. **Split is still confined to the last clip** — the playhead
is a fraction of the clip the engine has loaded — so it targets the selection only when that is the
last take and posts a status otherwise; that limit is U2. A successful split re-points at the second
half, which is the new last take, so ⌘T stays repeatable.

**H3 — Orphaned audio files accumulate. ✅ FIXED** Undo/`clearAll`/trim/split/duplicate removed
clip *references* but never deleted the WAVs they produced, so disk grew unbounded across sessions.
→ **Do:** on replace/clear, delete files no longer referenced (respect Undo: keep a trash set, or
sweep unreferenced files when the undo stack drops them).
→ **Fixed by:** `collectOrphanedFiles()` sweeps session-created files that no remaining clip
references, where the referenced set spans the current tracks plus every undo/redo snapshot — so a
trim/split/clear stays undoable until its pre-op snapshot ages out of the 30-deep stack. Files an
in-flight edit has written but not yet referenced are exempt (`registerPendingFile`), and imported
originals are never registered at all, so the sweep can't delete the user's own audio.

**H4 — Built-in presets clobber user presets on every launch. ✅ FIXED** `installBuiltInPresets`
rewrote `Clean/Warm/Ambient/Lo-Fi` unconditionally at `AudioManager.init`, so a user who saved over
one of those names lost their edit silently.
→ **Do:** write built-ins only if absent, or namespace them (`_builtin/…`).
→ **Fixed by:** built-ins are seeded only when the preset file is absent.

**H5 — Input format assumes ≤2 channels.** `EngineController.start` connects
`inputNode → mainMixerNode` with the device's native `hwFmt` (`EngineController.swift:101`, connect
at `:115`). A multi-channel interface (e.g. 8-in) then meets stereo downstream; the mismatch can
throw on connect or need explicit downmix.
→ **Do:** set the input connection format to a 2-channel mixdown explicitly (or verify with a
multichannel device).

**H6 — Path traversal on project load.** `ProjectController.performLoad`
(`ProjectController.swift:165`) builds `packageURL.appendingPathComponent(cd.relativePath)` (`:207`)
with no sanitisation; a hand-edited `project.json` with `../` reads arbitrary local files.
→ **Do:** reject `relativePath` containing `..` / absolute components.

## 8.3 Performance

**P1 — 60 Hz invalidation of the whole view tree. ✅ FIXED (2026-10-12).** The display tick mutated
per-frame state that the whole tree observed. It now writes only into `LiveState`'s three focused
objects (`meters`, `trackMeters`, `playhead`), and each view observes the one it reads — see
`updatePlaybackProgress` (`TransportController.swift:162`) and `tick` (`MeterController.swift:130`).
`tracks[i].loopProgress` no longer exists; the per-track playhead is `LiveState.playhead.trackProgress`.
**Fixed by:** the P1 stage of the 2026-10-12 refactor; §8.7.

**P2 — `rebuildChain` rebuilds the entire engine on every chain edit.** Add/remove/reorder
(`addSlot` `EffectsChainController.swift:82`, `removeSlot` `:87`, `moveSlot` `:93`, all landing in
`rebuildChain` `:100`) does a full `stopMonitoring()`/`startMonitoring()` — expensive, drops track
playback, and feeds C2.
→ **Do:** insert/remove only the affected AU node(s) in place.

## 8.4 UX correctness

**U1 — Count-in is not aligned to the metronome grid.** `RecordingController.start`
(`RecordingController.swift:164`) uses a one-shot `Timer` for `secsPerBar * countInBars` (`:175-184`)
and then records; the metronome schedules its own beat grid from `play()` with a different phase. If
the metronome was already running, or the tempo changes, the count-in clicks won't line up with where
recording starts. Timer drift adds more error.
→ **Do:** drive the count-in from the metronome's `beatCount` (record on the N-th future beat).
*2026-10-12:* re-pressing REC now restarts the count *and* the clicks, so a re-arm is heard from bar
1 — but a first count still inherits whatever phase a running metronome is on. U1 stands.

**U2 — Split requires a playhead you can place.** `splitClipAtPlayhead`
(`TransportController.swift:701`) reads the live per-track playhead. H2 (2026-10-12) narrowed this:
the split now targets the *selected* take, though still only when that take is the track's last one.
The 2026-10-12 seek narrowed it further: dragging the bar ruler parks `seekFraction` and writes the
same value into `trackProgress`, so a *stopped* clip can now be split at the dragged position, and
the Settings button asks for a playhead rather than for playback (`Views.swift:2350`).
→ **Still missing:** the position can only be placed on the ruler's span (`BarRulerView`, normalised
per track and scaled to the longest clip), not inside a lane, and every track reads the same fraction
of its *own* clip rather than a shared tape position. `clips.last` is still the only take decoded and
played (`loadTrackBuffer`, `TransportController.swift:1156`), so trim, duplicate and split on an
earlier take are silent.
→ **Do:** a playhead you can place inside a lane, and real multi-clip playback for it to describe.

**U3 — MIDI track-follow reacts to every channel-voice message.** `DeviceController.setupMIDI`
(`DeviceController.swift:98`) selects a track on *any* UMP channel-voice type `0x2`, including
note-off and CC — so sustained controller traffic from the OP-XY will fight the user's track clicks.
→ **Do:** react only to note-on (or a dedicated channel/message).

**U4 — Metronome phase jump on tempo change.** `refill` (`MetronomeController.swift:121`) does
`player.stop(); player.play()` (`:126`) when BPM changes, resetting the beat phase to 0 (audible
hiccup).
→ **Do:** re-anchor `nextBeatFrame` to the current playhead without restarting the node.

## 8.5 Cleanup (CL-1, concrete)

Confirmed unused / dead — safe to delete:

- `EffectState` class — declared, never used (`EffectsCore.swift:87`).
- `reverbPresets` + `reverbLabel` — only self-referential (`Models.swift:117`, `:129`).
- `Recording` + `AudioManager.recordings` — written (`RecordingController.swift:257`,
  cleared at `TransportController.swift:373`) but **never read by any view**; delete the struct and
  the published array together.
- `TrackInfo.layerCount` (`Models.swift:54`), `Recording.durationString` (`Models.swift:31`).
- `Theme.shadow` (`Theme.swift:16`) — confirmed: no `Theme.shadow` reference anywhere.
- `TopBar.blinkOpacity()` — returns a constant 1.0; no-op (`Views.swift:401`, called at `:324`).
- `WindowAccessor` — only used with an empty callback `{ _ in }` (`App.swift:213`;
  struct at `Views.swift:1993`).
- `TrackFader.color` parameter — accepted, unused (`Views.swift:171`).
- `ReelView.cx` / `cy` — passed, unused (`Views.swift:1514`).

Other notes: `KeyboardShortcutMonitor` matches raw `keyCode`s (`App.swift:27-148`) → breaks on
non-US layouts (prefer `characters`/`charactersIgnoringModifiers`). Master bus is silently attenuated
`× 0.6` (`EngineController.swift:181, 314`), so the OUT knob never reaches unity — make this explicit
or remove it. Mixdown loops short clips up to the longest track (`bounceMixdown`,
`TransportController.swift:898`), which is surprising for an export — confirm it's intended.

## 8.6 Verification checklist (needs the USB interface)

Run `open "Tape 08.app"` and walk this matrix; it is the part the refactor could not self-verify:

- **Lifecycle & permissions** — first-run mic prompt, deny→message, start/stop, feedback warning.
- **Capture** — record a take, hear it back; confirm the take is **dry** (pre-FX).
- **Count-in (U1)** — with metronome on, 1/2/4-bar count-in: do clicks line up with the record start?
- **Count-in lifecycle (2026-10-12)** — press REC, then REC again while it counts: the count must
  restart from bar 1, clicks included, and the button must read `IN` while it runs. Press STOP
  mid-count: the count must end and nothing must be recorded. Press STOP mid-take: the take must be
  filed and playback stopped. Confirm no second take appears a few seconds after a STOP.
- **Seek (2026-10-12)** — drag the bar ruler while playing: the loop must restart from where the
  pointer was released, without a click at the join, and the per-track playhead must not snap back to
  zero. Drag to the far left: the loop restarts from the top. Drag while stopped: a stationary
  playhead appears in every lane that has a clip, at the same x as the ruler marker; PLAY must then
  start from there. STOP must clear it.
- **Metronome** — accent every 4, tap tempo, BPM change mid-play (U4), volume.
- **Metering** — L/R RMS + peak-hold + dB readout; per-track meters; check for UI hitching under load (P1).
- **Effects** — add/remove/reorder/bypass each of the 13 modules; sweep knobs and confirm audible
  change (C1); save/load a preset; confirm built-ins survive a relaunch (H4).
- **Project** — save → quit → reopen `.xyproj`; verify tracks, volumes, chain, BPM; test a missing
  audio file (reports count, still loads).
- **Editing** — undo/redo across trim/split/duplicate/import/volume/mute/solo; verify files on disk
  after undo/clear (H3).
- **Edits in flight (C4)** — with a long take, start trim / split / duplicate / import / record-stop
  and **undo and redo while the edit is still running**; the edit must be dropped, not applied on top
  of the restored state. Two duplicates inside one second must land on distinct filenames (C4a).
  Cancelling TRIM while APPLY is running must stay cancelled.
- **Trim / Split / Duplicate / Export (H2, U2)** — on a multi-take track, click a take and confirm
  TRIM, DUP and ⌘E act on **that** take; ⌘T must still refuse a non-last take with its status, and
  must still be repeatable after a successful split. Move the selection while an edit is in flight and
  confirm it is not yanked back when the edit lands. Then undo and confirm the highlight, the track
  header, the transport's `/ TAKE n/m`, the FX header and the trim header all name the same take.
- **Import / Export / Mixdown** — drag-drop import; export a track; bounce; listen for clicks (H1).
- **Devices** — switch output while monitoring; unplug input; plug a >2-channel interface (H5).
- **MIDI** — touch OP-XY controls and confirm track-follow only on intended messages (U3).
- **Keyboard** — every shortcut in the list below; check a non-US layout (CL).

## 8.7 Updated priorities

| Priority | Task | Ref |
|----------|------|-----|
| ✅ done | ~~`C1` param thread-safety~~ · ~~`C2` async-insert epoch~~ · ~~`C3` render-thread file write~~ · ~~`C5` double-engine leak~~ | §8.9 |
| ✅ done | ~~`P1` 60 Hz whole-tree invalidation~~ · ~~`C4` off-main edit I/O~~ · ~~`H1` fades~~ · ~~`H2` clip selection~~ · ~~`H3` orphan files~~ · ~~`H4` presets~~ | §8.1–§8.3 |
| P0 | Fix `UI-1` tape layout when panels are open | §8.0 |
| P1 | `U1` count-in alignment; `U2` multi-clip playback & stationary edit playhead | §8.4 |
| P1 | `U3` MIDI filter, `U4` metronome phase | §8.4 |
| P2 | `H5` multichannel input, `H6` path traversal, `P2` in-place chain edits | §8.2, §8.3 |
| P2 | `UI-5` hit areas; visual re-check `UI-2/3/6/7/8` | §8.0 |
| P3 | `CL-1` dead-code sweep; keyboard layout | §8.5 |

**Landed 2026-10-12** (compile/link verified across all four gates; the audible and concurrent
behaviour still needs a hardware pass): `P1`, `C4`, `H1`–`H4`. See §8.1–§8.3 for what each fix
does. `U2` is the one that grew out of `H2`: only a track's last clip is decoded and played, so
trim and duplicate now work on any selected take but split is still confined to the last one.

**Landed 2026-10-12, from the first hardware run** — three transport faults reported together, none
of which compilation could have caught:

| Reported | Cause | Fix |
|---|---|---|
| STOP didn't stop | `stopAll` stopped playback and the metronome but not the recorder, so a pending count-in kept running and began recording after the stop | `TransportController.stopAll` now ends a pending count-in or an in-flight take too |
| REC didn't restart the count-in | that same pending count-in left `countingIn` set, so `start()` skipped its count-in branch and fell through to `begin()` | `start()` re-arms a running count from bar 1, and refuses while a take is rolling |
| No way to place playback | there was no seek control anywhere — the bar ruler had no gesture | dragging the ruler seeks; see §8.4 `U2` |

The third is a new feature rather than a repair, and the only one of the three still carrying real
risk: the seek schedules the buffer's **tail as a copy**, because `AVAudioPlayerNode` starts a
*buffer* at frame 0 and `scheduleSegment` — the only partway-in API — takes a file, which would drop
the anti-click fades `loadTrackBuffer` bakes in (`TransportController.swift:243`). Whether that join
is click-free is a listening test.

## 8.8 Section 2 rebaseline

Replace "# 2. Modular Sound Effects System" as written with the shipped reality and only keep the
parts still ahead of the code:

1. **Shipped:** `EffectModule` registry + `ChainSlot` chain + `EffectAudioUnit` kernel-host AU —
   document this as the plugin API (it already *is* the modular system).
2. **Keep as future work:** a bundle loader that scans
   `~/Library/Application Support/Tape08/Effects/*.bundle` and registers an `EffectModule` from a
   principal class — a thin layer over the existing registry, **not** a new graph engine.
3. **Deprioritise:** the port/node `AudioGraph` and the C++ `XYEffectDescriptor` bridge; neither is
   needed for the current linear-chain features and would duplicate working code.
4. Fold `C1` (param safety) and `C2` (insert lifecycle) from §8.1 into this section, since a real
   plugin host would inherit both.

---

## 8.9 Applied fixes — 2026-10-11

Audio-thread safety pass. One staged set of changes, no behaviour change for the UI.

| Finding | Fix | Files |
|---------|-----|-------|
| **C1** | `EffectAudioUnit` gained a `renderLock` (see `UnfairLock` in `Support.swift`); both `setKernelParameter` (main) and the render block's `kernel.process` take it, so a knob move can't tear a value the DSP is reading. | `EffectsCore.swift`, `Support.swift` |
| **C2** | Kernel insert reworked to `enqueueKernels` → `pumpKernelQueue`: **at most one instantiation in flight process-wide** (only `pump` writes the `EffectAudioUnit` statics), and each graph build carries an epoch so a completion from a torn-down/restarted graph is discarded instead of attaching to a dead engine. `start()`/`teardown()` bump the epoch. | `EngineController.swift` |
| **C3** | The dry tap copied frames into a fixed ~4 s interleaved ring (no I/O, no per-call allocation on the render thread); a background queue drains it to disk every 50 ms. `stop()`/`detach()` freeze the tap, flush the remainder, then release. Overflow is counted and reported in the status line. | `RecordingController.swift`, `Support.swift` |
| **C5** | `start()` now tears down an existing graph before building a new one, so the Monitor device picker can't leave two live engines (doubled audio). | `EngineController.swift` |

**Verified:** `swiftc -typecheck -parse-as-library Sources/*.swift` (EXIT=0), `./package.sh`, and
`xcodebuild -scheme Tape08` (BUILD SUCCEEDED) all pass. **Not yet verified on hardware** — the
audible result (no drop-outs while recording; correct DSP when adding/reordering effects mid-session)
still needs the OP-XY run in §8.6. `C4` (main-thread edit/export I/O) remains open by design; it is
not on the recording/effects critical path.             