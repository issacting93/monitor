// EngineController.swift — the AVAudioEngine graph spine
//
// Owns the AVAudioEngine and every node it builds (the pre-FX dry tap, the live
// post-FX mixer, the master mixer, the master limiter, and the per-bus kick-off),
// plus the async kernel-insert machinery. start()/stop() are the lifecycle entry
// points the facade forwards to; all the per-subsystem attach(...) handoffs happen
// here, in graph order, so each controller receives its nodes exactly as before.

import Foundation
import AVFoundation

final class EngineController {
    private unowned let manager: AudioManager

    private var engine:          AVAudioEngine?
    private var outMixer:        AVAudioMixerNode?   // live post-FX mixer
    private var masterMixer:     AVAudioMixerNode?
    private var dryTapMixer:     AVAudioMixerNode?   // pre-FX tap point for dry recording
    private var masterLimiterNode: AVAudioUnitEffect?

    // Async kernel-insert pipeline. `AVAudioUnit.instantiate` is asynchronous and an
    // AUAudioUnit subclass can't take init arguments, so the factory + sample rate are
    // passed via process-wide statics on EffectAudioUnit. To keep that safe we allow at
    // most ONE instantiation in flight process-wide (pumpKernelQueue refuses to start a
    // second), and tag each graph build with an epoch so a completion from a torn-down or
    // restarted graph is discarded rather than attaching to a dead engine or clobbering a
    // newer build's statics.
    private var kernelEpoch = 0
    private var pendingKernels: [(slot: ChainSlot, mod: EffectModule)] = []
    private var pendingSampleRate: Double = 0
    private var instantiationInFlight = false

    init(manager: AudioManager) {
        self.manager = manager
    }

    // MARK: - Lifecycle

