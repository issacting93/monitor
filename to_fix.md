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
- **Capture** — record a take, hear it back; confirm the take is **dry** (pre-FX). **Record → loop
  (2026-10-12, `3628f54`)** — check this as **two** cases, because a first take and a later take
  failed differently and only one of them was the silent one: (a) press REC on an **empty** track,
  record, press REC to stop — the take must **loop**, and until `3628f54` it did nothing at all,
  because `startTrackLoop` ran before the clip existed and bailed on its own guard; (b) press REC
  again on that **same** track — the new take must loop, and before the fix you would have heard the
  **previous** take instead, since the loop scheduled the stale cached buffer. Also check the STOP
  interaction, which is what `transportEpoch` was added for: start a take, press REC to stop, and hit
  STOP during the "Saving…" moment — no loop must start afterwards on a track you have just
  silenced. Works the same from the per-track REC arm and from either transport bar.
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
  change (C1); save/load a preset; confirm built-ins survive a relaunch (H4). **Bypass (2026-10-12,
  `9cf47ca`) — listen to this one specifically.** `setNodeBypass` set only `AVAudioUnitEffect.bypass`,
  which AVAudioEngine honours for Apple's three units but **not** for a custom AUv3: for the eleven
  kernel modules the render block ran regardless, so ON/BYP had never done anything audible. The
  unit now implements the bypass itself, in its render block. Measured offline before the fix, on a
  steady 1 kHz sine through the default chain: flanger swung the signal **634%**, chorus 68%, tremolo
  62%, compressor 12%, phaser 2.2%, distortion and tape-saturation changed the RMS outright, and the
  three Apple units on the identical call measured **0.0000** — the control that isolated it to the
  custom AU host. Post-fix every module measures 0.00% bypassed and identical to before when enabled.
  So: toggle ON/BYP on each of the eleven kernel modules and confirm the effect actually drops out,
  and confirm an enabled module still processes. This is a behaviour change, not a repair — the
  buttons did nothing before, so there is no prior behaviour to preserve.
- **Project** — save → quit → reopen `.xyproj`; verify tracks, volumes, chain, BPM; test a missing
  audio file (reports count, still loads). **Tampered manifest (H6, 2026-10-12, `ab46dd5`):** run
  `./Fixtures/make-h6-fixture.sh`, then Open Project → `Fixtures/build` → `H6-Tampered.xyproj`. The
  status line must read **`Loaded H6-Tampered (1 missing file, 6 paths outside the project)`**,
  track 1 must hold one clip, and tracks 2+ must be empty. The fixture carries all six hostile
  shapes — traversal, absolute, empty, `.`, `..`, and a symlink inside the package pointing out of
  it — each aimed at a file that **exists** (the traversal target is real audio, an octave below the
  good take, so a regression is *heard*), which is what makes a pass meaningful. If the guard
  regresses you would instead hear that second tone on track 2. `Fixtures/README.md` has the
  case-by-case table. Note the two failure kinds are reported **separately** — "N missing files" is
  a moved project, "M paths outside the project" is a hand-edited manifest, and a status line that
  folds them into one count is a regression of `ab46dd5` itself.
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

**Landed 2026-10-12, after the batch above** — two defects reported against the built app rather
than found by a compiler, both fixed once the deferred list had already landed. Listed separately
because neither is part of it:

| Commit | What changed | Verified by |
|---|---|---|
| `9cf47ca` | bypass — a slot's DSP runs only when the slot is on | **hardware-confirmed**; offline measurement put every module at 0.00% bypassed (§8.6) |
| `3628f54` | record — a take's loop starts when the take is *filed*, not at the REC press | compile only; needs a first take **and** a second take on one track (§8.6) |

The first is the phasing report: every slot is spliced into the graph whether or not it is enabled,
and bypass had been set with `AVAudioUnitEffect.bypass`, which AVAudioEngine does not honour for a
custom AUv3 — so the eleven kernel modules processed the monitor path whatever the slot said. Its
side effect is that ON/BYP had never done anything audible for those modules; it does now, which is
why §8.6's Effects row is worth *listening* to rather than ticking.

The second is "the recorded sound doesn't playback when I record a new track". `toggleTrackRecord`
called `startTrackLoop(i)` synchronously after `stopRecording()`, but the clip is filed off-main —
the peak decode is a full read of the file — so on a **first** take the `!clips.isEmpty` guard failed
and nothing ever played, and on a **later** take the loop started against the *previous* take's
cached buffer, so you heard the old one. One cause, two faces. The loop start now rides the filing
completion, and a new `transportEpoch` stops a STOP during that read from starting a loop the user
has already silenced. This was **not** a regression from `C4b`: the pre-`532c21b` source shows the
append was already dispatched, so the window is old — `C4b` widened it from one main-queue hop to a
full file read, which is what made it reproducible.

**Landed 2026-10-13** — §9 work, listed here as well because two of the five are defect repairs of the
same kind as the batch above: found against the built app, not by a compiler.

| Commit | What changed | Verified by |
|---|---|---|
| `bb52b9f` | the header's IN/OUT pickers actually switch the device — they assigned the published selection directly, and the engine reads it only at start time, so picking the OP-XY relabelled the picker and left the graph on the built-in mic | **hardware-confirmed by ear** — "yes it reads and there is sound". The first audio-path behaviour verified by listening in some time |
| `53fb570` | the status line names the device the audio is really going to, not the system default | compile only; the string is on screen |
| `66b24c4` | Return to Start seeks instead of stopping — it was an exact duplicate of Stop, because `stopAll` already returns to the start | compile only |
| `61b0611` | §9 Stage 6 — context menus on a take, a track header and the transport, plus Escape | compile only; needs a right-click and a keypress |
| `f4162de` | Delete clears the selected track's takes | compile only; the key mapping *was* verified against the live layout (`UCKeyTranslate`), which is what corrected an initial wrong guess |

All four gates green after each. Nothing in the batch touches the engine graph, so none of it needs
the OP-XY to be *trusted* — but `bb52b9f` is the one that changed the audio path, and it is also the
one that has been heard.

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

---

# 9. macOS platform conformance — 2026-10-12

## 9.0 Why this section exists

TAPE 08 looks like a Mac app and behaves like one in the audio path, but it is missing the parts a
Mac user meets *first* — and one of them is a data-loss bug rather than a polish gap.

The headline: **the app has no menu bar of its own.** On macOS the menu bar is the command-discovery
surface — where a user finds out what an app can do, where shortcuts are advertised, and where the
system looks for About, Settings, Undo and Quit. TAPE 08 implements ~28 keyboard shortcuts through a
global `NSEvent` monitor (`App.swift:12-167`) and **not one of them appears in a menu**, so the only
way to learn them is to read the source. That is the single largest gap in this section, and it is
also the cheapest to fix, because the actions all already exist on `AudioManager` as forwarders.

Whole-tree audit, 2026-10-12:

```
grep -rn "\.commands|CommandMenu|CommandGroup|Settings \{|orderFrontStandardAboutPanel|
          noteNewRecentDocumentURL|isDocumentEdited|representedURL|onOpenURL|handlesExternalEvents" Sources/
→ no matches
```

No menus. No Settings scene. No About. No document-open handling. No dirty indicator. No recents.

### 9.0.1 Status — updated 2026-10-13

Seven of the nine stages have landed, in the recommended order's first seven positions. The audit
block above and §9.6 are the **original 2026-10-12 snapshot** and are left in place as the record of
what the gap was; §9.6 carries a status column showing what has since changed, and the line numbers
there have been re-resolved.

| Stage | Status | Commits |
|---|---|---|
| 4 — dirty guard, title, frame | ✅ landed | `b841bb7` (quit guard) · `1230728` (title, edited dot, remembered frame) |
| 1 — the menu bar | ✅ landed | `3e35349` |
| 6 — context menus + Escape | ✅ landed | `61b0611` · `f4162de` (Delete) |
| 2 — Settings scene | ✅ landed | `6f8e503` (menu metronome) · `de99668` (the window) · `d0de50b` (preferences) · `d3af3a1` (devices) |
| 3 — About, Help, `CREDITS.md` | ✅ landed | `fb98d7b` |
| 5 — documents, recents, UTI, plist | ✅ landed | `b7537cb` (open event, Open Recent) · `48eb2b7` (bundle id, plists) |
| 7 — accessibility | ✅ landed | `7488c3b` (Reduce Motion) · `1717507` (never colour alone) · `fa3e053` (labels, values, adjustable actions) |
| 8 — tooltips, empty states, progress | not started | |
| 9 — Reveal, Share, notifications | not started | |

