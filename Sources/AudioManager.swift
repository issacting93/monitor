// AudioManager.swift — published app facade for TAPE 08
//
// The single ObservableObject the views and KeyboardShortcutMonitor talk to. It
// owns every @Published property and forwards each operation to the focused
// controller that implements it (device, effects, metronome, transport, meter,
// recorder, project, engine). Controllers hold a one-way `unowned` back-reference
// and write published state through it, so objectWillChange fires exactly as it
// did when this was one file.

import SwiftUI
import Foundation
import CoreAudio

class AudioManager: ObservableObject {
    @Published var inputDevices:     [AudioDevice] = []
    @Published var outputDevices:    [AudioDevice] = []
    @Published var selectedInputID:  DeviceID?
    @Published var selectedOutputID: DeviceID?
    @Published var isMonitoring = false
    @Published var isRecording  = false
    @Published var volume: Double = 0.3
    @Published var inputVolume: Double = 0.3
    @Published var recordingDuration: TimeInterval = 0

    /// High-frequency display state (meters, waveform, playhead progress). Kept off
    /// the @Published facade so the 60 Hz display tick doesn't re-render the whole tree.
    let live = LiveState()
    @Published var status = "Ready"
    @Published var sampleRateString = "48 kHz · 24-bit · Stereo"

    // Effect chain (replaces hardcoded EQ/Reverb/Delay/Tape)
    @Published var liveChain: [ChainSlot] = []
    @Published var showEffects = false

    // MARK: - Inspector drawer

    /// The one inspector drawer, which occupies the space to the left of the tape.
    ///
    /// Settings used to be the second one, sharing that space under a rule that opening
    /// either closed the other. It is now the ⌘, window in `SettingsView.swift`, so there
    /// is nothing left to keep out of the way and no exclusion rule left to enforce.

    func toggleEffectsDrawer() { showEffects.toggle() }

    /// How far the workspace is pushed right to clear the open drawer.
    var openDrawerWidth: CGFloat {
        showEffects ? Theme.effectsDrawerWidth : 0
    }

    /// Closes the drawer, if open.
    ///
    /// Escape is the only caller. The toolbar button *toggles*, so routing Escape
    /// through it would make a press with nothing open spring the panel open; closing is
    /// all Escape may ever do.
    func closeOpenDrawer() { showEffects = false }

    // Effect chain presets
    @Published var presetNames: [String] = []
    @Published var showPresetSave = false
    @Published var presetSaveName: String = ""

    // Settings
    @Published var saveLocation: URL = PlatformPaths.initialSaveLocation

    // Trim editor
    @Published var trimmingTrack: Int? = nil
    /// The clip the open editor is trimming. Stored alongside the track because
    /// `applyTrim`'s file work runs off-main: by the time it lands the user can have
    /// moved the selection, and the trim must still replace the clip it was opened on.
    @Published var trimClipID: UUID? = nil
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 1
    @Published var trimPeaks: [Double] = []
    var trimClipDuration: TimeInterval = 0

    // Count-in
    //
    // Persisted, along with the six other preferences further down this file: each
    // of those also writes through to `Preferences` and reads its factory value from
    // there, so the Settings window's choices survive a launch and there is one place
    // a default is written down. Everything else on this facade is session state and
    // stays that way — that is the line the drawer/scene split is drawn along.
    @Published var countInBars: Int = Preferences.countInBars {
        didSet { Preferences.countInBars = countInBars }
    }
    @Published var countingIn: Bool = false

    // View mode (0 = arrange, 1 = monitor)
    @Published var viewMode: Int = 0
    @Published var bounceStatus: String? = nil
    @Published var loopEnabled: Bool = Preferences.loopEnabled {
        didSet { Preferences.loopEnabled = loopEnabled }
    }

