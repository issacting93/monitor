// monitor.swift — OP-XY Looper: retro-tech USB audio monitor, effects & multitrack looper
//
// Build:  swiftc monitor.swift -o monitor
// Run:    ./monitor

import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import Darwin
import UniformTypeIdentifiers

// ── Theme (warm retro palette) ──────────────────────────────────────────────

enum Theme {
    static let bg            = Color(red: 0x08/255.0, green: 0x08/255.0, blue: 0x0A/255.0)
    static let surface       = Color(red: 0x0C/255.0, green: 0x0C/255.0, blue: 0x0E/255.0)
    static let surfaceRaised = Color(red: 0x1F/255.0, green: 0x1F/255.0, blue: 0x23/255.0)
    static let surfaceInset  = Color(red: 0x08/255.0, green: 0x08/255.0, blue: 0x0A/255.0)
    static let line          = Color(red: 0xEC/255.0, green: 0xE8/255.0, blue: 0xDE/255.0).opacity(0.10)
    static let bezel         = Color(red: 0x2A/255.0, green: 0x28/255.0, blue: 0x24/255.0)
    static let shadow        = Color(red: 0x2A/255.0, green: 0x28/255.0, blue: 0x24/255.0)

    static let accent        = Color(red: 0xE8/255.0, green: 0xB0/255.0, blue: 0x4A/255.0)
    static let accentDim     = Color(red: 0x8A/255.0, green: 0x76/255.0, blue: 0x38/255.0)
    static let danger        = Color(red: 0xFF/255.0, green: 0x4D/255.0, blue: 0x5E/255.0)
    static let loopGreen     = Color(red: 0x5B/255.0, green: 0xE3/255.0, blue: 0x9A/255.0)

    static let textPrimary   = Color(red: 0xEC/255.0, green: 0xE8/255.0, blue: 0xDE/255.0)
    static let textSecondary = Color(red: 0x8C/255.0, green: 0x89/255.0, blue: 0x81/255.0)
    static let textTertiary  = Color(red: 0x6E/255.0, green: 0x6B/255.0, blue: 0x64/255.0)
    static let textEngraved  = Color(red: 0x6E/255.0, green: 0x6B/255.0, blue: 0x64/255.0)

    static let eqColor       = Color(red: 0xE8/255.0, green: 0xB0/255.0, blue: 0x4A/255.0)
    static let reverbColor   = Color(red: 0x5B/255.0, green: 0xE3/255.0, blue: 0x9A/255.0)
    static let delayColor    = Color(red: 0x6F/255.0, green: 0x8C/255.0, blue: 0xFF/255.0)
    static let tapeColor     = Color(red: 0xFF/255.0, green: 0x8A/255.0, blue: 0x3D/255.0)
    static let gold          = Color(red: 0xE8/255.0, green: 0xB0/255.0, blue: 0x4A/255.0)

    static let waveformCount = 200
    static let trackCount    = 8
    static let clipPeaks     = 64

    static let trackColors: [Color] = [
        Color(red: 0xFF/255.0, green: 0x5A/255.0, blue: 0x6A/255.0),
        Color(red: 0x6F/255.0, green: 0x8C/255.0, blue: 0xFF/255.0),
        Color(red: 0x5B/255.0, green: 0xE3/255.0, blue: 0x9A/255.0),
        Color(red: 0xE8/255.0, green: 0xB0/255.0, blue: 0x4A/255.0),
        Color(red: 0xA9/255.0, green: 0x8B/255.0, blue: 0xFF/255.0),
        Color(red: 0x5C/255.0, green: 0xC8/255.0, blue: 0xE0/255.0),
        Color(red: 0xFF/255.0, green: 0x8A/255.0, blue: 0x3D/255.0),
        Color(red: 0xCF/255.0, green: 0xC8/255.0, blue: 0xB8/255.0),
    ]
    static func trackColor(_ i: Int) -> Color { trackColors[i % trackColors.count] }
}

// ── Models ──────────────────────────────────────────────────────────────────

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

struct Recording: Identifiable {
    let id = UUID()
    let url: URL
    let duration: TimeInterval
    let trackIndex: Int
    var name: String { url.lastPathComponent }
    var durationString: String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}

struct TrackClip: Identifiable {
    let id = UUID()
    let url: URL
    let duration: TimeInterval
    var peaks: [Double] = []
    var name: String { url.lastPathComponent }
}

struct TrackInfo: Identifiable {
    let id: Int
    var clips: [TrackClip] = []
    var volume: Double = 0.8
    var muted = false
    var solo = false
    var isPlaying = false
    var loopProgress: Double = 0
    var layerCount: Int { clips.count }
}

let reverbPresets: [(label: String, preset: AVAudioUnitReverbPreset)] = [
    ("Small Room",  .smallRoom),
    ("Medium Room", .mediumRoom),
    ("Large Room",  .largeRoom),
    ("Medium Hall", .mediumHall),
    ("Large Hall",  .largeHall),
    ("Plate",       .plate),
    ("Med Chamber", .mediumChamber),
    ("Lg Chamber",  .largeChamber),
    ("Cathedral",   .cathedral),
]

func reverbLabel(_ p: AVAudioUnitReverbPreset) -> String {
    reverbPresets.first { $0.preset.rawValue == p.rawValue }?.label ?? "Unknown"
}

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

    static var pendingKernelFactory: ((Double) -> any AudioEffectKernel)?

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let factory = Self.pendingKernelFactory ?? { sr in
            // Fallback: silent passthrough kernel
            PassthroughKernel(sampleRate: sr)
        }
        self.kernel = factory(44100.0)
        try super.init(componentDescription: componentDescription, options: options)

        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let inBus = try AUAudioUnitBus(format: fmt)
        let outBus = try AUAudioUnitBus(format: fmt)
        _inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kern = self.kernel
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, _, pullInputBlock in
            guard let pullInputBlock = pullInputBlock else { return noErr }
            let status = pullInputBlock(actionFlags, timestamp, frameCount, outputBusNumber, outputData)
            guard status == noErr else { return status }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let ptrs = abl.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            kern.process(ptrs, frames: Int(frameCount))
            return noErr
        }
    }

    func setKernelParameter(_ id: String, value: Float) {
        kernel.setParameter(id, value: value)
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
final class PassthroughKernel: AudioEffectKernel {
    required init(sampleRate: Double) {}
    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {}
    func setParameter(_ id: String, value: Float) {}
    func reset() {}
}

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
        register(EffectModule.neuralAmp)
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

    static let neuralAmp = EffectModule(
        identifier: "com.opxy.neural-amp",
        displayName: "Neural Amp",
        category: "Amp Modeler",
        version: 1,
        parameters: [
            EffectParameter(id: "inputGain", name: "Input", min: 0, max: 1, defaultValue: 0.5, unit: ""),
            EffectParameter(id: "mix",       name: "Mix",   min: 0, max: 1, defaultValue: 1.0, unit: ""),
        ],
        makeKernel: { sr in NeuralAmpKernel(sampleRate: sr) },
        applyParameter: { node, id, value in
            if let au = (node as? AVAudioUnit)?.auAudioUnit as? EffectAudioUnit {
                au.setKernelParameter(id, value: value)
            }
        }
    )
}

// MARK: - Tape Saturation Kernel (ported from Airwindows ToTape6, MIT license)
// Tape emulation with sin-based waveshaping, head bump resonance, high-frequency
// softening, and ADClip-style soft saturation. Original by Chris Johnson / Airwindows.

final class TapeSaturationKernel: AudioEffectKernel {
    private let sampleRate: Double
    private let overallscale: Double

    // Parameters (0–1 normalized)
    private var drive: Float = 0.5
    private var soften: Float = 0.5
    private var headBump: Float = 0.3
    private var outputGain: Float = 0.5
    private var mix: Float = 1.0

    // IIR mid-roller state (interleaved A/B for anti-aliasing)
    private var iirMidRollerAL: Double = 0, iirMidRollerBL: Double = 0
    private var iirMidRollerAR: Double = 0, iirMidRollerBR: Double = 0

    // Head bump resonance state
    private var iirHeadBumpAL: Double = 0, iirHeadBumpBL: Double = 0
    private var iirHeadBumpAR: Double = 0, iirHeadBumpBR: Double = 0

    // Biquad filter state (coefficients in [2,4,5,6], state in [7,8])
    private var biquadAL = [Double](repeating: 0, count: 9)
    private var biquadBL = [Double](repeating: 0, count: 9)
    private var biquadAR = [Double](repeating: 0, count: 9)
    private var biquadBR = [Double](repeating: 0, count: 9)

    // Soft-clip tracking
    private var lastSampleL: Double = 0, lastSampleR: Double = 0

    // Interleave flip-flop
    private var flip = true