Three things landed that this section did not plan, two of them found against the built app rather
than by reading it. All three are recorded in §9.1.1: a pair of **device-selection defects** where
the header's IN/OUT pickers moved a label without moving the audio, a Transport item that duplicated
Stop, and — found while writing Stage 2 — the **Metronome item in the Transport menu**, which flipped
the flag without going through the controller that also stops the click generator.

**Research base:** Apple's *Building and customizing the menu bar with SwiftUI*; the community
codification in `sindresorhus/human-interface-guidelines-extras`; and the macOS design /
accessibility skill references (menu structure, Settings window rules, Reduce Motion, colour-only
signalling). Sources are linked at the end of this section.

### 9.0.2 Already conformant — do not re-do

- App Sandbox + hardened runtime (`Tape08/Tape08.entitlements`, `ENABLE_HARDENED_RUNTIME = YES`).
- `NSMicrophoneUsageDescription` in both plists.
- `LSApplicationCategoryType = public.app-category.music`, `NSHumanReadableCopyright`,
  `CFBundleDocumentTypes` for `.xyproj`, and `ITSAppUsesNonExemptEncryption = false` — **all in the
  Xcode plist only**; see Stage 5 for why the `package.sh` plist matters too. Since `48eb2b7` the
  generated plist carries all four as well, and the two agree on every shared key.
- `applicationShouldTerminateAfterLastWindowClosed` (`App.swift:271`).
- Minimum window size enforced at 1280×720 (`App.swift:263`).
- The `#if os(...)` platform seam is clean, so nothing here should need to touch the iPad build
  except where noted.

## 9.1 The stages

Nine stages, ordered by (impact on a Mac user) ÷ (risk to the audio path). Every stage is one
self-contained, independently revertible commit with the four gates of §9.9 run after it, per the
established workflow. Nothing in this section touches the engine graph, so none of it needs a
hardware run to be trusted — but anything that changes a *shortcut* needs the §8.6 keyboard check
re-run, because Stage 1 moves the bindings out of the monitor and into menus.

### Stage 1 — The menu bar (highest impact) — ✅ LANDED (`3e35349`)

**Problem.** Every action is invisible and every shortcut unlearnable. `Edit > Undo` does not exist,
so ⌘Z works but the menu says nothing; `File > Save` does not exist, so ⌘S is folklore.

**Change.** Add a `.commands { }` block to the `WindowGroup` scene in `App.swift` and move the
monitor's bindings into real menu items with `.keyboardShortcut(...)`. The actions are all already
public on `AudioManager` — this is wiring, not implementation.

| Menu | Items |
|---|---|
| **File** | New Project · Open… (⌘O) · Open Recent ▸ ✅ *(Stage 5)* · Save (⌘S) · Save As… (⌘⇧S) · Export Track… (⌘E) · Bounce Mixdown… · Close (⌘W) |
| **Edit** | Undo (⌘Z) · Redo (⌘⇧Z) — via `CommandGroup(replacing: .undoRedo)`, titled dynamically |
| **Transport** *(app-specific `CommandMenu`)* | Play/Stop (Space) · Record (R) · Return to Start (Return) · Metronome (,) · Tap Tempo · Quantize cycle · Loop toggle · Count-in ▸ (Off/1/2/4) |
| **Track** *(app-specific `CommandMenu`)* | Select 1–8 (1…8) · Mute (M) · Solo (S) · Select Take 1–8 (⌘1…⌘8) · Trim / Split (⌘T) / Duplicate (⌘D) |
| **View** | Arrange (**moved off Tab**, see below) · Monitor · Effects drawer · Settings · Zoom In (⌘+) · Zoom Out (⌘−) · Follow Playhead (F) |
| **Window / Help** | keep the system defaults; Help gains a documentation item in Stage 3 |

**The part that needs judgement.** A menu item and the `NSEvent` monitor must not both fire on the
same key — a menu shortcut is consumed by the menu, so a live monitor bound to the same key would
double-fire for keys the menu does not claim and silently lose the ones it does. The plan is
therefore to **delete each binding from the monitor as its menu item lands**, and to retire the
monitor entirely once every binding has moved. The monitor's `firstResponder` guard (don't hijack
keys while a text field is focused, `App.swift:18-21`) is the one behaviour menus do not need to
reproduce: a menu shortcut is not delivered while a text field has focus in the first place.

`space`, `Return`, `Tab`, `1`–`8` and `,` are all menu-representable (`KeyEquivalent` accepts them),
so the monitor should end up empty rather than reduced. **Delete it in this stage or the last one,
whichever leaves no orphan** — a half-migrated monitor is worse than either extreme.

**Disabled state.** Items carry `.disabled(...)` from the matching `AudioManager` predicate so the
menu greys out correctly: nothing to undo, no clip to split, no track selected, not monitoring.

**A live bug this stage fixes.** The audit found that ⌘Z and ⌘⇧Z are swallowed by the `NSEvent`
monitor while SwiftUI's **stock `Edit > Undo` / `Redo` items still exist in the menu bar**, bound to
the responder chain and fed by an `undoManager` this app never populates. So today the Edit menu
advertises Undo, greys it out as unavailable, and the shortcut works anyway — the worst of both. The
`CommandGroup(replacing: .undoRedo)` above is what makes the menu and the shortcut agree.

**The Tab binding is a real conflict, not a detail.** `Tab` currently switches Arrange/Monitor
(`App.swift:137-139`), but on macOS `Tab` is the keyboard-focus traversal key. Keeping it as a
command shortcut means the app can never gain keyboard focus navigation (Stage 7), because the menu
eats Tab before the focus system sees it. Move the view switch to a shortcut that is not reserved —
the plan is ⌃1 / ⌃2 (⌘1–⌘8 are already take-select) — and leave Tab to focus. **Decide this in
Stage 1**, because it is the
stage that makes Tab a menu key equivalent; changing it later means re-teaching a shortcut.

**What landed, 2026-10-12 (`3e35349`).** File (Open ⌘O · Save ⌘S · Save As… ⌘⇧S · Export Track… ⌘E ·
Bounce Mixdown…), Edit (`CommandGroup(replacing: .undoRedo)`, so Undo ⌘Z and Redo ⌘⇧Z now agree with
the menu — the live bug below is fixed), Transport (Play/Stop · Record · Return to Start · Metronome ·
Tap Tempo · Quantize · Loop · Count-In), Track (Mute · Solo · Split at Playhead ⌘T · Duplicate Last
Clip ⌘D · Select Track · Select Take ⌘1–⌘8), and View additions (Layout · Effects Chain · Follow
Playhead · Zoom In ⌘= · Zoom Out ⌘−).

**Four gaps against the table above, none of them accidental:**

1. **No New Project item.** There is no multi-window and no session-reset command to wire it to; a
   "New Project" would have to mean *clear everything*, which is `Clear All Tracks` under a name that
   hides what it destroys. Left out rather than faked.
2. **Open Recent — closed by Stage 5** (`b7537cb`). It is a submenu inside this File group rather
   than a group of its own, because SwiftUI has no `.recents` placement; putting it anywhere else
   would have landed it after Save and Bounce instead of under Open Project….
3. **No Trim menu item.** Trim is still reachable — the trim editor's own button (`Views.swift:2516`),
   and since Stage 6 a take's context menu — but it is absent from the menu bar, which is the one
   place §9.5 says a command belongs. Worth closing when Stage 2 opens the Settings scene.
4. **The Tab decision was not made.** `Tab` is *still* a monitor binding (`App.swift:110`) and the
   View menu's Layout picker carries no key equivalent, so the conflict this stage was told to settle
   is still open: the app cannot gain keyboard focus navigation (Stage 7) while the monitor eats Tab.

**And the monitor was not retired — deliberately.** The ⌘-modified bindings left it and now live in
the menu bar; the bare keys (Space, R, M, S, Delete, 1–8, Return, comma, Tab, F) stayed. Giving a bare
key a menu key equivalent is not the same trade as giving a ⌘ chord one: a menu key equivalent is
matched *ahead of* the responder chain, so it would fire inside a focused preset-name field. The
monitor's `firstResponder` guard is the protection a menu item cannot express, and the reasoning is
recorded in `Tape08Commands`' header comment so it does not read as a half-finished migration.

### Stage 2 — A real Settings window (⌘,) — ✅ LANDED (`6f8e503`, `de99668`, `d0de50b`, `d3af3a1`)