    // What an edit is doing off the main thread, or nil when nothing is in flight.
    // Set by `runOffMain`, which every edit and export routes its file work through.
    // Views disable the controls that start edits while it is set, so a second tap
    // can't start a competing edit against state the first one is about to replace.
    @Published var busyEdit: String? = nil
    private var busyDepth = 0

    // Timeline zoom & playhead follow
    @Published var timelineZoom: Double = Preferences.timelineZoom {   // 0.5 – 4.0
        didSet { Preferences.timelineZoom = timelineZoom }
    }
    @Published var playheadFollow: Bool = Preferences.playheadFollow {
        didSet { Preferences.playheadFollow = playheadFollow }
    }

    // Metronome
    @Published var metronomeEnabled = true
    @Published var metronomeBPM: Double = Preferences.metronomeBPM {
        didSet { Preferences.metronomeBPM = metronomeBPM }
    }
    @Published var metronomeVolume: Double = Preferences.metronomeVolume {
        didSet { Preferences.metronomeVolume = metronomeVolume }
    }

    // Tap tempo
    @Published var tapTempoFlash: Bool = false

    // Quantize
    @Published var quantizeMode: Int = 0
    static let quantizeLabels = ["OFF", "BAR", "BEAT"]

    // Multitrack
    @Published var tracks: [TrackInfo] = (0..<Theme.trackCount).map { TrackInfo(id: $0) }
    @Published var selectedTrack: Int = 0

    /// The take the edit buttons act on, held as an id rather than an index and kept
    /// deliberately outside `tracks` so selecting a take is never an undo step.
    ///
    /// An id, because every constructive op (trim, split, duplicate, record, import)
    /// installs a brand-new `TrackClip` with a fresh UUID — an index would silently
    /// point at a different take — while undo and redo swap whole snapshots holding the
    /// very same structs, so the id rides through them untouched. The ops that install a
    /// clip re-point it, and only while the user hasn't moved the selection since.
    @Published var selectedClipID: UUID? = nil

    @Published var isPlaying = false

    /// A position the timeline was dragged to while nothing was playing, as a fraction
    /// of each track's own clip; nil whenever the playhead is following playback, or has
    /// never been placed.
    ///
    /// Optional rather than defaulting to 0, because "parked at the start" and "never
    /// placed" need different markers: the first draws a stationary playhead, the second
    /// draws none until something plays.
    @Published var seekFraction: Double? = nil

    // Project persistence
    @Published var projectURL: URL? = nil
    @Published var projectName: String = "Untitled"
    @Published var projectDirty: Bool = false

    /// The projects File ▸ Open Recent lists, newest first.
    ///
    /// A published copy of what `ProjectRecents` holds, because that list lives in
    /// `NSDocumentController` and nothing about it is observable — the submenu is built
    /// from this array and would otherwise only refresh when something else happened to
    /// redraw the menu bar. Empty on iOS, which has neither the store nor the submenu.
    /// Written only through `noteRecentProject` and `clearRecentProjects`.
    @Published var recentProjects: [URL] = []

    // Undo/Redo (state + logic live in TransportController)
    var canUndo: Bool { transport.canUndo }
    var canRedo: Bool { transport.canRedo }

    // MARK: - Clip Selection

    /// The index of the clip an edit should act on for `trackIndex`: the selected take
    /// when that resolves on this track, otherwise the track's last take — the behaviour
    /// every edit had before selection existed, so an empty or stale selection never
    /// changes what an edit does. Nil only when the track holds no clips at all.
    ///
    /// Resolution happens here, at use time, rather than being cached: the selection can
    /// go stale in ways nothing local to a view can see (undo, redo, a project load, a
    /// trim replacing the clip under it) and every one of those has to fall back cleanly.
    /// Views that show which take is current must resolve through this too, or the
    /// highlight would sit on a different take than the one the edits act on.
    func editTargetIndex(on trackIndex: Int) -> Int? {
        guard trackIndex >= 0, trackIndex < tracks.count else { return nil }
        let clips = tracks[trackIndex].clips
        guard !clips.isEmpty else { return nil }
        if trackIndex == selectedTrack, let id = selectedClipID,
           let i = clips.firstIndex(where: { $0.id == id }) {
            return i
        }
        return clips.count - 1
    }

