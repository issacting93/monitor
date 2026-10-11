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

    // Undo/Redo
    private var undoStack: [[TrackInfo]] = []
    private var redoStack: [[TrackInfo]] = []
    private var undoGestureActive: Bool = false   // debounce slider drags
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // Master limiter
    @Published var masterLimiterEnabled: Bool = true
    private var masterLimiterNode: AVAudioUnitEffect?

    // Internal Audio Engine
    private var engine:       AVAudioEngine?
    private var outMixer:     AVAudioMixerNode?
    var masterMixer:          AVAudioMixerNode?
    private var audioFile:    AVAudioFile?
    private var dryTapMixer:  AVAudioMixerNode?   // pre-FX tap point for dry recording
    private var playerNodes:     [AVAudioPlayerNode] = []
    private var trackMixers:     [AVAudioMixerNode] = []
    private var trackBuffers:    [AVAudioPCMBuffer?] = Array(repeating: nil, count: Theme.trackCount)

    // MIDI
    @Published var midiTrackFollow: Bool = true

    // Per-track metering
    @Published var trackLevels: [Double] = Array(repeating: 0, count: Theme.trackCount)

    // Meter bridge. The render-thread taps publish raw levels into `meters` under a
    // lock (cheap, uncontended, no allocation); the display timer reads that snapshot
    // on the main thread, which owns all smoothing / peak-hold state. This keeps the
    // render thread from racing the main thread on shared meter variables.
    private struct MeterSnapshot {
        var levelL: Float = 0
        var levelR: Float = 0
        var track: [Float] = Array(repeating: 0, count: Theme.trackCount)
    }
    private let meters = OSAllocatedUnfairLock(initialState: MeterSnapshot())

    // Main-thread-only meter smoothing / peak-hold state
    private var rawPeakL:  Float = 0
    private var rawPeakR:  Float = 0
    private var peakHoldL: Int   = 0
    private var peakHoldR: Int   = 0

    private var recordingStart: Date?
    private var displayTimer:   Timer?
    private var recordingTimer: Timer?

    // Sub-controllers. AudioManager stays the published facade the views talk to;
    // each controller owns a slice of private engine/algorithm state and reaches
    // back through `manager` (a one-way unowned reference). `init` force-touches
    // every controller so none can lazily initialize from a timer or audio thread.
    lazy var metronome = MetronomeController(manager: self)
    lazy var device    = DeviceController(manager: self)
    lazy var effects   = EffectsChainController(manager: self)

    init() {
        _ = metronome; _ = device; _ = effects
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
        liveMix.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.processMeterTap(buf)
        }

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
        playerNodes  = players
        trackMixers  = trkMixers
        installTrackMeterTaps()
        metronome.attach(player: metPlayer, mixer: metMix, sampleRate: stereoFmt.sampleRate)
        isMonitoring = true

        status = "\(inDev.name) → \(nameOfDevice(currentOutID))"
        sampleRateString = "\(Int(hwFmt.sampleRate / 1000)) kHz · 24-bit · Stereo"
        startDisplayTimer()

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
        displayTimer?.invalidate(); displayTimer = nil
        levelL = 0; levelR = 0; peakL = 0; peakR = 0
        peakDB = -Double.infinity
        waveformSamples = Array(repeating: 0, count: Theme.waveformCount)
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
        removeTrackMeterTaps()
        outMixer?.removeTap(onBus: 0)
        dryTapMixer?.removeTap(onBus: 0)
        engine?.stop()
        effects.clearChainNodes()
        engine = nil
        outMixer = nil; dryTapMixer = nil; masterMixer = nil; masterLimiterNode = nil
        playerNodes = []; trackMixers = []
    }

    // MARK: - Metering

    /// Metering-only tap (post-FX on liveMix). Does NOT write to the audio file.
    /// Runs on the render thread — only publishes raw RMS into the locked snapshot.
    private func processMeterTap(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        let channels = Int(buf.format.channelCount)

        var sumL: Float = 0
        for i in 0..<n { sumL += data[0][i] * data[0][i] }
        let rmsL = sqrt(sumL / Float(n))

        let rmsR: Float
        if channels > 1 {
            var sumR: Float = 0
            for i in 0..<n { sumR += data[1][i] * data[1][i] }
            rmsR = sqrt(sumR / Float(n))
        } else { rmsR = rmsL }

        meters.withLock { $0.levelL = rmsL; $0.levelR = rmsR }
    }

    private func installTrackMeterTaps() {
        for i in 0..<trackMixers.count {
            trackMixers[i].installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
                guard let self, let data = buf.floatChannelData else { return }
                let n = Int(buf.frameLength)
                guard n > 0 else { return }
                var peak: Float = 0
                for s in 0..<n { peak = max(peak, abs(data[0][s])) }
                if buf.format.channelCount > 1 {
                    for s in 0..<n { peak = max(peak, abs(data[1][s])) }
                }
                let peakValue = peak
                self.meters.withLock { $0.track[i] = peakValue }
            }
        }
    }

    private func removeTrackMeterTaps() {
        for mixer in trackMixers {
            mixer.removeTap(onBus: 0)
        }
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        // Timer fires on the main run loop, so all smoothing / peak-hold below is
        // main-thread state; the render thread only writes the locked snapshot.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let snap = self.meters.withLock { $0 }

            let scaledL = Double(min(snap.levelL * 4.5, 1))
            let scaledR = Double(min(snap.levelR * 4.5, 1))

            // Peak hold (main-thread only)
            if snap.levelL >= self.rawPeakL { self.rawPeakL = snap.levelL; self.peakHoldL = 0 }
            else { self.peakHoldL += 1; if self.peakHoldL > 30 { self.rawPeakL *= 0.94 } }
            if snap.levelR >= self.rawPeakR { self.rawPeakR = snap.levelR; self.peakHoldR = 0 }
            else { self.peakHoldR += 1; if self.peakHoldR > 30 { self.rawPeakR *= 0.94 } }

            let scaledPeakL = Double(min(self.rawPeakL * 4.5, 1))
            let scaledPeakR = Double(min(self.rawPeakR * 4.5, 1))
            let maxPeak     = Double(max(self.rawPeakL, self.rawPeakR))

            self.levelL = self.levelL * 0.70 + scaledL * 0.30
            self.levelR = self.levelR * 0.70 + scaledR * 0.30
            self.peakL  = scaledPeakL
            self.peakR  = scaledPeakR
            self.peakDB = maxPeak > 0 ? 20.0 * log10(maxPeak) : -Double.infinity

            var samples = self.waveformSamples
            samples.removeFirst()
            samples.append((self.levelL + self.levelR) / 2.0)
            self.waveformSamples = samples

            // Update per-track meters
            for i in 0..<Theme.trackCount {
                let raw = Double(min(snap.track[i] * 4.5, 1))
                self.trackLevels[i] = self.trackLevels[i] * 0.7 + raw * 0.3
            }

            // Update track loop progress
            for i in 0..<self.tracks.count where self.tracks[i].isPlaying {
                if i < self.playerNodes.count, let buffer = self.trackBuffers[i] {
                    if let nodeTime = self.playerNodes[i].lastRenderTime,
                       nodeTime.isSampleTimeValid,
                       let playerTime = self.playerNodes[i].playerTime(forNodeTime: nodeTime) {
                        let total = Double(buffer.frameLength)
                        if total > 0 {
                            let cur = abs(Double(playerTime.sampleTime)).truncatingRemainder(dividingBy: total)
                            self.tracks[i].loopProgress = cur / total
                        }
                    }
                }
            }
        }
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
        let url  = trackFolder(selectedTrack).appendingPathComponent(name)
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
            self.pushUndo()
            self.recordings.append(rec)
            self.tracks[trk].clips.append(clip)
            self.loadTrackBuffer(trk)
        }
    }

    // MARK: - Per-Track Playback

    // Toggles loop mode and re-schedules any currently-playing tracks so the change
    // takes effect immediately instead of at the next play.
    func setLoopEnabled(_ enabled: Bool) {
        guard enabled != loopEnabled else { return }
        loopEnabled = enabled
        for i in 0..<tracks.count where tracks[i].isPlaying {
            guard let buffer = trackBuffers[i] else { continue }
            scheduleTrackBuffer(i, buffer: buffer)
        }
        projectDirty = true
    }

    // Bumped on every (re)schedule so a stale one-shot completion handler can't stop
    // a later playback of the same track.
    private var playGenerations = [Int](repeating: 0, count: Theme.trackCount)

    // Schedules a track's buffer respecting `loopEnabled`: loop mode repeats forever,
    // one-shot mode plays once and marks the track stopped (on main) when it ends.
    private func scheduleTrackBuffer(_ i: Int, buffer: AVAudioPCMBuffer) {
        guard i < playerNodes.count else { return }
        let player = playerNodes[i]
        player.stop()
        if loopEnabled {
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        } else {
            playGenerations[i] += 1
            let gen = playGenerations[i]
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, gen == self.playGenerations[i] else { return }
                    self.stopTrackLoop(i)
                }
            })
        }
        player.play()
    }

    func startTrackLoop(_ i: Int) {
        guard isMonitoring, i < playerNodes.count else { return }
        if trackBuffers[i] == nil {
            // Buffer not decoded yet — load it off-main, then start once it's ready.
            loadTrackBuffer(i) { [weak self] in self?.startTrackLoop(i) }
            return
        }
        guard let buffer = trackBuffers[i] else { return }
        scheduleTrackBuffer(i, buffer: buffer)
        tracks[i].isPlaying = true
        refreshTrackMixers()
        if metronomeEnabled && !metronome.isRunning { metronome.start() }
        isPlaying = true
        status = "Looping TRK \(String(format: "%02d", i + 1))"
    }

    func stopTrackLoop(_ i: Int) {
        guard i < playerNodes.count else { return }
        playGenerations[i] += 1
        playerNodes[i].stop()
        tracks[i].isPlaying = false
        tracks[i].loopProgress = 0
        if !tracks.contains(where: { $0.isPlaying }) {
            metronome.stop()
            isPlaying = false
            status = "Stopped"
        }
    }

    func toggleTrackPlayback(_ i: Int) {
        if tracks[i].isPlaying { stopTrackLoop(i) } else { startTrackLoop(i) }
    }

    func toggleTrackRecord(_ i: Int) {
        selectedTrack = i
        if countingIn {
            // Count-in is pending (isRecording is still false) — cancel it instead
            // of starting a second recording on top of the scheduled one.
            stopRecording()
        } else if isRecording {
            stopRecording()
            startTrackLoop(i)
        } else {
            startRecording()
        }
    }

    func playAll() {
        guard isMonitoring else { return }
        // Decode any missing buffers off-main first, then re-enter to schedule.
        let missing = (0..<tracks.count).filter { !tracks[$0].clips.isEmpty && trackBuffers[$0] == nil }
        if !missing.isEmpty {
            let group = DispatchGroup()
            for i in missing {
                group.enter()
                loadTrackBuffer(i) { group.leave() }
            }
            group.notify(queue: .main) { [weak self] in self?.playAll() }
            return
        }
        for i in 0..<tracks.count where !tracks[i].clips.isEmpty {
            guard let buffer = trackBuffers[i] else { continue }
            scheduleTrackBuffer(i, buffer: buffer)
            tracks[i].isPlaying = true
        }
        refreshTrackMixers()
        isPlaying = true
        metronome.start()
        status = "Playing all tracks"
    }

    func stopAll() {
        metronome.stop()
        for i in 0..<tracks.count {
            if i < playerNodes.count { playerNodes[i].stop() }
            tracks[i].isPlaying = false
            tracks[i].loopProgress = 0
        }
        isPlaying = false
        status = "Stopped"
    }

    // MARK: - Undo/Redo

    func pushUndo() {
        undoStack.append(tracks)
        redoStack.removeAll()
        if undoStack.count > 30 { undoStack.removeFirst() }
        projectDirty = true
    }

    /// Push undo only once per gesture (for sliders/continuous controls).
    func beginUndoGesture() { undoGestureActive = false }
    func pushUndoIfNeeded() {
        if !undoGestureActive {
            undoGestureActive = true
            pushUndo()
        }
    }
    func endUndoGesture() { undoGestureActive = false }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(tracks)
        if redoStack.count > 30 { redoStack.removeFirst() }
        restoreTracks(snapshot)
        status = "Undo"
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(tracks)
        if undoStack.count > 30 { undoStack.removeFirst() }
        restoreTracks(snapshot)
        status = "Redo"
    }

    private func restoreTracks(_ snapshot: [TrackInfo]) {
        for i in 0..<tracks.count {
            if tracks[i].isPlaying && i < playerNodes.count {
                playerNodes[i].stop()
            }
        }
        tracks = snapshot
        for i in 0..<tracks.count {
            trackBuffers[i] = nil
            if !tracks[i].clips.isEmpty { loadTrackBuffer(i) }
            tracks[i].isPlaying = false
            tracks[i].loopProgress = 0
        }
        isPlaying = false
        refreshTrackMixers()
    }

    func clearAll() {
        pushUndo()
        stopAll()
        for i in 0..<tracks.count {
            tracks[i].clips.removeAll()
            trackBuffers[i] = nil
        }
        recordings.removeAll()
        status = "All tracks cleared"
    }

    // MARK: - Timeline Zoom

    func zoomIn() {
        timelineZoom = min(4.0, timelineZoom * 1.25)
    }

    func zoomOut() {
        timelineZoom = max(0.5, timelineZoom / 1.25)
    }

    // MARK: - Trim Editor

    func openTrimEditor(_ trackIndex: Int) {
        guard trackIndex < tracks.count, let clip = tracks[trackIndex].clips.last else { return }
        if tracks[trackIndex].isPlaying { stopTrackLoop(trackIndex) }
        trimClipDuration = clip.duration
        trimPeaks = computePeaks(url: clip.url, count: 256)
        trimStart = 0
        trimEnd = 1
        trimmingTrack = trackIndex
    }

    func cancelTrim() {
        trimmingTrack = nil
        trimPeaks = []
    }

    func applyTrim() {
        guard let ti = trimmingTrack, ti < tracks.count, let clip = tracks[ti].clips.last else { return }
        pushUndo()
        guard let srcFile = try? AVAudioFile(forReading: clip.url) else { return }
        let totalFrames = Int64(srcFile.length)
        let startFrame = Int64(trimStart * Double(totalFrames))
        let endFrame = Int64(trimEnd * Double(totalFrames))
        let trimmedFrames = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard trimmedFrames > 0 else { return }

        // Read the source region
        srcFile.framePosition = startFrame
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFile.processingFormat, frameCapacity: trimmedFrames) else { return }
        do { try srcFile.read(into: readBuf, frameCount: trimmedFrames) } catch { return }

        // Write trimmed file
        let dir = clip.url.deletingLastPathComponent()
        let trimName = "trim_\(timestampFmt.string(from: Date())).wav"
        let trimURL = dir.appendingPathComponent(trimName)
        do {
            let outFile = try AVAudioFile(forWriting: trimURL, settings: srcFile.fileFormat.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
            try outFile.write(from: readBuf)
        } catch { status = "Trim error: \(error.localizedDescription)"; return }

        // Replace clip
        let dur = Double(trimmedFrames) / srcFile.fileFormat.sampleRate
        let peaks = computePeaks(url: trimURL, count: Theme.clipPeaks)
        tracks[ti].clips[tracks[ti].clips.count - 1] = TrackClip(url: trimURL, duration: dur, peaks: peaks)
        trackBuffers[ti] = nil
        loadTrackBuffer(ti)
        trimmingTrack = nil
        trimPeaks = []
        status = "Trimmed → \(trimName)"
    }

    // MARK: - Split & Duplicate

    func splitClipAtPlayhead(_ trackIndex: Int) {
        guard trackIndex < tracks.count, !tracks[trackIndex].clips.isEmpty else {
            status = "No clip to split on TRK \(String(format: "%02d", trackIndex + 1))"
            return
        }
        let progress = tracks[trackIndex].loopProgress
        guard progress > 0.001 && progress < 0.999 else {
            status = "Move playhead inside clip to split"
            return
        }

        let clipIndex = tracks[trackIndex].clips.count - 1
        let clip = tracks[trackIndex].clips[clipIndex]
        guard let srcFile = try? AVAudioFile(forReading: clip.url) else {
            status = "Cannot read clip file"; return
        }
        let totalFrames = Int64(srcFile.length)
        let splitFrame = Int64(progress * Double(totalFrames))
        let framesA = AVAudioFrameCount(splitFrame)
        let framesB = AVAudioFrameCount(totalFrames - splitFrame)
        guard framesA > 0 && framesB > 0 else {
            status = "Split point too close to edge"; return
        }

        let wasPlaying = tracks[trackIndex].isPlaying
        if wasPlaying { stopTrackLoop(trackIndex) }

        let dir = clip.url.deletingLastPathComponent()
        let ts = timestampFmt.string(from: Date())

        // Part A: frames 0..<splitFrame
        srcFile.framePosition = 0
        guard let bufA = AVAudioPCMBuffer(pcmFormat: srcFile.processingFormat, frameCapacity: framesA) else { return }
        do { try srcFile.read(into: bufA, frameCount: framesA) } catch { status = "Split read error"; return }
        let urlA = dir.appendingPathComponent("split_A_\(ts).wav")
        do {
            let outA = try AVAudioFile(forWriting: urlA, settings: srcFile.fileFormat.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try outA.write(from: bufA)
        } catch { status = "Split write error: \(error.localizedDescription)"; return }

        // Part B: frames splitFrame..<totalFrames
        srcFile.framePosition = splitFrame
        guard let bufB = AVAudioPCMBuffer(pcmFormat: srcFile.processingFormat, frameCapacity: framesB) else { return }
        do { try srcFile.read(into: bufB, frameCount: framesB) } catch { status = "Split read error"; return }
        let urlB = dir.appendingPathComponent("split_B_\(ts).wav")
        do {
            let outB = try AVAudioFile(forWriting: urlB, settings: srcFile.fileFormat.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try outB.write(from: bufB)
        } catch { status = "Split write error: \(error.localizedDescription)"; return }

        let sr = srcFile.fileFormat.sampleRate
        let clipA = TrackClip(url: urlA, duration: Double(framesA) / sr,
                              peaks: computePeaks(url: urlA, count: Theme.clipPeaks))
        let clipB = TrackClip(url: urlB, duration: Double(framesB) / sr,
                              peaks: computePeaks(url: urlB, count: Theme.clipPeaks))

        pushUndo()
        tracks[trackIndex].clips.remove(at: clipIndex)
        tracks[trackIndex].clips.insert(clipA, at: clipIndex)
        tracks[trackIndex].clips.insert(clipB, at: clipIndex + 1)

        trackBuffers[trackIndex] = nil
        loadTrackBuffer(trackIndex)
        projectDirty = true
        status = "Split TRK \(String(format: "%02d", trackIndex + 1)) at \(Int(progress * 100))%"
    }

    func duplicateClip(_ trackIndex: Int, clipIndex: Int? = nil) {
        guard trackIndex < tracks.count, !tracks[trackIndex].clips.isEmpty else {
            status = "No clip to duplicate on TRK \(String(format: "%02d", trackIndex + 1))"
            return
        }
        let ci = clipIndex ?? (tracks[trackIndex].clips.count - 1)
        guard ci >= 0 && ci < tracks[trackIndex].clips.count else { return }
        let clip = tracks[trackIndex].clips[ci]

        let fm = FileManager.default
        let dir = clip.url.deletingLastPathComponent()
        let base = clip.url.deletingPathExtension().lastPathComponent
        let ext = clip.url.pathExtension
        let ts = timestampFmt.string(from: Date())
        let dupURL = dir.appendingPathComponent("\(base)_dup_\(ts).\(ext)")
        do {
            try fm.copyItem(at: clip.url, to: dupURL)
        } catch {
            status = "Duplicate error: \(error.localizedDescription)"; return
        }

        let peaks = computePeaks(url: dupURL, count: Theme.clipPeaks)
        let newClip = TrackClip(url: dupURL, duration: clip.duration, peaks: peaks,
                                fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
        pushUndo()
        tracks[trackIndex].clips.insert(newClip, at: ci + 1)
        trackBuffers[trackIndex] = nil
        loadTrackBuffer(trackIndex)
        projectDirty = true
        status = "Duplicated clip → \(dupURL.lastPathComponent)"
    }

    // MARK: - Export

    func exportTrack(_ trackIndex: Int) {
        guard trackIndex < tracks.count, let clip = tracks[trackIndex].clips.last else {
            status = "No clip to export on TRK \(String(format: "%02d", trackIndex + 1))"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "TRK\(String(format: "%02d", trackIndex + 1))_\(timestampFmt.string(from: Date())).wav"
        panel.title = "Export Track \(trackIndex + 1)"
        panel.begin { [weak self] response in
            guard response == .OK, let destURL = panel.url else { return }
            do {
                try FileManager.default.copyItem(at: clip.url, to: destURL)
                DispatchQueue.main.async { self?.status = "Exported → \(destURL.lastPathComponent)" }
            } catch {
                DispatchQueue.main.async { self?.status = "Export error: \(error.localizedDescription)" }
            }
        }
    }

    func importAudioFile(_ url: URL, toTrack trackIndex: Int) {
        guard trackIndex < tracks.count else { return }
        let fm = FileManager.default

        // Validate it's a readable audio file
        guard let file = try? AVAudioFile(forReading: url) else {
            status = "Cannot read audio file: \(url.lastPathComponent)"
            return
        }

        // Copy into track directory
        let trackDir = saveLocation.appendingPathComponent("Track \(String(format: "%02d", trackIndex + 1))")
        try? fm.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let destURL = trackDir.appendingPathComponent(url.lastPathComponent)
        if !fm.fileExists(atPath: destURL.path) {
            do { try fm.copyItem(at: url, to: destURL) }
            catch { status = "Import error: \(error.localizedDescription)"; return }
        }

        let duration = Double(file.length) / file.fileFormat.sampleRate
        let peaks = computePeaks(url: destURL, count: Theme.clipPeaks)
        let clip = TrackClip(url: destURL, duration: duration, peaks: peaks)
        pushUndo()
        tracks[trackIndex].clips.append(clip)
        loadTrackBuffer(trackIndex)
        projectDirty = true
        status = "Imported \(url.lastPathComponent) → TRK \(String(format: "%02d", trackIndex + 1))"
    }

    func changeSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Save Location"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.saveLocation = url
                self?.status = "Save location → \(url.path)"
            }
        }
    }

    // MARK: - Mixdown Export

    func bounceMixdown() {
        let anySolo = tracks.contains { $0.solo }
        // Collect audible tracks with audio
        var sources: [(buffer: AVAudioPCMBuffer, volume: Float, pan: Float)] = []
        for (_, t) in tracks.enumerated() {
            let audible = t.solo || (!anySolo && !t.muted)
            guard audible, let clip = t.clips.last else { continue }
            guard let file = try? AVAudioFile(forReading: clip.url) else { continue }
            let frames = AVAudioFrameCount(file.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { continue }
            do { try file.read(into: buf) } catch { continue }
            sources.append((buf, Float(t.volume), Float(t.pan)))
        }
        guard !sources.isEmpty else { status = "No audible tracks to bounce"; return }

        // Find the longest track duration
        let maxFrames = sources.map { Int($0.buffer.frameLength) }.max()!
        let fmt = sources[0].buffer.format
        let sr = fmt.sampleRate
        let channels = Int(fmt.channelCount)

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(maxFrames)) else { return }
        outBuf.frameLength = AVAudioFrameCount(maxFrames)

        // Zero the output
        for ch in 0..<channels {
            let ptr = outBuf.floatChannelData![ch]
            for f in 0..<maxFrames { ptr[f] = 0 }
        }

        bounceStatus = "Mixing..."

        // Mix each source into the output
        for src in sources {
            let srcLen = Int(src.buffer.frameLength)
            let vol = src.volume
            // Simple equal-power pan: left = cos(angle), right = sin(angle)
            let angle = (src.pan + 1.0) * 0.5 * Float.pi * 0.5  // 0..pi/2
            let gainL = vol * cosf(angle)
            let gainR = vol * sinf(angle)
            let gains = channels >= 2 ? [gainL, gainR] : [vol]

            for ch in 0..<min(channels, 2) {
                let outPtr = outBuf.floatChannelData![ch]
                let srcPtr = src.buffer.floatChannelData![min(ch, Int(src.buffer.format.channelCount) - 1)]
                let g = gains[ch]
                for f in 0..<maxFrames {
                    let srcFrame = f % srcLen  // loop shorter tracks
                    outPtr[f] += srcPtr[srcFrame] * g
                }
            }
        }

        // Soft-clip via tanh to prevent digital overs
        for ch in 0..<channels {
            let ptr = outBuf.floatChannelData![ch]
            for f in 0..<maxFrames { ptr[f] = tanhf(ptr[f]) }
        }

        // Present save panel
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.wav]
        panel.nameFieldStringValue = "Mixdown_\(timestampFmt.string(from: Date())).wav"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                DispatchQueue.main.async { self?.bounceStatus = nil }
                return
            }
            do {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sr,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                ]
                let outFile = try AVAudioFile(forWriting: url, settings: settings,
                                               commonFormat: .pcmFormatFloat32, interleaved: false)
                try outFile.write(from: outBuf)
                DispatchQueue.main.async {
                    self?.bounceStatus = nil
                    self?.status = "Mixdown exported → \(url.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.bounceStatus = nil
                    self?.status = "Mixdown error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Track Helpers

    func toggleMute(_ i: Int) { pushUndo(); tracks[i].muted.toggle(); refreshTrackMixers() }
    func toggleSolo(_ i: Int) { pushUndo(); tracks[i].solo.toggle(); refreshTrackMixers() }
    func setTrackVolume(_ i: Int, _ v: Double) { pushUndoIfNeeded(); tracks[i].volume = v; refreshTrackMixers() }
    func setTrackPan(_ i: Int, _ p: Double) { pushUndoIfNeeded(); tracks[i].pan = p; refreshTrackMixers() }

    private func refreshTrackMixers() {
        let anySolo = tracks.contains { $0.solo }
        for i in 0..<tracks.count where i < trackMixers.count {
            let t = tracks[i]
            let audible = t.solo || (!anySolo && !t.muted)
            trackMixers[i].outputVolume = audible ? Float(t.volume) : 0
            trackMixers[i].pan = Float(t.pan)
        }
    }

    // Decodes the track's last clip off the main thread (long recordings are tens of
    // MB), then publishes the buffer back on main. `completion` runs on the main
    // thread once the buffer is ready (or immediately if there was nothing to load),
    // so playback callers can defer scheduling until the read finishes.
    private func loadTrackBuffer(_ i: Int, completion: (() -> Void)? = nil) {
        guard i < tracks.count, let lastClip = tracks[i].clips.last else {
            completion?()
            return
        }
        let url = lastClip.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded: AVAudioPCMBuffer?
            if let file = try? AVAudioFile(forReading: url) {
                let frames = AVAudioFrameCount(file.length)
                if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) {
                    try? file.read(into: buffer)
                    loaded = buffer
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let loaded, i < self.trackBuffers.count { self.trackBuffers[i] = loaded }
                completion?()
            }
        }
    }

    private func trackFolder(_ index: Int) -> URL {
        let dir = saveLocation.appendingPathComponent("Track \(index + 1)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
        trackBuffers = Array(repeating: nil, count: Theme.trackCount)

        // Load track buffers for tracks that have clips
        for i in 0..<tracks.count where !tracks[i].clips.isEmpty {
            loadTrackBuffer(i)
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
        refreshTrackMixers()

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