**Problem.** `showSettings` is a floating drawer holding what are, by HIG definition, *preferences*.
There is no ⌘, and no Settings item in the app menu.

**Change.** A `Settings { }` scene with `Form` + `.formStyle(.grouped)`, grouped into sections:
**Audio** (default input/output device, sample-rate readout, master limiter), **Recording** (save
location, default count-in bars, dry-take note), **Playback** (default BPM, metronome volume,
loop-by-default), **Timeline** (default zoom, follow playhead).

**Open decision — recorded so it is not re-litigated.** The drawer and the scene are *not* the same
thing and the split is deliberate: the **Settings scene holds persistent preferences** (what the app
should do next launch), the **FX drawer stays a drawer** (it is a live performance surface, not a
preference). `showSettings` in `App.swift:223` is retired; the gear in `TopBar` opens the scene. If
that split turns out wrong, the revert is one commit.

Per the HIG rules quoted in §9.5: not translucent, Escape must not close it (the `Settings` scene
gives this for free), traffic-light buttons disabled-but-present, and no About/licence tab inside it.

#### What landed, 2026-10-13

Four commits, not one, because the parts are independently revertible and one of them was a defect
found while writing the others.

| Commit | What |
|---|---|
| `6f8e503` | **Not this stage's work** — the Transport menu's Metronome item. See §9.1.1 |
| `de99668` | The `Settings {}` scene, `SettingsView.swift`, the gear as a `SettingsLink`, `showSettings` and the 206-line `SettingsPanel` deleted, `SettingsPanel`'s Trim button relocated to the Track menu |
| `d0de50b` | `Preferences.swift` — seven scalars write through from `AudioManager` |
| `d3af3a1` | `AudioDevice.uid`; the chosen input/output remembered across launches |

**Five consequences worth recording, because each changes behaviour rather than only layout.**

1. **The window is a preference store, so seven properties now persist.** Count-in bars, master
   limiter, click tempo and level, loop, timeline zoom, playhead follow. The doc called these
   "defaults"; they are bound to the live value, so the *live value is the preference* — load a
   project saved at 90 BPM and 90 is what the next launch starts at. Honest for a window that shows
   the current value, but it is a change from the previous always-120 startup.
2. **Device choice persists too**, by CoreAudio UID rather than by device id, which the HAL reuses.
   Restore sits ahead of the name heuristic in `loadDevices`; persist sits in the selection paths and
   deliberately *not* in `loadDevices`, whose fallback also fires when the remembered device is merely
   unplugged. Output keeps the system default ahead of a remembered device.
3. **The device rows were the one part of this window that needed routing, not binding.**
   `selectInput`, `selectOutput` and `toggleMasterLimiter` each do work beyond assignment — restart
   the graph, rebuild the aggregate, move a node's bypass — so a `$`-binding would have moved the
   control and left the audio where it was. That is the §9.1.1 bug this stage could easily have
   reintroduced three times over.
4. **Trim had to move to a menu.** `SettingsPanel` held the app's only Trim *button*; deleting the
   panel would have left Trim reachable only from a take's context menu, which §9.5 says belongs in
   the menu bar anyway. So `Track ▸ Trim…` is a requirement of this stage, not scope creep.
   EXPORT, SPLIT and DUP were already in menus.
5. **A fifth section, "Current Session", is a deviation.** The doc specifies four. The panel being
   deleted was the only place the session counts — clips, tracks used, effects active — appeared, so
   they are kept as a read-only section rather than silently dropped.

**Not a deviation:** the window uses a stock `Form` inside a `Settings` scene rather than the app's
retro theme. A `Form` in a `Settings` scene is drawn by the system, and the HIG rules quoted in §9.5
are about conforming to it rather than restyling it. The theme still governs the main window.

**Unverified without the hardware run:** the window's layout, that ⌘, and the app-menu item appear,
that the gear opens it, that Escape does *not* close it, the traffic-light state, and every
persistence round trip through a real launch. The store's accessor logic and the
`didSet`-over-`@Published` mechanism were both verified by probe (§9.4).

### Stage 3 — About panel, Help menu, and credits — ✅ LANDED (`fb98d7b`)

**Problem.** `CommandGroup(replacing: .appInfo)` is absent, so About shows the system default — but
more importantly there is nowhere that states the version, and **no attribution for the ported DSP**.
The product plan already asks for a `CREDITS.md`, and the effects are Airwindows ports
(`ARCHITECTURE.md` §1.8), which is a licensing obligation rather than a nicety.

**Change.** A custom About window (app icon, name, `CFBundleShortVersionString` +
`CFBundleVersion`, copyright, a credits line) reachable from the app menu, plus `CREDITS.md` and a
Help menu item pointing at it. This is the one stage with a **legal** motivation, so treat the
attribution text as required, not decorative.

#### What landed, 2026-10-13 — and where it departed from the above

**The obligation was worse than "no attribution".** MIT requires the copyright notice *and* the
permission notice to be included in all copies of the software. The notice existed as one comment in
`EffectsKernels.swift` — a source file, which is not a copy of the app. So nothing in the shipping
`.app` named where the DSP came from, which is precisely the case the licence exists to cover. The
full notice is now in the About panel's credits, inside the binary, reachable from the app menu and
from Help. The text is quoted from the Airwindows repository's own `LICENSE` — fetched and read
rather than written from memory — and it is quoted rather than paraphrased, because the wording *is*
the licence.

**The standard About panel, not a custom window.** A second departure from the doc's wording, and
the same reasoning as Stage 2's fifth section: the panel brings the icon, the name, the two version
strings from the bundle, the copyright, and its own sizing, so there is no layout of ours to get
wrong. A bespoke window would re-implement that for no visible gain and add one more surface that no
gate in §9.4 can check.

**Help** replaces the stock "TAPE 08 Help" item, which pointed at a help book this app does not have.
It opens the same panel, because the credits block *is* the licence text; a second copy in a bespoke
Help window would be a third place for the notice to drift.

**Two build-side things the panel forced, both found by trying:**

| Found | Fix |
|---|---|
| `NSApplication.AboutPanelOptionKey` has **no `copyright` member** — the panel reads `NSHumanReadableCopyright` from the bundle itself. The Xcode plist had the key; `package.sh`'s generated plist did not, so the dev build's panel would have had no copyright line | the key added to `package.sh` |
| `package.sh` wrote `CFBundleShortVersionString 1.0` / `CFBundleVersion 1.0`, where the project has `MARKETING_VERSION 1.0.0` / `CURRENT_PROJECT_VERSION 1`. Both are *shown* by the panel, so the dev build read "Version 1.0 (1.0)" — a build number that isn't one | aligned to the project's values, which shrinks Stage 5's reconciliation instead of adding to it |

**Verified.** `strings` *can* see a 1.4 KB licence text, whatever §9.4's correction says about short
literals — the grant, the requirement and the attribution line are each in the packaged binary once,
with a known long literal as a positive control and absent text as the negative. The generated plist
carries the copyright and the aligned version keys.

**Not verified:** that the panel appears, that its credits area is legible in both appearances, and
that the two menu items are where they should be. Running the app settles all three, and that is on
the hardware run's list.

### Stage 4 — Don't lose the user's work (correctness, not polish) — ✅ LANDED (`b841bb7`, `1230728`)

**Problem.** `projectDirty` exists and is maintained, but **nothing reads it on quit**.
`applicationShouldTerminateAfterLastWindowClosed` returns `true` (`App.swift:271`), so ⌘W or the red
button quits immediately and an unsaved project is gone with no prompt. Combined with
`.windowStyle(.hiddenTitleBar)` (`App.swift:266`) there is also **no edited dot and no filename** in
the title bar, so the user has no indication there is anything to lose. A looper records takes — this
is the stage where an unfixed gap costs real work.

**Change.** `applicationShouldTerminate` returns `.terminateLater` when `projectDirty`, shows a
Save / Discard / Cancel alert, and replies once resolved. In the other direction: a `WindowGroup`
title that carries the project name and `NSWindow.isDocumentEdited` so the dot appears. Either drop
`.hiddenTitleBar` or keep it and set `representedURL` — the second keeps the app's look, and is what
this stage should try first, since the title bar is part of the design the user has already signed
off on.

**Same stage, because it is the same "the window remembers the session" idea: the frame is not
saved either.** There is no `setFrameAutosaveName`, no `.defaultPosition`, and no `.defaultSize` —
nothing in `Sources/` touches `NSWindow` at all. The opening size is faked with
`.frame(minWidth: 1280, minHeight: 720)` (`App.swift:263`), which both fails to remember a resized
window *and* forces a 1280×720 window onto a smaller display. Give the scene a stable id and
`.defaultSize`, and autosave the frame. It is two lines, it is the kind of thing users notice
immediately, and it belongs with the dirty-state work rather than in a stage of its own.