    /// Whether the selected track has a take for the edit buttons to act on.
    var hasEditableClip: Bool { editTargetIndex(on: selectedTrack) != nil }

    /// Selects take `number` (1-based) on the selected track, for the ⌘1–⌘8 shortcuts.
    /// A number past the end does nothing, so a shortcut can't wipe a selection the
    /// user made by clicking.
    func selectClip(number: Int) {
        guard selectedTrack >= 0, selectedTrack < tracks.count else { return }
        let clips = tracks[selectedTrack].clips
        guard number >= 1, number <= clips.count else { return }
        selectedClipID = clips[number - 1].id
    }

    // Master limiter
    @Published var masterLimiterEnabled: Bool = Preferences.masterLimiterEnabled {
        didSet { Preferences.masterLimiterEnabled = masterLimiterEnabled }
    }

    // MIDI
    @Published var midiTrackFollow: Bool = true

    // Per-track metering lives in `live` (LiveState).

    // Sub-controllers. AudioManager stays the published facade the views talk to;
    // each controller owns a slice of private engine/algorithm state and reaches
    // back through `manager` (a one-way unowned reference). `init` force-touches
    // every controller so none can lazily initialize from a timer or audio thread.
    lazy var metronome = MetronomeController(manager: self)
    lazy var device    = DeviceController(manager: self)
    lazy var effects   = EffectsChainController(manager: self)
    lazy var transport = TransportController(manager: self)
    lazy var meter     = MeterController(manager: self)
    lazy var recorder  = RecordingController(manager: self)
    lazy var project   = ProjectController(manager: self)
    lazy var engine    = EngineController(manager: self)

