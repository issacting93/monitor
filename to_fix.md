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
| UI-1 | Tape UI doesn't resize when panels shown | **Done (2026-10-12)** — the panels had since become overlays, so this row's "clip/compress" was out of date; the real defect was the opposite, 660 pt of panel *covering* a 1060 pt window. Fixed by pushing the workspace right by the open drawer's width. | `App.swift:220`, `:262`; `Theme.swift:41`; `AudioManager.swift:54` |
| UI-2 | No count-in | **Done** — `countInBars` + transport "CIN" cycle (`Views.swift:1455`) + `RecordingController` count-in timer. (Timing concern below, U1.) | `RecordingController.swift:151` (count-in `:156-161`) |
| UI-3 | Cannot split a recorded track | **Done** — `splitClipAtPlayhead` (⌘T). Limited: only the last take, only while playing (U2). | `TransportController.swift:588` |
| UI-4 | Remove neural amp | **Already absent** — no NAM/amp code anywhere. Nothing to do. | — |
| UI-5 | Touch zones too small | **Done (2026-10-12)** — track play/M/S are drawn at 28 pt inside a 44 pt target, chain-editor chevrons and delete 24 → 32, iOS card and top bar controls 44. One deliberate exception below 44: the zoom/follow trio is 44 × 18, because that row is the grid's vertical rhythm and growing it moves all eight track rows. | `Views.swift:41`, `:632`, `Views_iOS.swift` |
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
(`loadTrackBuffer`, `TransportController.swift:1155`, call at `:1175`) and in `bounceMixdown` (`:1017`,
call at `:1043`), so playback and export agree.

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

**H5 — Input format assumes ≤2 channels. ✅ FIXED (2026-10-12)** `EngineController.start` connected
`inputNode → mainMixerNode` with the device's native `hwFmt` (`EngineController.swift:101`, connect
at `:116`). A multi-channel interface (e.g. 8-in) then met stereo downstream; the mismatch can throw
on connect or need explicit downmix.
→ **Fixed by:** the input connection uses `stereoFmt` when `hwFmt.channelCount > 2` (`:116`) —
same sample rate, so the converter the mixer inserts is a channel map rather than a resample — and
at two channels or fewer the connection is byte-identical to before. The status line names the
count (`8 ch → stereo`) so a multichannel device is visible rather than guessed at. **Hardware-only
verification:** whether a given interface downmixes cleanly is not something a compiler or a
simulator settles.

**H6 — Path traversal on project load. ✅ FIXED (2026-10-12)** `ProjectController.performLoad`
(`ProjectController.swift:165`) built `packageURL.appendingPathComponent(cd.relativePath)` — now at
`:249`, inside the helper below — with no sanitisation; a hand-edited `project.json` with `../` reads
arbitrary local files.
→ **Fixed by:** `resolveInPackage(_:packageURL:)` (`ProjectController.swift:240`) rejects an empty
or absolute path, rejects any component that is empty, `.` or `..`, **and** re-checks containment by
comparing the resolved URL's path against the package root's — components alone are not enough,
because a symlink *inside* the package defeats a purely lexical check. Both sides are resolved
before comparing, since the package itself can be reached through a symlink (`/tmp` is one). Rejected
entries are counted in the load status ("2 paths outside the project") so a tampered manifest is
visible rather than silently skipped. The save side needed nothing: its `relativePath` comes from
`clip.url.lastPathComponent`, always one component.

## 8.3 Performance

**P1 — 60 Hz invalidation of the whole view tree. ✅ FIXED (2026-10-12).** The display tick mutated
per-frame state that the whole tree observed. It now writes only into `LiveState`'s three focused
objects (`meters`, `trackMeters`, `playhead`), and each view observes the one it reads — see
`updatePlaybackProgress` (`TransportController.swift:167`) and `tick` (`MeterController.swift:130`).
`tracks[i].loopProgress` no longer exists; the per-track playhead is `LiveState.playhead.trackProgress`.
**Fixed by:** the P1 stage of the 2026-10-12 refactor; §8.7.

**P2 — `rebuildChain` rebuilds the entire engine on every chain edit.** Add/remove/reorder
(`addSlot` `EffectsChainController.swift:82`, `removeSlot` `:87`, `moveSlot` `:93`, all landing in
`rebuildChain` `:100`) does a full `stopMonitoring()`/`startMonitoring()` — expensive, drops track
playback, and feeds C2.
→ **Do:** insert/remove only the affected AU node(s) in place.