### Stage 5 — Documents: open, recent, and a UTI — ✅ LANDED (`b7537cb`, `48eb2b7`)

**Problem.** The Xcode plist declares `.xyproj` as a document type with `LSHandlerRank = Owner`
(`Tape08/Tape08/Info.plist`), but **nothing handles the open event**, so double-clicking a project in
Finder launches the app and does nothing — which is worse than not claiming the type. There is no
Open Recent. There is no exported UTI, so the system invents a dynamic one. And the two plists have
**diverged**: `package.sh`'s has no category, no copyright, no document types, and a different
bundle id (`com.opxy.tape08` vs the Xcode project's `com.tape08.app`).

**Change.** Handle the open event (`.onOpenURL` on `ContentView`, or
`application(_:open:)` on the delegate) and route it to the existing `performLoad`. Add
`CommandGroup(replacing: .recents)` with `NSDocumentController.shared.noteNewRecentDocumentURL` on
every successful save/load. Declare `UTExportedTypeDeclarations` for the `.xyproj` UTI. Then make
`package.sh`'s plist agree with the Xcode one, and settle the bundle id — **the id is the one item
here that cannot be changed after shipping**, so it is a decision to make deliberately, not to
inherit from whichever file was edited last. While in the plist, set
`NSApplicationSupportsSecureRestorableState` (the audit found it absent) so macOS 14 stops warning
about it — and note that the *built* plist has neither `NSHumanReadableCopyright` nor
`LSApplicationCategoryType`, both of which the Xcode plist does carry, which is exactly the
divergence this stage exists to close.

**What landed, 2026-10-13 — and the two decisions in it.**

| Commit | What |
|---|---|
| `b7537cb` | `AppDelegate.application(_:open:)` → `performLoad`; Open Recent on `NSDocumentController`; `Sources/ProjectRecents.swift` |
| `48eb2b7` | bundle id settled; `UTExportedTypeDeclarations`; `NSApplicationSupportsSecureRestorableState`; the two plists reconciled |

**The bundle id was put to the user, not picked.** The doc says it is "the one item here that cannot
be changed after shipping, so it is a decision to make deliberately, not to inherit from whichever
file was edited last", so it was asked rather than resolved from the diff. The answer was
`com.tape08.app` — the Xcode target's id, kept; `package.sh` moved. The evidence for it: the Xcode
target is the sandboxed, Mac App Store-bound one, `README.md:154` documents the sandbox container as
`~/Library/Containers/com.tape08.app/`, and `ARCHITECTURE.md:374` gives the iPad sibling as
`com.tape08.app.ipad`, which only reads as a child of it. **Nothing had pinned it**: there are no
provisioning profiles in `~/Library/MobileDevice/` and `DEVELOPMENT_TEAM = ""`. That is what made it
free to settle here and expensive to settle later.

**`com.opxy.*` was deliberately left alone.** The obvious reading of "the bundle id was
`com.opxy.tape08`, so `opxy` is the namespace" is wrong: those strings are effect *registry keys*
(`com.opxy.tape-saturation`, `com.opxy.noise-gate`, …) which are written into `project.json` and into
saved presets. Renaming them to match the id would silently break every project already on disk. The
shared prefix was coincidence. Anything that later "aligns" them is a data-loss bug.

**Departures from the doc's wording, and why.**

- The doc offers `.onOpenURL` *or* `application(_:open:)`. The delegate method was chosen because the
  delegate already exists and already holds the `AudioManager`, and because on macOS a Finder
  double-click for a document type is delivered to the delegate rather than through SwiftUI's URL
  plumbing. It also made the launch-order problem explicit — see below — rather than latent.
- The doc says "route it to the existing `performLoad`". Doing that literally required a new public
  entry point (`ProjectController.open(at:)`), which is the one place this could have gone wrong: a
  second loader that trusted a URL more than the panel's would be a way around Stage 4's manifest
  checks. There is one `performLoad` and it is the only thing that reads a package.
- `UTTypeConformsTo` is `com.apple.package`, not `public.data`. The doc does not say which, and a
  project *is* a directory holding `project.json` plus an `Audio/` tree. That makes Finder show it as
  one document — a visible change, listed under what needs the hardware run.

**Two consequences of the new surfaces, one of them a real follow-up.**

- A project deleted from under Open Recent stays listed, so `performLoad` gained a "the package is
  gone" branch ahead of its "not a project" one. Reporting a missing `project.json` for a folder that
  isn't there describes the wrong problem.
- **Opening a project while the session is dirty replaces it with no prompt.** This is what ⌘O
  already did, so it is not a new defect — but Open Recent and Finder are two new routes to it, and
  the quit path (Stage 4) already has the alert this wants. Not fixed here: it is a session-lifecycle
  decision, not a document one, and it needs the same hardware pass as the rest. Its own item if
  wanted.

**What the gates could and could not settle.** Both typechecks, `./package.sh` and the Xcode build
were green. The recents store *is* testable headlessly, and was: a probe compiling
`Sources/ProjectRecents.swift` itself — not a restatement of it, the mistake §9.4 records — in a
scratch defaults domain showed two projects listed newest-first with a `.wav` filtered out, `clear`
emptying it, and **a second process reading back what the first wrote**, which is the survival claim
the feature actually makes. A non-existent `.xyproj` is refused, and that turned out to be
`noteNewRecentDocumentURL`'s own filter rather than ours — worth knowing, because it is why noting
on the *success* paths is safe and noting a path a save never reached would have been harmless anyway.
`application:openURLs:` is present in the shipped binary beside its sibling delegate selectors, with
negative controls absent; that says AppKit can reach the method, not that LaunchServices calls it.

The plist reconciliation is checkable and was checked: a scripted comparison of both plists' shared
keys, with the Xcode `$(…)` build settings resolved to their real values, reports **zero value
differences across all 17**, the nested `CFBundleDocumentTypes` and `UTExportedTypeDeclarations`
dictionaries included. Four keys differ on purpose, all about where resources live rather than what
the app is: `CFBundleIconFile` vs `CFBundleIconName` (no asset catalog on the dev path), and
`NSPrincipalClass`/`LSUIElement` (wanted by a hand-assembled bundle, supplied by Xcode anyway).

**Needs the OP-XY run:** whether Finder actually hands the URL over on a double-click; whether the
Open Recent submenu draws directly under Open Project… at all; whether a `.xyproj` now shows as one
document rather than a browsable folder; and whether the dev build's menu bar reads TAPE 08.

**One doc claim corrected while here.** `README.md:55-59` and `ARCHITECTURE.md:370-374` both describe
a `Tape08iPad/Tape08iPad.xcodeproj` with `com.tape08.app.ipad`. **There is no `Tape08iPad/`
directory in the tree** — `Tape08/` holds only `Tape08` and `Tape08.xcodeproj`. The references are
aspirational. They were still good evidence of the intended id *family*, which is why they are cited
above, but they are not a description of what exists.

### Stage 6 — Context menus, and Escape — ✅ LANDED (`61b0611`, `f4162de`)

**Problem.** `grep -rn "\.contextMenu" Sources/` finds none. Every right-click on the timeline, a
track header, a clip or the ruler does nothing, so the app's most natural surfaces are inert.

**Change.** `.contextMenu` on: a clip (Trim · Split at Playhead · Duplicate · Export · Select Take ·
Delete), a track header (Arm · Mute · Solo · Clear Track · Select Take 1–8), the bar ruler (Seek
Here), the transport (Play/Stop · Record · Return to Start). Per the HIG rule quoted in §9.5, a
context menu is the *relevant subset* of the menu-bar commands, not a different command set — so
this stage depends on Stage 1 having defined those commands, which is why it comes after it.

**Escape, while in the interaction stage.** Escape does nothing anywhere today: no `.onExitCommand`,
no `onKeyPress`, no Escape branch in the monitor. The Trim editor can only be dismissed by clicking
its CANCEL button (`Views.swift:2223-2233`), and the FX/Settings drawers likewise. Escape should
cancel trim, close whichever drawer is open, and clear the clip selection — in that order, one press
each. This is the same class of change as a context menu (an expected input that is silently inert),
so it rides in this stage rather than waiting for Stage 8.

**What actually landed — three of the four surfaces, not four.** `.contextMenu` on a take, a track
header and the transport. The ruler's **Seek Here is not there and cannot be**: `.contextMenu`
reports no click location, so "here" is not expressible — and the ruler already seeks on click and
drag (`DragGesture(minimumDistance: 0)`), so the item would have been redundant even if it worked.

Each menu carries the menu-bar commands appropriate to the thing clicked, and the take menu
**re-targets before every command that depends on the selection**. A right-click does not run the
click gesture, and the take commands all resolve through `editTargetIndex`, which reads
`selectedClipID` — so without that, right-clicking take 4 and choosing Split would have cut take 1
while appearing to act on take 4. `Duplicate` takes its index directly and is deliberately left
un-re-targeted.

**The two omissions in the plan's own table, and why.** `Delete` on a take and `Clear Track` on a
header were both listed. Neither operation existed. `clearAll` was global only, and there is no
per-take delete at all. Rather than invent destructive commands from a context menu — with the undo,
orphan-sweep and file-lifecycle questions that drag in — both were left out and reported as omitted.
`Clear Track` has since landed the honest way, as a real operation (§9.1.1 and `f4162de`), and it is
in both menus; **per-take delete still does not exist**, and the clip context menu still does not
offer it. Delete *is* in the clip menu's table row above, so that row is currently wrong.

`f4162de` also added the **Delete key**: it clears the selected track's takes. It could not have been
done as a menu key equivalent for the reason in Stage 1 — a bare key handed to the menu bar fires
inside a focused text field — so it lives in the monitor, behind the same `firstResponder` guard.
Two notes worth keeping: a track's **lane cannot be removed** (`tracks` is a fixed `Theme.trackCount`
array that the grid, the eight mixers and the MIDI channel map are all indexed by), so Delete empties
the track and leaves the lane; and the keys are matched as `\u{8}` (the Delete key) and `\u{7F}`
(fn+Delete) — `UCKeyTranslate` against the live layout gives exactly that pairing, which is the
reverse of what the ASCII names BS/DEL suggest, so do not "correct" it.