    required init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.overallscale = sampleRate / 44100.0
    }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "drive":  drive = value
        case "soften": soften = value
        case "bump":   headBump = value
        case "output": outputGain = value
        case "mix":    mix = value
        default: break
        }
    }

    func reset() {
        iirMidRollerAL = 0; iirMidRollerBL = 0
        iirMidRollerAR = 0; iirMidRollerBR = 0
        iirHeadBumpAL = 0; iirHeadBumpBL = 0
        iirHeadBumpAR = 0; iirHeadBumpBR = 0
        biquadAL = [Double](repeating: 0, count: 9)
        biquadBL = [Double](repeating: 0, count: 9)
        biquadAR = [Double](repeating: 0, count: 9)
        biquadBR = [Double](repeating: 0, count: 9)
        lastSampleL = 0; lastSampleR = 0
        flip = true
    }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        guard buffers.count >= 2 else { return }
        let inL = buffers[0], inR = buffers[1]

        let inputgain = pow(10.0, (Double(drive) - 0.5) * 24.0 / 20.0)
        let softenCtl = pow(Double(soften), 2)
        let rollAmount = (1.0 - softenCtl * 0.45) / overallscale
        let bumpCtl = Double(headBump) * 0.25 * inputgain
        let bumpFreq = 0.12 / overallscale
        let outgain = pow(10.0, (Double(outputGain) - 0.5) * 24.0 / 20.0)
        let wet = Double(mix)
        let refclip = 0.99
        let softness = 0.618033988749894848204586

        // Biquad coefficients for head bump bandpass filter
        let bqFreq = 0.007 / overallscale
        let bqQ = 0.0009
        let K = tan(Double.pi * bqFreq)
        let norm = 1.0 / (1.0 + K / bqQ + K * K)
        let b0 = K / bqQ * norm
        let b2 = -b0
        let a1 = 2.0 * (K * K - 1.0) * norm
        let a2 = (1.0 - K / bqQ + K * K) * norm

        biquadAL[2] = b0; biquadAL[4] = b2; biquadAL[5] = a1; biquadAL[6] = a2
        biquadBL[2] = b0; biquadBL[4] = b2; biquadBL[5] = a1; biquadBL[6] = a2
        biquadAR[2] = b0; biquadAR[4] = b2; biquadAR[5] = a1; biquadAR[6] = a2
        biquadBR[2] = b0; biquadBR[4] = b2; biquadBR[5] = a1; biquadBR[6] = a2

        for i in 0..<frames {
            var sL = Double(inL[i])
            var sR = Double(inR[i])
            let dryL = sL, dryR = sR

            // Input gain
            if inputgain != 1.0 { sL *= inputgain; sR *= inputgain }

            // Mid-roller: separate highs from body (interleaved A/B for smoothing)
            var highsL: Double, highsR: Double
            if flip {
                iirMidRollerAL = iirMidRollerAL * (1.0 - rollAmount) + sL * rollAmount
                iirMidRollerAR = iirMidRollerAR * (1.0 - rollAmount) + sR * rollAmount
                highsL = sL - iirMidRollerAL
                highsR = sR - iirMidRollerAR

                // Head bump resonance
                iirHeadBumpAL += sL * 0.05
                iirHeadBumpAR += sR * 0.05
                iirHeadBumpAL -= iirHeadBumpAL * iirHeadBumpAL * iirHeadBumpAL * bumpFreq
                iirHeadBumpAR -= iirHeadBumpAR * iirHeadBumpAR * iirHeadBumpAR * bumpFreq
                iirHeadBumpAL = sin(iirHeadBumpAL)
                iirHeadBumpAR = sin(iirHeadBumpAR)

                // Biquad filter on head bump
                var temp = iirHeadBumpAL * biquadAL[2] + biquadAL[7]
                biquadAL[7] = -temp * biquadAL[5] + biquadAL[8]
                biquadAL[8] = iirHeadBumpAL * biquadAL[4] - temp * biquadAL[6]
                iirHeadBumpAL = max(-1, min(1, temp))
                iirHeadBumpAL = asin(iirHeadBumpAL)

                temp = iirHeadBumpAR * biquadAR[2] + biquadAR[7]
                biquadAR[7] = -temp * biquadAR[5] + biquadAR[8]
                biquadAR[8] = iirHeadBumpAR * biquadAR[4] - temp * biquadAR[6]
                iirHeadBumpAR = max(-1, min(1, temp))
                iirHeadBumpAR = asin(iirHeadBumpAR)

                // Tape saturation: sin() waveshaping
                sL = sin(sL); sR = sin(sR)
            } else {
                iirMidRollerBL = iirMidRollerBL * (1.0 - rollAmount) + sL * rollAmount
                iirMidRollerBR = iirMidRollerBR * (1.0 - rollAmount) + sR * rollAmount
                highsL = sL - iirMidRollerBL
                highsR = sR - iirMidRollerBR

                iirHeadBumpBL += sL * 0.05
                iirHeadBumpBR += sR * 0.05
                iirHeadBumpBL -= iirHeadBumpBL * iirHeadBumpBL * iirHeadBumpBL * bumpFreq
                iirHeadBumpBR -= iirHeadBumpBR * iirHeadBumpBR * iirHeadBumpBR * bumpFreq
                iirHeadBumpBL = sin(iirHeadBumpBL)
                iirHeadBumpBR = sin(iirHeadBumpBR)

                var temp = iirHeadBumpBL * biquadBL[2] + biquadBL[7]
                biquadBL[7] = -temp * biquadBL[5] + biquadBL[8]
                biquadBL[8] = iirHeadBumpBL * biquadBL[4] - temp * biquadBL[6]
                iirHeadBumpBL = max(-1, min(1, temp))
                iirHeadBumpBL = asin(iirHeadBumpBL)

                temp = iirHeadBumpBR * biquadBR[2] + biquadBR[7]
                biquadBR[7] = -temp * biquadBR[5] + biquadBR[8]
                biquadBR[8] = iirHeadBumpBR * biquadBR[4] - temp * biquadBR[6]
                iirHeadBumpBR = max(-1, min(1, temp))
                iirHeadBumpBR = asin(iirHeadBumpBR)

                sL = sin(sL); sR = sin(sR)
            }
            flip = !flip

            // Soften highs (frequency-dependent saturation)
            var appL = abs(highsL) * 1.57079633
            if appL > 1.57079633 { appL = 1.57079633 }
            appL = 1.0 - cos(appL)
            if highsL > 0 { sL -= appL }
            if highsL < 0 { sL += appL }

            var appR = abs(highsR) * 1.57079633
            if appR > 1.57079633 { appR = 1.57079633 }
            appR = 1.0 - cos(appR)
            if highsR > 0 { sR -= appR }
            if highsR < 0 { sR += appR }

            // Apply head bump
            sL += (iirHeadBumpAL + iirHeadBumpBL) * bumpCtl
            sR += (iirHeadBumpAR + iirHeadBumpBR) * bumpCtl

            // Wavefolder with mojo
            sL = max(-1, min(1, sL))
            sR = max(-1, min(1, sR))
            let mojoL = pow(abs(sL), 0.25)
            if mojoL > 0 { sL = sin(sL * mojoL * Double.pi * 0.5) / mojoL }
            let mojoR = pow(abs(sR), 0.25)
            if mojoR > 0 { sR = sin(sR * mojoR * Double.pi * 0.5) / mojoR }

            // Output gain
            if outgain != 1.0 { sL *= outgain; sR *= outgain }

            // ADClip-style soft saturation (L)
            if lastSampleL >= refclip {
                if sL < refclip { lastSampleL = refclip * softness + sL * (1.0 - softness) }
                else { lastSampleL = refclip }
            }
            if lastSampleL <= -refclip {
                if sL > -refclip { lastSampleL = -refclip * softness + sL * (1.0 - softness) }
                else { lastSampleL = -refclip }
            }
            if sL > refclip {
                if lastSampleL < refclip { sL = refclip * softness + lastSampleL * (1.0 - softness) }
                else { sL = refclip }
            }
            if sL < -refclip {
                if lastSampleL > -refclip { sL = -refclip * softness + lastSampleL * (1.0 - softness) }
                else { sL = -refclip }
            }
            lastSampleL = sL

            // ADClip-style soft saturation (R)
            if lastSampleR >= refclip {
                if sR < refclip { lastSampleR = refclip * softness + sR * (1.0 - softness) }
                else { lastSampleR = refclip }
            }
            if lastSampleR <= -refclip {
                if sR > -refclip { lastSampleR = -refclip * softness + sR * (1.0 - softness) }
                else { lastSampleR = -refclip }
            }
            if sR > refclip {
                if lastSampleR < refclip { sR = refclip * softness + lastSampleR * (1.0 - softness) }
                else { sR = refclip }
            }
            if sR < -refclip {
                if lastSampleR > -refclip { sR = -refclip * softness + lastSampleR * (1.0 - softness) }
                else { sR = -refclip }
            }
            lastSampleR = sR

            // Hard clip
            sL = max(-refclip, min(refclip, sL))
            sR = max(-refclip, min(refclip, sR))

            // Wet/dry mix
            if wet < 1.0 {
                sL = sL * wet + dryL * (1.0 - wet)
                sR = sR * wet + dryR * (1.0 - wet)
            }

            inL[i] = Float(sL)
            inR[i] = Float(sR)
        }
    }
}

// ── Neural Amp Modeler ─────────────────────────────────────────────────────

/// Dense (fully connected) layer: y = W*x + b, with optional activation
final class NeuralDenseLayer {
    let inSize: Int
    let outSize: Int
    let weights: [Float]  // [outSize * inSize] row-major
    let bias: [Float]     // [outSize]
    let activation: String // "none", "tanh", "relu", "sigmoid"

    init(inSize: Int, outSize: Int, weights: [Float], bias: [Float], activation: String = "none") {
        self.inSize = inSize
        self.outSize = outSize
        self.weights = weights
        self.bias = bias
        self.activation = activation
    }

    func forward(_ input: [Float]) -> [Float] {
        // Guard against mismatched dimensions to avoid crashing the audio thread
        guard input.count >= inSize,
              weights.count >= outSize * inSize,
              bias.count >= outSize else {
            return input
        }
        var output = [Float](repeating: 0, count: outSize)
        for i in 0..<outSize {
            var sum: Float = bias[i]
            for j in 0..<inSize {
                sum += weights[i * inSize + j] * input[j]
            }
            switch activation {
            case "tanh":    sum = tanhf(sum)
            case "relu":    sum = max(0, sum)
            case "sigmoid": sum = 1.0 / (1.0 + expf(-sum))
            default: break
            }
            output[i] = sum
        }
        return output
    }
}

/// GRU (Gated Recurrent Unit) layer — PyTorch gate ordering: reset(r), update(z), new(n)
final class NeuralGRULayer {
    let inputSize: Int
    let hiddenSize: Int
    let weightIH: [Float]  // [3*hiddenSize, inputSize]
    let weightHH: [Float]  // [3*hiddenSize, hiddenSize]
    let biasIH: [Float]    // [3*hiddenSize]
    let biasHH: [Float]    // [3*hiddenSize]
    var hiddenState: [Float]

    init(inputSize: Int, hiddenSize: Int, weightIH: [Float], weightHH: [Float],
         biasIH: [Float], biasHH: [Float]) {
        self.inputSize = inputSize
        self.hiddenSize = hiddenSize
        self.weightIH = weightIH
        self.weightHH = weightHH
        self.biasIH = biasIH
        self.biasHH = biasHH
        self.hiddenState = [Float](repeating: 0, count: hiddenSize)
    }

    func forward(_ input: [Float]) -> [Float] {
        let h = hiddenSize
        guard input.count >= inputSize,
              weightIH.count >= 3 * h * inputSize,
              weightHH.count >= 3 * h * h,
              biasIH.count >= 3 * h,
              biasHH.count >= 3 * h else {
            return hiddenState
        }

        // Compute input contributions: W_ih * x + b_ih
        var ihResult = [Float](repeating: 0, count: 3 * h)
        for i in 0..<(3 * h) {
            var sum: Float = biasIH[i]
            for j in 0..<inputSize {
                sum += weightIH[i * inputSize + j] * input[j]
            }
            ihResult[i] = sum
        }

        // Compute hidden contributions: W_hh * h_prev + b_hh
        var hhResult = [Float](repeating: 0, count: 3 * h)
        for i in 0..<(3 * h) {
            var sum: Float = biasHH[i]
            for j in 0..<h {
                sum += weightHH[i * h + j] * hiddenState[j]
            }
            hhResult[i] = sum
        }

        // Gates
        var r = [Float](repeating: 0, count: h)
        var z = [Float](repeating: 0, count: h)
        var n = [Float](repeating: 0, count: h)

        for i in 0..<h {
            r[i] = sigmoidf(ihResult[i] + hhResult[i])
            z[i] = sigmoidf(ihResult[h + i] + hhResult[h + i])
            n[i] = tanhf(ihResult[2*h + i] + r[i] * hhResult[2*h + i])
        }

        // New hidden state
        for i in 0..<h {
            hiddenState[i] = (1 - z[i]) * n[i] + z[i] * hiddenState[i]
        }

        return hiddenState
    }

    func reset() { hiddenState = [Float](repeating: 0, count: hiddenSize) }

    private func sigmoidf(_ x: Float) -> Float { 1.0 / (1.0 + expf(-x)) }
}

/// LSTM layer — PyTorch gate ordering: input(i), forget(f), cell(g), output(o)
final class NeuralLSTMLayer {
    let inputSize: Int
    let hiddenSize: Int
    let weightIH: [Float]  // [4*hiddenSize, inputSize]
    let weightHH: [Float]  // [4*hiddenSize, hiddenSize]
    let biasIH: [Float]    // [4*hiddenSize]
    let biasHH: [Float]    // [4*hiddenSize]
    var hiddenState: [Float]
    var cellState: [Float]

    init(inputSize: Int, hiddenSize: Int, weightIH: [Float], weightHH: [Float],
         biasIH: [Float], biasHH: [Float]) {
        self.inputSize = inputSize
        self.hiddenSize = hiddenSize
        self.weightIH = weightIH
        self.weightHH = weightHH
        self.biasIH = biasIH
        self.biasHH = biasHH
        self.hiddenState = [Float](repeating: 0, count: hiddenSize)
        self.cellState = [Float](repeating: 0, count: hiddenSize)
    }

    func forward(_ input: [Float]) -> [Float] {
        let h = hiddenSize
        guard input.count >= inputSize,
              weightIH.count >= 4 * h * inputSize,
              weightHH.count >= 4 * h * h,
              biasIH.count >= 4 * h,
              biasHH.count >= 4 * h else {
            return hiddenState
        }

        // Compute input contributions: W_ih * x + b_ih
        var ihResult = [Float](repeating: 0, count: 4 * h)
        for i in 0..<(4 * h) {
            var sum: Float = biasIH[i]
            for j in 0..<inputSize {
                sum += weightIH[i * inputSize + j] * input[j]
            }
            ihResult[i] = sum
        }

        // Compute hidden contributions: W_hh * h_prev + b_hh
        var hhResult = [Float](repeating: 0, count: 4 * h)
        for i in 0..<(4 * h) {
            var sum: Float = biasHH[i]
            for j in 0..<h {
                sum += weightHH[i * h + j] * hiddenState[j]
            }
            hhResult[i] = sum
        }

        // Gates (PyTorch order: i, f, g, o)
        for i in 0..<h {
            let ig = sigmoidf(ihResult[i] + hhResult[i])          // input gate
            let fg = sigmoidf(ihResult[h + i] + hhResult[h + i])  // forget gate
            let gg = tanhf(ihResult[2*h + i] + hhResult[2*h + i]) // cell gate
            let og = sigmoidf(ihResult[3*h + i] + hhResult[3*h + i]) // output gate

            cellState[i] = fg * cellState[i] + ig * gg
            hiddenState[i] = og * tanhf(cellState[i])
        }

        return hiddenState
    }

    func reset() {
        hiddenState = [Float](repeating: 0, count: hiddenSize)
        cellState = [Float](repeating: 0, count: hiddenSize)
    }

    private func sigmoidf(_ x: Float) -> Float { 1.0 / (1.0 + expf(-x)) }
}

/// Container for a loaded neural amp/pedal model
final class NeuralModel {
    enum Layer {
        case gru(NeuralGRULayer)
        case lstm(NeuralLSTMLayer)
        case dense(NeuralDenseLayer)
    }

    let name: String
    let layers: [Layer]

    init(name: String, layers: [Layer]) {
        self.name = name
        self.layers = layers
    }

    func process(_ input: [Float]) -> [Float] {
        var x = input
        for layer in layers {
            switch layer {
            case .gru(let gru): x = gru.forward(x)
            case .lstm(let lstm): x = lstm.forward(x)
            case .dense(let dense): x = dense.forward(x)
            }
        }
        return x
    }

    func reset() {
        for layer in layers {
            switch layer {
            case .gru(let gru): gru.reset()
            case .lstm(let lstm): lstm.reset()
            case .dense(_): break
            }
        }
    }

    /// Recursively flatten any nested array structure to [Float]
    private static func flattenToFloats(_ value: Any) -> [Float] {
        if let arr = value as? [Any] {
            return arr.flatMap { flattenToFloats($0) }
        } else if let num = value as? NSNumber {
            return [num.floatValue]
        } else if let d = value as? Double {
            return [Float(d)]
        } else if let i = value as? Int {
            return [Float(i)]
        }
        return []
    }

    /// Load from RTNeural/GuitarML-compatible JSON
    static func loadFromJSON(url: URL) -> NeuralModel? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let modelName = url.deletingPathExtension().lastPathComponent