## 8.4 UX correctness

**U1 — Count-in is not aligned to the metronome grid. ✅ FIXED (2026-10-12)** `RecordingController.start`
(`RecordingController.swift:160`) used a one-shot `Timer` for `secsPerBar * countInBars` and then
recorded; the metronome schedules its own beat grid from `play()` with a different phase.
If the metronome was already running, or the tempo changed, the count-in clicks didn't line up with
where recording started. Timer drift added more error.
→ **Fixed by:** the grid is now the only clock. `MetronomeController` records each beat it schedules
— index and the frame on the player node's own timeline — while an observer is installed, and a
10 ms poll on the common run-loop mode fires it for beats that clock has reached
(`observeBeats` `MetronomeController.swift:209`, `pollBeats` `:238`). Reading the audio clock rather
than counting down a wall-clock interval is what removes the drift; the poll only bounds how late a
beat is noticed. Arming rebuilds the table from the beats already queued (`rebuildBeatTable` `:254`),
which is what stops the first count from waiting out the two-second lookahead in silence.
`RecordingController.start` arms that observer instead of the timer and waits for the next bar line
plus `4 × countInBars` beats (`countInBeat` `RecordingController.swift:209`). A re-arm re-targets the
next bar line and **does not restart the node**, which is what used to pull the clicks out of phase
with a track already looping. The wall clock survives only as the fallback for a user with the clicks
switched off, where there is no node to observe and the count is silent either way. `stop()`,
`detach()` and the tempo-change branch all clear the table — a frame from a dead timeline would have
the count start against a beat that never sounds.
→ **Residual, needs an ear:** the take still begins at a render-callback boundary, so the first
sample lands within the poll interval (≤10 ms) of the downbeat rather than exactly on it. Whether
that is audible is a hardware question, not a compile-time one.

**U2 — Split requires a playhead you can place.** `splitClipAtPlayhead`
(`TransportController.swift:700`) reads the live per-track playhead. H2 (2026-10-12) narrowed this:
the split now targets the *selected* take, though still only when that take is the track's last one.
The 2026-10-12 seek narrowed it further: dragging the bar ruler parks `seekFraction` and writes the
same value into `trackProgress`, so a *stopped* clip can now be split at the dragged position, and
the Settings button asks for a playhead rather than for playback (`Views.swift:2356`).
→ **Still missing:** the position can only be placed on the ruler's span (`BarRulerView`, normalised
per track and scaled to the longest clip), not inside a lane, and every track reads the same fraction
of its *own* clip rather than a shared tape position. `clips.last` is still the only take decoded and
played (`loadTrackBuffer`, `TransportController.swift:1155`), so trim, duplicate and split on an
earlier take are silent.
→ **Do:** a playhead you can place inside a lane, and real multi-clip playback for it to describe.

**U3 — MIDI track-follow reacts to every channel-voice message. ✅ FIXED (2026-10-12)**
`DeviceController.setupMIDI` (`DeviceController.swift:98`) selected a track on *any* UMP
channel-voice type `0x2`, including note-off and CC — so sustained controller traffic from the OP-XY
will fight the user's track clicks.
→ **Fixed by:** the guard now requires note-on with a non-zero velocity — kind `(status >> 4) & 0xF ==
0x9` and `word & 0xFF > 0`, velocity 0 being the running-status note-off convention whatever the
status nibble says. Everything else a channel-voice message can be (note-off, CC, program change,
aftertouch) names a channel too, and those now fall through. The `midiTrackFollow` gate and the
channel bound are unchanged.

**U4 — Metronome phase jump on tempo change. ✅ FIXED (2026-10-12)** `refill`
(`MetronomeController.swift:132`) answered a BPM change with `player.stop(); player.play()` (the
branch now opens at `:140`, the restart at `:150`). The restart is right — the queue holds ~2 s of
beats already spaced at the old tempo and nothing can re-space a queued buffer — but it used to reset
the phase to 0 (`nextBeatFrame = 0; beatCount = 0`), which is the audible hiccup and the bar silently
restarting.
→ **Fixed by:** the phase is carried across the restart. The elapsed fraction of the beat in
progress is read before the stop and expressed from the node's new zero afterwards —
`nextBeatFrame = (1 - phase) * newInterval` — so the click that was due arrives when it was due.
`beatCount` is deliberately left alone, so the accent pattern continues on the same beats of the bar
instead of restarting the bar under the user. The beats queued on the old timeline are dropped from
the observer's table in the same branch, since their frames no longer mean anything.