**Escape landed as `.onExitCommand`** on `ContentView` (`App.swift:435`), not as a monitor case.
The monitor hands back every event it does not claim, and a focused text field has first call on
Escape; a raw `NSEvent` branch would cancel a trim out from under a field the user is typing in.

### Stage 7 — Accessibility — ✅ LANDED

**Problem.** The app is entirely custom-drawn. Every control in §9.6's audit is a `Button` with a
drawn shape and no `accessibilityLabel`, so VoiceOver announces them as unlabelled buttons; mute,
solo and record state are signalled by **colour alone**; and animations are not gated on
Reduce Motion.

**Change, in three passes:**
1. **Labels** — `accessibilityLabel` + `accessibilityValue` on every icon-only or shape-only
   control, and `.accessibilityElement(children: .combine)` where a control is icon + text. Faders
   and knobs get a value and an adjustable action so VoiceOver can change them.
2. **Never colour alone** — mute/solo/record/armed states gain a shape or text difference, so they
   survive greyscale and the Increase Contrast setting.
3. **Reduce Motion** — the drawer slide, playhead motion, and any spring are gated on
   `@Environment(\.accessibilityReduceMotion)`.

This is the stage where a green typecheck proves the least — it needs VoiceOver and the Accessibility
Inspector, which are **hardware-free** but cannot be automated here, so it joins §8.6 as a manual
check.

#### What landed

`7488c3b` (pass 3), `1717507` (pass 2), `fa3e053` (pass 1).

**Pass 3 — Reduce Motion.** `LoopGridView`, `PlayheadScrollFollower` and `ReelView` take
`@Environment(\.accessibilityReduceMotion)`:
- The play-start scroll and the follow scroll jump rather than glide when the setting is on. These
  are the only movements that can cross the whole grid in one step, which is exactly what the
  setting exists to suppress.
- The reel's `repeatForever` rotation is dropped outright, not slowed — it is the one thing on the
  screen that never stops while audio plays.
- The 3 % press scale in `RetroButtonStyle` and the 60 ms colour fades are **deliberately left
  alone**. They are an order of magnitude below what the setting is for, and suppressing them would
  make the controls feel dead rather than calm. Both are commented in place.

**Deviation from this section's list: there is no drawer slide to gate.** The list named one, but
`App.swift:483-487` swaps padding and inserts `SideEffectsPanelView` with no `withAnimation` and no
`.transition` — the drawer already appears instantly. Nothing was invented to give the setting
something to switch off.

**Pass 2 — never colour alone.** The claim in §9.6 item 29 turned out to be **half wrong**, and the
correction matters: `RetroButtonStyle` and `IconToggle` invert *both* fill and border when active,
which is a large luminance difference that greyscale preserves. Mute and solo were therefore not
purely colour. What passed was a smaller, real defect, and one genuinely colour-only case was found
elsewhere:
- macOS and iOS mute now draw the `M` **struck through**; solo underlines the `S`. These are second,
  text-level differences on top of the existing inversion — not the only signal, but the one that
  survives an adjustment that washes the fill out.
- The iOS record dot drew `circle.fill` in both states, so its state *was* carried by tint alone. It
  now switches glyph: hollow when idle, solid when recording.

**Pass 1 — labels.** `grep -rn accessibility Sources/*.swift` returned **0** before this, so it is
the app's first accessibility work rather than a correction. Icon-only controls gained a label, a
value where they have a state, and an `isSelected` trait on the toggles. `ArcKnob`, `TrackFader`,
the timeline ruler and the trim editor's two invisible 30 pt handles gained
`accessibilityAdjustableAction` — they were bare drag targets with no focusable control and no
keyboard affordance at all. The eight track headers (macOS) and eight iOS rows gained a spoken
value, because "01"…"08" was otherwise the whole story. Decoration is hidden rather than labelled:
the reels, the header glyph, the level meters, the waveform lanes, and the numeric readouts that sit
beside a control already speaking the same number.

**Increase Contrast was deliberately not implemented.** §9.6's honest note proposed responding to
it alongside Reduce Motion. It is not: `Theme` (`Theme.swift:9-65`) is a plain enum of `static let`
colours with no environment, so nothing downstream can react to `colorSchemeContrast`; and the
obvious lever — an `@Environment` inside `RetroButtonStyle` — sits on a `ButtonStyle` rather than a
`View`, where dynamic-property support is undocumented, so it could silently do nothing and no gate
in §9.4 would say so. Making the palette environment-driven is a real change to `Theme` and belongs
in its own stage, not bolted onto this one.

**Verification.** All four gates green on each of the three commits: macOS and iOS typecheck,
`./package.sh`, `xcodebuild`. **That settles compilation and nothing else.** Per §9.4 this stage
cannot be verified by any gate here; it needs VoiceOver and the Accessibility Inspector by hand.
Specifically unsettled, and worth checking first in that pass: whether `accessibilityAdjustableAction`
is reachable at all on these custom views, and whether `.accessibilityElement()` on the ruler and the
trim handles exposes them — an element that is silently dropped from the tree looks identical to a
working one from the compiler's side.

### Stage 8 — Tooltips, empty states, and progress

**Problem.** Exactly **two** `.help(...)` calls exist in the whole app (`Views.swift:1126`, `:1861`),
so the small custom controls explain themselves only by shape. An empty track and an empty project
look the same as a broken one. Long operations (bounce, export, project save) show a text status and
no determinate progress — the app's only `ProgressView` is indeterminate (`Views.swift:1754`) — so a
30-second mixdown is indistinguishable from a hang.

Also here: **no hover affordances.** `grep -rn "onHover" Sources/` returns nothing, so clips that are
drop targets (`.onDrop`, `Views.swift:735`) and lanes that respond to the pointer give no feedback
that they are interactive.

**Change.** `.help()` on the transport, track-header, chain-editor and zoom controls. A
`ContentUnavailableView` (macOS 14, within target) for an empty project and for an empty track lane.
A determinate `ProgressView` driven by the existing `busyEdit` plumbing for bounce/export/save.

### Stage 9 — Reveal in Finder, Share, and completion notifications

**Problem.** After an export or bounce, the app says "Exported …" and the file is somewhere the user
has to go and find. There is no Share, and a long bounce finishing while the user is in another app
announces itself nowhere.

**Change.** A **Reveal in Finder** affordance on completion
(`NSWorkspace.shared.activateFileViewerSelecting`), and a Share action (`NSSharingServicePicker`) on
exported files. A user notification (`UNUserNotificationCenter`) when a bounce or export completes
**while the app is not frontmost** — and only then, per the "restrained notifications" rule: an
in-app status line is enough when the user is already looking at it.