    init() {
        _ = metronome; _ = device; _ = effects; _ = transport; _ = meter; _ = recorder
        _ = project; _ = engine
        EffectAudioUnit.registerComponent()
        EffectRegistry.shared.registerBuiltIns()
        liveChain = [
            ChainSlot(moduleID: "com.opxy.noise-gate", enabled: false),
            ChainSlot(moduleID: "com.apple.eq", enabled: false),
            ChainSlot(moduleID: "com.opxy.compressor", enabled: false),
            ChainSlot(moduleID: "com.opxy.distortion", enabled: false),
            ChainSlot(moduleID: "com.opxy.tape-saturation", enabled: false),
            ChainSlot(moduleID: "com.opxy.chorus", enabled: false),
            ChainSlot(moduleID: "com.opxy.flanger", enabled: false),
            ChainSlot(moduleID: "com.opxy.phaser", enabled: false),
            ChainSlot(moduleID: "com.opxy.tremolo", enabled: false),
            ChainSlot(moduleID: "com.opxy.bitcrusher", enabled: false),
            ChainSlot(moduleID: "com.apple.delay", enabled: false),
            ChainSlot(moduleID: "com.apple.reverb", enabled: false),
        ]
        device.loadDevices()
        device.setupHardwareListeners()
        device.setupMIDI()
        effects.installBuiltInPresets()
        effects.refreshPresetList()
        // The list survives relaunch inside `NSDocumentController`, so it is read once
        // here rather than lazily by the menu: seeding it in `init` means the submenu is
        // populated on the very first build of the menu bar, with no empty flash.
        #if os(macOS)
        recentProjects = ProjectRecents.all
        #endif
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Monitoring Engine (forwarders — graph lives in EngineController)

    func startMonitoring() { engine.start() }

    func stopMonitoring() { engine.stop() }

    func switchOutput(to id: DeviceID) { device.switchOutput(to: id) }

    func applyVolume(_ v: Double) { engine.applyVolume(v) }

    func applyInputVolume(_ v: Double) { engine.applyInputVolume(v) }

    func toggleMasterLimiter() { engine.toggleMasterLimiter() }

    // MARK: - Device Selection

    /// Selects the input device and rebuilds the graph on it when monitoring is running.
    ///
    /// A picker must not assign `selectedInputID` directly. The engine reads that
    /// property exactly once, inside `EngineController.start`, so a bare assignment
    /// only moves the label: the graph stays on the previous device and the UI goes on
    /// advertising a live engine on a device the user isn't listening to. Routing is
    /// decided at start time, which is why changing the device has to restart.
    func selectInput(_ id: DeviceID?) {
        guard id != selectedInputID else { return }
        selectedInputID = id
        device.rememberDevice(id, input: true)
        if isMonitoring { startMonitoring() }
    }

    /// Selects the output device and rebuilds the graph on it when monitoring is running.
    /// `switchOutput` already restarts — on macOS a differing output is what makes the
    /// engine pin itself to a private aggregate — so this only adds the no-op guard,
    /// keeping a re-pick of the current device from tearing the graph down and rebuilding it.
    func selectOutput(_ id: DeviceID?) {
        guard let id, id != selectedOutputID else { return }
        switchOutput(to: id)
    }

    // MARK: - Chain Effects (forwarders — behaviour lives in EffectsChainController)

    func toggleSlotBypass(_ slotIndex: Int) { effects.toggleSlotBypass(slotIndex) }

    func paramBinding(slot index: Int, param id: String) -> Binding<Double> {
        effects.paramBinding(slot: index, param: id)
    }

    func addSlot(moduleID: String) { effects.addSlot(moduleID: moduleID) }

    func removeSlot(at index: Int) { effects.removeSlot(at: index) }

    func moveSlot(from: Int, to: Int) { effects.moveSlot(from: from, to: to) }

    func saveChainPreset(name: String) { effects.saveChainPreset(name: name) }

    func loadChainPreset(name: String) { effects.loadChainPreset(name: name) }

    func deleteChainPreset(name: String) { effects.deleteChainPreset(name: name) }

    // MARK: - Metronome (forwarders — behaviour lives in MetronomeController)

    func toggleMetronome() { metronome.toggle() }

    func setMetronomeVolume(_ v: Double) { metronome.setVolume(v) }

    func tapTempo() { metronome.tapTempo() }

    func cycleQuantize() {
        quantizeMode = (quantizeMode + 1) % Self.quantizeLabels.count
    }

    // MARK: - Transport (forwarders — behaviour lives in TransportController)

    func setLoopEnabled(_ enabled: Bool) { transport.setLoopEnabled(enabled) }

    func startTrackLoop(_ i: Int) { transport.startTrackLoop(i) }

    func toggleTrackPlayback(_ i: Int) { transport.toggleTrackPlayback(i) }

    func toggleTrackRecord(_ i: Int) { transport.toggleTrackRecord(i) }

    func playAll() { transport.playAll() }

    func stopAll() { transport.stopAll() }

    func seek(toFraction fraction: Double) { transport.seek(toFraction: fraction) }

    func beginUndoGesture() { transport.beginUndoGesture() }

    func endUndoGesture() { transport.endUndoGesture() }

    func undo() { transport.undo() }

    func redo() { transport.redo() }

    func clearAll() { transport.clearAll() }

    func clearTrack(_ i: Int) { transport.clearTrack(i) }

    func openTrimEditor(_ trackIndex: Int) { transport.openTrimEditor(trackIndex) }

    func cancelTrim() { transport.cancelTrim() }

    func applyTrim() { transport.applyTrim() }

    func splitClipAtPlayhead(_ trackIndex: Int) { transport.splitClipAtPlayhead(trackIndex) }

    func duplicateClip(_ trackIndex: Int, clipIndex: Int? = nil) {
        transport.duplicateClip(trackIndex, clipIndex: clipIndex)
    }

    func exportTrack(_ trackIndex: Int) { transport.exportTrack(trackIndex) }

    func importAudioFile(_ url: URL, toTrack trackIndex: Int) {
        transport.importAudioFile(url, toTrack: trackIndex)
    }

    func changeSaveLocation() { transport.changeSaveLocation() }

    func bounceMixdown() { transport.bounceMixdown() }

    func toggleMute(_ i: Int) { transport.toggleMute(i) }

    func toggleSolo(_ i: Int) { transport.toggleSolo(i) }

    func setTrackVolume(_ i: Int, _ v: Double) { transport.setTrackVolume(i, v) }

    func setTrackPan(_ i: Int, _ p: Double) { transport.setTrackPan(i, p) }

    // MARK: - Recording (forwarders — behaviour lives in RecordingController)

    func startRecording() { recorder.start() }

    /// Ends a take. `loopWhenFiled` starts the track looping once the take is actually on
    /// it, which the call site cannot do: the clip is filed off-main, so at the moment REC
    /// is pressed there is either no clip yet (a first take) or only the previous take's
    /// buffer to hand the player.
    func stopRecording(loopWhenFiled: Bool = false) {
        recorder.stop(loopWhenFiled: loopWhenFiled)
    }

    // MARK: - Timeline Zoom

    func zoomIn() {
        timelineZoom = min(4.0, timelineZoom * 1.25)
    }

    func zoomOut() {
        timelineZoom = max(0.5, timelineZoom / 1.25)
    }

    // MARK: - Project Save/Load (forwarders — behaviour lives in ProjectController)

    /// `completion` reports whether the project was actually written: `false` covers a
    /// cancelled save panel and a write error alike, so a caller that must not proceed
    /// until the work is safely on disk (the quit guard) can treat both as "don't".
    func saveProject(completion: ((Bool) -> Void)? = nil) { project.save(completion: completion) }

    func saveProjectAs() { project.saveAs() }

    func openProject() { project.open() }

    /// Opens a project the app did not have to ask for — a `.xyproj` double-clicked in
    /// Finder, or an entry in the File ▸ Open Recent submenu. `LSHandlerRank = Owner` in
    /// the bundle's document types means LaunchServices sends those events here, so this
    /// is the other half of claiming the type: without it the app launches and does
    /// nothing, which §9 rightly called worse than not claiming it at all.
    func openProject(at url: URL) { project.open(at: url) }

    /// Records a project as recently used and republishes the submenu's list. Lives here
    /// rather than in `ProjectController` so the store, the published copy and the
    /// platform guard stay in one place — `ProjectRecents` is AppKit, and both call sites
    /// (a successful save, a successful load) are otherwise platform-neutral code.
    func noteRecentProject(_ url: URL) {
        #if os(macOS)
        ProjectRecents.note(url)
        recentProjects = ProjectRecents.all
        #endif
    }

    func clearRecentProjects() {
        #if os(macOS)
        ProjectRecents.clear()
        recentProjects = ProjectRecents.all
        #endif
    }

    // MARK: - Off-main work

    /// Runs an edit's file work off the main thread and `apply` back on it,
    /// publishing `busy` on `busyEdit` for the duration.
    ///
    /// `work` must read only values captured *before* this call — the session state
    /// they came from can change while it runs. `apply` runs on the main thread.
    /// Callers whose result can be superseded re-check an epoch inside `apply`.
    ///
    /// The label is reference-counted rather than simply cleared on return: a keyboard
    /// shortcut can start a second edit while one is already running, and the first to
    /// finish must not re-enable the controls for the one still in flight.
    func runOffMain<T>(busy: String, work: @escaping () -> T, apply: @escaping (T) -> Void) {
        busyDepth += 1
        busyEdit = busy
        performOffMain(work: work) { [weak self] result in
            guard let self else { return }
            self.busyDepth -= 1
            if self.busyDepth == 0 { self.busyEdit = nil }
            apply(result)
        }
    }
}