## 8.5 Cleanup (CL-1, concrete) — ✅ DONE (2026-10-12)

Confirmed unused / dead, all now deleted (`16c62ee`). The anchors below are as they were *before*
the deletion, since that is what the sweep had to find:

- `EffectState` class — declared, never used (`EffectsCore.swift:87`).
- `reverbPresets` + `reverbLabel` — only self-referential (`Models.swift:117`, `:129`).
- `Recording` + `AudioManager.recordings` — written (`RecordingController.swift:257`,
  cleared at `TransportController.swift:373`) but **never read by any view**; struct and published
  array went together.
- `TrackInfo.layerCount` (`Models.swift:54`), `Recording.durationString` (`Models.swift:31`).
- `Theme.shadow` (`Theme.swift:16`) — confirmed: no `Theme.shadow` reference anywhere.
- `TopBar.blinkOpacity()` — returned a constant 1.0; no-op (`Views.swift:401`, called at `:324`);
  the call site is now a plain `.opacity(1)`.
- `WindowAccessor` — only used with an empty callback `{ _ in }` (`App.swift:213`;
  struct at `Views.swift:2039`).
- `TrackFader.color` parameter — accepted, unused (`Views.swift:171`).
- `ReelView.cx` / `cy` — passed, unused (`Views.swift:1560`).

A green typecheck is unusually strong evidence here: deleting a symbol cannot change behaviour if
nothing referenced it, and the compiler proves the absence of references.

**Keyboard layout — ✅ DONE (2026-10-12, `11878c7`).** `KeyboardShortcutMonitor` matched raw
`keyCode`s (`App.swift:27-148`), i.e. ANSI *positions*, so the bindings moved on a non-US layout.
It switches on `event.charactersIgnoringModifiers` lowercased now. Two consequences worth knowing:
Return (CR) and keypad Enter (ETX) collapse into one case, and the Cmd-guarded zoom keys accept `=`
with `+` and `-` with `_` rather than assuming the unshifted glyph. This is a **behaviour** change —
it deliberately re-points each binding at the printed key — so it is its own commit.

Still open, unrelated to this sweep: the master bus is silently attenuated `× 0.6`
(`EngineController.swift:181, 314`), so the OUT knob never reaches unity; mixdown loops short clips
up to the longest track (`bounceMixdown`, `TransportController.swift:1017`), which is surprising for
an export.

## 8.6 Verification checklist (needs the USB interface)

Run `open "Tape 08.app"` and walk this matrix; it is the part the refactor could not self-verify:

- **Lifecycle & permissions** — first-run mic prompt, deny→message, start/stop, feedback warning.
- **Capture** — record a take, hear it back; confirm the take is **dry** (pre-FX).
- **Count-in (U1, rewritten 2026-10-12)** — with the metronome on, 1/2/4-bar count-in: **bar 1 of the
  count must carry the accent**, and recording must start on the downbeat that ends the count, not
  near it. The count rides the click grid now instead of a `240/BPM × bars` timer, so the three
  things to listen for are: the accent is on the count's own first click; the take's first sample
  lands on the bar line (≤10 ms late by construction — whether that is audible is the question); and
  the clicks do not drift late across a long count. With a track **already looping**: start a
  count-in, and re-press REC mid-count — the clicks must stay in phase with the loop, which they did
  not before, because a re-arm restarted the metronome node.
- **Count-in lifecycle (2026-10-12)** — press REC, then REC again while it counts: the count must
  re-target the **next bar line** (bar 1 of the new count carries the accent) and the button must read
  `IN` while it runs. Press STOP mid-count: the count must end and nothing must be recorded. Press
  STOP mid-take: the take must be filed and playback stopped. Confirm no second take appears a few
  seconds after a STOP. Then switch the metronome **off** and press REC with a count-in set: the
  count is silent and the take still starts after the same wall-clock waits — the fallback path, since
  there is no click node to observe.