**Drag-out, which is the same finding seen from the other side.** `.onDrag` / `.draggable` appear
nowhere; the only drag-and-drop in the app is *inbound* (`.onDrop`, `Views.swift:614-627`). WAVs are
produced and cannot be dragged to Finder or into a DAW — the standard way a Mac user moves audio out
of an app. The exported file and the exported clip both want an `NSItemProvider`.

### 9.1.1 Found and fixed while executing this section

Not in the plan, because none of it was visible by reading — each was reported against the built app.

| Reported | Cause | Fix |
|---|---|---|
| the signal meters stayed at −57.8 dB with the OP-XY selected | the header's IN/OUT pickers assigned `selectedInputID`/`selectedOutputID` directly, but the engine reads those **once, inside `EngineController.start`**. Nothing observed the properties — no `onChange`, no `didSet` — so picking the OP-XY relabelled the picker and left the graph pinned to the built-in mic. The engine's own status string was the only honest clue on screen | `bb52b9f` — the pickers route through `selectInput`/`selectOutput`, which restart the graph when monitoring. **Hardware-confirmed by the user** ("yes it reads and there is sound"), which makes this the first audio-path behaviour verified by ear in some time |
| the status line named a device the audio was not going to | `currentOutputName` reports the **system default**, which is only the destination when no separate output is chosen. With one, the engine sits on a private input+output aggregate and the audio reaches that selection | `53fb570` — the status names the routed output when it differs from the input |
| — | found while writing Stage 6: `stopAll` already returns to the start and clears `seekFraction`, so the Transport menu's **Return to Start was an exact duplicate of Stop** | `66b24c4` — it seeks now, which is what the label promises |
| — | found while writing Stage 2: the Transport menu's **Metronome** item bound `isOn: $audio.metronomeEnabled`, but the flag is not the click — `MetronomeController.toggle` is what starts and stops the generator, and the toolbar button that does the same job already called it. Switching the click off from the menu flipped the state and left up to ~2 s of already-scheduled beats playing (the refill queue) | `6f8e503` — the item routes through `toggleMetronome` |

**The iOS gap this exposed.** `switchOutput` is gated on `io.outputSelectionSupported`, and the iOS
provider reports `false` — so `Views_iOS.swift` has no route picker at all, and a take recorded on
iPad is monitored through the session's default route with no way to see or change which one. That is
a real gap rather than a deliberate omission, and it is not covered by any stage above. **Unscheduled.**

## 9.2 What is deliberately not in scope

- **A document-based architecture** (`DocumentGroup`, `NSDocument`). The app holds one session, and
  rewiring to `DocumentGroup` would rewrite save/load, undo and the dirty flag — a large change for
  no user-visible gain over Stage 4 + Stage 5. Revisit only if multi-window editing is wanted.
- **Autosave / crash recovery.** The product plan wants it (`OP-XY Monitor multitrack product
  plan.md:47`) but it is a scheduling and file-management feature, not a platform-conformance one,
  and it interacts with the orphan-sweep (`H3`). Its own section when it is picked up.
- **A customisable toolbar.** The app uses `.hiddenTitleBar` and no `.toolbar`; adding one is a
  design change, not a conformance fix.
- **`CREDITS.md` beyond the DSP attribution** — that is a legal item and ships in Stage 3; a fuller
  open-source inventory can follow.
- **Quick Look (`QLPreviewPanel`).** The audit notes it is absent, and normally a Mac app should
  preview what it can. Here it is genuinely blocked: Quick Look's gesture is the space bar, and space
  is already play/stop — the app's single most important key. Not worth re-binding play/stop for.
- **The Services menu.** No `registerServices` and no provider. Nothing in a looper obviously wants
  a system service, so this is noted and skipped rather than planned.
- **Pinch-to-zoom on the timeline.** No `MagnifyGesture`; zoom is keyboard and buttons only. Two-finger
  *scroll* works incidentally through the lane `ScrollView` (`Views.swift:929`). A nice-to-have, not a
  conformance gap, so it is listed here rather than staged.
- **Localisation.** Every string is a literal. Out of scope, but worth noting that Stage 1 puts a
  large number of new user-visible strings into the codebase, which is the point at which a
  `Localizable.strings` extraction would be cheapest if it is ever wanted.

## 9.3 Priority

| Priority | Stage | Status | Why this order |
|---|---|---|---|
| **P0** | 4 — dirty guard | ✅ done | Only stage that prevents **data loss**. Can land any time; do it regardless of the rest. |
| **P1** | 1 — menu bar | ✅ done | Largest discoverability gap; every action already exists, so it is wiring |
| **P1** | 5 — documents + plist reconciliation | ✅ done | Double-click was broken *today* and the plists had diverged |
| **P2** | 2 — Settings scene | ✅ done | Needed before shipping to MAS; ⌘, is expected |
| **P2** | 3 — About + credits | ✅ done | Contained a licensing obligation |
| **P2** | 6 — context menus | ✅ done | Depends on 1 |
| **P3** | 7 — accessibility | ✅ done | Highest effort, cannot be auto-verified |
| **P3** | 8 — tooltips / empty states / progress | | |
| **P3** | 9 — Reveal / Share / notifications | | |

**Suggested execution order** differs from priority because of dependencies: **4 → 1 → 6 → 2 → 3 → 5 →
7 → 8 → 9**. Stage 4 is first because it is small, independent, and the only correctness item;
Stage 5 is late despite being P1 because the bundle-id decision in it may want a deliberate answer
rather than a rushed one. That is how it turned out: the id was put to the user, and it took one
question to settle rather than a guess.

**Progress against that order, 2026-10-13:** the first seven have landed, so the next is **Stage 8**,
then **9**. Stage 3 was moved ahead of Stage 5 and is done — the licensing obligation it carried has
been discharged, and discharged in the app rather than in the repository, which is where MIT wanted
it.

**Stage 7 carries a verification debt that no later stage discharges.** It is the one stage in this
section whose four gates prove nothing about whether the work functions: the labels have never been
heard, and the adjustable actions have never been reached. It needs a VoiceOver and Accessibility
Inspector pass, and that pass has not happened.

## 9.4 Verification

Four gates after each stage, unchanged from §8.6/§8.9:

```bash
TC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
MACSDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
IOSSIMSDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk
$TC -typecheck -parse-as-library -target arm64-apple-macosx14.0   -sdk "$MACSDK"    -module-name Tape08 Sources/*.swift
$TC -typecheck -parse-as-library -target arm64-apple-ios17.0-simulator -sdk "$IOSSIMSDK" -module-name Tape08 Sources/*.swift
./package.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Tape08/Tape08.xcodeproj -scheme Tape08 build
```

**Stages 1, 3 and 6 are largely self-verifying**: a menu item that exists in the built app is a menu
item that exists. The honest limit is that **whether a menu item is enabled at the right moment, and
whether its shortcut collides with a live monitor binding, is a runtime property** — §8.6's keyboard
check must be re-run after Stage 1, and it must now exercise the *menus*, not just the keys.

**Stage 2 is the exception, and it is worth being plain about it**: every gate below can pass while
the window is unusable. A `Form` in a `Settings` scene either appears at ⌘, or it doesn't; its
traffic-light state, its Escape behaviour and its controls' widths are all runtime properties that no
compiler checks. What *is* offline-checkable in it — the preferences store and the device UID match
rule — was probed, as above. The rest is on the hardware run.

⚠️ **Correction, 2026-10-13 — `strings` does not verify a command set, and this section previously
said it did.** It was tried against the built bundle and reported `TRIM`, `APPLY` and `Ready` as
**missing** when all three are in the source, because **Swift stores string literals of 15 UTF-8
bytes or fewer inline in the instruction stream rather than in the string table**. `Tape08MainWindow`
(16 bytes) was visible; `Tape08` was not. So `strings` + `grep` cannot see most menu titles, most
status strings, and essentially every short label — and a "not found" from it proves nothing in
either direction. It was retracted rather than left standing. Verifying a menu now means launching
the app and reading the menu bar; there is no offline substitute.

**Probes, and the trap in them.** Stage 2's `Preferences` store is the first thing in this section
whose logic is testable offline, and it was tested: a throwaway `main.swift` compiled against the
source and run, print-per-check, covering absent keys, round trips, a stored zero that must not read
back as the default, a bogus value, and a mistyped one. That is stronger evidence than a typecheck,
and it is how the `didSet`-over-`@Published` assumption behind the whole write-through was checked —
direct assignment, key-path assignment (what a SwiftUI `$audio.x` compiles to), no fire during
`init`, and the publisher still firing.