        // Try Format A: GuitarML/Proteus style
        // { "model_data": { "model": { "layers": [...] } } }
        if let modelData = json["model_data"] as? [String: Any],
           let modelInfo = modelData["model"] as? [String: Any],
           let layersArray = modelInfo["layers"] as? [[String: Any]] {

            let inputSize = (modelInfo["input_size"] as? Int) ?? 1
            let hiddenSize = (modelInfo["hidden_size"] as? Int) ?? 20
            var layers: [Layer] = []
            var prevSize = inputSize

            for layerDict in layersArray {
                // GRU layer
                if let wIH = layerDict["gru.weight_ih_l0"],
                   let wHH = layerDict["gru.weight_hh_l0"],
                   let bIH = layerDict["gru.bias_ih_l0"],
                   let bHH = layerDict["gru.bias_hh_l0"] {
                    let weightIH = flattenToFloats(wIH)
                    let weightHH = flattenToFloats(wHH)
                    let biasIH = flattenToFloats(bIH)
                    let biasHH = flattenToFloats(bHH)
                    let hs = biasIH.count / 3
                    let iSize = weightIH.count / (3 * hs)
                    let gru = NeuralGRULayer(inputSize: iSize > 0 ? iSize : prevSize,
                                             hiddenSize: hs > 0 ? hs : hiddenSize,
                                             weightIH: weightIH, weightHH: weightHH,
                                             biasIH: biasIH, biasHH: biasHH)
                    layers.append(.gru(gru))
                    prevSize = hs > 0 ? hs : hiddenSize
                }
                // LSTM layer
                else if let wIH = layerDict["lstm.weight_ih_l0"],
                        let wHH = layerDict["lstm.weight_hh_l0"],
                        let bIH = layerDict["lstm.bias_ih_l0"],
                        let bHH = layerDict["lstm.bias_hh_l0"] {
                    let weightIH = flattenToFloats(wIH)
                    let weightHH = flattenToFloats(wHH)
                    let biasIH = flattenToFloats(bIH)
                    let biasHH = flattenToFloats(bHH)
                    let hs = biasIH.count / 4
                    let iSize = weightIH.count / (4 * hs)
                    let lstm = NeuralLSTMLayer(inputSize: iSize > 0 ? iSize : prevSize,
                                               hiddenSize: hs > 0 ? hs : hiddenSize,
                                               weightIH: weightIH, weightHH: weightHH,
                                               biasIH: biasIH, biasHH: biasHH)
                    layers.append(.lstm(lstm))
                    prevSize = hs > 0 ? hs : hiddenSize
                }
                // Dense/Linear layer
                else if let w = layerDict["linear.weight"],
                        let b = layerDict["linear.bias"] {
                    let weights = flattenToFloats(w)
                    let bias = flattenToFloats(b)
                    let outSize = bias.count
                    let inSize = outSize > 0 ? weights.count / outSize : prevSize
                    let dense = NeuralDenseLayer(inSize: inSize, outSize: outSize,
                                                 weights: weights, bias: bias)
                    layers.append(.dense(dense))
                    prevSize = outSize
                }
            }

            if !layers.isEmpty {
                return NeuralModel(name: modelName, layers: layers)
            }
        }

        // Try Format B: simple/generic
        // { "layers": [ { "type": "gru", ... }, { "type": "dense", ... } ] }
        if let layersArray = json["layers"] as? [[String: Any]] {
            var layers: [Layer] = []

            for layerDict in layersArray {
                guard let type = layerDict["type"] as? String else { continue }

                switch type {
                case "gru":
                    let iSize = (layerDict["input_size"] as? Int) ?? 1
                    let hSize = (layerDict["hidden_size"] as? Int) ?? 20
                    let weightIH = flattenToFloats(layerDict["weight_ih"] as Any)
                    let weightHH = flattenToFloats(layerDict["weight_hh"] as Any)
                    let biasIH = flattenToFloats(layerDict["bias_ih"] as Any)
                    let biasHH = flattenToFloats(layerDict["bias_hh"] as Any)
                    let gru = NeuralGRULayer(inputSize: iSize, hiddenSize: hSize,
                                             weightIH: weightIH, weightHH: weightHH,
                                             biasIH: biasIH, biasHH: biasHH)
                    layers.append(.gru(gru))

                case "lstm":
                    let iSize = (layerDict["input_size"] as? Int) ?? 1
                    let hSize = (layerDict["hidden_size"] as? Int) ?? 20
                    let weightIH = flattenToFloats(layerDict["weight_ih"] as Any)
                    let weightHH = flattenToFloats(layerDict["weight_hh"] as Any)
                    let biasIH = flattenToFloats(layerDict["bias_ih"] as Any)
                    let biasHH = flattenToFloats(layerDict["bias_hh"] as Any)
                    let lstm = NeuralLSTMLayer(inputSize: iSize, hiddenSize: hSize,
                                               weightIH: weightIH, weightHH: weightHH,
                                               biasIH: biasIH, biasHH: biasHH)
                    layers.append(.lstm(lstm))

                case "dense", "linear":
                    let inF = (layerDict["in_features"] as? Int) ?? 1
                    let outF = (layerDict["out_features"] as? Int) ?? 1
                    let weights = flattenToFloats(layerDict["weight"] as Any)
                    let bias = flattenToFloats(layerDict["bias"] as Any)
                    let activation = (layerDict["activation"] as? String) ?? "none"
                    let dense = NeuralDenseLayer(inSize: inF, outSize: outF,
                                                 weights: weights, bias: bias,
                                                 activation: activation)
                    layers.append(.dense(dense))

                default: break
                }
            }

            if !layers.isEmpty {
                return NeuralModel(name: modelName, layers: layers)
            }
        }

        return nil
    }
}

// MARK: - Neural Amp Kernel

final class NeuralAmpKernel: AudioEffectKernel {
    private var model: NeuralModel?
    private var inputGain: Float = 0.5
    private var mix: Float = 1.0
    private let sampleRate: Double

    /// Shared model reference set by AudioManager when user loads a .json file
    static var sharedModel: NeuralModel?

    required init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func loadModel(_ m: NeuralModel) {
        self.model = m
    }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let activeModel = model ?? Self.sharedModel
        guard let activeModel = activeModel else { return }
        for buf in buffers {
            for i in 0..<frames {
                let dry = buf[i]
                let input = dry * inputGain * 2.0
                let output = activeModel.process([input])
                let wet = output.first ?? 0
                buf[i] = dry * (1.0 - mix) + wet * mix
            }
        }
    }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "inputGain": inputGain = value
        case "mix": mix = value
        default: break
        }
    }

    func reset() {
        model?.reset()
        Self.sharedModel?.reset()
    }
}

// ── CoreAudio Helpers ───────────────────────────────────────────────────────

private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

