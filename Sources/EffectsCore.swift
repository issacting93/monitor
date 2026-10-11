// EffectsCore.swift — modular effect system core
//
// Module/parameter model, the AudioEffectKernel protocol, ChainSlot,
// EffectState, the EffectAudioUnit AU host, EffectRegistry, and the
// Apple built-in + custom module definitions.
//
// Extracted from the AudioManager mono-file. Pure move, no behaviour change.

import SwiftUI
import Foundation
import AVFoundation
import CoreAudio
import AppKit
import Darwin

// ── Modular Effect System ──────────────────────────────────────────────────
// Foundation for the modular effects architecture. Every audio effect —
// Apple built-in or custom DSP — is described by an EffectModule and
// registered in the EffectRegistry. Custom DSP lives in AudioEffectKernel
// conformers; Apple effects return their native AVAudioNode directly.

struct EffectParameter: Codable, Identifiable {
    let id: String
    let name: String
    let min: Float
    let max: Float
    let defaultValue: Float
    let unit: String
}

protocol AudioEffectKernel: AnyObject {
    init(sampleRate: Double)
    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int)
    func setParameter(_ id: String, value: Float)
    func reset()
}

struct ChainSlot: Identifiable {
    let id: UUID
    var moduleID: String
    var enabled: Bool
    var parameters: [String: Float]

    init(moduleID: String, enabled: Bool = true) {
        self.id = UUID()
        self.moduleID = moduleID
        self.enabled = enabled
        if let mod = EffectRegistry.shared.modules[moduleID] {
            var p: [String: Float] = [:]
            for param in mod.parameters { p[param.id] = param.defaultValue }
            self.parameters = p
        } else {
            self.parameters = [:]
        }
    }
}

struct EffectModule {
    let identifier: String
    let displayName: String
    let category: String
    let version: Int
    let parameters: [EffectParameter]
    let makeKernel: ((Double) -> any AudioEffectKernel)?
    let makeAudioNode: (() -> AVAudioNode)?
    let applyParameter: ((AVAudioNode, String, Float) -> Void)?

    init(identifier: String, displayName: String, category: String, version: Int,
         parameters: [EffectParameter],
         makeKernel: ((Double) -> any AudioEffectKernel)? = nil,
         makeAudioNode: (() -> AVAudioNode)? = nil,
         applyParameter: ((AVAudioNode, String, Float) -> Void)? = nil) {
        self.identifier = identifier
        self.displayName = displayName
        self.category = category
        self.version = version
        self.parameters = parameters
        self.makeKernel = makeKernel
        self.makeAudioNode = makeAudioNode
        self.applyParameter = applyParameter
    }
}

class EffectState: ObservableObject {
    @Published var values: [String: Float]
    let parameters: [EffectParameter]
    var onParameterChange: ((String, Float) -> Void)?

    init(parameters: [EffectParameter]) {
        self.parameters = parameters
        var vals: [String: Float] = [:]
        for p in parameters { vals[p.id] = p.defaultValue }
        self.values = vals
    }

    func binding(for id: String) -> Binding<Float> {
        Binding(
            get: { self.values[id] ?? 0 },
            set: { newVal in
                self.values[id] = newVal
                self.onParameterChange?(id, newVal)
            }
        )
    }
}

// AUAudioUnit subclass that hosts any AudioEffectKernel for use in AVAudioEngine.
// Set pendingKernelFactory before instantiating via AVAudioUnit.instantiate().
final class EffectAudioUnit: AUAudioUnit {
    private let kernel: any AudioEffectKernel
    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    // Serialises main-thread parameter writes (`setKernelParameter`) against the
    // render-thread `process()` call, so a knob move can't tear a value the DSP is
    // mid-read of. The render thread only ever waits for the few instructions of a
    // parameter switch; parameter writes block for at most one buffer of DSP.
    private let renderLock = UnfairLock()