The trap: **a probe that re-implements the logic tests the probe.** The first version of the UID
probe spelled the accessors out again against a scratch `UserDefaults` suite and passed — while
proving nothing about `Preferences.swift`. Both probes now compile the real file, against the
standard domain, and clean up their keys afterwards. Compile the file; don't restate it.

**Stage 7 (accessibility) cannot be verified by any gate in this document.** It needs VoiceOver and
the Accessibility Inspector, by hand. Listing it as "compile-verified" would be a false claim.

## 9.5 Platform rules applied

The specific rules from the sources below that the stages above lean on — recorded here so a future
reader can tell a *convention* from an *opinion*:

- **Menu bar.** Every command the app offers belongs in the menu bar, with its shortcut shown. The
  menu bar is the canonical command list; a shortcut that exists only as a key press is not
  discoverable. Menu items are validated (`disabled`) rather than hidden.
- **Context menus.** A right-click menu is the *relevant subset* of the menu-bar commands for the
  thing clicked — never a different, larger command set.
- **Settings window.** Opened by ⌘, from the app menu, titled "Settings…". Not translucent. Escape
  does not close it. The traffic-light buttons are present but disabled. **No About or licence tab
  inside it** — About belongs in the app menu.
- **About.** Reachable from the app menu; carries version and copyright.
- **Quit.** Never discard unsaved work silently. The window shows an edited state, and quitting
  prompts.
- **Documents.** If an app claims a document type, opening one must actually open it; a claimed type
  with no open handler is worse than no claim.
- **Accessibility.** Controls are labelled; state is never signalled by colour alone (it must survive
  greyscale and Increase Contrast); Reduce Motion is honoured.
- **Notifications.** Restrained — a notification is for when the user is *not* looking at the app,
  never for something the in-app UI already said.
- **Pointer targets.** 44×44 pt where the layout allows; icon-only controls carry a help tag.

**Sources.**

- Apple, *Building and customizing the menu bar with SwiftUI* —
  <https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui>
- `sindresorhus/human-interface-guidelines-extras` —
  <https://github.com/sindresorhus/human-interface-guidelines-extras>
- macOS design / accessibility skill references (menu structure, Settings-window rules, Reduce
  Motion, colour-only signalling) — <https://github.com/robzilla1738/roberts-skills>

## 9.6 Audit detail

Whole-tree audit of `Sources/`, 2026-10-12. Each row is `file.swift:line`, or **ABSENT** with the
grep that establishes it. Line numbers are from that audit and are expected to drift.

### App structure

| # | Item | State | Where |
|---|---|---|---|
| 1 | `Settings` scene (⌘,) | **ABSENT** — in-window drawer instead | `App.swift:223` (`if audio.showSettings`), toggle at `AudioManager.swift:48-51`, gear at `Views.swift:403-409` |
| 2 | About panel | **ABSENT** — SwiftUI's implicit default only | no `orderFrontStandardAboutPanel` in `Sources/` |
| 3 | `.commands` / `CommandGroup` / `CommandMenu` | **ABSENT** — stock menu bar only | `grep` → 0 hits; scene is just `WindowGroup` at `App.swift:255-267` |
| 4 | File ▸ New/Open/Save/Save As items | **ABSENT** as menu items; shortcuts exist in the monitor | `App.swift:95-107` |
| 5 | `WindowGroup` sizing | **PARTIAL** — no `.windowResizability`, no `.defaultSize` | min size faked at `App.swift:263` |
| 6 | Window frame autosave / restoration | **ABSENT** — no `NSWindow` reference at all | `grep -rn "NSWindow\|setFrameAutosaveName" Sources/` → 0 |
| 7 | `NSApplicationDelegate` methods | **ONE** — the terminate-after-close flag only | `App.swift:270-272` |
| 8 | Full-screen / `.toolbar` on macOS | **ABSENT** | `.toolbar` only at `Views_iOS.swift:376` |

### Document & file handling

| # | Item | State | Where |
|---|---|---|---|
| 9 | Open Recent | **ABSENT** | no `noteNewRecentDocumentURL`; `ProjectController.performSave` `:53-103`, `performLoad` `:165-230` |
| 10 | Unsaved-changes guard on quit | **ABSENT** — `projectDirty` drives only a title asterisk | `AudioManager.swift:139`, `Views.swift:317` |
| 11 | Autosave / crash recovery | **ABSENT** | undo stack is in-memory only, `TransportController.swift:453-477` |
| 12 | Window title / represented filename / edited dot | **ABSENT** | no `representedURL`, no `.navigationTitle` on macOS; title bar hidden at `App.swift:266` |
| 13 | Drag & drop **out** | **ABSENT** — inbound only | `.onDrop` at `Views.swift:614-627`; no `.onDrag`/`.draggable` |
| 14 | Reveal in Finder | **ABSENT** — status string only | `TransportController.swift:912-941` (export), `:1027-1142` (mixdown) |
| 15 | Share sheet | **ABSENT** | no `NSSharingServicePicker`/`ShareLink` |
| 16 | Quick Look | **ABSENT** — and blocked by space=play | no `QLPreviewPanel` |
| 17 | Services menu | **ABSENT** | no `registerServices` |

### Interaction & input

| # | Item | State | Where |
|---|---|---|---|
| 18 | Context menus | **ABSENT** | `grep -rn "contextMenu" Sources/` → **0** |
| 19 | Tooltips (`.help`) | **PARTIAL — 2 total** | `Views.swift:877`, `:1544` only |
| 20 | Keyboard shortcuts | **PRESENT, 20 bindings, all invisible** | `App.swift:12-167`; table below |
| 21 | Pinch-to-zoom | **ABSENT** — keyboard/buttons only | no `MagnifyGesture`; scroll works via `Views.swift:929` |
| 22 | Hover effects | **ABSENT** | `grep -rn "onHover" Sources/` → **0** |
| 23 | Multi-select / copy-paste of clips | **ABSENT** | single `selectedClipID`; no ⌘C/⌘V in the monitor |
| 24 | Focus / keyboard navigation | **ABSENT** — and Tab is repurposed | no `.focusable`/`@FocusState`; Tab at `App.swift:137-139` |
| 25 | Escape handling | **ABSENT** | no `.onExitCommand`; trim editor closes only by button, `Views.swift:2223-2233` |

**Item 20 in full** — the monitor's bindings, all of which Stage 1 must move into menus:

| Key | Mods | Action | Line |
|---|---|---|---|
| Space | — | Play/stop all | 42-46 |
| R / M / S | — | Record / Mute / Solo on selected track | 49-61 |
| 1–8 | — | Select track | 64-71 |
| 1–8 | ⌘ | Select take | 75-82 |
| Z | ⌘ / ⌘⇧ | Undo / Redo | 85-92 |
| S / S | ⌘ / ⌘⇧ | Save / Save As | 95-102 |
| O | ⌘ | Open | 105-107 |
| E | ⌘ | Export selected track | 110-112 |
| T | ⌘ | Split at playhead | 115-117 |
| D | ⌘ | Duplicate last clip | 120-122 |
| Return / keypad Enter | — | Stop and return to start | 127-129 |
| , | — | Metronome | 132-134 |
| Tab | — | Arrange/Monitor | 137-139 |
| = / + , − / _ | ⌘ | Zoom in / out | 142-149 |
| F | — | Follow playhead | 152-154 |

The monitor bails out when a text field has focus (`App.swift:18-21`). The bare-letter bindings
(R/M/S/F, 1–8, Tab, comma) fire with no modifier anywhere in the window, which is what collides with
standard macOS behaviour — see the ⌘Z finding in Stage 1 and the Tab finding below it.

### Accessibility

| # | Item | State | Where |
|---|---|---|---|
| 26 | `accessibilityLabel` / `Value` / `Hint` | **ABSENT — 0 in the entire codebase** | `grep -rn "accessibility" Sources/*.swift \| wc -l` → **0** |
| 27 | `accessibilityElement(children:)` | **ABSENT** | as above |
| 28 | Reduce Motion / Transparency / Contrast | **ABSENT** — animates unconditionally | `.animation(...)` + `.scaleEffect` at `Views.swift:48-49` |
| 29 | Colour-only signalling | **PARTIAL — mute/solo and track identity are colour-only** | `Views.swift:650-664`, `Theme.trackColor` at `:638`. Status text is fine (colour + text, `:294-340`); REC pairs colour with a label (`:1430-1442`) |

