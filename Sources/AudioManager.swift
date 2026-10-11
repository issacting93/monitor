// monitor.swift — OP-XY Looper: retro-tech USB audio monitor, effects & multitrack looper
//
// Build:  swiftc monitor.swift -o monitor
// Run:    ./monitor

import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import CoreMIDI
import Darwin
import os
import UniformTypeIdentifiers

// ── AudioManager ────────────────────────────────────────────────────────────

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
    private var countInTimer: Timer?

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
    private var masterLimiterNode: AVAudioUnitEffect?

    // Internal Audio Engine
    private var engine:       AVAudioEngine?
    private var outMixer:     AVAudioMixerNode?
    var masterMixer:          AVAudioMixerNode?
    private var audioFile:    AVAudioFile?
    private var dryTapMixer:  AVAudioMixerNode?   // pre-FX tap point for dry recording

    // MIDI
    @Published var midiTrackFollow: Bool = true

    // Per-track metering
    @Published var trackLevels: [Double] = Array(repeating: 0, count: Theme.trackCount)

    private var recordingStart: Date?
    private var recordingTimer: Timer?

    // Sub-controllers. AudioManager stays the published facade the views talk to;
    // each controller owns a slice of private engine/algorithm state and reaches
    // back through `manager` (a one-way unowned reference). `init` force-touches
    // every controller so none can lazily initialize from a timer or audio thread.
    lazy var metronome = MetronomeController(manager: self)
    lazy var device    = DeviceController(manager: self)
    lazy var effects   = EffectsChainController(manager: self)
    lazy var transport = TransportController(manager: self)
    lazy var meter     = MeterController(manager: self)

    init() {
        _ = metronome; _ = device; _ = effects; _ = transport; _ = meter
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

    // MARK: - Monitoring Engine

    func startMonitoring() {
        if inputDevices.isEmpty { device.loadDevices() }

        // Request mic permission off the main thread before touching the audio engine
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            status = "Requesting microphone access…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startMonitoring() }
                    else { self?.status = "Microphone access denied — grant in System Settings" }
                }
            }
            return
        case .denied, .restricted:
            status = "Microphone access denied — grant in System Settings"
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        guard let inID = selectedInputID,
              let inDev = inputDevices.first(where: { $0.id == inID }) else {
            status = "No input device selected"; return
        }

        let currentOutID = getDefaultAudioDevice(input: false)
        if currentOutID == inID {
            status = "Output = \(inDev.name) — change output to avoid loopback"; return
        }

        // Warn about feedback when using built-in mic with built-in speakers
        let inName = inDev.name.lowercased()
        let outName = nameOfDevice(currentOutID).lowercased()
        if (inName.contains("macbook") || inName.contains("built-in") || inName.contains("microphone"))
            && (outName.contains("macbook") || outName.contains("built-in") || outName.contains("speaker")) {
            status = "Warning: built-in mic + speakers may cause feedback — use headphones"
        }

        let eng = AVAudioEngine()
        // Select the input device on our own engine instead of the system default, so
        // we don't take over the input for every other app.
        setEngineInputDevice(eng, inID)
        let hwFmt = eng.inputNode.inputFormat(forBus: 0)

        guard hwFmt.sampleRate > 0, hwFmt.channelCount > 0 else {
            status = "No usable input format — check Microphone permissions"
            return
        }

        let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: hwFmt.sampleRate, channels: 2) ?? hwFmt

        let dryTap  = AVAudioMixerNode()   // pre-FX tap point for dry recording
        let liveMix = AVAudioMixerNode()
        let master  = AVAudioMixerNode()
        eng.attach(dryTap); eng.attach(liveMix); eng.attach(master)

        eng.connect(eng.inputNode,     to: eng.mainMixerNode, format: hwFmt)
        eng.mainMixerNode.outputVolume = Float(inputVolume)

        // Build chain from liveChain slots (Apple nodes only — kernels added async after start)
        var chainNodes: [(id: UUID, node: AVAudioNode)] = []
        var pendingKernelSlots: [(index: Int, slot: ChainSlot, mod: EffectModule)] = []
        for (i, slot) in liveChain.enumerated() {
            guard let mod = EffectRegistry.shared.module(for: slot.moduleID) else { continue }
            if let node = mod.makeAudioNode?() {
                eng.attach(node)
                effects.setNodeBypass(node, bypass: !slot.enabled)
                for (pid, val) in slot.parameters { mod.applyParameter?(node, pid, val) }
                chainNodes.append((slot.id, node))
            } else if mod.makeKernel != nil {
                pendingKernelSlots.append((i, slot, mod))
            }
        }

        // Connect chain: mainMixer → dryTap → [effect1 → effect2 → ...] → liveMix
        // Recording taps dryTap (pre-FX); metering taps liveMix (post-FX).
        eng.connect(eng.mainMixerNode, to: dryTap, format: stereoFmt)
        var prev: AVAudioNode = dryTap
        for entry in chainNodes {
            eng.connect(prev, to: entry.node, format: stereoFmt)
            prev = entry.node
        }
        eng.connect(prev, to: liveMix, format: stereoFmt)
        eng.connect(liveMix, to: master, format: stereoFmt)

        var players: [AVAudioPlayerNode] = []
        var trkMixers: [AVAudioMixerNode] = []
        for i in 0..<Theme.trackCount {
            let player = AVAudioPlayerNode()
            let trkMix = AVAudioMixerNode()
            eng.attach(player); eng.attach(trkMix)
            eng.connect(player, to: trkMix, format: stereoFmt)
            eng.connect(trkMix, to: master, format: stereoFmt)
            trkMix.outputVolume = Float(tracks[i].volume)
            trkMix.pan = Float(tracks[i].pan)
            players.append(player)
            trkMixers.append(trkMix)
        }

        let metPlayer = AVAudioPlayerNode()
        let metMix    = AVAudioMixerNode()
        eng.attach(metPlayer); eng.attach(metMix)
        eng.connect(metPlayer, to: metMix, format: stereoFmt)
        eng.connect(metMix,    to: master, format: stereoFmt)
        metMix.outputVolume = Float(metronomeVolume)

        // Master limiter: prevents digital clipping on the output bus
        let limiterDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        let limiter = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        eng.attach(limiter)
        let au = limiter.audioUnit
        AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.012, 0)
        AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        limiter.bypass = !masterLimiterEnabled
        eng.connect(master, to: limiter, format: nil)
        eng.connect(limiter, to: eng.outputNode, format: nil)
        masterLimiterNode = limiter
        master.outputVolume = Float(volume) * 0.6   // slight headroom to reduce clipping

        // Metering tap: post-FX signal (meters show effected output)
        meter.attach(postFX: liveMix)

        // Recording tap: pre-FX dry signal (takes are recorded without effects)
        dryTap.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            if let file = self?.audioFile { try? file.write(from: buf) }
        }

        eng.prepare()
        do { try eng.start() } catch {
            status = "Engine failure: \(error.localizedDescription)"
            return
        }

        engine       = eng
        effects.setChainNodes(chainNodes)
        outMixer     = liveMix
        dryTapMixer  = dryTap
        masterMixer  = master
        transport.attach(players: players, mixers: trkMixers)
        meter.installTrackTaps(trkMixers)
        metronome.attach(player: metPlayer, mixer: metMix, sampleRate: stereoFmt.sampleRate)
        isMonitoring = true

        status = "\(inDev.name) → \(nameOfDevice(currentOutID))"
        sampleRateString = "\(Int(hwFmt.sampleRate / 1000)) kHz · 24-bit · Stereo"
        meter.startDisplayTimer()

        // Async-insert kernel-based modules. AVAudioUnit instantiation is async and
        // AUAudioUnit subclasses can't take init arguments, so the kernel factory and
        // sample rate are passed via process-wide statics. Instantiate one at a time:
        // otherwise a later slot overwrites the static before an earlier instantiation
        // completes, and every kernel ends up with the last module's DSP.
        instantiateKernels(Array(pendingKernelSlots), sampleRate: stereoFmt.sampleRate)
    }

    private func instantiateKernels(_ pending: [(index: Int, slot: ChainSlot, mod: EffectModule)],
                                    sampleRate: Double) {
        guard let head = pending.first else { return }
        let rest = Array(pending.dropFirst())
        guard let factory = head.mod.makeKernel else {
            instantiateKernels(rest, sampleRate: sampleRate)
            return
        }
        EffectAudioUnit.pendingKernelFactory = factory
        EffectAudioUnit.pendingSampleRate = sampleRate
        AVAudioUnit.instantiate(with: EffectAudioUnit.componentDesc, options: .loadInProcess) { [weak self] unit, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                EffectAudioUnit.pendingKernelFactory = nil
                if let kernelNode = unit, self.isMonitoring,
                   let eng = self.engine, let liveMix = self.outMixer {
                    let fmt = liveMix.outputFormat(forBus: 0)
                    // Insert after the last chain node, or after dryTapMixer
                    let insertAfter: AVAudioNode
                    if let last = self.effects.lastChainNode { insertAfter = last }
                    else if let dryTap = self.dryTapMixer { insertAfter = dryTap }
                    else { insertAfter = eng.mainMixerNode }
                    eng.disconnectNodeOutput(insertAfter)
                    eng.attach(kernelNode)
                    eng.connect(insertAfter, to: kernelNode, format: fmt)
                    eng.connect(kernelNode,  to: liveMix, format: fmt)
                    kernelNode.auAudioUnit.shouldBypassEffect = !head.slot.enabled
                    for (pid, val) in head.slot.parameters { head.mod.applyParameter?(kernelNode, pid, val) }
                    self.effects.appendChainNode(id: head.slot.id, node: kernelNode)
                }
                self.instantiateKernels(rest, sampleRate: sampleRate)
            }
        }
    }

    func stopMonitoring() {
        if isRecording { stopRecording() }
        stopAll()
        teardown()
        isMonitoring = false
        meter.resetDisplay()
        status = "Stopped"
    }

    func switchOutput(to id: AudioDeviceID) { device.switchOutput(to: id) }

    func applyVolume(_ v: Double) {
        volume = v
        masterMixer?.outputVolume = Float(v) * 0.6
    }

    func applyInputVolume(_ v: Double) {
        inputVolume = v
        engine?.mainMixerNode.outputVolume = Float(v)
    }

    func toggleMasterLimiter() {
        masterLimiterEnabled.toggle()
        masterLimiterNode?.bypass = !masterLimiterEnabled
    }

    private func teardown() {
        metronome.detach()
        meter.detach()
        dryTapMixer?.removeTap(onBus: 0)
        engine?.stop()
        effects.clearChainNodes()
        engine = nil
        outMixer = nil; dryTapMixer = nil; masterMixer = nil; masterLimiterNode = nil
        transport.detach()
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

    // MARK: - Recording

    func startRecording() {
        guard isMonitoring, engine != nil else { return }

        // Count-in: play metronome clicks for N bars before actually recording
        if countInBars > 0 && !countingIn {
            countingIn = true
            status = "Count-in..."
            if !metronome.isRunning { metronome.start() }
            let secsPerBar = 240.0 / metronomeBPM
            let countInDuration = secsPerBar * Double(countInBars)
            countInTimer = Timer.scheduledTimer(withTimeInterval: countInDuration, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.countingIn = false
                    self?.countInTimer = nil
                    self?.beginRecording()
                }
            }
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        guard engine != nil, let dryTap = dryTapMixer else { return }
        let fmt  = dryTap.outputFormat(forBus: 0)
        let name = "take_\(timestampFmt.string(from: Date())).wav"
        let url  = transport.trackFolder(selectedTrack).appendingPathComponent(name)
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            recordingStart    = Date()
            recordingDuration = 0
            isRecording       = true
            status            = "Recording TRK \(String(format: "%02d", selectedTrack + 1))"
            if metronomeEnabled && !metronome.isRunning { metronome.start() }
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let s = self.recordingStart else { return }
                DispatchQueue.main.async { self.recordingDuration = Date().timeIntervalSince(s) }
            }
        } catch {
            status = "Recording error: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        // Cancel count-in if active
        if countingIn {
            countInTimer?.invalidate(); countInTimer = nil
            countingIn = false
            status = "Count-in cancelled"
            if !tracks.contains(where: { $0.isPlaying }) { metronome.stop() }
            return
        }
        recordingTimer?.invalidate(); recordingTimer = nil
        let saved = audioFile?.url
        let dur   = recordingDuration
        let trk   = selectedTrack
        audioFile   = nil
        isRecording = false
        if !tracks.contains(where: { $0.isPlaying }) { metronome.stop() }

        guard let u = saved else { return }
        let peaks = computePeaks(url: u, count: Theme.clipPeaks)
        let clip  = TrackClip(url: u, duration: dur, peaks: peaks)
        let rec   = Recording(url: u, duration: dur, trackIndex: trk)

        status = "Saved \(u.lastPathComponent) → TRK \(String(format: "%02d", trk + 1))"
        DispatchQueue.main.async {
            self.transport.pushUndo()
            self.recordings.append(rec)
            self.tracks[trk].clips.append(clip)
            self.transport.loadTrackBuffer(trk)
        }
    }

    // MARK: - Timeline Zoom

    func zoomIn() {
        timelineZoom = min(4.0, timelineZoom * 1.25)
    }

    func zoomOut() {
        timelineZoom = max(0.5, timelineZoom / 1.25)
    }


    // MARK: - Project Save/Load

    private func buildProjectData() -> ProjectData {
        var trackDataList: [ProjectTrackData] = []
        for t in tracks {
            let clipDataList = t.clips.map { clip -> ProjectClipData in
                let fileName = clip.url.lastPathComponent
                return ProjectClipData(relativePath: "Audio/Track \(t.id + 1)/\(fileName)",
                                       duration: clip.duration)
            }
            trackDataList.append(ProjectTrackData(
                index: t.id,
                clips: clipDataList,
                volume: t.volume,
                pan: t.pan,
                muted: t.muted,
                solo: t.solo
            ))
        }

        let chainData = liveChain.map { slot in
            ProjectChainSlotData(moduleID: slot.moduleID, enabled: slot.enabled, parameters: slot.parameters)
        }

        return ProjectData(
            bpm: metronomeBPM,
            metronomeEnabled: metronomeEnabled,
            metronomeVolume: metronomeVolume,
            quantizeMode: quantizeMode,
            countInBars: countInBars,
            loopEnabled: loopEnabled,
            masterVolume: volume,
            inputVolume: inputVolume,
            selectedTrack: selectedTrack,
            tracks: trackDataList,
            effectChain: chainData,
            masterLimiterEnabled: masterLimiterEnabled
        )
    }

    func saveProject() {
        if let url = projectURL {
            performSave(to: url)
        } else {
            saveProjectAs()
        }
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.nameFieldStringValue = projectName
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destURL = panel.url else { return }
            DispatchQueue.main.async {
                var url = destURL
                if url.pathExtension != "xyproj" {
                    url = url.appendingPathExtension("xyproj")
                }
                self?.performSave(to: url)
            }
        }
    }

    private func performSave(to packageURL: URL) {
        let fm = FileManager.default

        // Create package directory
        try? fm.createDirectory(at: packageURL, withIntermediateDirectories: true)

        // Copy audio files into Audio/ subdirectory
        for t in tracks {
            guard !t.clips.isEmpty else { continue }
            let trackAudioDir = packageURL.appendingPathComponent("Audio/Track \(t.id + 1)")
            try? fm.createDirectory(at: trackAudioDir, withIntermediateDirectories: true)
            for clip in t.clips {
                let destFile = trackAudioDir.appendingPathComponent(clip.url.lastPathComponent)
                if !fm.fileExists(atPath: destFile.path) {
                    try? fm.copyItem(at: clip.url, to: destFile)
                }
            }
        }

        // Serialize project data
        let data = buildProjectData()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let jsonData = try encoder.encode(data)
            let jsonURL = packageURL.appendingPathComponent("project.json")
            try jsonData.write(to: jsonURL)
        } catch {
            status = "Save error: \(error.localizedDescription)"
            return
        }

        projectURL = packageURL
        projectName = packageURL.deletingPathExtension().lastPathComponent
        projectDirty = false
        status = "Saved \(projectName)"
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "xyproj") ?? .folder]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.performLoad(from: url)
            }
        }
    }

    private func performLoad(from packageURL: URL) {
        let jsonURL = packageURL.appendingPathComponent("project.json")
        let fm = FileManager.default

        guard fm.fileExists(atPath: jsonURL.path) else {
            status = "Not a valid project: missing project.json"
            return
        }

        let decoder = JSONDecoder()
        let proj: ProjectData
        do {
            let jsonData = try Data(contentsOf: jsonURL)
            proj = try decoder.decode(ProjectData.self, from: jsonData)
        } catch {
            status = "Load error: \(error.localizedDescription)"
            return
        }

        // Stop current playback
        stopAll()

        // Restore session state
        metronomeBPM = proj.bpm
        metronomeEnabled = proj.metronomeEnabled
        metronomeVolume = proj.metronomeVolume ?? 0.45
        quantizeMode = proj.quantizeMode
        countInBars = proj.countInBars
        loopEnabled = proj.loopEnabled
        applyVolume(proj.masterVolume)
        applyInputVolume(proj.inputVolume)
        masterLimiterEnabled = proj.masterLimiterEnabled ?? true
        selectedTrack = min(proj.selectedTrack, Theme.trackCount - 1)

        // Resolve which clip files exist and collect the peak-decode work. Peak
        // buckets are computed off the main thread below (a project can hold many
        // long clips; reading them on the main thread stalls the UI on open).
        var plan: [(trackIndex: Int, duration: Double, url: URL)] = []
        var missingFiles: [String] = []
        for td in proj.tracks where td.index < Theme.trackCount {
            for cd in td.clips {
                let fileURL = packageURL.appendingPathComponent(cd.relativePath)
                if fm.fileExists(atPath: fileURL.path) {
                    plan.append((td.index, cd.duration, fileURL))
                } else {
                    missingFiles.append(cd.relativePath)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let built: [(trackIndex: Int, clip: TrackClip)] = plan.map { p in
                let peaks = computePeaks(url: p.url, count: Theme.clipPeaks)
                return (p.trackIndex, TrackClip(url: p.url, duration: p.duration, peaks: peaks))
            }
            DispatchQueue.main.async {
                self?.applyLoadedProject(proj, packageURL: packageURL,
                                         builtClips: built, missingFiles: missingFiles)
            }
        }
    }

    // Applies a decoded project on the main thread, after the off-main clip peak
    // decode in `performLoad`.
    private func applyLoadedProject(_ proj: ProjectData, packageURL: URL,
                                    builtClips: [(trackIndex: Int, clip: TrackClip)],
                                    missingFiles: [String]) {
        var newTracks = (0..<Theme.trackCount).map { TrackInfo(id: $0) }
        for td in proj.tracks where td.index < Theme.trackCount {
            newTracks[td.index].volume = td.volume
            newTracks[td.index].pan = td.pan
            newTracks[td.index].muted = td.muted
            newTracks[td.index].solo = td.solo
        }
        for item in builtClips {
            newTracks[item.trackIndex].clips.append(item.clip)
        }
        tracks = newTracks
        transport.resetTrackBuffers()

        // Load track buffers for tracks that have clips
        for i in 0..<tracks.count where !tracks[i].clips.isEmpty {
            transport.loadTrackBuffer(i)
        }

        // Restore effect chain
        var newChain: [ChainSlot] = []
        for slotData in proj.effectChain {
            var slot = ChainSlot(moduleID: slotData.moduleID, enabled: slotData.enabled)
            for (key, value) in slotData.parameters { slot.parameters[key] = value }
            newChain.append(slot)
        }
        liveChain = newChain

        // Rebuild engine to apply the restored effect chain
        if isMonitoring {
            stopMonitoring()
            startMonitoring()
        }
        transport.refreshTrackMixers()

        projectURL = packageURL
        projectName = packageURL.deletingPathExtension().lastPathComponent
        projectDirty = false

        if missingFiles.isEmpty {
            status = "Loaded \(projectName)"
        } else {
            status = "Loaded \(projectName) (\(missingFiles.count) missing file\(missingFiles.count == 1 ? "" : "s"))"
        }
    }
}