    static var pendingKernelFactory: ((Double) -> any AudioEffectKernel)?
    // Sample rate for the next instantiation. Set alongside pendingKernelFactory
    // (AUAudioUnit subclasses can't receive init arguments through instantiate()).
    static var pendingSampleRate: Double = 44100

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let factory = Self.pendingKernelFactory ?? { sr in
            // Fallback: silent passthrough kernel
            PassthroughKernel(sampleRate: sr)
        }
        let sampleRate = Self.pendingSampleRate > 0 ? Self.pendingSampleRate : 44100
        self.kernel = factory(sampleRate)
        try super.init(componentDescription: componentDescription, options: options)

        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let inBus = try AUAudioUnitBus(format: fmt)
        let outBus = try AUAudioUnitBus(format: fmt)
        _inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kern = self.kernel
        let lock = self.renderLock
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, _, pullInputBlock in
            guard let pullInputBlock = pullInputBlock else { return noErr }
            let status = pullInputBlock(actionFlags, timestamp, frameCount, outputBusNumber, outputData)
            guard status == noErr else { return status }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let ptrs = abl.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            lock.withLock { kern.process(ptrs, frames: Int(frameCount)) }
            return noErr
        }
    }

    func setKernelParameter(_ id: String, value: Float) {
        renderLock.withLock { kernel.setParameter(id, value: value) }
    }

    // Component description for custom kernels
    static let componentDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x74617065,   // 'tape'
        componentManufacturer: 0x4F705859, // 'OpXY'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var registered = false
    static func registerComponent() {
        guard !registered else { return }
        AUAudioUnit.registerSubclass(
            EffectAudioUnit.self,
            as: componentDesc,
            name: "OP-XY Effect",
            version: 1
        )
        registered = true
    }
}

// Minimal passthrough kernel (does nothing to audio)

// MARK: - Effect Registry

final class EffectRegistry {
    static let shared = EffectRegistry()
    private(set) var modules: [String: EffectModule] = [:]

    private init() {}

    func register(_ module: EffectModule) {
        modules[module.identifier] = module
    }

    func module(for id: String) -> EffectModule? {
        modules[id]
    }

    var all: [EffectModule] {
        Array(modules.values).sorted { $0.identifier < $1.identifier }
    }

    func registerBuiltIns() {
        register(EffectModule.appleEQ)
        register(EffectModule.appleReverb)
        register(EffectModule.appleDelay)
        register(EffectModule.tapeSaturation)
        register(EffectModule.gain)
        register(EffectModule.distortion)
        register(EffectModule.chorus)
        register(EffectModule.compressor)
        register(EffectModule.flanger)
        register(EffectModule.phaser)
        register(EffectModule.tremolo)
        register(EffectModule.bitcrusher)
        register(EffectModule.noiseGate)
    }
}

// MARK: - Apple Built-in Modules

extension EffectModule {
    static let appleEQ = EffectModule(
        identifier: "com.apple.eq",
        displayName: "EQ",
        category: "EQ & Filter",
        version: 1,
        parameters: [
            EffectParameter(id: "lowGain",  name: "Low",  min: -24, max: 24, defaultValue: 0, unit: "dB"),
            EffectParameter(id: "midGain",  name: "Mid",  min: -24, max: 24, defaultValue: 0, unit: "dB"),
            EffectParameter(id: "highGain", name: "High", min: -24, max: 24, defaultValue: 0, unit: "dB"),
        ],
        makeAudioNode: {
            let eq = AVAudioUnitEQ(numberOfBands: 3)
            eq.bands[0].filterType = .lowShelf;   eq.bands[0].frequency = 200;  eq.bands[0].bypass = false
            eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 1000; eq.bands[1].bandwidth = 1; eq.bands[1].bypass = false
            eq.bands[2].filterType = .highShelf;  eq.bands[2].frequency = 8000; eq.bands[2].bypass = false
            return eq
        },
        applyParameter: { node, id, value in
            guard let eq = node as? AVAudioUnitEQ else { return }
            switch id {
            case "lowGain":  eq.bands[0].gain = value
            case "midGain":  eq.bands[1].gain = value
            case "highGain": eq.bands[2].gain = value
            default: break
            }
        }
    )

    static let appleReverb = EffectModule(
        identifier: "com.apple.reverb",
        displayName: "Reverb",
        category: "Space",
        version: 1,
        parameters: [
            EffectParameter(id: "wetDryMix", name: "Mix",    min: 0, max: 100, defaultValue: 40, unit: "%"),
            EffectParameter(id: "preset",    name: "Preset", min: 0, max: 8,   defaultValue: 3,  unit: ""),
        ],
        makeAudioNode: {
            let r = AVAudioUnitReverb()
            r.loadFactoryPreset(.mediumHall)
            r.wetDryMix = 40
            return r
        },
        applyParameter: { node, id, value in
            guard let r = node as? AVAudioUnitReverb else { return }
            switch id {
            case "wetDryMix": r.wetDryMix = value
            case "preset":
                if let p = AVAudioUnitReverbPreset(rawValue: Int(value)) { r.loadFactoryPreset(p) }
            default: break
            }
        }
    )