- **Seek (2026-10-12)** — drag the bar ruler while playing: the loop must restart from where the
  pointer was released, without a click at the join, and the per-track playhead must not snap back to
  zero. Drag to the far left: the loop restarts from the top. Drag while stopped: a stationary
  playhead appears in every lane that has a clip, at the same x as the ruler marker; PLAY must then
  start from there. STOP must clear it.
- **Metronome** — accent every 4, tap tempo, volume. **BPM change mid-play (U4, 2026-10-12):** the
  click spacing must change with **no bar reset** — the accent must stay on the same beat of the bar
  rather than jumping to a downbeat — and the click that was already due must still arrive when it was
  due. Nudge the tempo up and down a few times in a row; the phase should walk, not hiccup.
- **Metering** — L/R RMS + peak-hold + dB readout; per-track meters; check for UI hitching under load (P1).
- **Effects** — add/remove/reorder/bypass each of the 13 modules; sweep knobs and confirm audible
  change (C1); save/load a preset; confirm built-ins survive a relaunch (H4).
- **Project** — save → quit → reopen `.xyproj`; verify tracks, volumes, chain, BPM; test a missing
  audio file (reports count, still loads). **Tampered manifest (H6, 2026-10-12):** hand-edit a
  `project.json` so a `relativePath` contains `../` — the load must report those clips among the
  missing ones and must read nothing outside the package. A path that is absolute, empty, `.`/`..`,
  or that escapes via a symlink inside the package must all be rejected the same way.
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
- **Devices** — switch output while monitoring; unplug input. **Multichannel input (H5,
  2026-10-12):** plug an interface with more than 2 inputs. It must connect and monitor instead of
  failing at the first input connection, and the status line must name the input's channel count so
  a downmix is visible rather than guessed at. Listen for channel loss or comb filtering — the
  input's own converter is doing a channel map here, and whether a given interface folds 8 into 2
  cleanly is not something a compiler settles. A ≤2-channel device must behave exactly as before.
- **MIDI** — touch OP-XY controls and confirm track-follow fires on **note-on with velocity > 0**
  only (U3, 2026-10-12): note-offs, CC, program change and aftertouch must not move the selected
  track. Play a sustained note and wiggle a mod wheel at the same time — the track selection must
  not flicker.
- **Keyboard** — every shortcut in the list below. The bindings are matched by the **printed
  character** now, not the key's physical position (2026-10-12), so check them on your own layout,
  including Cmd+`+`/Cmd+`-` where `+` needs Shift, and Return: keypad Enter and the main Return key
  are the same binding now.
- **Layout / hit areas (UI-1, UI-5, 2026-10-12)** — open the FX drawer: the tape must slide right so
  nothing sits under the panel; open Settings: it must close FX, and vice versa. Close both and the
  tape returns. Resize down to the 1280 pt minimum with a drawer open — the lane region must still
  show its right-hand column rather than clipping. Then, with the pointer only: reach track
  play / M / S, the grid's zoom / follow trio, the chain editor's reorder chevrons and delete, and
  the iOS card controls. Nothing must have reflowed to get them there — in particular a 12-slot
  chain must be the same height it was. The zoom / follow trio is **44 × 18**, not 44 × 44: it is
  boxed in above by the header's top edge and below by track 1's select button, which as the later
  sibling wins any overlap. Confirm it is comfortably clickable at that size, or say so if it is not
  — that is the one target in this batch that could not reach HIG's 44 pt on both axes.

## 8.7 Updated priorities

| Priority | Task | Ref |
|----------|------|-----|
| ✅ done | ~~`C1` param thread-safety~~ · ~~`C2` async-insert epoch~~ · ~~`C3` render-thread file write~~ · ~~`C5` double-engine leak~~ | §8.9 |
| ✅ done | ~~`P1` 60 Hz whole-tree invalidation~~ · ~~`C4` off-main edit I/O~~ · ~~`H1` fades~~ · ~~`H2` clip selection~~ · ~~`H3` orphan files~~ · ~~`H4` presets~~ | §8.1–§8.3 |
| ✅ done | ~~`UI-1` drawer covers the tape~~ · ~~`UI-5` hit areas~~ · ~~`CL-1` dead code~~ · ~~keyboard layout~~ | §8.0, §8.5 |
| ✅ done | ~~`U1` count-in alignment~~ · ~~`U3` MIDI filter~~ · ~~`U4` metronome phase~~ · ~~`H5` multichannel input~~ · ~~`H6` path traversal~~ | §8.2, §8.4 |
| **P1** | **`U2`** multi-clip playback & stationary edit playhead | §8.4 |
| **P2** | **`P2`** in-place chain edits (incl. kernel splice order) | §8.3 |
| P2 | visual re-check `UI-2/3/6/7/8` | §8.0 |