### Visual / system integration

| # | Item | State | Where |
|---|---|---|---|
| 30 | Dark mode adaptation | **ABSENT** — hardcoded dark palette, no `colorScheme` | `Theme.swift:10-31` |
| 31 | System accent colour | **ABSENT** — hardcoded gold, ignores the user's accent | `Theme.swift:17`; no `Color.accentColor` reference |
| 32 | SF Symbols vs custom drawing | **MIXED** — both, heavily | SF Symbols at `Views.swift:305, 404, 845, 859, 1500, 1550, 2329, 2364`; custom `Path`/`Canvas` for `ArcKnob` `:65`, `TrackFader` `:188`, `VerticalMeter` `:441`, `WaveformLaneView` `:475`, `ReelView` `:1582`, `DotGridBackground` `:14` |
| 33 | `Form` / `GroupBox` / `LabeledContent` | **ABSENT** — settings drawer is hand-laid-out `VStack`s | `Views.swift:2256-2344` |
| 34 | Progress indication | **PARTIAL — indeterminate only** | `ProgressView()` at `Views.swift:1462`; `busyEdit` disables buttons but is never rendered as progress |
| 35 | Completion notifications | **ABSENT** | no `UNUserNotificationCenter`; status strings at `TransportController.swift:934-935, 1134-1135` |

**Honest note on items 30–32.** The hardcoded palette and the fully custom controls are a *design*
choice for a retro instrument, not an oversight, and this plan does not propose replacing them. What
is proposed is narrower: that the app respond to **Increase Contrast** and **Reduce Motion**, and
that mute/solo stop meaning "colour only" — both of which are correctness under a user's accessibility
settings rather than a change of look.

### 9.6.1 Re-audit — 2026-10-13

The tables above are the 2026-10-12 snapshot. These are the rows that have since moved, with line
numbers re-resolved against the tree rather than adjusted by arithmetic.

**Re-resolved again in `48eb2b7`, and the previous lot were wrong.** Rows 3–12 and 25 below claimed
to be re-resolved but carried the 2026-10-12 numbers: at `3722ee7` the File group was at `:207`, not
`:190`, and `.commands` at `:525`, not `:487`. Every App.swift number in this table has now been
computed from the current file rather than adjusted by hand, and the same pass caught that the
"Moved since" paragraph's `:191` for the About group was off by one and its `:215` for Help was the
*current* value rather than the one it was written against. `Views.swift` numbers were unaffected at
that point, because nothing in those stages touched that file; **Stage 7 changed that.** Its three
commits added roughly 260 lines to `Views.swift` and 60 to `Views_iOS.swift`, so every `Views.swift`
anchor in this table was recomputed against the current tree — rows 18 and 19, item 13's `onDrop`,
and item 34's `ProgressView` all moved. `Views_iOS.swift` anchors: the only one still standing is
row 8's `.toolbar` at `Views_iOS.swift:376`, which is now `:437`.

| # | Item | Was | Now | Where |
|---|---|---|---|---|
| 3 | `.commands` / `CommandGroup` / `CommandMenu` | ABSENT | **PRESENT** — `.commands` plus five groups | `App.swift:567`; groups at `:222` File, `:268` Edit, `:278` Transport, `:316` Track, `:364` View |
| 4 | File ▸ New/Open/Save items | ABSENT | **PRESENT — 6 items, one gap** | `App.swift:222-262`. No *New Project*; Open Recent added by Stage 5 (`:238`) |
| 5 | `WindowGroup` sizing | PARTIAL | **PRESENT** | `.defaultSize(width: 1440, height: 900)` at `App.swift:566` |
| 6 | Window frame autosave | ABSENT | **PRESENT** | `setFrameAutosaveName` at `App.swift:418` |
| 7 | `NSApplicationDelegate` methods | ONE | **THREE** | `:600` `application(_:open:)` · `:625` terminate-after-close · `:635` `applicationShouldTerminate` |
| 10 | Unsaved-changes guard on quit | ABSENT | **PRESENT** — Save / Cancel / Don't Save sheet | `App.swift:635-666` |
| 12 | Window title / represented URL / edited dot | ABSENT | **PRESENT** | `App.swift:412-414`, `:500` |
| 18 | Context menus | ABSENT (0) | **PRESENT — 3** | take `Views.swift:666` · track header `:882` · transport `:1788` |
| 19 | Tooltips (`.help`) | 2 | **still 2**, lines drifted | `Views.swift:1126`, `:1861` |
| 20 | Keyboard shortcuts | 20 bindings, all invisible | **split in two** | see below |
| 24 | Focus / keyboard navigation | ABSENT — Tab repurposed | **unchanged** — Tab is still a monitor binding | `App.swift:110` |
| 25 | Escape handling | ABSENT | **PRESENT** | `.onExitCommand` at `App.swift:509` |

**Item 20 has changed shape, and the binding table above is now wrong.** `3e35349` moved every
**⌘-modified** binding out of the monitor and into the menu bar, where it carries a real
`keyboardShortcut` and is therefore visible and learnable: ⌘O, ⌘S, ⌘⇧S, ⌘E, ⌘Z, ⌘⇧Z, ⌘T, ⌘D, ⌘1–⌘8
and the ⌘-zoom pair (`App.swift:222-381`). The **bare keys stayed** in the monitor — Space, R, M, S,
1–8, Return, comma, Tab, F, and Delete — as 17 `case` labels (`App.swift:40-115`), because a bare key
handed to the menu bar is matched ahead of the responder chain and would fire inside a focused text
field. So the table's rows for ⌘Z, ⌘S, ⌘O, ⌘E, ⌘T, ⌘D, ⌘1–⌘8 and ⌘-zoom now describe the **menu
bar**, not the monitor, and its line numbers are all stale. **Delete is new and absent from that
table entirely.**

**Moved since:** item 1 (Settings scene) is **PRESENT** — `Settings {` at `App.swift:576`, the gear
as a `SettingsLink` at `Views.swift:463`, and the scene supplies both the app-menu item and ⌘, with
no `keyboardShortcut` written anywhere. Item 2 (About panel) is **PRESENT** — `AboutPanel.show()` from
`CommandGroup(replacing: .appInfo)` at `App.swift:207`, Help replaced at `:215`, and the ported DSP's
full MIT notice carried in the panel's credits. Item 9 (Open Recent) is **PRESENT** — a submenu inside
the File group at `App.swift:238`, on `NSDocumentController` through `Sources/ProjectRecents.swift`,
with the open event that makes its entries mean something handled at `App.swift:600`. Item 19 is
still 2 tooltips. Item 4's second gap is closed, so File's remaining gap is *New Project* alone.

**Items 26–29 are now PRESENT, and this is the largest single change since the snapshot.** The
count went from `grep -rn "accessibility" Sources/*.swift | wc -l` → **0** to **129** (95 in
`Views.swift`, 34 in `Views_iOS.swift`). Row 26 and 27: every icon-only or shape-only control has a
label and, where it has a state, a value — and `accessibilityElement(children:)` appears at eight
sites, `.ignore` where `.combine` would read the same fact twice and plain `.accessibilityElement()`
on the bare drag targets. Row 28: `@Environment(\.accessibilityReduceMotion)` in `LoopGridView`,
`PlayheadScrollFollower` and `ReelView`, gating the two whole-grid scrolls and the reel's
`repeatForever` rotation. Row 29: mute and solo gained a strike and an underline, and the iOS record
dot a glyph change. See "What landed" under Stage 7 for the two deviations — no drawer slide existed
to gate, and Increase Contrast was deliberately not attempted.

**Still ABSENT, verified again 2026-10-13:** items
11 (autosave / crash recovery), 13 (drag **out** — one `onDrop` at
`Views.swift:735`; the `onDragStart`/`onDragEnd` at `Views.swift:209-236` are a *fader's* undo-gesture
closures, not SwiftUI `.onDrag`, so a grep for "onDrag" is misleading here), 14, 15, 16, 17, 21, 22,
23, 30–33 and 35. Item 34 is still the single indeterminate `ProgressView` (`Views.swift:1754`).

**Item 29 was also half wrong, and the correction is recorded rather than quietly dropped.** The
snapshot called mute/solo and track identity "colour-only". Mute and solo are not: `RetroButtonStyle`
inverts both fill and border when active, a luminance difference greyscale keeps. Track identity
*is* colour-only — `Theme.trackColor` is the only thing telling eight rows apart — and that is left
as it is, being the retro-instrument design choice items 30–32's honest note already carves out.