    static let appleDelay = EffectModule(
        identifier: "com.apple.delay",
        displayName: "Delay",
        category: "Time",
        version: 1,
        parameters: [
            EffectParameter(id: "time",      name: "Time",      min: 0,    max: 2,     defaultValue: 0.25,  unit: "s"),
            EffectParameter(id: "feedback",  name: "Feedback",  min: -100, max: 100,   defaultValue: 30,    unit: "%"),
            EffectParameter(id: "wetDryMix", name: "Mix",       min: 0,    max: 100,   defaultValue: 25,    unit: "%"),
            EffectParameter(id: "cutoff",    name: "LP Cutoff", min: 100,  max: 20000, defaultValue: 15000, unit: "Hz"),
        ],
        makeAudioNode: {
            let d = AVAudioUnitDelay()
            d.delayTime = 0.25; d.feedback = 30; d.wetDryMix = 25; d.lowPassCutoff = 15000
            return d
        },
        applyParameter: { node, id, value in
            guard let d = node as? AVAudioUnitDelay else { return }
            switch id {
            case "time":      d.delayTime = Double(value)
            case "feedback":  d.feedback = value
            case "wetDryMix": d.wetDryMix = value
            case "cutoff":    d.lowPassCutoff = value
            default: break
            }
        }
    )