private func audioAddress(_ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allAudioDevices() -> [AudioDeviceID] {
    var addr = audioAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObjectID, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObjectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func nameOfDevice(_ id: AudioDeviceID) -> String {
    var addr = audioAddress(kAudioObjectPropertyName)
    var cfName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName) == noErr,
          let value = cfName?.takeRetainedValue() else { return "(unknown)" }
    return value as String
}

func deviceChannelCount(_ id: AudioDeviceID, input: Bool) -> Int {
    let scope: AudioObjectPropertyScope = input
        ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    var addr = audioAddress(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func getDefaultAudioDevice(input: Bool) -> AudioDeviceID {
    let sel: AudioObjectPropertySelector = input
        ? kAudioHardwarePropertyDefaultInputDevice
        : kAudioHardwarePropertyDefaultOutputDevice
    var addr = audioAddress(sel)
    var id: AudioDeviceID = 0
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObjectID, &addr, 0, nil, &sz, &id)
    return id
}

func setDefaultAudioDevice(_ id: AudioDeviceID, input: Bool) {
    let sel: AudioObjectPropertySelector = input
        ? kAudioHardwarePropertyDefaultInputDevice
        : kAudioHardwarePropertyDefaultOutputDevice
    var addr = audioAddress(sel)
    var dev = id
    AudioObjectSetPropertyData(systemObjectID, &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}

// ── AudioManager ────────────────────────────────────────────────────────────

class AudioManager: ObservableObject {
    @Published var inputDevices:     [AudioDevice] = []
    @Published var outputDevices:    [AudioDevice] = []
    @Published var selectedInputID:  AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?
    @Published var isMonitoring = false
    @Published var isRecording  = false
    @Published var volume: Double = 0.85
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
    private var liveChainNodes: [(id: UUID, node: AVAudioNode)] = []

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

    // Neural amp
    @Published var neuralModelName: String = "No Model"

    // View mode (0 = arrange, 1 = monitor)
    @Published var viewMode: Int = 0
    @Published var loopEnabled: Bool = true

    // Metronome
    @Published var metronomeEnabled = true
    @Published var metronomeBPM: Double = 120

    // Quantize
    @Published var quantizeMode: Int = 0
    static let quantizeLabels = ["OFF", "BAR", "BEAT"]

    // Multitrack
    @Published var recordings: [Recording] = []
    @Published var tracks: [TrackInfo] = (0..<Theme.trackCount).map { TrackInfo(id: $0) }
    @Published var selectedTrack: Int = 0
    @Published var isPlaying = false

    // Internal Audio Engine
    private var engine:       AVAudioEngine?
    private var outMixer:     AVAudioMixerNode?
    var masterMixer:          AVAudioMixerNode?
    private var audioFile:    AVAudioFile?
    private var previousDefaultInput: AudioDeviceID?
    private var playerNodes:     [AVAudioPlayerNode] = []
    private var trackMixers:     [AVAudioMixerNode] = []
    private var trackBuffers:    [AVAudioPCMBuffer?] = Array(repeating: nil, count: Theme.trackCount)
    private var metronomePlayer: AVAudioPlayerNode?
    private var metronomeMixer:  AVAudioMixerNode?
    private var metronomeTimer:  Timer?
    private var metronomeClickBuffer: AVAudioPCMBuffer?
    private var metronomeBeatCount: Int = 0

    // Metering
    private var rawLevelL: Float = 0
    private var rawLevelR: Float = 0
    private var rawPeakL:  Float = 0
    private var rawPeakR:  Float = 0
    private var peakHoldL: Int   = 0
    private var peakHoldR: Int   = 0

    private var recordingStart: Date?
    private var displayTimer:   Timer?
    private var recordingTimer: Timer?

    private static let timestampFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()

    private static let tracksBaseURL: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/OP-XY Monitor/Tracks")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    init() {
        EffectAudioUnit.registerComponent()
        EffectRegistry.shared.registerBuiltIns()
        liveChain = [
            ChainSlot(moduleID: "com.apple.eq", enabled: false),
            ChainSlot(moduleID: "com.apple.reverb", enabled: false),
            ChainSlot(moduleID: "com.apple.delay", enabled: false),
            ChainSlot(moduleID: "com.opxy.tape-saturation", enabled: false),
            ChainSlot(moduleID: "com.opxy.neural-amp", enabled: false),
        ]
        loadDevices()
        setupHardwareListeners()
    }

    deinit { stopMonitoring() }

    // MARK: - Device Discovery

    func loadDevices() {
        let allIDs  = allAudioDevices()
        let inputs  = allIDs.filter { deviceChannelCount($0, input: true) > 0 }
                            .map { AudioDevice(id: $0, name: nameOfDevice($0)) }
        let outputs = allIDs.filter { deviceChannelCount($0, input: false) > 0 }
                            .map { AudioDevice(id: $0, name: nameOfDevice($0)) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inputDevices  = inputs
            self.outputDevices = outputs

            if self.selectedInputID == nil || !inputs.contains(where: { $0.id == self.selectedInputID }) {
                self.selectedInputID = inputs.first(where: { $0.name.localizedCaseInsensitiveContains("XY") })?.id
                    ?? inputs.first(where: { $0.name.localizedCaseInsensitiveContains("OP") })?.id
                    ?? inputs.first?.id
            }

            let currentSysOut = getDefaultAudioDevice(input: false)
            if self.selectedOutputID == nil || !outputs.contains(where: { $0.id == self.selectedOutputID }) {
                self.selectedOutputID = currentSysOut != 0 ? currentSysOut : outputs.first?.id
            }
        }
    }

    private func setupHardwareListeners() {
        var devAddr = audioAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &devAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.loadDevices()
        }
        var outAddr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &outAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.loadDevices()
        }
    }

    // MARK: - Monitoring Engine

    func startMonitoring() {
        if inputDevices.isEmpty { loadDevices() }

        guard let inID = selectedInputID,
              let inDev = inputDevices.first(where: { $0.id == inID }) else {
            status = "No input device selected"; return
        }

        let currentOutID = getDefaultAudioDevice(input: false)
        if currentOutID == inID {
            status = "Output = \(inDev.name) — change output to avoid loopback"; return
        }

        previousDefaultInput = getDefaultAudioDevice(input: true)
        setDefaultAudioDevice(inID, input: true)

        let eng = AVAudioEngine()
        let hwFmt = eng.inputNode.inputFormat(forBus: 0)

        guard hwFmt.sampleRate > 0, hwFmt.channelCount > 0 else {
            status = "No usable input format — check Microphone permissions"
            restoreDefaultInput(); return
        }

        let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: hwFmt.sampleRate, channels: 2) ?? hwFmt

        let liveMix = AVAudioMixerNode()
        let master  = AVAudioMixerNode()
        eng.attach(liveMix); eng.attach(master)

        eng.connect(eng.inputNode,     to: eng.mainMixerNode, format: hwFmt)
        eng.mainMixerNode.outputVolume = 1.0

        // Build chain from liveChain slots (Apple nodes only — kernels added async after start)
        var chainNodes: [(id: UUID, node: AVAudioNode)] = []
        var pendingKernelSlots: [(index: Int, slot: ChainSlot, mod: EffectModule)] = []
        for (i, slot) in liveChain.enumerated() {
            guard let mod = EffectRegistry.shared.module(for: slot.moduleID) else { continue }
            if let node = mod.makeAudioNode?() {
                eng.attach(node)
                setNodeBypass(node, bypass: !slot.enabled)
                for (pid, val) in slot.parameters { mod.applyParameter?(node, pid, val) }
                chainNodes.append((slot.id, node))
            } else if mod.makeKernel != nil {
                pendingKernelSlots.append((i, slot, mod))
            }
        }

        // Connect chain: mainMixer → [effect1 → effect2 → ...] → liveMix
        var prev: AVAudioNode = eng.mainMixerNode
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
            players.append(player)
            trkMixers.append(trkMix)
        }

        let metPlayer = AVAudioPlayerNode()
        let metMix    = AVAudioMixerNode()
        eng.attach(metPlayer); eng.attach(metMix)
        eng.connect(metPlayer, to: metMix, format: stereoFmt)
        eng.connect(metMix,    to: master, format: stereoFmt)
        metMix.outputVolume = 0.45

        eng.connect(master, to: eng.outputNode, format: nil)
        master.outputVolume = Float(volume)

        liveMix.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.processTap(buf)
        }

        eng.prepare()
        do { try eng.start() } catch {
            status = "Engine failure: \(error.localizedDescription)"
            restoreDefaultInput(); return
        }

        engine       = eng
        liveChainNodes = chainNodes
        outMixer     = liveMix
        masterMixer  = master
        playerNodes  = players
        trackMixers  = trkMixers
        metronomePlayer      = metPlayer
        metronomeMixer       = metMix
        metronomeClickBuffer = generateClickBuffer(sampleRate: stereoFmt.sampleRate, channels: 2)
        isMonitoring = true

        let outName = nameOfDevice(currentOutID)
        status = "\(inDev.name) → \(outName)"
        sampleRateString = "\(Int(hwFmt.sampleRate / 1000)) kHz · 24-bit · Stereo"
        startDisplayTimer()

        // Async-insert kernel-based modules (v3 AU requires async instantiation)
        for pending in pendingKernelSlots {
            let slot = pending.slot
            let mod = pending.mod
            EffectAudioUnit.pendingKernelFactory = mod.makeKernel
            AVAudioUnit.instantiate(with: EffectAudioUnit.componentDesc, options: .loadInProcess) { [weak self] unit, error in
                guard let self, let kernelNode = unit, let eng = self.engine, let liveMix = self.outMixer else { return }
                DispatchQueue.main.async {
                    guard self.isMonitoring else { return }
                    let fmt = liveMix.outputFormat(forBus: 0)
                    // Find insertion point: after last Apple node or after mainMixer
                    let insertAfter: AVAudioNode
                    if let last = self.liveChainNodes.last?.node { insertAfter = last }
                    else { insertAfter = eng.mainMixerNode }
                    eng.disconnectNodeOutput(insertAfter)
                    eng.attach(kernelNode)
                    eng.connect(insertAfter, to: kernelNode, format: fmt)
                    eng.connect(kernelNode,  to: liveMix, format: fmt)
                    kernelNode.auAudioUnit.shouldBypassEffect = !slot.enabled
                    for (pid, val) in slot.parameters { mod.applyParameter?(kernelNode, pid, val) }
                    self.liveChainNodes.append((slot.id, kernelNode))
                }
            }
        }
    }

    func stopMonitoring() {
        if isRecording { stopRecording() }
        stopAll()
        teardown()
        restoreDefaultInput()
        isMonitoring = false
        displayTimer?.invalidate(); displayTimer = nil
        levelL = 0; levelR = 0; peakL = 0; peakR = 0
        peakDB = -Double.infinity
        waveformSamples = Array(repeating: 0, count: Theme.waveformCount)
        status = "Stopped"
    }

    func switchOutput(to id: AudioDeviceID) {
        selectedOutputID = id
        if isMonitoring { stopMonitoring(); startMonitoring() }
    }

    func applyVolume(_ v: Double) {
        volume = v
        masterMixer?.outputVolume = Float(v)
    }

    private func teardown() {
        stopMetronome()
        outMixer?.removeTap(onBus: 0)
        engine?.stop()
        liveChainNodes = []
        engine = nil
        outMixer = nil; masterMixer = nil
        playerNodes = []; trackMixers = []
        metronomePlayer = nil; metronomeMixer = nil; metronomeClickBuffer = nil
    }

    private func restoreDefaultInput() {
        if let prev = previousDefaultInput {
            setDefaultAudioDevice(prev, input: true)
            previousDefaultInput = nil
        }
    }

    // MARK: - Metering

    private func processTap(_ buf: AVAudioPCMBuffer) {
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

        rawLevelL = rmsL; rawLevelR = rmsR

        if rmsL >= rawPeakL { rawPeakL = rmsL; peakHoldL = 0 }
        else { peakHoldL += 1; if peakHoldL > 30 { rawPeakL *= 0.94 } }

        if rmsR >= rawPeakR { rawPeakR = rmsR; peakHoldR = 0 }
        else { peakHoldR += 1; if peakHoldR > 30 { rawPeakR *= 0.94 } }

        if let file = audioFile { try? file.write(from: buf) }
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let scaledL     = Double(min(self.rawLevelL * 4.5, 1))
            let scaledR     = Double(min(self.rawLevelR * 4.5, 1))
            let scaledPeakL = Double(min(self.rawPeakL * 4.5, 1))
            let scaledPeakR = Double(min(self.rawPeakR * 4.5, 1))
            let maxPeak     = Double(max(self.rawPeakL, self.rawPeakR))

            DispatchQueue.main.async {
                self.levelL = self.levelL * 0.70 + scaledL * 0.30
                self.levelR = self.levelR * 0.70 + scaledR * 0.30
                self.peakL  = scaledPeakL
                self.peakR  = scaledPeakR
                self.peakDB = maxPeak > 0 ? 20.0 * log10(maxPeak) : -Double.infinity

                var samples = self.waveformSamples
                samples.removeFirst()
                samples.append((self.levelL + self.levelR) / 2.0)
                self.waveformSamples = samples

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
    }

    // MARK: - Chain Effects

    private func setNodeBypass(_ node: AVAudioNode, bypass: Bool) {
        if let effect = node as? AVAudioUnitEffect { effect.bypass = bypass }
        else if let au = node as? AVAudioUnit { au.auAudioUnit.shouldBypassEffect = bypass }
    }

    func applySlotParam(_ slotIndex: Int, _ paramID: String, _ value: Float) {
        guard slotIndex < liveChain.count else { return }
        let slot = liveChain[slotIndex]
        guard let mod = EffectRegistry.shared.module(for: slot.moduleID),
              let entry = liveChainNodes.first(where: { $0.id == slot.id }) else { return }
        mod.applyParameter?(entry.node, paramID, value)
    }

    func toggleSlotBypass(_ slotIndex: Int) {
        guard slotIndex < liveChain.count else { return }
        liveChain[slotIndex].enabled.toggle()
        let slot = liveChain[slotIndex]
        if let entry = liveChainNodes.first(where: { $0.id == slot.id }) {
            setNodeBypass(entry.node, bypass: !slot.enabled)
        }
    }

    func paramBinding(slot index: Int, param id: String) -> Binding<Double> {
        Binding(
            get: { [weak self] in Double(self?.liveChain[index].parameters[id] ?? 0) },
            set: { [weak self] newVal in
                guard let self, index < self.liveChain.count else { return }
                self.liveChain[index].parameters[id] = Float(newVal)
                self.applySlotParam(index, id, Float(newVal))
            }
        )
    }

    func addSlot(moduleID: String) {
        liveChain.append(ChainSlot(moduleID: moduleID))
        rebuildChain()
    }

    func removeSlot(at index: Int) {
        guard index < liveChain.count else { return }
        liveChain.remove(at: index)
        rebuildChain()
    }

    func moveSlot(from: Int, to: Int) {
        guard from < liveChain.count, to < liveChain.count, from != to else { return }
        let slot = liveChain.remove(at: from)
        liveChain.insert(slot, at: to)
        rebuildChain()
    }

    private func rebuildChain() {
        guard isMonitoring else { return }
        stopMonitoring()
        startMonitoring()
    }

    // MARK: - Metronome

    private func generateClickBuffer(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer? {
        let duration = 0.015
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard let data = buf.floatChannelData else { return nil }
        let freq: Float = 1000.0
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(sampleRate)
            let envelope = 1.0 - (Float(i) / Float(frames))
            let sample = sin(2.0 * .pi * freq * t) * envelope * 0.8
            for ch in 0..<Int(channels) { data[ch][i] = sample }
        }
        return buf
    }

    private func generateAccentClickBuffer(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer? {
        let duration = 0.02
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard let data = buf.floatChannelData else { return nil }
        let freq: Float = 1500.0
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(sampleRate)
            let envelope = 1.0 - (Float(i) / Float(frames))
            let sample = sin(2.0 * .pi * freq * t) * envelope * 0.95
            for ch in 0..<Int(channels) { data[ch][i] = sample }
        }
        return buf
    }

    private func startMetronome() {
        guard metronomeEnabled, let player = metronomePlayer, let click = metronomeClickBuffer else { return }
        let accentClick = generateAccentClickBuffer(
            sampleRate: click.format.sampleRate, channels: click.format.channelCount) ?? click
        metronomeBeatCount = 0
        player.play()

        let interval = 60.0 / metronomeBPM
        metronomeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, let player = self.metronomePlayer else { return }
            let isAccent = self.metronomeBeatCount % 4 == 0
            player.scheduleBuffer(isAccent ? accentClick : click, at: nil, options: [], completionHandler: nil)
            self.metronomeBeatCount += 1
        }
        player.scheduleBuffer(accentClick, at: nil, options: [], completionHandler: nil)
        metronomeBeatCount = 1
    }

    private func stopMetronome() {
        metronomeTimer?.invalidate(); metronomeTimer = nil
        metronomePlayer?.stop()
        metronomeBeatCount = 0
    }

    func toggleMetronome() {
        metronomeEnabled.toggle()
        if tracks.contains(where: { $0.isPlaying }) {
            if metronomeEnabled { startMetronome() } else { stopMetronome() }
        }
    }

    func cycleQuantize() {
        quantizeMode = (quantizeMode + 1) % Self.quantizeLabels.count
    }

    // MARK: - Recording

    func startRecording() {
        guard isMonitoring, let eng = engine else { return }
        let fmt  = eng.mainMixerNode.outputFormat(forBus: 0)
        let name = "take_\(Self.timestampFmt.string(from: Date())).wav"
        let url  = trackFolder(selectedTrack).appendingPathComponent(name)
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            recordingStart    = Date()
            recordingDuration = 0
            isRecording       = true
            status            = "Recording TRK \(String(format: "%02d", selectedTrack + 1))"
            if metronomeEnabled && metronomeTimer == nil { startMetronome() }
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let s = self.recordingStart else { return }
                DispatchQueue.main.async { self.recordingDuration = Date().timeIntervalSince(s) }
            }
        } catch {
            status = "Recording error: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate(); recordingTimer = nil
        let saved = audioFile?.url
        let dur   = recordingDuration
        let trk   = selectedTrack
        audioFile   = nil
        isRecording = false
        if !tracks.contains(where: { $0.isPlaying }) { stopMetronome() }

        guard let u = saved else { return }
        let peaks = computePeaks(url: u, count: Theme.clipPeaks)
        let clip  = TrackClip(url: u, duration: dur, peaks: peaks)
        let rec   = Recording(url: u, duration: dur, trackIndex: trk)

        status = "Saved \(u.lastPathComponent) → TRK \(String(format: "%02d", trk + 1))"
        DispatchQueue.main.async {
            self.recordings.append(rec)
            self.tracks[trk].clips.append(clip)
            self.loadTrackBuffer(trk)
        }
    }

    // MARK: - Per-Track Playback

    func startTrackLoop(_ i: Int) {
        guard isMonitoring, i < playerNodes.count else { return }
        if trackBuffers[i] == nil { loadTrackBuffer(i) }
        guard let buffer = trackBuffers[i] else { return }
        let player = playerNodes[i]
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
        tracks[i].isPlaying = true
        refreshTrackMixers()
        if metronomeEnabled && metronomeTimer == nil { startMetronome() }
        isPlaying = true
        status = "Looping TRK \(String(format: "%02d", i + 1))"
    }

    func stopTrackLoop(_ i: Int) {
        guard i < playerNodes.count else { return }
        playerNodes[i].stop()
        tracks[i].isPlaying = false
        tracks[i].loopProgress = 0
        if !tracks.contains(where: { $0.isPlaying }) {
            stopMetronome()
            isPlaying = false
            status = "Stopped"
        }
    }

    func toggleTrackPlayback(_ i: Int) {
        if tracks[i].isPlaying { stopTrackLoop(i) } else { startTrackLoop(i) }
    }

    func toggleTrackRecord(_ i: Int) {
        selectedTrack = i
        if isRecording {
            stopRecording()
            startTrackLoop(i)
        } else {
            startRecording()
        }
    }

    func playAll() {
        guard isMonitoring else { return }
        for i in 0..<tracks.count where !tracks[i].clips.isEmpty {
            if trackBuffers[i] == nil { loadTrackBuffer(i) }
            guard let buffer = trackBuffers[i] else { continue }
            let player = playerNodes[i]
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play()
            tracks[i].isPlaying = true
        }
        refreshTrackMixers()
        isPlaying = true
        startMetronome()
        status = "Playing all tracks"
    }

    func stopAll() {
        stopMetronome()
        for i in 0..<tracks.count {
            if i < playerNodes.count { playerNodes[i].stop() }
            tracks[i].isPlaying = false
            tracks[i].loopProgress = 0
        }
        isPlaying = false
        status = "Stopped"
    }

    func undoTrack(_ i: Int) {
        guard i < tracks.count, !tracks[i].clips.isEmpty else { return }
        if tracks[i].isPlaying { stopTrackLoop(i) }
        tracks[i].clips.removeLast()
        trackBuffers[i] = nil
        if !tracks[i].clips.isEmpty { loadTrackBuffer(i) }
    }

    func clearAll() {
        stopAll()
        for i in 0..<tracks.count {
            tracks[i].clips.removeAll()
            trackBuffers[i] = nil
        }
        recordings.removeAll()
        status = "All tracks cleared"
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
        let trimName = "trim_\(Self.timestampFmt.string(from: Date())).wav"
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

    // MARK: - Export

    func exportTrack(_ trackIndex: Int) {
        guard trackIndex < tracks.count, let clip = tracks[trackIndex].clips.last else {
            status = "No clip to export on TRK \(String(format: "%02d", trackIndex + 1))"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "TRK\(String(format: "%02d", trackIndex + 1))_\(Self.timestampFmt.string(from: Date())).wav"
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

    // MARK: - Neural Amp Model Loading

    func loadNeuralModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "json")!]
        panel.title = "Load Neural Amp Model"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let model = NeuralModel.loadFromJSON(url: url) else {
                DispatchQueue.main.async { self?.status = "Failed to load model" }
                return
            }
            DispatchQueue.main.async {
                NeuralAmpKernel.sharedModel = model
                self?.neuralModelName = model.name
                self?.status = "Loaded model: \(model.name)"
            }
        }
    }

    // MARK: - Track Helpers

    func toggleMute(_ i: Int) { tracks[i].muted.toggle(); refreshTrackMixers() }
    func toggleSolo(_ i: Int) { tracks[i].solo.toggle(); refreshTrackMixers() }
    func setTrackVolume(_ i: Int, _ v: Double) { tracks[i].volume = v; refreshTrackMixers() }

    private func refreshTrackMixers() {
        let anySolo = tracks.contains { $0.solo }
        for i in 0..<tracks.count where i < trackMixers.count {
            let t = tracks[i]
            let audible = t.solo || (!anySolo && !t.muted)
            trackMixers[i].outputVolume = audible ? Float(t.volume) : 0
        }
    }

    private func loadTrackBuffer(_ i: Int) {
        guard i < tracks.count, let lastClip = tracks[i].clips.last else { return }
        if let file = try? AVAudioFile(forReading: lastClip.url) {
            let frames = AVAudioFrameCount(file.length)
            if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) {
                try? file.read(into: buffer)
                trackBuffers[i] = buffer
            }
        }
    }

    private func trackFolder(_ index: Int) -> URL {
        let dir = saveLocation.appendingPathComponent("Track \(index + 1)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func computePeaks(url: URL, count: Int) -> [Double] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return [] }
        try? file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength)
        let step = max(n / count, 1)
        var result: [Double] = []
        for i in 0..<count {
            let start = i * step
            let end = min(start + step, n)
            var pk: Float = 0
            for j in start..<end { pk = max(pk, abs(data[0][j])) }
            result.append(Double(min(pk, 1)))
        }
        return result
    }
}

