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
    @Published var selectedInputID:  AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?
    @Published var isMonitoring = false
    @Published var isRecording  = false
    @Published var volume: Double = 0.3
    @Published var inputVolume: Double = 0.3
    @Published var levelL: Double = 0
    @Published var levelR: Double = 0
    @Published var peakL:  Double = 0
    @Published var peakR:  Double = 0
    @Published var peakDB: Double = -Double.infinity
    @Published var waveformSamples: [Double] = Array(repeating: 0, count: Theme.waveformCount)
    @Published var recordingDuration: TimeInterval = 0
    @Published var status = "Ready"
    @Published var sampleRateString = "48 kHz · 24-bit · Stereo"

    // Effect chain (replaces hardcoded EQ/Reverb/Delay/Tape)
    @Published var liveChain: [ChainSlot] = []
    @Published var showEffects = false
    @Published var showSettings = false

    // Effect chain presets
    @Published var presetNames: [String] = []
    @Published var showPresetSave = false
    @Published var presetSaveName: String = ""

    // Settings
    @Published var saveLocation: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/OP-XY Monitor/Tracks")
        return base
    }()

    // Trim editor
    @Published var trimmingTrack: Int? = nil
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 1
    @Published var trimPeaks: [Double] = []
    var trimClipDuration: TimeInterval = 0

    // Count-in
    @Published var countInBars: Int = 0   // 0 = off, 1–4
    @Published var countingIn: Bool = false

    // View mode (0 = arrange, 1 = monitor)
    @Published var viewMode: Int = 0
    @Published var bounceStatus: String? = nil
    @Published var loopEnabled: Bool = true

    // Timeline zoom & playhead follow
    @Published var timelineZoom: Double = 1.0     // 0.5 – 4.0
    @Published var playheadFollow: Bool = true

    // Metronome
    @Published var metronomeEnabled = true
    @Published var metronomeBPM: Double = 120
    @Published var metronomeVolume: Double = 0.45

    // Tap tempo
    @Published var tapTempoFlash: Bool = false

    // Quantize
    @Published var quantizeMode: Int = 0
    static let quantizeLabels = ["OFF", "BAR", "BEAT"]

    // Multitrack
    @Published var recordings: [Recording] = []
    @Published var tracks: [TrackInfo] = (0..<Theme.trackCount).map { TrackInfo(id: $0) }
    @Published var selectedTrack: Int = 0
    @Published var isPlaying = false

    // Project persistence
    @Published var projectURL: URL? = nil
    @Published var projectName: String = "Untitled"
    @Published var projectDirty: Bool = false

    // Undo/Redo (state + logic live in TransportController)
    var canUndo: Bool { transport.canUndo }
    var canRedo: Bool { transport.canRedo }

    // Master limiter
    @Published var masterLimiterEnabled: Bool = true

    // MIDI
    @Published var midiTrackFollow: Bool = true

    // Per-track metering
    @Published var trackLevels: [Double] = Array(repeating: 0, count: Theme.trackCount)

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
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Monitoring Engine (forwarders — graph lives in EngineController)

    func startMonitoring() { engine.start() }

    func stopMonitoring() { engine.stop() }

    func switchOutput(to id: AudioDeviceID) { device.switchOutput(to: id) }

    func applyVolume(_ v: Double) { engine.applyVolume(v) }

    func applyInputVolume(_ v: Double) { engine.applyInputVolume(v) }

    func toggleMasterLimiter() { engine.toggleMasterLimiter() }

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

    func beginUndoGesture() { transport.beginUndoGesture() }

    func endUndoGesture() { transport.endUndoGesture() }

    func undo() { transport.undo() }

    func redo() { transport.redo() }

    func clearAll() { transport.clearAll() }

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

    func stopRecording() { recorder.stop() }

    // MARK: - Timeline Zoom

    func zoomIn() {
        timelineZoom = min(4.0, timelineZoom * 1.25)
    }

    func zoomOut() {
        timelineZoom = max(0.5, timelineZoom / 1.25)
    }

    // MARK: - Project Save/Load (forwarders — behaviour lives in ProjectController)

    func saveProject() { project.save() }

    func saveProjectAs() { project.saveAs() }

    func openProject() { project.open() }
}