    static let tapeSaturation = EffectModule(
        identifier: "com.opxy.tape-saturation",
        displayName: "Tape Saturation",
        category: "Saturation",
        version: 1,
        parameters: [
            EffectParameter(id: "drive",  name: "Drive",     min: 0, max: 1, defaultValue: 0.5, unit: ""),
            EffectParameter(id: "soften", name: "Soften",    min: 0, max: 1, defaultValue: 0.5, unit: ""),
            EffectParameter(id: "bump",   name: "Head Bump", min: 0, max: 1, defaultValue: 0.3, unit: ""),
            EffectParameter(id: "output", name: "Output",    min: 0, max: 1, defaultValue: 0.5, unit: ""),
            EffectParameter(id: "mix",    name: "Mix",       min: 0, max: 1, defaultValue: 1.0, unit: ""),
        ],
        makeKernel: { sr in TapeSaturationKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )

}

// MARK: - Effect Module Definitions

extension EffectModule {
    static let gain = EffectModule(
        identifier: "com.opxy.gain",
        displayName: "Gain",
        category: "Utility",
        version: 1,
        parameters: [
            EffectParameter(id: "gain", name: "Gain", min: -24, max: 24, defaultValue: 0, unit: "dB"),
        ],
        makeKernel: { sr in GainKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )

    static let distortion = EffectModule(
        identifier: "com.opxy.distortion",
        displayName: "Distortion",
        category: "Saturation",
        version: 1,
        parameters: [
            EffectParameter(id: "drive", name: "Drive", min: 0, max: 1, defaultValue: 0.5, unit: ""),
            EffectParameter(id: "tone",  name: "Tone",  min: 0, max: 1, defaultValue: 0.7, unit: ""),
            EffectParameter(id: "level", name: "Level", min: 0, max: 1, defaultValue: 0.5, unit: ""),
            EffectParameter(id: "mix",   name: "Mix",   min: 0, max: 1, defaultValue: 1.0, unit: ""),
        ],
        makeKernel: { sr in DistortionKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )

    static let chorus = EffectModule(
        identifier: "com.opxy.chorus",
        displayName: "Chorus",
        category: "Modulation",
        version: 1,
        parameters: [
            EffectParameter(id: "rate",  name: "Rate",  min: 0.1, max: 5,   defaultValue: 0.5, unit: "Hz"),
            EffectParameter(id: "depth", name: "Depth", min: 0,   max: 1,   defaultValue: 0.5, unit: ""),
            EffectParameter(id: "mix",   name: "Mix",   min: 0,   max: 1,   defaultValue: 0.5, unit: ""),
        ],
        makeKernel: { sr in ChorusKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )

    static let compressor = EffectModule(
        identifier: "com.opxy.compressor",
        displayName: "Compressor",
        category: "Dynamics",
        version: 1,
        parameters: [
            EffectParameter(id: "threshold", name: "Thresh", min: -60, max: 0,  defaultValue: -12, unit: "dB"),
            EffectParameter(id: "ratio",     name: "Ratio",  min: 1,   max: 20, defaultValue: 4,   unit: ":1"),
            EffectParameter(id: "attack",    name: "Atk",    min: 0.001, max: 0.1, defaultValue: 0.01, unit: "s"),
            EffectParameter(id: "release",   name: "Rel",    min: 0.01, max: 1.0, defaultValue: 0.1, unit: "s"),
            EffectParameter(id: "makeup",    name: "Makeup", min: 0,   max: 24,  defaultValue: 0,   unit: "dB"),
        ],
        makeKernel: { sr in CompressorKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )

    static let flanger = EffectModule(
        identifier: "com.opxy.flanger",
        displayName: "Flanger",
        category: "Modulation",
        version: 1,
        parameters: [
            EffectParameter(id: "rate",     name: "Rate",  min: 0.05, max: 5,  defaultValue: 0.3, unit: "Hz"),
            EffectParameter(id: "depth",    name: "Depth", min: 0,    max: 1,  defaultValue: 0.5, unit: ""),
            EffectParameter(id: "feedback", name: "Fdbk",  min: 0,    max: 1,  defaultValue: 0.5, unit: ""),
            EffectParameter(id: "mix",      name: "Mix",   min: 0,    max: 1,  defaultValue: 0.5, unit: ""),
        ],
        makeKernel: { sr in FlangerKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )

    static let phaser = EffectModule(
        identifier: "com.opxy.phaser",
        displayName: "Phaser",
        category: "Modulation",
        version: 1,
        parameters: [
            EffectParameter(id: "rate",     name: "Rate",  min: 0.05, max: 5,  defaultValue: 0.5, unit: "Hz"),
            EffectParameter(id: "depth",    name: "Depth", min: 0,    max: 1,  defaultValue: 0.7, unit: ""),
            EffectParameter(id: "feedback", name: "Fdbk",  min: 0,    max: 1,  defaultValue: 0.3, unit: ""),
            EffectParameter(id: "mix",      name: "Mix",   min: 0,    max: 1,  defaultValue: 0.5, unit: ""),
        ],
        makeKernel: { sr in PhaserKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )

    static let tremolo = EffectModule(
        identifier: "com.opxy.tremolo",
        displayName: "Tremolo",
        category: "Modulation",
        version: 1,
        parameters: [
            EffectParameter(id: "rate",  name: "Rate",  min: 0.5, max: 20, defaultValue: 4,   unit: "Hz"),
            EffectParameter(id: "depth", name: "Depth", min: 0,   max: 1,  defaultValue: 0.5, unit: ""),
            EffectParameter(id: "shape", name: "Shape", min: 0,   max: 1,  defaultValue: 0,   unit: ""),
        ],
        makeKernel: { sr in TremoloKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )

    static let bitcrusher = EffectModule(
        identifier: "com.opxy.bitcrusher",
        displayName: "Bitcrusher",
        category: "Lo-fi",
        version: 1,
        parameters: [
            EffectParameter(id: "bits",       name: "Bits",   min: 1,  max: 16, defaultValue: 8,   unit: ""),
            EffectParameter(id: "downsample", name: "Dnsmpl", min: 1,  max: 50, defaultValue: 1,   unit: "x"),
            EffectParameter(id: "mix",        name: "Mix",    min: 0,  max: 1,  defaultValue: 1.0, unit: ""),
        ],
        makeKernel: { sr in BitcrusherKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )

    static let noiseGate = EffectModule(
        identifier: "com.opxy.noise-gate",
        displayName: "Gate",
        category: "Dynamics",
        version: 1,
        parameters: [
            EffectParameter(id: "threshold", name: "Thresh",  min: -80, max: 0,   defaultValue: -40,  unit: "dB"),
            EffectParameter(id: "attack",    name: "Atk",     min: 0.0001, max: 0.05, defaultValue: 0.001, unit: "s"),
            EffectParameter(id: "hold",      name: "Hold",    min: 0.001, max: 0.5,  defaultValue: 0.05, unit: "s"),
            EffectParameter(id: "release",   name: "Rel",     min: 0.005, max: 0.5,  defaultValue: 0.05, unit: "s"),
        ],
        makeKernel: { sr in NoiseGateKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )
}