// ── Dot Grid Background ─────────────────────────────────────────────────────

struct DotGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 16
            for x in stride(from: CGFloat(0), to: size.width, by: spacing) {
                for y in stride(from: CGFloat(0), to: size.height, by: spacing) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)),
                                 with: .color(Theme.textPrimary.opacity(0.07)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ScreenBezel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(Theme.surfaceInset)
            .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.10), lineWidth: 1))
    }
}

// ── RetroButtonStyle ────────────────────────────────────────────────────────

struct RetroButtonStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary
    var active: Bool = false
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(filled && active ? tint : Color.clear)
            .overlay(Rectangle().stroke(active ? tint : Theme.textPrimary.opacity(0.16), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}

// ── ArcKnob ─────────────────────────────────────────────────────────────────

struct ArcKnob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color
    var bipolar: Bool = false
    var size: CGFloat = 56

    private let startAngle: Double = 135
    private let sweepAngle: Double = 270

    private var normalized: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private var totalSize: CGFloat { size + 16 }
    private var center: CGPoint { CGPoint(x: totalSize / 2, y: totalSize / 2) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                ForEach(0..<13, id: \.self) { i in
                    let t = Double(i) / 12.0
                    let angle = (startAngle + sweepAngle * t) * .pi / 180
                    let r = size / 2 + 4
                    Capsule()
                        .fill(i % 3 == 0 ? Theme.textSecondary : Theme.textTertiary)
                        .frame(width: 1, height: i % 3 == 0 ? 4 : 2.5)
                        .offset(x: cos(angle) * r, y: sin(angle) * r)
                        .rotationEffect(.radians(angle + .pi / 2))
                        .position(center)
                }

                arcPath(from: 0, to: 1)
                    .stroke(Theme.surfaceInset, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                if bipolar {
                    arcPath(from: 0.5, to: normalized)
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                } else {
                    arcPath(from: 0, to: normalized)
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }

                indicatorLine()
                    .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: totalSize, height: totalSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        let delta = -gesture.translation.height / 150
                        let newNorm = min(max(normalized + delta, 0), 1)
                        value = range.lowerBound + newNorm * (range.upperBound - range.lowerBound)
                    }
            )

            VStack(spacing: 1) {
                Text(displayValue)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                Text(label.uppercased())
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(Theme.textEngraved)
            }
        }
    }

    private var displayValue: String {
        if bipolar {
            let v = Int(value)
            return (v >= 0 ? "+" : "") + "\(v)"
        } else if range.upperBound > 10 {
            return "\(Int(value))"
        } else {
            return "\(Int(value * 1000))ms"
        }
    }

    private func angleForValue(_ v: Double) -> Double {
        (startAngle + sweepAngle * min(max(v, 0), 1)) * .pi / 180
    }

    private func arcPath(from: Double, to: Double) -> Path {
        let r = size / 2
        let s = min(from, to), e = max(from, to)
        return Path { p in
            p.addArc(center: center, radius: r,
                     startAngle: Angle(degrees: startAngle + sweepAngle * s),
                     endAngle: Angle(degrees: startAngle + sweepAngle * e),
                     clockwise: false)
        }
    }

    private func indicatorLine() -> Path {
        let a = angleForValue(normalized)
        let innerR = size * 0.10, outerR = size * 0.42
        return Path { p in
            p.move(to: CGPoint(x: center.x + innerR * cos(a), y: center.y + innerR * sin(a)))
            p.addLine(to: CGPoint(x: center.x + outerR * cos(a), y: center.y + outerR * sin(a)))
        }
    }
}

// ── TrackFader ──────────────────────────────────────────────────────────────

struct TrackFader: View {
    @Binding var value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track line
                Rectangle()
                    .fill(Theme.textPrimary.opacity(0.22))
                    .frame(height: 1)
                // Thumb
                Rectangle()
                    .fill(Theme.textPrimary)
                    .frame(width: 6, height: 16)
                    .offset(x: max(0, min(geo.size.width - 6, CGFloat(value) * (geo.size.width - 6))))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        value = max(0, min(1, Double(g.location.x / geo.size.width)))
                    }
            )
        }
    }
}

// ── TempoControl ────────────────────────────────────────────────────────────

struct TempoControl: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 0) {
            Button { audio.metronomeBPM = max(40, audio.metronomeBPM - 1) } label: {
                Text("\u{2212}")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 40, height: 44)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))

            VStack(spacing: 2) {
                Text("\(Int(audio.metronomeBPM))")
                    .font(.system(size: 17, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.accent)
                    .monospacedDigit()
                Text("BPM")
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(width: 64, height: 44)
            .overlay(
                Rectangle().stroke(Theme.textPrimary.opacity(0.10), lineWidth: 1)
            )

            Button { audio.metronomeBPM = min(300, audio.metronomeBPM + 1) } label: {
                Text("+")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 40, height: 44)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
        }
        .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
    }
}

// ── HeaderBar (legacy — kept for reference) ────────────────────────────────

struct HeaderBar: View {
    @ObservedObject var audio: AudioManager
    var body: some View { TopBar(audio: audio) }
}

// ── TopBar (TAPE 08 header) ────────────────────────────────────────────────

struct TopBar: View {
    @ObservedObject var audio: AudioManager