Two rows are left, and both are deliberately held back: `U2` and `P2` each rewrite the audio path —
decode/scheduling and the engine graph respectively — and the count-in and seek work they would sit on
top of has still not been on the OP-XY. Landing them before the hardware pass would make the next run
unattributable. See "Second run" below for what each does.

**Landed 2026-10-12** (compile/link verified across all four gates; the audible and concurrent
behaviour still needs a hardware pass): `P1`, `C4`, `H1`–`H4`. See §8.1–§8.3 for what each fix
does. `U2` is the one that grew out of `H2`: only a track's last clip is decoded and played, so
trim and duplicate now work on any selected take but split is still confined to the last one.

**Landed 2026-10-12, from the first hardware run** — three transport faults reported together, none
of which compilation could have caught:

| Reported | Cause | Fix |
|---|---|---|
| STOP didn't stop | `stopAll` stopped playback and the metronome but not the recorder, so a pending count-in kept running and began recording after the stop | `TransportController.stopAll` now ends a pending count-in or an in-flight take too |
| REC didn't restart the count-in | that same pending count-in left `countingIn` set, so `start()` skipped its count-in branch and fell through to `begin()` | `start()` re-arms a running count — now at the **next bar line** rather than from bar 1, per `U1` below — and refuses while a take is rolling |
| No way to place playback | there was no seek control anywhere — the bar ruler had no gesture | dragging the ruler seeks; see §8.4 `U2` |

The third is a new feature rather than a repair, and the only one of the three still carrying real
risk: the seek schedules the buffer's **tail as a copy**, because `AVAudioPlayerNode` starts a
*buffer* at frame 0 and `scheduleSegment` — the only partway-in API — takes a file, which would drop
the anti-click fades `loadTrackBuffer` bakes in (`TransportController.swift:240`). Whether that join
is click-free is a listening test.

**Landed 2026-10-12, the deferred list** — eight commits, all four gates green after each, in the
order they were planned (lowest risk first). Nothing here has been on the OP-XY yet; §8.6 carries the
checks each one needs.

| Commit | What changed | Verified by |
|---|---|---|
| `f87adb2` | `U3` — MIDI track-follow requires note-on with velocity > 0 | compile only; the message filter is a pure predicate |
| `77884df` | `U4` — tempo change carries the beat phase across the node restart | compile only; needs an ear (§8.6) |
| `5314918` | `H5` — an input with >2 channels connects through `stereoFmt` | compile only, **and hardware-only by nature** |
| `ab46dd5` | `H6` — manifest paths resolved inside the package, symlinks included | compile + reasoning; needs a tampered manifest (§8.6) |
| `16c62ee` | `CL-1` — dead code removed | compile; a green typecheck *is* the proof here |
| `11878c7` | keyboard — bindings matched by character, not key position | compile only; needs the user's own layout (§8.6) |
| `c30ca8b` | `UI-1` — drawers push the workspace right and are mutually exclusive | compile; needs the eye (§8.6) |
| `3b1ed57` | `UI-5` — hit areas grown to 44 pt where the layout allows | compile; needs the pointer (§8.6) |
| `cfdb538` | `U1` — the count-in rides the click grid instead of a timer | compile only; needs the ear (§8.6) |

Two of these are worth flagging as *behaviour* changes rather than repairs, and each is its own
commit for that reason: the keyboard sweep re-points every binding at the printed key (so muscle
memory for a US layout is intact but a non-US layout now gets the *right* key), and `U1` changes when
a re-pressed count starts — the next bar line, not bar 1 immediately. The rest are defects being
removed.

The one place the plan and the result differ is `UI-5`'s zoom / follow trio: the plan called for
44 × 44, and it landed at **44 × 18**. A taller target is not available — above the row is the
header's top edge, so the parent `HStack` refuses the hit test, and below it is track 1's select
button, which as the later sibling wins any overlap. Widening was the only axis with room. It is
documented in the code comment at `Views.swift:835` and called out in §8.6 as the one target to
check with a pointer.

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