    func start() {
        let m = manager
        // Guard against a second graph: some call sites (e.g. the Monitor device picker)
        // call start() while already monitoring. Without this, start() would build a second
        // AVAudioEngine and leak the first, leaving two live graphs (doubled audio).
        if m.isMonitoring { stop() }
        kernelEpoch &+= 1   // invalidate any in-flight kernel insert from a prior graph

        // iOS: configure + activate the audio session before anything reads the input
        // format — it is 0 Hz / 0 ch until the session is active. macOS: no-op.
        try? m.device.io.prepareForEngineStart()

        if m.inputDevices.isEmpty { m.device.loadDevices() }

        // Request mic permission off the main thread before touching the audio engine
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            m.status = "Requesting microphone access…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.start() }
                    else { self?.manager.status = "Microphone access denied — grant in System Settings" }
                }
            }
            return
        case .denied, .restricted:
            m.status = "Microphone access denied — grant in System Settings"
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        guard let inID = m.selectedInputID,
              let inDev = m.inputDevices.first(where: { $0.id == inID }) else {
            m.status = "No input device selected"; return
        }

        #if os(macOS)
        let currentOutID = getDefaultAudioDevice(input: false)
        if currentOutID == inID {
            m.status = "Output = \(inDev.name) — change output to avoid loopback"; return
        }

        // Warn about feedback when using built-in mic with built-in speakers
        let inName = inDev.name.lowercased()
        let outName = nameOfDevice(currentOutID).lowercased()
        if (inName.contains("macbook") || inName.contains("built-in") || inName.contains("microphone"))
            && (outName.contains("macbook") || outName.contains("built-in") || outName.contains("speaker")) {
            m.status = "Warning: built-in mic + speakers may cause feedback — use headphones"
        }
        #endif

        let eng = AVAudioEngine()
        // Point the engine's input at the chosen device without changing the system
        // default input (macOS AUHAL pin) / set the session's preferred input (iOS).
        m.device.io.applyInputDevice(inID, to: eng)
        let hwFmt = eng.inputNode.inputFormat(forBus: 0)

        guard hwFmt.sampleRate > 0, hwFmt.channelCount > 0 else {
            m.status = "No usable input format — check Microphone permissions"
            return
        }

        let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: hwFmt.sampleRate, channels: 2) ?? hwFmt

        let dryTap  = AVAudioMixerNode()   // pre-FX tap point for dry recording
        let liveMix = AVAudioMixerNode()
        let master  = AVAudioMixerNode()
        eng.attach(dryTap); eng.attach(liveMix); eng.attach(master)

        eng.connect(eng.inputNode,     to: eng.mainMixerNode, format: hwFmt)
        eng.mainMixerNode.outputVolume = Float(m.inputVolume)

        // Build chain from liveChain slots (Apple nodes only — kernels added async after start)
        var chainNodes: [(id: UUID, node: AVAudioNode)] = []
        var pendingKernelSlots: [(index: Int, slot: ChainSlot, mod: EffectModule)] = []
        for (i, slot) in m.liveChain.enumerated() {
            guard let mod = EffectRegistry.shared.module(for: slot.moduleID) else { continue }
            if let node = mod.makeAudioNode?() {
                eng.attach(node)
                m.effects.setNodeBypass(node, bypass: !slot.enabled)
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
            trkMix.outputVolume = Float(m.tracks[i].volume)
            trkMix.pan = Float(m.tracks[i].pan)
            players.append(player)
            trkMixers.append(trkMix)
        }

        let metPlayer = AVAudioPlayerNode()
        let metMix    = AVAudioMixerNode()
        eng.attach(metPlayer); eng.attach(metMix)
        eng.connect(metPlayer, to: metMix, format: stereoFmt)
        eng.connect(metMix,    to: master, format: stereoFmt)
        metMix.outputVolume = Float(m.metronomeVolume)

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
        limiter.bypass = !m.masterLimiterEnabled
        eng.connect(master, to: limiter, format: nil)
        eng.connect(limiter, to: eng.outputNode, format: nil)
        masterLimiterNode = limiter
        master.outputVolume = Float(m.volume) * 0.6   // slight headroom to reduce clipping

        // Metering tap: post-FX signal (meters show effected output)
        m.meter.attach(postFX: liveMix)

        // Recording tap: pre-FX dry signal (takes are recorded without effects)
        m.recorder.attach(dryMixer: dryTap)

        eng.prepare()
        do { try eng.start() } catch {
            m.status = "Engine failure: \(error.localizedDescription)"
            return
        }

        engine       = eng
        m.effects.setChainNodes(chainNodes)
        outMixer     = liveMix
        dryTapMixer  = dryTap
        masterMixer  = master
        m.transport.attach(players: players, mixers: trkMixers)
        m.meter.installTrackTaps(trkMixers)
        m.metronome.attach(player: metPlayer, mixer: metMix, sampleRate: stereoFmt.sampleRate)
        m.isMonitoring = true

        m.status = "\(inDev.name) → \(m.device.io.currentOutputName)"
        m.sampleRateString = "\(Int(hwFmt.sampleRate / 1000)) kHz · 24-bit · Stereo"
        m.meter.startDisplayTimer()

        // Async-insert kernel-based modules. AVAudioUnit instantiation is async and
        // AUAudioUnit subclasses can't take init arguments, so the kernel factory and
        // sample rate are passed via process-wide statics. See pumpKernelQueue for how
        // that shared state is kept safe across graph rebuilds.
        enqueueKernels(pendingKernelSlots, sampleRate: stereoFmt.sampleRate)
    }

    private func enqueueKernels(_ slots: [(index: Int, slot: ChainSlot, mod: EffectModule)],
                                sampleRate: Double) {
        pendingKernels = slots.map { (slot: $0.slot, mod: $0.mod) }
        pendingSampleRate = sampleRate
        pumpKernelQueue()
    }

    // Instantiates the head pending kernel, one at a time. This is the ONLY place that
    // writes the process-wide EffectAudioUnit statics, and it refuses to run while an
    // instantiation is in flight — so the statics are never overwritten before their
    // own instantiation has consumed them. Each completion re-pumps, so the queue drains
    // serially; a completion whose epoch is stale (graph restarted) is dropped.
    private func pumpKernelQueue() {
        guard !instantiationInFlight, !pendingKernels.isEmpty else { return }
        let head = pendingKernels[0]
        guard let factory = head.mod.makeKernel else {
            pendingKernels.removeFirst()
            pumpKernelQueue()
            return
        }
        let epoch = kernelEpoch
        instantiationInFlight = true
        EffectAudioUnit.pendingKernelFactory = factory
        EffectAudioUnit.pendingSampleRate = pendingSampleRate
        // .loadInProcess is macOS-only; on iOS the registered in-process subclass is
        // used with the default options.
        #if os(macOS)
        let auOptions: AudioComponentInstantiationOptions = .loadInProcess
        #else
        let auOptions: AudioComponentInstantiationOptions = []
        #endif
        AVAudioUnit.instantiate(with: EffectAudioUnit.componentDesc, options: auOptions) { [weak self] unit, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                EffectAudioUnit.pendingKernelFactory = nil
                self.instantiationInFlight = false

                let stale = (epoch != self.kernelEpoch)
                if stale {
                    // Pipeline was restarted: `pendingKernels` already belongs to the new
                    // build, so leave it untouched and just let the next pump drain it.
                } else if let kernelNode = unit, self.manager.isMonitoring,
                          let eng = self.engine, let liveMix = self.outMixer {
                    let fmt = liveMix.outputFormat(forBus: 0)
                    // Insert after the last chain node, or after dryTapMixer
                    let insertAfter: AVAudioNode
                    if let last = self.manager.effects.lastChainNode { insertAfter = last }
                    else if let dryTap = self.dryTapMixer { insertAfter = dryTap }
                    else { insertAfter = eng.mainMixerNode }
                    eng.disconnectNodeOutput(insertAfter)
                    eng.attach(kernelNode)
                    eng.connect(insertAfter, to: kernelNode, format: fmt)
                    eng.connect(kernelNode,  to: liveMix, format: fmt)
                    kernelNode.auAudioUnit.shouldBypassEffect = !head.slot.enabled
                    for (pid, val) in head.slot.parameters { head.mod.applyParameter?(kernelNode, pid, val) }
                    self.manager.effects.appendChainNode(id: head.slot.id, node: kernelNode)
                    self.pendingKernels.removeFirst()
                } else {
                    // Live graph gone but not superseded — drop the head and continue.
                    self.pendingKernels.removeFirst()
                }
                self.pumpKernelQueue()
            }
        }
    }

    func stop() {
        let m = manager
        if m.isRecording { m.stopRecording() }
        m.stopAll()
        teardown()
        m.isMonitoring = false
        m.meter.resetDisplay()
        m.status = "Stopped"
    }

    private func teardown() {
        let m = manager
        kernelEpoch &+= 1        // discard any in-flight kernel insert for this graph
        pendingKernels.removeAll()
        m.metronome.detach()
        m.meter.detach()
        m.recorder.detach()
        engine?.stop()
        m.effects.clearChainNodes()
        engine = nil
        outMixer = nil; dryTapMixer = nil; masterMixer = nil; masterLimiterNode = nil
        m.transport.detach()
    }

    // MARK: - Mix controls

    func applyVolume(_ v: Double) {
        manager.volume = v
        masterMixer?.outputVolume = Float(v) * 0.6
    }

    func applyInputVolume(_ v: Double) {
        manager.inputVolume = v
        engine?.mainMixerNode.outputVolume = Float(v)
    }

    func toggleMasterLimiter() {
        manager.masterLimiterEnabled.toggle()
        masterLimiterNode?.bypass = !manager.masterLimiterEnabled
    }
}