    private var statusText: String {
        if audio.isRecording { return "REC" }
        if audio.isPlaying { return "PLAY" }
        return "IDLE"
    }
    private var statusColor: Color {
        if audio.isRecording { return Theme.danger }
        if audio.isPlaying { return Theme.accent }
        return Theme.textSecondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Brand
            HStack(spacing: 14) {
                // Reel icon
                Image(systemName: "circle.circle")
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(Theme.textPrimary)
                Text("TAPE 08")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(Theme.textPrimary)
                Text("MULTITRACK")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(Theme.textTertiary)
            }

            Spacer()

            // View tabs
            HStack(spacing: 4) {
                tabButton("ARRANGE", mode: 0)
                tabButton("MONITOR", mode: 1)
            }

            Spacer()

            // Status
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .opacity(audio.isRecording ? (blinkOpacity()) : 1)
                    Text(statusText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(3)
                        .foregroundColor(statusColor)
                }

                Text(audio.sampleRateString.uppercased())
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Theme.textSecondary)
            }

            // Device pickers
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("IN")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textTertiary)
                    Picker("", selection: $audio.selectedInputID) {
                        ForEach(audio.inputDevices) { d in
                            Text(d.name).tag(d.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                HStack(spacing: 4) {
                    Text("OUT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textTertiary)
                    Picker("", selection: $audio.selectedOutputID) {
                        ForEach(audio.outputDevices) { d in
                            Text(d.name).tag(d.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            // FX + Settings
            HStack(spacing: 6) {
                Button(action: { audio.showEffects.toggle() }) {
                    Text("FX")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundColor(audio.showEffects ? Theme.bg : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: audio.showEffects, filled: audio.showEffects))

                Button(action: { audio.showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .foregroundColor(audio.showSettings ? Theme.bg : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: audio.showSettings, filled: audio.showSettings))
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .bottom)
    }

    private func blinkOpacity() -> Double {
        // Simple blink approximation — the actual blink uses animation
        1.0
    }

    @ViewBuilder
    private func tabButton(_ label: String, mode: Int) -> some View {
        Button { audio.viewMode = mode } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(3)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundColor(audio.viewMode == mode ? Theme.textPrimary : Theme.textSecondary)
                .overlay(
                    Rectangle()
                        .fill(audio.viewMode == mode ? Theme.accent : Color.clear)
                        .frame(height: 1),
                    alignment: .bottom
                )
        }
        .buttonStyle(.plain)
    }
}

// ── Vertical Meter (TAPE 08 style) ──────────────────────────────────────────

struct VerticalMeter: View {
    let label: String
    let level: Double
    let peak: Double

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Theme.textPrimary.opacity(0.12))
                        .frame(width: 2)
                    Rectangle().fill(Theme.danger)
                        .frame(width: 2, height: max(0, CGFloat(level) * geo.size.height))
                    // Peak dot
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 12, height: 12)
                        .offset(y: -max(0, CGFloat(peak) * geo.size.height) + 6)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(maxWidth: .infinity)
            }
            Text(label)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
        }
    }
}

// ── LoopPadView (TAPE 08 track row) ─────────────────────────────────────────

struct LoopPadView: View {
    let index: Int
    let track: TrackInfo
    @ObservedObject var audio: AudioManager
    var totalBars: Int = 8
    var secsPerBar: Double = 2.0

    private var color: Color { Theme.trackColor(index) }
    private var isRecordingThis: Bool { audio.isRecording && audio.selectedTrack == index }
    private var hasClip: Bool { !track.clips.isEmpty }
    private var isSelected: Bool { audio.selectedTrack == index }
    private var anySolo: Bool { audio.tracks.contains { $0.solo } }
    private var audible: Bool { anySolo ? track.solo : !track.muted }

    var body: some View {
        HStack(spacing: 0) {
            // Track info (left column)
            Button(action: { audio.selectedTrack = index }) {
                HStack(spacing: 10) {
                    // Arm dot + track number
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isSelected ? Theme.danger : Theme.danger.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 18, weight: .light, design: .monospaced))
                            .foregroundColor(isSelected ? Theme.accent : Theme.textTertiary)
                    }

                    // Color stripe
                    Rectangle()
                        .fill(color)
                        .frame(width: 2, height: 30)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(hasClip ? (track.clips.last?.name ?? "CLIP") : "TRK \(String(format: "%02d", index + 1))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .tracking(1.5)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if hasClip {
                            Text("TAKE \(track.clips.count)")
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(Theme.textTertiary)
                        } else {
                            Text("EMPTY")
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
                .frame(width: 200, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Waveform lane — tempo-aligned grid
            GeometryReader { geo in
                let barWidth = geo.size.width / CGFloat(totalBars)
                ZStack(alignment: .leading) {
                    // Bar grid lines — thin on every bar, thicker every 4
                    Path { path in
                        for i in 1..<totalBars {
                            let x = CGFloat(i) * barWidth
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                    }
                    .stroke(Theme.textPrimary.opacity(0.04), lineWidth: 0.5)

                    Path { path in
                        for i in stride(from: 4, to: totalBars, by: 4) {
                            let x = CGFloat(i) * barWidth
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                    }
                    .stroke(Theme.textPrimary.opacity(0.08), lineWidth: 0.5)

                    if hasClip {
                        // Position clips sequentially, sized by their duration in bars
                        ForEach(Array(track.clips.enumerated()), id: \.element.id) { ci, clip in
                            let clipBars = clip.duration / secsPerBar
                            let clipW = CGFloat(clipBars) * barWidth
                            let prevOffset = track.clips.prefix(ci).reduce(0.0) { $0 + $1.duration }
                            let clipX = CGFloat(prevOffset / secsPerBar) * barWidth

                            ZStack(alignment: .topLeading) {
                                // Clip border
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(color.opacity(0.4), lineWidth: 1)

                                // Bottom color bar
                                Rectangle()
                                    .fill(color)
                                    .frame(height: 2)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                                    .padding(.horizontal, 1)

                                // Waveform
                                if !clip.peaks.isEmpty {
                                    Path { path in
                                        let midY = geo.size.height / 2
                                        let drawW = max(clipW - 2, 1)
                                        let stepX = drawW / CGFloat(clip.peaks.count)
                                        for (j, peak) in clip.peaks.enumerated() {
                                            let x = CGFloat(j) * stepX + stepX / 2
                                            let h = max(0.5, CGFloat(peak) * midY * 0.8)
                                            path.move(to: CGPoint(x: x, y: midY - h))
                                            path.addLine(to: CGPoint(x: x, y: midY + h))
                                        }
                                    }
                                    .stroke(color.opacity(0.9), lineWidth: 1)
                                }

                                // Take label
                                Text("TAKE \(ci + 1)")
                                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                                    .tracking(1.5)
                                    .foregroundColor(Theme.textSecondary)
                                    .padding(.leading, 4).padding(.top, 2)
                            }
                            .frame(width: max(clipW - 2, 4), height: geo.size.height - 2)
                            .offset(x: clipX + 1, y: 1)
                        }

                        // Playhead — positioned by loop progress across total visible duration
                        if track.isPlaying {
                            let lastClip = track.clips.last
                            let clipDur = lastClip?.duration ?? 1
                            let playX = CGFloat(track.loopProgress) * CGFloat(clipDur / secsPerBar) * barWidth
                            Rectangle()
                                .fill(Theme.textPrimary)
                                .frame(width: 1)
                                .offset(x: playX)
                                .frame(maxHeight: .infinity)
                        }
                    } else {
                        // Empty track — dashed center line
                        Path { path in
                            let midY = geo.size.height / 2
                            path.move(to: CGPoint(x: 0, y: midY))
                            path.addLine(to: CGPoint(x: geo.size.width, y: midY))
                        }
                        .stroke(Theme.textPrimary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        Text("\u{2014} EMPTY \u{2014}")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .tracking(4)
                            .foregroundColor(Theme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if isRecordingThis {
                        Rectangle()
                            .fill(Theme.danger.opacity(0.05))
                            .overlay(Rectangle().stroke(Theme.danger.opacity(0.4), lineWidth: 1))
                    }
                }
            }
            .frame(height: 52)
            .background(isSelected ? Theme.textPrimary.opacity(0.025) : Color.clear)
            .overlay(
                Rectangle().stroke(isSelected ? color.opacity(0.4) : Theme.textPrimary.opacity(0.10), lineWidth: 1)
                    .frame(height: nil), alignment: .leading
            )

            // Controls (right column)
            HStack(spacing: 6) {
                // Play
                Button { audio.toggleTrackPlayback(index) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .frame(width: 28, height: 28)
                        .foregroundColor(track.isPlaying ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: track.isPlaying))

                // Mute
                Button { audio.toggleMute(index) } label: {
                    Text("M")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .frame(width: 28, height: 28)
                        .foregroundColor(track.muted ? Theme.bg : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: track.muted, filled: track.muted))

                // Solo
                Button { audio.toggleSolo(index) } label: {
                    Text("S")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .frame(width: 28, height: 28)
                        .foregroundColor(track.solo ? Theme.bg : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Color(red: 0x5C/255.0, green: 0xC8/255.0, blue: 0xE0/255.0), active: track.solo, filled: track.solo))

                // Volume slider
                TrackFader(
                    value: Binding(
                        get: { track.volume },
                        set: { audio.setTrackVolume(index, $0) }
                    ), color: color
                )
                .frame(width: 80, height: 20)

                Text("\(Int(track.volume * 100))")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .opacity(audible ? 1 : 0.32)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.07)).frame(height: 1), alignment: .bottom)
    }
}

// ── LoopGridView (with ruler) ───────────────────────────────────────────────

struct BarRulerView: View {
    @ObservedObject var audio: AudioManager
    let totalBars: Int
    let secsPerBar: Double

    var body: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width / CGFloat(totalBars)

            ZStack(alignment: .leading) {
                // Bar numbers — every 4 bars
                ForEach(Array(stride(from: 1, through: totalBars, by: 4)), id: \.self) { bar in
                    Text(String(format: "%02d", bar))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .position(x: CGFloat(bar - 1) * barWidth + barWidth / 2, y: 8)
                }

                // Green loop bracket (spans longest clip)
                if audio.loopEnabled {
                    let longestBars = longestClipBars()
                    if longestBars > 0 {
                        let lw = CGFloat(longestBars) * barWidth
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Theme.loopGreen, lineWidth: 1.5)
                            .frame(width: lw, height: 12)
                            .position(x: lw / 2, y: 8)
                    }
                }

                // Diamond playhead
                let currentBar = audio.recordingDuration / secsPerBar
                let playX = CGFloat(currentBar) * barWidth
                Path { p in
                    p.move(to: CGPoint(x: playX, y: 2))
                    p.addLine(to: CGPoint(x: playX + 5, y: 8))
                    p.addLine(to: CGPoint(x: playX, y: 14))
                    p.addLine(to: CGPoint(x: playX - 5, y: 8))
                    p.closeSubpath()
                }
                .fill(Theme.textPrimary)
            }
        }
        .frame(height: 18)
    }

    private func longestClipBars() -> Int {
        let maxDur = audio.tracks.flatMap(\.clips).map(\.duration).max() ?? 0
        guard maxDur > 0 else { return 0 }
        return Int(ceil(maxDur / secsPerBar))
    }
}

struct LoopGridView: View {
    @ObservedObject var audio: AudioManager

    private var secsPerBar: Double { 240.0 / audio.metronomeBPM }  // 4/4 time
    private var totalBars: Int {
        let maxDur = audio.tracks.flatMap(\.clips).map(\.duration).max() ?? 0
        let barsFromClips = maxDur > 0 ? Int(ceil(maxDur / secsPerBar)) : 0
        // Minimum 8 bars, round up to nearest multiple of 4
        let raw = max(8, barsFromClips + 4)
        return ((raw + 3) / 4) * 4
    }

    var body: some View {
        VStack(spacing: 0) {
            // Bar ruler
            HStack(spacing: 0) {
                Color.clear.frame(width: 200)
                BarRulerView(audio: audio, totalBars: totalBars, secsPerBar: secsPerBar)
                Color.clear.frame(width: 260)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 2)

            ForEach(0..<Theme.trackCount, id: \.self) { i in
                LoopPadView(index: i, track: audio.tracks[i], audio: audio,
                            totalBars: totalBars, secsPerBar: secsPerBar)
            }
        }
        .padding(.horizontal, 28)
    }
}

// ── SideEffectsPanelView (Chain Editor) ─────────────────────────────────────

struct SideEffectsPanelView: View {
    @ObservedObject var audio: AudioManager

    private let slotColors: [Color] = [
        Theme.eqColor, Theme.reverbColor, Theme.delayColor, Theme.tapeColor,
        Theme.accent, Color(red: 0.6, green: 0.8, blue: 0.5),
        Color(red: 0.8, green: 0.5, blue: 0.7), Color(red: 0.5, green: 0.7, blue: 0.9),
    ]
    private func slotColor(_ i: Int) -> Color { slotColors[i % slotColors.count] }

    private var selectedTrackName: String {
        let t = audio.tracks[audio.selectedTrack]
        return t.clips.last?.name ?? "TRK \(String(format: "%02d", audio.selectedTrack + 1))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FX CHAIN")
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textPrimary)
                    Text("TRK \(String(format: "%02d", audio.selectedTrack + 1)) \u{00B7} \(selectedTrackName)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Menu {
                    ForEach(EffectRegistry.shared.all, id: \.identifier) { mod in
                        Button(mod.displayName) { audio.addSlot(moduleID: mod.identifier) }
                    }
                } label: {
                    Text("+ ADD")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundColor(Theme.accent)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // IN label
                    HStack(spacing: 6) {
                        Circle().fill(Theme.textTertiary).frame(width: 6, height: 6)
                        Text("IN \u{00B7} \(audio.inputDevices.first { $0.id == audio.selectedInputID }?.name.uppercased() ?? "MBP MIC")")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.leading, 16).padding(.bottom, 8)

                    ForEach(Array(audio.liveChain.enumerated()), id: \.element.id) { index, slot in
                        if let mod = EffectRegistry.shared.module(for: slot.moduleID) {
                            HStack(alignment: .top, spacing: 0) {
                                // Signal flow spine
                                VStack(spacing: 0) {
                                    // Dotted line above
                                    Path { p in
                                        p.move(to: CGPoint(x: 3, y: 0))
                                        p.addLine(to: CGPoint(x: 3, y: 16))
                                    }
                                    .stroke(slotColor(index).opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .frame(width: 6, height: 16)
                                    // Colored square node
                                    Rectangle()
                                        .fill(slot.enabled ? slotColor(index) : Theme.textTertiary)
                                        .frame(width: 6, height: 6)
                                    // Dotted line below
                                    GeometryReader { geo in
                                        Path { p in
                                            p.move(to: CGPoint(x: 3, y: 0))
                                            p.addLine(to: CGPoint(x: 3, y: geo.size.height))
                                        }
                                        .stroke(slotColor(index).opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    }
                                    .frame(width: 6)
                                }
                                .padding(.leading, 16)

                                effectCard(index: index, slot: slot, mod: mod, color: slotColor(index))
                                    .padding(.leading, 8)
                            }
                            .padding(.bottom, 8)
                        }
                    }

                    // OUT label
                    HStack(spacing: 6) {
                        Circle().fill(Theme.textTertiary).frame(width: 6, height: 6)
                        Text("OUT \u{00B7} TRK \(String(format: "%02d", audio.selectedTrack + 1)) FADER")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.leading, 16).padding(.top, 4)
                }
                .padding(.horizontal, 8).padding(.bottom, 16)
            }
        }
        .frame(width: 400)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(width: 1), alignment: .trailing)
    }

    @ViewBuilder
    private func effectCard(index: Int, slot: ChainSlot, mod: EffectModule, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: index dot, name, controls
            HStack(spacing: 8) {
                // Index badge
                ZStack {
                    Circle()
                        .stroke(slot.enabled ? color : Theme.textTertiary, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(slot.enabled ? color : Theme.textTertiary)
                }

                Text(mod.displayName.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(slot.enabled ? Theme.textPrimary : Theme.textEngraved)

                Spacer()

                // Move buttons
                HStack(spacing: 2) {
                    if index > 0 {
                        Button { audio.moveSlot(from: index, to: index - 1) } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 24)
                                .foregroundColor(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    if index < audio.liveChain.count - 1 {
                        Button { audio.moveSlot(from: index, to: index + 1) } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 24)
                                .foregroundColor(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // ON/BYP pill toggle
                Button { audio.toggleSlotBypass(index) } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(slot.enabled ? color : Theme.textTertiary)
                            .frame(width: 6, height: 6)
                        Text(slot.enabled ? "ON" : "BYP")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(slot.enabled ? color : Theme.textTertiary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(slot.enabled ? color.opacity(0.5) : Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)

                // Delete
                Button { audio.removeSlot(at: index) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
                        .foregroundColor(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            // Neural amp model loader
            if slot.moduleID == "com.opxy.neural-amp" {
                Button { audio.loadNeuralModel() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 10))
                        Text(audio.neuralModelName)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(Theme.accent)
                    .background(Theme.surfaceInset)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }

            // Parameter knobs — fixed 4-column grid
            if !mod.parameters.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 0), count: 4), alignment: .leading, spacing: 6) {
                    ForEach(mod.parameters) { param in
                        ArcKnob(
                            label: param.name.uppercased(),
                            value: audio.paramBinding(slot: index, param: param.id),
                            range: Double(param.min)...Double(param.max),
                            color: color,
                            bipolar: param.min < 0,
                            size: 42
                        )
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
                .opacity(slot.enabled ? 1 : 0.2)
            }
        }
        .background(Theme.surfaceRaised)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(slot.enabled ? color.opacity(0.25) : Theme.line.opacity(0.5), lineWidth: 1)
        )
    }
}

// ── TransportBar (TAPE 08 footer) ───────────────────────────────────────────

struct TransportBar: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 0) {
            // Left: selected track
            HStack(spacing: 12) {
                Rectangle().fill(Theme.accent).frame(width: 10, height: 10)
                HStack(spacing: 4) {
                    Text("TRK \(String(format: "%02d", audio.selectedTrack + 1))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(2).foregroundColor(Theme.accent)
                    Text("/ \(audio.tracks[audio.selectedTrack].clips.isEmpty ? "EMPTY" : "TAKE \(audio.tracks[audio.selectedTrack].clips.count)")")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .tracking(2).foregroundColor(Theme.textTertiary)
                }
            }
            .frame(minWidth: 200, alignment: .leading)

            Spacer()

            // Center: transport buttons
            HStack(spacing: 6) {
                tpBtn(icon: "arrow.uturn.backward", label: "UNDO",
                      fg: Theme.textPrimary, border: Theme.textPrimary.opacity(0.16)) {
                    audio.undoTrack(audio.selectedTrack)
                }
                tpBtn(icon: audio.isPlaying ? "pause.fill" : "play.fill",
                      label: audio.isPlaying ? "PAUSE" : "PLAY",
                      fg: audio.isPlaying ? Theme.bg : Theme.accent,
                      bg: audio.isPlaying ? Theme.accent : Color.clear,
                      border: Theme.accent) { audio.playAll() }

                Button {
                    if audio.isRecording { audio.stopRecording(); audio.startTrackLoop(audio.selectedTrack) }
                    else { audio.startRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(audio.isRecording ? Theme.bg : Theme.danger).frame(width: 10, height: 10)
                        Text("REC").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
                    }
                    .frame(height: 44).padding(.horizontal, 26)
                    .foregroundColor(audio.isRecording ? Theme.bg : Theme.danger)
                    .background(audio.isRecording ? Theme.danger : Color.clear)
                    .overlay(Rectangle().stroke(Theme.danger, lineWidth: 1))
                }
                .buttonStyle(.plain)

                tpBtn(icon: "stop.fill", label: "STOP",
                      fg: Theme.textPrimary, border: Theme.textPrimary.opacity(0.16)) { audio.stopAll() }

                Button { audio.clearAll() } label: {
                    Text("CLEAR").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
                        .frame(height: 44).padding(.horizontal, 18)
                        .foregroundColor(Theme.textSecondary)
                        .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Right: BPM, metronome, VOL, monitor
            HStack(spacing: 10) {
                TempoControl(audio: audio)
                Button { audio.toggleMetronome() } label: {
                    Image(systemName: "metronome.fill").font(.system(size: 12, weight: .medium))
                        .frame(width: 44, height: 44)
                        .foregroundColor(audio.metronomeEnabled ? Theme.bg : Theme.textPrimary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: audio.metronomeEnabled, filled: audio.metronomeEnabled))
                ArcKnob(label: "VOL", value: Binding(
                    get: { audio.volume * 100 }, set: { audio.applyVolume($0 / 100) }
                ), range: 0...100, color: Theme.accent, size: 38)
                Button {
                    if audio.isMonitoring { audio.stopMonitoring() } else { audio.startMonitoring() }
                } label: {
                    ZStack {
                        Circle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1).frame(width: 40, height: 40)
                        Image(systemName: "headphones").font(.system(size: 14, weight: .medium))
                            .foregroundColor(audio.isMonitoring ? Theme.textPrimary : Theme.textSecondary)
                    }
                    .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .top)
    }

    @ViewBuilder
    private func tpBtn(icon: String, label: String, fg: Color, bg: Color = .clear,
                        border: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
            }
            .frame(height: 44).padding(.horizontal, 18)
            .foregroundColor(fg).background(bg)
            .overlay(Rectangle().stroke(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// ── Reel SVG ────────────────────────────────────────────────────────────────

struct ReelView: View {
    let cx: CGFloat
    let cy: CGFloat
    let spinning: Bool
    let fast: Bool

    var body: some View {
        ZStack {
            // Outer rim
            Circle()
                .stroke(Theme.textPrimary, lineWidth: 1.5)
                .frame(width: 90, height: 90)
            // Hub
            Circle()
                .stroke(Theme.textPrimary, lineWidth: 1.5)
                .frame(width: 22, height: 22)
            Circle()
                .stroke(Theme.textPrimary, lineWidth: 1.5)
                .frame(width: 10, height: 10)
            Circle()
                .fill(Theme.textPrimary)
                .frame(width: 3, height: 3)
            // 3 spokes
            ForEach(0..<3, id: \.self) { i in
                let angle = Angle.degrees(Double(i) * 120 - 90)
                Path { p in
                    p.move(to: CGPoint(x: 45 + 11 * cos(angle.radians),
                                       y: 45 + 11 * sin(angle.radians)))
                    p.addLine(to: CGPoint(x: 45 + 39 * cos(angle.radians),
                                          y: 45 + 39 * sin(angle.radians)))
                }
                .stroke(Theme.textPrimary, lineWidth: 1.5)
            }
        }
        .frame(width: 90, height: 90)
        .rotationEffect(spinning ? .degrees(360) : .zero)
        .animation(spinning ? .linear(duration: fast ? 1.4 : 2.6).repeatForever(autoreverses: false) : .default, value: spinning)
    }
}

// ── ArrangeHeadUnit (TAPE 08 head section) ──────────────────────────────────

struct ArrangeHeadUnit: View {
    @ObservedObject var audio: AudioManager

    private var timerText: String {
        let t = audio.recordingDuration
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let tenths = Int((t - floor(t)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }
    private var statusText: String {
        audio.isRecording ? "REC" : (audio.isPlaying ? "PLAY" : "IDLE")
    }
    private var barPosition: String {
        let bpm = audio.metronomeBPM
        let secsPerBar = 240.0 / bpm  // 4 beats per bar
        let bar = Int(audio.recordingDuration / secsPerBar) + 1
        let beat = Int((audio.recordingDuration.truncatingRemainder(dividingBy: secsPerBar)) / (secsPerBar / 4)) + 1
        return String(format: "%03d.%d", bar, beat)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            // Left: selected track info
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    // Boxed track number — rounded corners
                    Text(String(format: "%02d", audio.selectedTrack + 1))
                        .font(.system(size: 44, weight: .ultraLight, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .frame(width: 84, height: 84)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.textPrimary, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SELECTED\nTRACK")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(Theme.textSecondary)
                            .lineSpacing(2)
                        Text(audio.tracks[audio.selectedTrack].clips.last?.name ?? "TRK \(String(format: "%02d", audio.selectedTrack + 1))")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Text("\u{25CF} ARMED")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(Theme.danger)
                    }
                }

                // Info grid: 2×2
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    infoItem("INPUT", audio.inputDevices.first { $0.id == audio.selectedInputID }?.name ?? "MBP MIC")
                    infoItem("OUTPUT", audio.outputDevices.first { $0.id == audio.selectedOutputID }?.name ?? "MBP SPK")
                    infoItem("POSITION", "BAR \(barPosition)")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LOOP")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(Theme.textTertiary)
                        Text("BAR 05 \u{2192} 16")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundColor(Theme.loopGreen)
                    }
                }
            }
            .frame(minWidth: 240, alignment: .leading)

            // Center: reels + timecode
            VStack(spacing: 0) {
                ZStack {
                    // Reels
                    HStack(spacing: 0) {
                        ReelView(cx: 0, cy: 0, spinning: audio.isPlaying || audio.isRecording, fast: audio.isRecording)
                        Spacer()
                        ReelView(cx: 0, cy: 0, spinning: audio.isPlaying || audio.isRecording, fast: audio.isRecording)
                    }
                    .padding(.horizontal, 20)

                    // Timecode overlay
                    VStack(spacing: 6) {
                        Text("TRK \(String(format: "%02d", audio.selectedTrack + 1)) \u{00B7} \(statusText)")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(4)
                            .foregroundColor(Theme.textSecondary)
                        Text(timerText)
                            .font(.system(size: 60, weight: .ultraLight, design: .monospaced))
                            .foregroundColor(audio.isRecording ? Theme.danger : Theme.textPrimary)
                            .monospacedDigit()

                        // Bar position below timecode
                        Text("BAR \(barPosition)")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                // Tape path
                HStack(spacing: 0) {
                    Spacer()
                    // Rollers + head
                    HStack(spacing: 20) {
                        Circle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 12, height: 12)
                        Circle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 18, height: 18)
                            .overlay(Circle().fill(Theme.textPrimary).frame(width: 5, height: 5))
                        // Playhead/tape guide
                        VStack(spacing: 2) {
                            Rectangle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 18, height: 16)
                            Rectangle().fill(Theme.accent).frame(width: 1.5, height: 10)
                        }
                        Circle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 18, height: 18)
                            .overlay(
                                Path { p in
                                    p.move(to: CGPoint(x: 4, y: 14)); p.addLine(to: CGPoint(x: 14, y: 4))
                                }.stroke(Theme.textPrimary, lineWidth: 1.5)
                            )
                        Circle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                .padding(.top, 4)

                // Loop toggle
                Button(action: { audio.loopEnabled.toggle() }) {
                    Image(systemName: "repeat")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(audio.loopEnabled ? Theme.loopGreen : Theme.textTertiary)
                        .frame(width: 48, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(audio.loopEnabled ? Theme.loopGreen.opacity(0.4) : Theme.textTertiary.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)

            // Right: peak + tempo + meters
            HStack(spacing: 28) {
                VStack(alignment: .trailing, spacing: 16) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("PEAK")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(Theme.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(audio.peakDB.isFinite ? String(format: "%.1f", audio.peakDB) : "\u{2212}\u{221E}")
                                .font(.system(size: 28, weight: .light, design: .monospaced))
                                .foregroundColor(audio.peakDB > -0.5 ? Theme.danger : Theme.textPrimary)
                                .monospacedDigit()
                            Text("dB")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("TEMPO / SIG")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(Theme.textSecondary)
                        Text("\(Int(audio.metronomeBPM)) \u{00B7} 4/4")
                            .font(.system(size: 20, weight: .light, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                    }
                }

                // Vertical L/R meters
                HStack(spacing: 14) {
                    VerticalMeter(label: "L", level: audio.levelL, peak: audio.peakL)
                    VerticalMeter(label: "R", level: audio.levelR, peak: audio.peakR)
                    VStack {
                        Text("0").frame(maxHeight: .infinity, alignment: .top)
                        Text("-6").frame(maxHeight: .infinity)
                        Text("-12").frame(maxHeight: .infinity)
                        Text("-24").frame(maxHeight: .infinity)
                        Text("-36").frame(maxHeight: .infinity)
                        Text("-60").frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                }
                .frame(height: 196)
            }
            .frame(minWidth: 240, alignment: .trailing)
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
    }
}

// ── MonitorView (live signal display) ───────────────────────────────────────

struct MonitorView: View {
    @ObservedObject var audio: AudioManager

    private var timerText: String {
        let t = audio.recordingDuration
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let tenths = Int((t - floor(t)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }
    private var barColor: Color {
        if audio.isRecording { return Theme.danger }
        return audio.isMonitoring ? Theme.accent : Theme.textTertiary
    }
    private var inputName: String {
        audio.inputDevices.first { $0.id == audio.selectedInputID }?.name ?? "No Input"
    }
    private var outputName: String {
        audio.outputDevices.first { $0.id == audio.selectedOutputID }?.name ?? "No Output"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status + timecode
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(audio.isRecording ? Theme.danger : (audio.isMonitoring ? Theme.accent : Theme.textTertiary))
                        .frame(width: 6, height: 6)
                    Text(audio.isRecording ? "REC" : (audio.isMonitoring ? "LIVE" : "IDLE"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(4)
                        .foregroundColor(audio.isRecording ? Theme.danger : (audio.isMonitoring ? Theme.accent : Theme.textTertiary))
                    Text("\(inputName) \u{2192} \(outputName)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textSecondary)
                }

                Text(timerText)
                    .font(.system(size: 60, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(audio.isRecording ? Theme.danger : Theme.textPrimary)
                    .monospacedDigit()

                // Signal chain breadcrumb
                HStack(spacing: 8) {
                    Text("In").foregroundColor(Theme.accent)
                    ForEach(Array(audio.liveChain.enumerated()), id: \.element.id) { _, slot in
                        Text("\u{2192}").foregroundColor(Theme.textTertiary)
                        Circle()
                            .fill(slot.enabled ? Theme.accent : Theme.textTertiary)
                            .frame(width: 6, height: 6)
                        Text(EffectRegistry.shared.module(for: slot.moduleID)?.displayName ?? slot.moduleID)
                            .foregroundColor(slot.enabled ? Theme.textPrimary : Theme.textTertiary)
                    }
                    Text("\u{2192}").foregroundColor(Theme.textTertiary)
                    Text("Out").foregroundColor(Theme.accent)
                }
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            // Scrolling waveform (hero)
            GeometryReader { geo in
                let midY = geo.size.height / 2
                ZStack {
                    // Grid lines
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: midY))
                        p.addLine(to: CGPoint(x: geo.size.width, y: midY))
                    }
                    .stroke(Theme.textPrimary.opacity(0.08), lineWidth: 0.5)

                    // Recording marker
                    if audio.isRecording {
                        let recX = geo.size.width * 0.5
                        Path { p in
                            p.move(to: CGPoint(x: recX, y: 0))
                            p.addLine(to: CGPoint(x: recX, y: geo.size.height))
                        }
                        .stroke(Theme.danger, lineWidth: 1)
                        Text("REC IN")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(Theme.danger)
                            .position(x: recX, y: 12)
                    }

                    // Waveform bars
                    Path { path in
                        let count = audio.waveformSamples.count
                        guard count > 0 else { return }
                        let barWidth: CGFloat = 3
                        let spacing = geo.size.width / CGFloat(count)
                        for (i, val) in audio.waveformSamples.enumerated() {
                            let x = CGFloat(i) * spacing + spacing / 2
                            let h = CGFloat(val) * (geo.size.height / 2.2)
                            let rect = CGRect(x: x - barWidth / 2, y: midY - h,
                                              width: barWidth, height: h * 2)
                            path.addRect(rect)
                        }
                    }
                    .fill(barColor.opacity(0.85))
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 28)
            .background(Theme.bg)

            // Time axis
            HStack {
                Text("-40s"); Spacer(); Text("-30s"); Spacer()
                Text("-20s"); Spacer(); Text("-10s"); Spacer(); Text("now")
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 32).padding(.vertical, 4)

            // Horizontal L/R meters
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    hMeter(label: "L", level: audio.levelL, peak: audio.peakL)
                    hMeter(label: "R", level: audio.levelR, peak: audio.peakR)
                    // dB scale
                    GeometryReader { geo in
                        ZStack {
                            let marks: [(String, Double)] = [("-60", 0), ("-36", 0.24), ("-24", 0.40),
                                                              ("-12", 0.60), ("-6", 0.80), ("0 dB", 1.0)]
                            ForEach(marks, id: \.0) { mark in
                                Text(mark.0)
                                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .position(x: 14 + CGFloat(mark.1) * (geo.size.width - 28), y: 6)
                            }
                        }
                    }
                    .frame(height: 14)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text("PEAK")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textTertiary)
                    Text(audio.peakDB.isFinite ? String(format: "%+.1f dB", audio.peakDB) : "\u{2212}\u{221E} dB")
                        .font(.system(size: 22, weight: .light, design: .monospaced))
                        .foregroundColor(audio.peakDB > -0.5 ? Theme.danger : Theme.textPrimary)
                        .monospacedDigit()
                }
                .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)

            // Device pickers + routing
            HStack(spacing: 24) {
                HStack(spacing: 6) {
                    Text("Input").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                    Picker("", selection: Binding(
                        get: { audio.selectedInputID },
                        set: { audio.selectedInputID = $0; audio.startMonitoring() }
                    )) {
                        ForEach(audio.inputDevices) { dev in Text(dev.name).tag(Optional(dev.id)) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                HStack(spacing: 6) {
                    Text("Output").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                    Picker("", selection: Binding(
                        get: { audio.selectedOutputID },
                        set: { if let id = $0 { audio.switchOutput(to: id) } }
                    )) {
                        ForEach(audio.outputDevices) { dev in Text(dev.name).tag(Optional(dev.id)) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                Spacer()
                Text("Volume")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                Text("\(Int(audio.volume * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(.horizontal, 28).padding(.vertical, 10)
            .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .top)
        }
    }

    @ViewBuilder
    private func hMeter(label: String, level: Double, peak: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary).frame(width: 8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.surfaceInset)
                    Rectangle()
                        .fill(level > 0.95 ? Theme.danger : Theme.accent)
                        .frame(width: max(0, CGFloat(level) * geo.size.width))
                    Rectangle()
                        .fill(Theme.textPrimary)
                        .frame(width: 2)
                        .offset(x: max(0, min(geo.size.width - 2, CGFloat(peak) * geo.size.width)))
                }
            }
            .frame(height: 6)
        }
    }
}

// ── WindowAccessor ──────────────────────────────────────────────────────────

struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { callback(nsView.window) }
    }
}

// ── Trim Editor ─────────────────────────────────────────────────────────────

struct TrimEditorView: View {
    @ObservedObject var audio: AudioManager

    private func timeString(_ fraction: Double) -> String {
        let t = fraction * audio.trimClipDuration
        let m = Int(t) / 60
        let s = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 100)
        return String(format: "%d:%02d.%02d", m, s, ms)
    }

    private var trimmedDuration: String {
        let d = (audio.trimEnd - audio.trimStart) * audio.trimClipDuration
        let m = Int(d) / 60
        let s = Int(d) % 60
        let ms = Int((d - Double(Int(d))) * 100)
        return String(format: "%d:%02d.%02d", m, s, ms)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("TRIM")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(Theme.gold)
                if let ti = audio.trimmingTrack {
                    Text("TRK \(String(format: "%02d", ti + 1))")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.gold.opacity(0.6))
                }
                Spacer()
                Text(trimmedDuration)
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundColor(Theme.gold)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Rectangle().fill(Theme.gold.opacity(0.2)).frame(height: 1)

            // Waveform with trim handles
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let leftX = CGFloat(audio.trimStart) * w
                let rightX = CGFloat(audio.trimEnd) * w

                ZStack(alignment: .topLeading) {
                    // Grid lines
                    Path { path in
                        for i in 1..<8 {
                            let x = w * CGFloat(i) / 8
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: h))
                        }
                        path.move(to: CGPoint(x: 0, y: h / 2))
                        path.addLine(to: CGPoint(x: w, y: h / 2))
                    }
                    .stroke(Theme.gold.opacity(0.08), lineWidth: 0.5)

                    // Dimmed regions outside trim
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: max(0, leftX))
                        .frame(maxHeight: .infinity, alignment: .leading)
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: max(0, w - rightX))
                        .frame(maxHeight: .infinity, alignment: .trailing)
                        .position(x: (rightX + w) / 2, y: h / 2)

                    // Waveform bars
                    if !audio.trimPeaks.isEmpty {
                        Path { path in
                            let midY = h / 2
                            let barW = w / CGFloat(audio.trimPeaks.count)
                            for (j, peak) in audio.trimPeaks.enumerated() {
                                let x = CGFloat(j) * barW + barW / 2
                                let barH = CGFloat(peak) * midY * 0.85
                                path.move(to: CGPoint(x: x, y: midY - barH))
                                path.addLine(to: CGPoint(x: x, y: midY + barH))
                            }
                        }
                        .stroke(Theme.gold.opacity(0.7), lineWidth: max(1, w / CGFloat(audio.trimPeaks.count) - 1))
                    }

                    // Left handle
                    Rectangle()
                        .fill(Theme.gold)
                        .frame(width: 2, height: h)
                        .position(x: leftX, y: h / 2)
                    Path { p in
                        p.move(to: CGPoint(x: leftX, y: h / 2 - 14))
                        p.addLine(to: CGPoint(x: leftX + 10, y: h / 2))
                        p.addLine(to: CGPoint(x: leftX, y: h / 2 + 14))
                        p.closeSubpath()
                    }
                    .fill(Theme.gold)

                    // Right handle
                    Rectangle()
                        .fill(Theme.gold)
                        .frame(width: 2, height: h)
                        .position(x: rightX, y: h / 2)
                    Path { p in
                        p.move(to: CGPoint(x: rightX, y: h / 2 - 14))
                        p.addLine(to: CGPoint(x: rightX - 10, y: h / 2))
                        p.addLine(to: CGPoint(x: rightX, y: h / 2 + 14))
                        p.closeSubpath()
                    }
                    .fill(Theme.gold)

                    // Time labels at handles
                    Text(timeString(audio.trimStart))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.gold)
                        .position(x: leftX + 28, y: 10)
                    Text(timeString(audio.trimEnd))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.gold)
                        .position(x: rightX - 28, y: 10)

                    // Drag zones
                    Color.clear
                        .frame(width: 30, height: h)
                        .contentShape(Rectangle())
                        .position(x: leftX, y: h / 2)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { g in
                                    let frac = max(0, min(audio.trimEnd - 0.01, Double(g.location.x / w)))
                                    audio.trimStart = frac
                                }
                        )
                    Color.clear
                        .frame(width: 30, height: h)
                        .contentShape(Rectangle())
                        .position(x: rightX, y: h / 2)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { g in
                                    let frac = min(1, max(audio.trimStart + 0.01, Double(g.location.x / w)))
                                    audio.trimEnd = frac
                                }
                        )
                }
            }
            .frame(height: 100)
            .background(Theme.surfaceInset)
            .padding(.horizontal, 16).padding(.top, 8)

            Rectangle().fill(Theme.gold.opacity(0.2)).frame(height: 1)
                .padding(.top, 8)

            // Buttons
            HStack(spacing: 12) {
                Spacer()
                Button { audio.cancelTrim() } label: {
                    Text("CANCEL")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.surface)
                        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button { audio.applyTrim() } label: {
                    Text("APPLY")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.bg)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Theme.gold)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.bg)
        .overlay(Rectangle().stroke(Theme.gold.opacity(0.3), lineWidth: 1))
    }
}

// ── Settings Panel ──────────────────────────────────────────────────────────

struct SettingsPanel: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(16)
            Rectangle().fill(Theme.accent.opacity(0.15)).frame(height: 1)

            VStack(alignment: .leading, spacing: 16) {
                // Save location
                VStack(alignment: .leading, spacing: 6) {
                    Text("SAVE LOCATION")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)
                    HStack(spacing: 8) {
                        Text(audio.saveLocation.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { audio.changeSaveLocation() } label: {
                            Text("CHANGE")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .tracking(1)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .foregroundColor(Theme.accent)
                                .background(Theme.surfaceInset)
                                .overlay(Rectangle().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                // Audio info
                VStack(alignment: .leading, spacing: 6) {
                    Text("AUDIO")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)

                    settingsRow("Sample Rate", audio.sampleRateString)

                    if let inputName = audio.inputDevices.first(where: { $0.id == audio.selectedInputID })?.name {
                        settingsRow("Input", inputName)
                    }
                    if let outputName = audio.outputDevices.first(where: { $0.id == audio.selectedOutputID })?.name {
                        settingsRow("Output", outputName)
                    }
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                // Export
                VStack(alignment: .leading, spacing: 6) {
                    Text("EXPORT")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)

                    Button { audio.exportTrack(audio.selectedTrack) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 10, weight: .bold))
                            Text("EXPORT TRK \(String(format: "%02d", audio.selectedTrack + 1))")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .tracking(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(Theme.accent)
                        .background(Theme.surfaceInset)
                        .overlay(Rectangle().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                // Session info
                VStack(alignment: .leading, spacing: 6) {
                    Text("SESSION")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)

                    let clipCount = audio.tracks.reduce(0) { $0 + $1.clips.count }
                    settingsRow("Clips", "\(clipCount)")
                    settingsRow("Tracks Used", "\(audio.tracks.filter { !$0.clips.isEmpty }.count) / \(Theme.trackCount)")
                    settingsRow("Effects", "\(audio.liveChain.filter { $0.enabled }.count) active")
                }
            }
            .padding(16)

            Spacer()
        }
        .frame(width: 260)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(width: 1), alignment: .trailing)
    }

    private func settingsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
    }
}

// ── Root View ───────────────────────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var audio = AudioManager()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(audio: audio)

            HStack(spacing: 0) {
                if audio.showSettings {
                    SettingsPanel(audio: audio)
                }

                if audio.showEffects {
                    SideEffectsPanelView(audio: audio)
                }

                if audio.viewMode == 0 {
                    // Arrange view
                    VStack(spacing: 0) {
                        ArrangeHeadUnit(audio: audio)

                        // Track label
                        HStack {
                            Text("TRACKS \u{00B7} \(String(format: "%02d", Theme.trackCount))")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .tracking(3)
                                .foregroundColor(Theme.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 6)

                        ScrollView(.vertical, showsIndicators: false) {
                            LoopGridView(audio: audio)
                        }
                        .frame(maxHeight: .infinity)

                        if audio.trimmingTrack != nil {
                            TrimEditorView(audio: audio)
                                .padding(.horizontal, 28).padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Monitor view
                    MonitorView(audio: audio)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            TransportBar(audio: audio)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DotGridBackground())
        .background(Theme.bg)
        .background(WindowAccessor { _ in })
        .onAppear { audio.startMonitoring() }
    }
}

// ── App Entry Point ─────────────────────────────────────────────────────────

@main
struct MonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1060, minHeight: 720)
                .background(Theme.bg)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
