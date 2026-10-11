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

// MARK: - Gain Kernel

final class GainKernel: AudioEffectKernel {
    private var gain: Float = 0.0  // dB

    required init(sampleRate: Double) {}

    func setParameter(_ id: String, value: Float) {
        if id == "gain" { gain = value }
    }

    func reset() {}

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let linear = powf(10.0, gain / 20.0)
        for buf in buffers {
            for i in 0..<frames { buf[i] *= linear }
        }
    }
}

// MARK: - Distortion Kernel (tanh waveshaper + tone + output)

final class DistortionKernel: AudioEffectKernel {
    private let sampleRate: Double
    private var drive: Float = 0.5   // 0–1
    private var tone: Float = 0.5    // 0–1 (low-pass cutoff proportion)
    private var level: Float = 0.5   // 0–1
    private var mix: Float = 1.0

    // One-pole LP state per channel
    private var lpL: Float = 0, lpR: Float = 0

    required init(sampleRate: Double) { self.sampleRate = sampleRate }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "drive": drive = value
        case "tone":  tone = value
        case "level": level = value
        case "mix":   mix = value
        default: break
        }
    }

    func reset() { lpL = 0; lpR = 0 }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let driveAmt = 1.0 + drive * 30.0        // 1–31× gain into tanh
        let outGain = level * 2.0                 // 0–2× output
        let cutoff = 0.05 + tone * 0.95           // LP coefficient 0.05–1.0
        let wet = mix

        for (ci, buf) in buffers.enumerated() {
            var lp = ci == 0 ? lpL : lpR
            for i in 0..<frames {
                let dry = buf[i]
                var s = dry * driveAmt
                // Soft-clip via tanh
                s = tanhf(s)
                // One-pole tone filter
                lp += cutoff * (s - lp)
                s = lp
                s *= outGain
                buf[i] = dry * (1.0 - wet) + s * wet
            }
            if ci == 0 { lpL = lp } else { lpR = lp }
        }
    }
}

// MARK: - Chorus Kernel (LFO-modulated delay)

final class ChorusKernel: AudioEffectKernel {
    private let sampleRate: Float
    private var rate: Float = 0.5    // Hz
    private var depth: Float = 0.5   // 0–1
    private var mix: Float = 0.5     // 0–1

    // Delay buffers per channel (50ms max)
    private var delayL: [Float] = []
    private var delayR: [Float] = []
    private var writeIdx = 0
    private var lfoPhase: Float = 0

    required init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        let maxDelay = Int(sampleRate * 0.05) + 1
        delayL = [Float](repeating: 0, count: maxDelay)
        delayR = [Float](repeating: 0, count: maxDelay)
    }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "rate":  rate = value
        case "depth": depth = value
        case "mix":   mix = value
        default: break
        }
    }

    func reset() {
        delayL = [Float](repeating: 0, count: delayL.count)
        delayR = [Float](repeating: 0, count: delayR.count)
        writeIdx = 0
        lfoPhase = 0
    }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let bufSize = delayL.count
        guard bufSize > 1 else { return }
        let wet = mix

        for i in 0..<frames {
            // LFO
            lfoPhase += rate / sampleRate
            if lfoPhase > 1 { lfoPhase -= 1 }
            let lfo = sinf(2.0 * .pi * lfoPhase)

            // Modulated delay in samples (0–20ms)
            let delaySamples = depth * 0.02 * sampleRate * (0.5 + 0.5 * lfo)
            let readF = Float(writeIdx) - delaySamples
            let readI = ((Int(readF) % bufSize) + bufSize) % bufSize
            let frac = readF - floorf(readF)
            let nextI = (readI + 1) % bufSize

            // Index delayL/delayR directly. Binding a local (let delay = delayL)
            // and then mutating delayL leaves a second reference to the buffer and
            // can force a copy-on-write of the whole delay line every sample.
            for (ci, buf) in buffers.enumerated() {
                let dry = buf[i]
                let delayed: Float
                if ci == 0 {
                    let a = delayL[readI], b = delayL[nextI]
                    delayed = a + (b - a) * frac
                    delayL[writeIdx] = dry
                } else {
                    let a = delayR[readI], b = delayR[nextI]
                    delayed = a + (b - a) * frac
                    delayR[writeIdx] = dry
                }
                buf[i] = dry * (1.0 - wet) + delayed * wet
            }

            writeIdx = (writeIdx + 1) % bufSize
        }
    }
}

// MARK: - Compressor Kernel (envelope follower + gain reduction)

final class CompressorKernel: AudioEffectKernel {
    private let sampleRate: Double
    private var threshold: Float = -12.0  // dB
    private var ratio: Float = 4.0
    private var attack: Float = 0.01      // seconds
    private var release: Float = 0.1      // seconds
    private var makeupGain: Float = 0.0   // dB

    private var envelope: Float = 0

    required init(sampleRate: Double) { self.sampleRate = sampleRate }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "threshold": threshold = value
        case "ratio":     ratio = value
        case "attack":    attack = value
        case "release":   release = value
        case "makeup":    makeupGain = value
        default: break
        }
    }

    func reset() { envelope = 0 }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let attackCoeff = expf(-1.0 / (Float(sampleRate) * max(attack, 0.0001)))
        let releaseCoeff = expf(-1.0 / (Float(sampleRate) * max(release, 0.001)))
        let threshLinear = powf(10.0, threshold / 20.0)
        let makeup = powf(10.0, makeupGain / 20.0)

        for i in 0..<frames {
            // Peak across channels
            var peak: Float = 0
            for buf in buffers { peak = max(peak, fabsf(buf[i])) }

            // Envelope follower
            let coeff = peak > envelope ? attackCoeff : releaseCoeff
            envelope = coeff * envelope + (1.0 - coeff) * peak

            // Gain computation
            var gain: Float = 1.0
            if envelope > threshLinear {
                let overDB = 20.0 * log10f(envelope / threshLinear)
                let compressedDB = overDB / ratio
                gain = powf(10.0, (compressedDB - overDB) / 20.0)
            }
            gain *= makeup

            for buf in buffers { buf[i] *= gain }
        }
    }
}

// MARK: - Flanger Kernel (short modulated delay + feedback)

final class FlangerKernel: AudioEffectKernel {
    private let sampleRate: Float
    private var rate: Float = 0.3     // Hz
    private var depth: Float = 0.5    // 0–1
    private var feedback: Float = 0.5 // 0–1
    private var mix: Float = 0.5

    private var delayL: [Float] = []
    private var delayR: [Float] = []
    private var writeIdx = 0
    private var lfoPhase: Float = 0

    required init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        let maxDelay = Int(sampleRate * 0.01) + 1  // 10ms max
        delayL = [Float](repeating: 0, count: maxDelay)
        delayR = [Float](repeating: 0, count: maxDelay)
    }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "rate":     rate = value
        case "depth":    depth = value
        case "feedback": feedback = value
        case "mix":      mix = value
        default: break
        }
    }

    func reset() {
        delayL = [Float](repeating: 0, count: delayL.count)
        delayR = [Float](repeating: 0, count: delayR.count)
        writeIdx = 0; lfoPhase = 0
    }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let bufSize = delayL.count
        guard bufSize > 1 else { return }
        let fb = min(feedback * 0.95, 0.95)  // cap to prevent runaway

        for i in 0..<frames {
            lfoPhase += rate / sampleRate
            if lfoPhase > 1 { lfoPhase -= 1 }
            let lfo = sinf(2.0 * .pi * lfoPhase)

            // 0.1–5ms modulated delay
            let delaySamples = depth * 0.005 * sampleRate * (0.5 + 0.5 * lfo) + 0.0001 * sampleRate
            let readF = Float(writeIdx) - delaySamples
            let readI = ((Int(readF) % bufSize) + bufSize) % bufSize
            let frac = readF - floorf(readF)
            let nextI = (readI + 1) % bufSize

            // Index delayL/delayR directly to avoid a per-sample copy-on-write of
            // the delay line (see ChorusKernel for details).
            for (ci, buf) in buffers.enumerated() {
                let dry = buf[i]
                let delayed: Float
                if ci == 0 {
                    delayed = delayL[readI] + (delayL[nextI] - delayL[readI]) * frac
                    delayL[writeIdx] = dry + delayed * fb
                } else {
                    delayed = delayR[readI] + (delayR[nextI] - delayR[readI]) * frac
                    delayR[writeIdx] = dry + delayed * fb
                }
                buf[i] = dry * (1.0 - mix) + delayed * mix
            }
            writeIdx = (writeIdx + 1) % bufSize
        }
    }
}

// MARK: - Phaser Kernel (cascaded all-pass filters + LFO)

final class PhaserKernel: AudioEffectKernel {
    private let sampleRate: Float
    private var rate: Float = 0.5    // Hz
    private var depth: Float = 0.7   // 0–1
    private var feedback: Float = 0.3
    private var mix: Float = 0.5
    private let stageCount = 6

    // All-pass filter state per stage per channel
    private var apStateL: [Float] = []
    private var apStateR: [Float] = []
    private var lfoPhase: Float = 0
    private var feedbackL: Float = 0
    private var feedbackR: Float = 0

    required init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        apStateL = [Float](repeating: 0, count: stageCount)
        apStateR = [Float](repeating: 0, count: stageCount)
    }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "rate":     rate = value
        case "depth":    depth = value
        case "feedback": feedback = value
        case "mix":      mix = value
        default: break
        }
    }

    func reset() {
        apStateL = [Float](repeating: 0, count: stageCount)
        apStateR = [Float](repeating: 0, count: stageCount)
        lfoPhase = 0; feedbackL = 0; feedbackR = 0
    }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let fb = min(feedback * 0.95, 0.95)

        for i in 0..<frames {
            lfoPhase += rate / sampleRate
            if lfoPhase > 1 { lfoPhase -= 1 }
            let lfo = sinf(2.0 * .pi * lfoPhase)

            // LFO sweeps all-pass coefficient between ~200Hz and ~4kHz
            let minFreq: Float = 200
            let maxFreq: Float = 4000
            let freq = minFreq + (maxFreq - minFreq) * (0.5 + 0.5 * lfo) * depth
            let coeff = (1.0 - tanf(.pi * freq / sampleRate)) / (1.0 + tanf(.pi * freq / sampleRate))

            for (ci, buf) in buffers.enumerated() {
                let dry = buf[i]
                var s = dry + (ci == 0 ? feedbackL : feedbackR) * fb
                var apState = ci == 0 ? apStateL : apStateR

                // Cascade first-order all-pass stages
                // y[n] = c * x[n] + state;  state = x[n] - c * y[n]
                for stage in 0..<stageCount {
                    let y = coeff * s + apState[stage]
                    apState[stage] = s - coeff * y
                    s = y
                }

                if ci == 0 { apStateL = apState; feedbackL = s }
                else       { apStateR = apState; feedbackR = s }

                buf[i] = dry * (1.0 - mix) + s * mix
            }
        }
    }
}

// MARK: - Tremolo Kernel (LFO amplitude modulation)

final class TremoloKernel: AudioEffectKernel {
    private let sampleRate: Float
    private var rate: Float = 4.0    // Hz
    private var depth: Float = 0.5   // 0–1
    private var shape: Float = 0     // 0 = sine, 1 = square

    private var lfoPhase: Float = 0

    required init(sampleRate: Double) { self.sampleRate = Float(sampleRate) }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "rate":  rate = value
        case "depth": depth = value
        case "shape": shape = value
        default: break
        }
    }

    func reset() { lfoPhase = 0 }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        for i in 0..<frames {
            lfoPhase += rate / sampleRate
            if lfoPhase > 1 { lfoPhase -= 1 }

            let lfo: Float
            if shape < 0.5 {
                lfo = sinf(2.0 * .pi * lfoPhase)
            } else {
                lfo = lfoPhase < 0.5 ? 1.0 : -1.0
            }

            // Modulate amplitude: 1.0 at center, (1-depth) at extremes
            let gain = 1.0 - depth * 0.5 * (1.0 - lfo)

            for buf in buffers { buf[i] *= gain }
        }
    }
}

// MARK: - Bitcrusher Kernel (sample rate & bit depth reduction)

final class BitcrusherKernel: AudioEffectKernel {
    private let sampleRate: Float
    private var bitDepth: Float = 16   // 1–16 bits
    private var downsample: Float = 1  // 1–50 (hold every N samples)
    private var mix: Float = 1.0

    private var holdL: Float = 0, holdR: Float = 0
    private var holdCounter: Int = 0

    required init(sampleRate: Double) { self.sampleRate = Float(sampleRate) }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "bits":       bitDepth = value
        case "downsample": downsample = value
        case "mix":        mix = value
        default: break
        }
    }

    func reset() { holdL = 0; holdR = 0; holdCounter = 0 }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let steps = powf(2.0, floorf(bitDepth)) - 1.0
        let hold = max(1, Int(downsample))

        for i in 0..<frames {
            holdCounter += 1

            for (ci, buf) in buffers.enumerated() {
                let dry = buf[i]

                if holdCounter >= hold {
                    // Quantize
                    let crushed = roundf(dry * steps) / steps
                    if ci == 0 { holdL = crushed } else { holdR = crushed }
                }

                buf[i] = dry * (1.0 - mix) + (ci == 0 ? holdL : holdR) * mix
            }

            if holdCounter >= hold { holdCounter = 0 }
        }
    }
}

// MARK: - Noise Gate Kernel (threshold-based gating)

final class NoiseGateKernel: AudioEffectKernel {
    private let sampleRate: Double
    private var threshold: Float = -40  // dB
    private var attack: Float = 0.001   // seconds
    private var hold: Float = 0.05      // seconds
    private var release: Float = 0.05   // seconds

    private var envelope: Float = 0
    private var gateGain: Float = 0
    private var holdCounter: Int = 0

    required init(sampleRate: Double) { self.sampleRate = sampleRate }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "threshold": threshold = value
        case "attack":    attack = value
        case "hold":      hold = value
        case "release":   release = value
        default: break
        }
    }

    func reset() { envelope = 0; gateGain = 0; holdCounter = 0 }

    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let threshLin = powf(10.0, threshold / 20.0)
        let attackCoeff = expf(-1.0 / (Float(sampleRate) * max(attack, 0.0001)))
        let releaseCoeff = expf(-1.0 / (Float(sampleRate) * max(release, 0.001)))
        let holdSamples = Int(Float(sampleRate) * hold)

        for i in 0..<frames {
            // Peak detect across channels
            var peak: Float = 0
            for buf in buffers { peak = max(peak, fabsf(buf[i])) }

            // Envelope
            let envCoeff = peak > envelope ? attackCoeff : releaseCoeff
            envelope = envCoeff * envelope + (1.0 - envCoeff) * peak

            // Gate logic
            if envelope > threshLin {
                gateGain = 1.0
                holdCounter = holdSamples
            } else if holdCounter > 0 {
                holdCounter -= 1
                gateGain = 1.0
            } else {
                // Release
                gateGain *= releaseCoeff
            }

            for buf in buffers { buf[i] *= gateGain }
        }
    }
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

// Points the engine's input AUHAL at a specific device *without* changing the system
// default input device (which would hijack input for every other running app).
func setEngineInputDevice(_ engine: AVAudioEngine, _ id: AudioDeviceID) {
    guard let unit = engine.inputNode.audioUnit else { return }
    var dev = id
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                         kAudioUnitScope_Global, 0, &dev,
                         UInt32(MemoryLayout<AudioDeviceID>.size))
}

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
    private var liveChainNodes: [(id: UUID, node: AVAudioNode)] = []

    // Effect chain presets
    @Published var presetNames: [String] = []
    @Published var showPresetSave = false
    @Published var presetSaveName: String = ""

    private static let presetDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tape08/Presets")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

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
    private var tapTimestamps: [Date] = []

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
    private var metronomePlayer: AVAudioPlayerNode?
    private var metronomeMixer:  AVAudioMixerNode?
    private var metronomeTimer:  Timer?            // low-frequency queue-refill timer
    private var metronomeClickBuffer: AVAudioPCMBuffer?
    private var metronomeBeatCount: Int = 0
    // Sample-accurate metronome scheduling state. Beats are queued on the player node
    // at exact frame positions ahead of time, so the refill timer's own jitter never
    // reaches the output (a plain per-beat Timer would drift).
    private var metronomeNextBeatFrame: Double = 0
    private var metronomeScheduledBPM: Double = 0

    // MIDI
    private var midiClient: MIDIClientRef = 0
    private var midiPort: MIDIPortRef = 0
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

    private static let timestampFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()

    init() {
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
        loadDevices()
        setupHardwareListeners()
        setupMIDI()
        installBuiltInPresets()
        refreshPresetList()
    }

    deinit {
        stopMonitoring()
        if midiPort != 0 { MIDIPortDispose(midiPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }

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

    // MARK: - MIDI (OP-XY track follow)

    private func setupMIDI() {
        MIDIClientCreateWithBlock("Tape08" as CFString, &midiClient) { [weak self] _ in
            DispatchQueue.main.async { self?.connectMIDISources() }
        }
        MIDIInputPortCreateWithProtocol(midiClient, "Input" as CFString, ._1_0, &midiPort) { [weak self] eventList, _ in
            guard let self, self.midiTrackFollow else { return }
            eventList.unsafeSequence().forEach { event in
                let word = event.pointee.words.0
                // MIDI 1.0 channel voice in UMP: type 0x2
                guard (word >> 28) & 0xF == 0x2 else { return }
                let status = (word >> 16) & 0xFF
                let channel = Int(status & 0x0F)
                // Any channel voice message → select matching track
                if channel < Theme.trackCount {
                    DispatchQueue.main.async { self.selectedTrack = channel }
                }
            }
        }
        connectMIDISources()
    }

    private func connectMIDISources() {
        // Disconnect all first
        let sourceCount = MIDIGetNumberOfSources()
        for i in 0..<sourceCount {
            let src = MIDIGetSource(i)
            MIDIPortDisconnectSource(midiPort, src)
        }
        // Connect to all sources (OP-XY will be among them)
        for i in 0..<sourceCount {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(midiPort, src, nil)
        }
    }

    // MARK: - Monitoring Engine

    func startMonitoring() {
        if inputDevices.isEmpty { loadDevices() }

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
                setNodeBypass(node, bypass: !slot.enabled)
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
        liveChainNodes = chainNodes
        outMixer     = liveMix
        dryTapMixer  = dryTap
        masterMixer  = master
        playerNodes  = players
        trackMixers  = trkMixers
        installTrackMeterTaps()
        metronomePlayer      = metPlayer
        metronomeMixer       = metMix
        metronomeClickBuffer = generateClickBuffer(sampleRate: stereoFmt.sampleRate, channels: 2)
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
                    if let last = self.liveChainNodes.last?.node { insertAfter = last }
                    else if let dryTap = self.dryTapMixer { insertAfter = dryTap }
                    else { insertAfter = eng.mainMixerNode }
                    eng.disconnectNodeOutput(insertAfter)
                    eng.attach(kernelNode)
                    eng.connect(insertAfter, to: kernelNode, format: fmt)
                    eng.connect(kernelNode,  to: liveMix, format: fmt)
                    kernelNode.auAudioUnit.shouldBypassEffect = !head.slot.enabled
                    for (pid, val) in head.slot.parameters { head.mod.applyParameter?(kernelNode, pid, val) }
                    self.liveChainNodes.append((head.slot.id, kernelNode))
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

    func switchOutput(to id: AudioDeviceID) {
        selectedOutputID = id
        if isMonitoring { stopMonitoring(); startMonitoring() }
    }

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
        stopMetronome()
        removeTrackMeterTaps()
        outMixer?.removeTap(onBus: 0)
        dryTapMixer?.removeTap(onBus: 0)
        engine?.stop()
        liveChainNodes = []
        engine = nil
        outMixer = nil; dryTapMixer = nil; masterMixer = nil; masterLimiterNode = nil
        playerNodes = []; trackMixers = []
        metronomePlayer = nil; metronomeMixer = nil; metronomeClickBuffer = nil
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
            get: { [weak self] in
                guard let self, index < self.liveChain.count else { return 0 }
                return Double(self.liveChain[index].parameters[id] ?? 0)
            },
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

    // MARK: - Effect Chain Presets

    private func presetURL(name: String) -> URL {
        Self.presetDir.appendingPathComponent(name + ".json")
    }

    func refreshPresetList() {
        let fm = FileManager.default
        let dir = Self.presetDir
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            presetNames = []
            return
        }
        presetNames = files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func saveChainPreset(name: String) {
        let data = liveChain.map { slot in
            ProjectChainSlotData(moduleID: slot.moduleID, enabled: slot.enabled, parameters: slot.parameters)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let json = try? encoder.encode(data) else { return }
        try? json.write(to: presetURL(name: name))
        refreshPresetList()
        status = "Preset saved: \(name)"
    }

    func loadChainPreset(name: String) {
        let url = presetURL(name: name)
        guard let json = try? Data(contentsOf: url),
              let slots = try? JSONDecoder().decode([ProjectChainSlotData].self, from: json) else {
            status = "Failed to load preset"
            return
        }
        var newChain: [ChainSlot] = []
        for slotData in slots {
            var slot = ChainSlot(moduleID: slotData.moduleID, enabled: slotData.enabled)
            // Merge saved values over the module defaults so partial presets don't
            // drop unspecified parameters to zero (which desyncs the UI from the DSP).
            for (key, value) in slotData.parameters { slot.parameters[key] = value }
            newChain.append(slot)
        }
        liveChain = newChain
        rebuildChain()
        status = "Loaded preset: \(name)"
    }

    func deleteChainPreset(name: String) {
        try? FileManager.default.removeItem(at: presetURL(name: name))
        refreshPresetList()
        status = "Deleted preset: \(name)"
    }

    private func installBuiltInPresets() {
        let builtIns: [(String, [ProjectChainSlotData])] = [
            ("Clean", []),
            ("Warm", [
                ProjectChainSlotData(moduleID: "com.apple.eq", enabled: true, parameters: ["lowGain": 3, "midGain": -1, "highGain": -2]),
                ProjectChainSlotData(moduleID: "com.opxy.tape-saturation", enabled: true, parameters: ["drive": 0.4, "bump": 0.6, "mix": 0.5]),
            ]),
            ("Ambient", [
                ProjectChainSlotData(moduleID: "com.apple.reverb", enabled: true, parameters: ["wetDryMix": 55, "preset": 4]),
                ProjectChainSlotData(moduleID: "com.apple.delay", enabled: true, parameters: ["time": 0.35, "feedback": 40, "wetDryMix": 30, "cutoff": 8000]),
            ]),
            ("Lo-Fi", [
                ProjectChainSlotData(moduleID: "com.opxy.bitcrusher", enabled: true, parameters: ["bits": 10, "downsample": 8, "mix": 0.6]),
                ProjectChainSlotData(moduleID: "com.opxy.tape-saturation", enabled: true, parameters: ["drive": 0.5, "bump": 0.7, "mix": 0.4]),
                ProjectChainSlotData(moduleID: "com.opxy.chorus", enabled: true, parameters: ["rate": 0.8, "depth": 0.5, "mix": 0.4]),
            ]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Built-ins are code-defined defaults, so (re)write them on launch. This
        // keeps them current when their definitions change between builds.
        for (name, chain) in builtIns {
            if let json = try? encoder.encode(chain) {
                try? json.write(to: presetURL(name: name))
            }
        }
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
        let sr = click.format.sampleRate

        metronomeBeatCount = 0
        metronomeNextBeatFrame = 0
        metronomeScheduledBPM = metronomeBPM
        player.stop()
        player.play()
        refillMetronomeQueue(accent: accentClick, click: click, sampleRate: sr)

        // Beats are queued sample-accurately ~2 s ahead, so this timer only tops up the
        // queue; its jitter is inaudible.
        metronomeTimer?.invalidate()
        metronomeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refillMetronomeQueue(accent: accentClick, click: click, sampleRate: sr)
        }
    }

    // Queues any beats that fall within the lookahead window at their exact frame
    // positions on the player node's timeline.
    private func refillMetronomeQueue(accent: AVAudioPCMBuffer, click: AVAudioPCMBuffer, sampleRate: Double) {
        guard let player = metronomePlayer, metronomeEnabled else { return }

        // Tempo changed — drop the queued beats and re-anchor to the current playhead.
        if metronomeScheduledBPM != metronomeBPM {
            player.stop()
            player.play()
            metronomeScheduledBPM = metronomeBPM
            metronomeNextBeatFrame = 0
            metronomeBeatCount = 0
        }

        let interval = (60.0 / metronomeBPM) * sampleRate   // frames per beat
        guard interval >= 1 else { return }

        // Current playhead position on the node's timeline (0 until it starts rendering).
        var nowFrame: Double = 0
        if let nodeTime = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nodeTime) {
            nowFrame = Double(pt.sampleTime)
        }
        // If we've fallen behind (e.g. after a stall), resume just ahead of the playhead.
        if metronomeNextBeatFrame < nowFrame { metronomeNextBeatFrame = nowFrame }

        let horizon = nowFrame + sampleRate * 2.0
        while metronomeNextBeatFrame < horizon {
            let isAccent = metronomeBeatCount % 4 == 0
            let at = AVAudioTime(sampleTime: AVAudioFramePosition(metronomeNextBeatFrame.rounded()),
                                 atRate: sampleRate)
            player.scheduleBuffer(isAccent ? accent : click, at: at, options: [], completionHandler: nil)
            metronomeBeatCount += 1
            metronomeNextBeatFrame += interval
        }
    }

    private func stopMetronome() {
        metronomeTimer?.invalidate(); metronomeTimer = nil
        metronomePlayer?.stop()
        metronomeBeatCount = 0
        metronomeNextBeatFrame = 0
        metronomeScheduledBPM = 0
    }

    func toggleMetronome() {
        metronomeEnabled.toggle()
        if tracks.contains(where: { $0.isPlaying }) {
            if metronomeEnabled { startMetronome() } else { stopMetronome() }
        }
    }

    func setMetronomeVolume(_ v: Double) {
        metronomeVolume = v
        metronomeMixer?.outputVolume = Float(v)
    }

    func tapTempo() {
        let now = Date()
        // Reset if more than 2 seconds since last tap
        if let last = tapTimestamps.last, now.timeIntervalSince(last) > 2.0 {
            tapTimestamps.removeAll()
        }
        tapTimestamps.append(now)
        // Keep last 8 taps
        if tapTimestamps.count > 8 { tapTimestamps.removeFirst() }
        // Need at least 2 taps to calculate
        if tapTimestamps.count >= 2 {
            var totalInterval: TimeInterval = 0
            for i in 1..<tapTimestamps.count {
                totalInterval += tapTimestamps[i].timeIntervalSince(tapTimestamps[i - 1])
            }
            let avgInterval = totalInterval / Double(tapTimestamps.count - 1)
            let newBPM = 60.0 / avgInterval
            metronomeBPM = min(300, max(40, newBPM.rounded()))
        }
        // Visual flash
        tapTempoFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.tapTempoFlash = false
        }
    }

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
            if metronomeTimer == nil { startMetronome() }
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
        // Cancel count-in if active
        if countingIn {
            countInTimer?.invalidate(); countInTimer = nil
            countingIn = false
            status = "Count-in cancelled"
            if !tracks.contains(where: { $0.isPlaying }) { stopMetronome() }
            return
        }
        recordingTimer?.invalidate(); recordingTimer = nil
        let saved = audioFile?.url
        let dur   = recordingDuration
        let trk   = selectedTrack
        audioFile   = nil
        isRecording = false
        if !tracks.contains(where: { $0.isPlaying }) { stopMetronome() }

        guard let u = saved else { return }
        let peaks = Self.computePeaks(url: u, count: Theme.clipPeaks)
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
        if metronomeEnabled && metronomeTimer == nil { startMetronome() }
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
        trimPeaks = Self.computePeaks(url: clip.url, count: 256)
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
        let trimName = "trim_\(Self.timestampFmt.string(from: Date())).wav"
        let trimURL = dir.appendingPathComponent(trimName)
        do {
            let outFile = try AVAudioFile(forWriting: trimURL, settings: srcFile.fileFormat.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
            try outFile.write(from: readBuf)
        } catch { status = "Trim error: \(error.localizedDescription)"; return }

        // Replace clip
        let dur = Double(trimmedFrames) / srcFile.fileFormat.sampleRate
        let peaks = Self.computePeaks(url: trimURL, count: Theme.clipPeaks)
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
        let ts = Self.timestampFmt.string(from: Date())

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
                              peaks: Self.computePeaks(url: urlA, count: Theme.clipPeaks))
        let clipB = TrackClip(url: urlB, duration: Double(framesB) / sr,
                              peaks: Self.computePeaks(url: urlB, count: Theme.clipPeaks))

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
        let ts = Self.timestampFmt.string(from: Date())
        let dupURL = dir.appendingPathComponent("\(base)_dup_\(ts).\(ext)")
        do {
            try fm.copyItem(at: clip.url, to: dupURL)
        } catch {
            status = "Duplicate error: \(error.localizedDescription)"; return
        }

        let peaks = Self.computePeaks(url: dupURL, count: Theme.clipPeaks)
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
        let peaks = Self.computePeaks(url: destURL, count: Theme.clipPeaks)
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
        panel.nameFieldStringValue = "Mixdown_\(Self.timestampFmt.string(from: Date())).wav"
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

    // Pure: reads `url` and returns `count` peak buckets. Static (no instance state)
    // so it can be called from a background queue during project load.
    private static func computePeaks(url: URL, count: Int) -> [Double] {
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
                let peaks = Self.computePeaks(url: p.url, count: Theme.clipPeaks)
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

// ── RetroButtonStyle ────────────────────────────────────────────────────────

struct RetroButtonStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary
    var active: Bool = false
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(filled && active ? tint : Color.clear)
            .contentShape(Rectangle())
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

    @State private var dragStartNorm: Double = 0

    private let startAngle: Double = 135
    private let sweepAngle: Double = 270

    private var normalized: Double {
        (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001)
    }

    private var totalSize: CGFloat { size + 12 }
    private var center: CGPoint { CGPoint(x: totalSize / 2, y: totalSize / 2) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                // Background track
                arcPath(from: 0, to: 1)
                    .stroke(Theme.textPrimary.opacity(0.10), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                // Value arc
                if bipolar {
                    arcPath(from: 0.5, to: normalized)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                } else {
                    arcPath(from: 0, to: normalized)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }

                // Indicator dot at current position
                let a = angleForValue(normalized)
                let dotR = size / 2
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .position(x: center.x + cos(a) * dotR, y: center.y + sin(a) * dotR)

                // Center dot
                Circle()
                    .fill(Theme.textPrimary.opacity(0.15))
                    .frame(width: 3, height: 3)
                    .position(center)
            }
            .frame(width: totalSize, height: totalSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if abs(gesture.translation.height) < 1 && abs(gesture.translation.width) < 1 {
                            dragStartNorm = normalized
                        }
                        let delta = -gesture.translation.height / 150
                        let newNorm = min(max(dragStartNorm + delta, 0), 1)
                        value = range.lowerBound + newNorm * (range.upperBound - range.lowerBound)
                    }
            )

            Text(displayValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(Theme.textEngraved)
                .lineLimit(1)
        }
    }

    private var displayValue: String {
        let span = range.upperBound - range.lowerBound
        if bipolar {
            // Signed display: +12, -3, +0.0
            if span > 10 {
                let v = Int(value)
                return (v >= 0 ? "+" : "") + "\(v)"
            } else {
                let v = value
                return (v >= 0 ? "+" : "") + String(format: "%.1f", v)
            }
        }
        // Percentage for 0–1 ranges
        if range.lowerBound >= 0 && range.upperBound <= 1.01 {
            return "\(Int(value * 100))%"
        }
        // Large values: abbreviate
        if abs(value) >= 10000 {
            return String(format: "%.1fk", value / 1000)
        }
        // Integer display for ranges > 10
        if span >= 10 {
            return "\(Int(value))"
        }
        // Small decimal ranges
        return String(format: "%.2f", value)
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
}

// ── TrackFader ──────────────────────────────────────────────────────────────

struct TrackFader: View {
    @Binding var value: Double
    let color: Color
    var onDragStart: (() -> Void)? = nil
    var onDragEnd: (() -> Void)? = nil
    @State private var isDragging = false

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
                        if !isDragging { isDragging = true; onDragStart?() }
                        value = max(0, min(1, Double(g.location.x / geo.size.width)))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnd?()
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
                    .contentShape(Rectangle())
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))

            Button { audio.tapTempo() } label: {
                Text("TAP")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .frame(width: 44, height: 44)
                    .foregroundColor(audio.tapTempoFlash ? Theme.bg : Theme.accent)
                    .background(audio.tapTempoFlash ? Theme.accent : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(audio.tapTempoFlash ? Theme.accent : Theme.textPrimary.opacity(0.16), lineWidth: 1))
            .animation(.easeOut(duration: 0.06), value: audio.tapTempoFlash)
        }
        .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
    }
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
                // Project name
                Text(audio.projectName.uppercased() + (audio.projectDirty ? " *" : ""))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Theme.accent.opacity(0.8))
                    .lineLimit(1)
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
                            Text(d.name).tag(Optional(d.id))
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
                            Text(d.name).tag(Optional(d.id))
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
                .contentShape(Rectangle())
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
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Theme.textPrimary.opacity(0.12))
                        .frame(width: 3)
                    Rectangle().fill(Theme.danger)
                        .frame(width: 3, height: max(0, CGFloat(level) * geo.size.height))
                    // Peak dot
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 8, height: 8)
                        .offset(y: -max(0, CGFloat(peak) * geo.size.height) + 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 14)
            Text(label)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
        }
    }
}

// ── Waveform Lane (scrollable middle) ─────────────────────────────────────

struct WaveformLaneView: View {
    let index: Int
    let track: TrackInfo
    @ObservedObject var audio: AudioManager
    let totalBars: Int
    let secsPerBar: Double
    let laneWidth: CGFloat

    private var color: Color { Theme.trackColor(index) }
    private var isRecordingThis: Bool { audio.isRecording && audio.selectedTrack == index }
    private var hasClip: Bool { !track.clips.isEmpty }
    private var isSelected: Bool { audio.selectedTrack == index }

    var body: some View {
        let barWidth = laneWidth / CGFloat(totalBars)
        ZStack(alignment: .leading) {
            // Bar grid lines
            Path { path in
                for i in 1..<totalBars {
                    let x = CGFloat(i) * barWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 52))
                }
            }
            .stroke(Theme.textPrimary.opacity(0.04), lineWidth: 0.5)

            Path { path in
                for i in stride(from: 4, to: totalBars, by: 4) {
                    let x = CGFloat(i) * barWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 52))
                }
            }
            .stroke(Theme.textPrimary.opacity(0.08), lineWidth: 0.5)

            if hasClip {
                ForEach(Array(track.clips.enumerated()), id: \.element.id) { ci, clip in
                    let clipBars = clip.duration / secsPerBar
                    let clipW = CGFloat(clipBars) * barWidth
                    let prevOffset = track.clips.prefix(ci).reduce(0.0) { $0 + $1.duration }
                    let clipX = CGFloat(prevOffset / secsPerBar) * barWidth

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(color.opacity(0.4), lineWidth: 1)
                        Rectangle()
                            .fill(color)
                            .frame(height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.horizontal, 1)
                        if !clip.peaks.isEmpty {
                            Path { path in
                                let midY: CGFloat = 25
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
                        Text("TAKE \(ci + 1)")
                            .font(.system(size: 7, weight: .regular, design: .monospaced))
                            .tracking(1.5)
                            .foregroundColor(Theme.textSecondary)
                            .padding(.leading, 4).padding(.top, 2)
                    }
                    .frame(width: max(clipW - 2, 4), height: 50)
                    .offset(x: clipX + 1, y: 1)
                }

                // Playhead
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
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 26))
                    path.addLine(to: CGPoint(x: laneWidth, y: 26))
                }
                .stroke(Theme.textPrimary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                Text("\u{2014} EMPTY \u{2014}")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: laneWidth, height: 52)
            }

            if isRecordingThis {
                Rectangle()
                    .fill(Theme.danger.opacity(0.05))
                    .overlay(Rectangle().stroke(Theme.danger.opacity(0.4), lineWidth: 1))
            }
        }
        .frame(width: laneWidth, height: 52)
        .background(isSelected ? Theme.textPrimary.opacity(0.025) : Color.clear)
        .overlay(
            Rectangle().stroke(isSelected ? color.opacity(0.4) : Theme.textPrimary.opacity(0.10), lineWidth: 1)
        )
        .onDrop(of: [.audio, .fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                    guard let data = data as? Data,
                          let urlStr = String(data: data, encoding: .utf8),
                          let fileURL = URL(string: urlStr) else { return }
                    let ext = fileURL.pathExtension.lowercased()
                    guard ["wav", "aiff", "aif", "m4a", "caf", "mp3", "flac"].contains(ext) else { return }
                    DispatchQueue.main.async { audio.importAudioFile(fileURL, toTrack: index) }
                }
            }
            return true
        }
    }
}

// ── Track Controls (fixed right column) ───────────────────────────────────

struct TrackControlsView: View {
    let index: Int
    let track: TrackInfo
    @ObservedObject var audio: AudioManager

    private var color: Color { Theme.trackColor(index) }

    var body: some View {
        HStack(spacing: 6) {
            Button { audio.toggleTrackPlayback(index) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .frame(width: 28, height: 28)
                    .foregroundColor(track.isPlaying ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: track.isPlaying))

            Button { audio.toggleMute(index) } label: {
                Text("M")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .frame(width: 28, height: 28)
                    .foregroundColor(track.muted ? Theme.bg : Theme.textSecondary)
            }
            .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: track.muted, filled: track.muted))

            Button { audio.toggleSolo(index) } label: {
                Text("S")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .frame(width: 28, height: 28)
                    .foregroundColor(track.solo ? Theme.bg : Theme.textSecondary)
            }
            .buttonStyle(RetroButtonStyle(tint: Color(red: 0x5C/255.0, green: 0xC8/255.0, blue: 0xE0/255.0), active: track.solo, filled: track.solo))

            TrackFader(
                value: Binding(
                    get: { track.volume },
                    set: { audio.setTrackVolume(index, $0) }
                ), color: color,
                onDragStart: { audio.beginUndoGesture() },
                onDragEnd: { audio.endUndoGesture() }
            )
            .frame(width: 80, height: 20)

            Text("\(Int(track.volume * 100))")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)

            Text("L")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Slider(value: Binding(
                get: { track.pan },
                set: { audio.setTrackPan(index, $0) }
            ), in: -1...1) { editing in
                if editing { audio.beginUndoGesture() } else { audio.endUndoGesture() }
            }
            .frame(width: 50)
            .tint(color.opacity(0.6))
            Text("R")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Text(track.pan == 0 ? "C" : (track.pan < 0 ? "L\(Int(abs(track.pan) * 100))" : "R\(Int(track.pan * 100))"))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 32, alignment: .trailing)

            GeometryReader { geo in
                let lvl = index < audio.trackLevels.count ? audio.trackLevels[index] : 0
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.surfaceInset)
                    Rectangle()
                        .fill(lvl > 0.9 ? Theme.danger : color.opacity(0.8))
                        .frame(width: max(0, CGFloat(lvl) * geo.size.width))
                }
            }
            .frame(width: 40, height: 6)
            .cornerRadius(2)
        }
        .padding(.horizontal, 10)
        .frame(width: 410)
    }
}

// ── BarRulerView (scrollable ruler) ───────────────────────────────────────

struct BarRulerView: View {
    @ObservedObject var audio: AudioManager
    let totalBars: Int
    let secsPerBar: Double
    let rulerWidth: CGFloat

    var body: some View {
        let barWidth = rulerWidth / CGFloat(totalBars)

        ZStack(alignment: .leading) {
            ForEach(Array(stride(from: 1, through: totalBars, by: 4)), id: \.self) { bar in
                Text(String(format: "%02d", bar))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .position(x: CGFloat(bar - 1) * barWidth + barWidth / 2, y: 8)
            }

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
        .frame(width: rulerWidth, height: 18)
    }

    private func longestClipBars() -> Int {
        let maxDur = audio.tracks.flatMap(\.clips).map(\.duration).max() ?? 0
        guard maxDur > 0 else { return 0 }
        return Int(ceil(maxDur / secsPerBar))
    }
}

// ── LoopGridView (with ruler, zoom & playhead follow) ─────────────────────

struct LoopGridView: View {
    @ObservedObject var audio: AudioManager

    private var secsPerBar: Double { 240.0 / audio.metronomeBPM }
    private var totalBars: Int {
        let maxDur = audio.tracks.flatMap(\.clips).map(\.duration).max() ?? 0
        let barsFromClips = maxDur > 0 ? Int(ceil(maxDur / secsPerBar)) : 0
        let raw = max(8, barsFromClips + 4)
        return ((raw + 3) / 4) * 4
    }

    // Quantized playhead tick for driving scroll-follow (~20 updates/loop)
    private var playheadTick: Int {
        guard let t = audio.tracks.first(where: { $0.isPlaying && !$0.clips.isEmpty }) else { return 0 }
        return Int(t.loopProgress * 20)
    }

    var body: some View {
        GeometryReader { outerGeo in
            let headerW: CGFloat = 200
            let controlsW: CGFloat = 410
            let hPad: CGFloat = 56
            let availableW = max(outerGeo.size.width - headerW - controlsW - hPad, 100)
            let laneWidth = availableW * CGFloat(audio.timelineZoom)

            HStack(spacing: 0) {
                // ── Fixed left: track headers + zoom/follow controls ──
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Button { audio.zoomOut() } label: {
                            Image(systemName: "minus.magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Text("\(Int(audio.timelineZoom * 100))%")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 36)

                        Button { audio.zoomIn() } label: {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button { audio.playheadFollow.toggle() } label: {
                            Image(systemName: "scope")
                                .font(.system(size: 10))
                                .foregroundColor(audio.playheadFollow ? Theme.accent : Theme.textTertiary)
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(audio.playheadFollow ? "Follow ON (F)" : "Follow OFF (F)")
                    }
                    .frame(width: headerW, height: 18)

                    ForEach(0..<Theme.trackCount, id: \.self) { i in
                        let trk = audio.tracks[i]
                        let anySolo = audio.tracks.contains { $0.solo }
                        let audible = anySolo ? trk.solo : !trk.muted
                        Button(action: { audio.selectedTrack = i }) {
                            HStack(spacing: 10) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(audio.selectedTrack == i ? Theme.danger : Theme.danger.opacity(0.3))
                                        .frame(width: 8, height: 8)
                                    Text(String(format: "%02d", i + 1))
                                        .font(.system(size: 18, weight: .light, design: .monospaced))
                                        .foregroundColor(audio.selectedTrack == i ? Theme.accent : Theme.textTertiary)
                                }
                                Rectangle()
                                    .fill(Theme.trackColor(i))
                                    .frame(width: 2, height: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(!trk.clips.isEmpty ? (trk.clips.last?.name ?? "CLIP") : "TRK \(String(format: "%02d", i + 1))")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .tracking(1.5)
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(!trk.clips.isEmpty ? "TAKE \(trk.clips.count)" : "EMPTY")
                                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                                        .tracking(2)
                                        .foregroundColor(Theme.textTertiary)
                                }
                            }
                            .frame(width: headerW, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(height: 52)
                        .padding(.vertical, 6)
                        .opacity(audible ? 1 : 0.32)
                        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.07)).frame(height: 1), alignment: .bottom)
                    }
                }

                // ── Scrollable middle: ruler + waveform lanes ──
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 0) {
                            BarRulerView(audio: audio, totalBars: totalBars,
                                         secsPerBar: secsPerBar, rulerWidth: laneWidth)

                            ForEach(0..<Theme.trackCount, id: \.self) { i in
                                let trk = audio.tracks[i]
                                let anySolo = audio.tracks.contains { $0.solo }
                                let audible = anySolo ? trk.solo : !trk.muted
                                WaveformLaneView(index: i, track: trk, audio: audio,
                                                 totalBars: totalBars, secsPerBar: secsPerBar,
                                                 laneWidth: laneWidth)
                                    .padding(.vertical, 6)
                                    .opacity(audible ? 1 : 0.32)
                                    .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.07)).frame(height: 1), alignment: .bottom)
                            }

                            // Invisible anchor at the playhead position for scroll-to
                            let phFrac = playheadFraction()
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("playhead_anchor")
                                .offset(x: CGFloat(phFrac) * laneWidth - laneWidth / 2)
                        }
                    }
                    .onChange(of: playheadTick) {
                        guard audio.isPlaying && audio.playheadFollow && audio.timelineZoom > 1.0 else { return }
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo("playhead_anchor", anchor: .center)
                        }
                    }
                    .onChange(of: audio.isPlaying) {
                        if audio.isPlaying && audio.playheadFollow && audio.timelineZoom > 1.0 {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("playhead_anchor", anchor: .center)
                            }
                        }
                    }
                }
                .clipped()

                // ── Fixed right: track controls ──
                VStack(spacing: 0) {
                    Color.clear.frame(height: 18)
                    ForEach(0..<Theme.trackCount, id: \.self) { i in
                        let trk = audio.tracks[i]
                        let anySolo = audio.tracks.contains { $0.solo }
                        let audible = anySolo ? trk.solo : !trk.muted
                        TrackControlsView(index: i, track: trk, audio: audio)
                            .frame(height: 52)
                            .padding(.vertical, 6)
                            .opacity(audible ? 1 : 0.32)
                            .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.07)).frame(height: 1), alignment: .bottom)
                    }
                }
            }
            .padding(.horizontal, 28)
        }
    }

    private func playheadFraction() -> Double {
        guard let t = audio.tracks.first(where: { $0.isPlaying && !$0.clips.isEmpty }),
              let lastClip = t.clips.last else { return 0 }
        let clipBars = lastClip.duration / secsPerBar
        return t.loopProgress * clipBars / Double(totalBars)
    }
}

// ── SideEffectsPanelView (Chain Editor) ─────────────────────────────────────

struct SideEffectsPanelView: View {
    @ObservedObject var audio: AudioManager

    private let slotColors: [Color] = [
        Color(red: 0.9, green: 0.4, blue: 0.3),  // Gate (red)
        Theme.eqColor,                             // EQ
        Color(red: 0.5, green: 0.7, blue: 0.9),   // Compressor (blue)
        Color(red: 0.9, green: 0.6, blue: 0.2),   // Distortion (orange)
        Theme.tapeColor,                           // Tape Sat
        Color(red: 0.4, green: 0.8, blue: 0.7),   // Chorus (teal)
        Color(red: 0.7, green: 0.5, blue: 0.9),   // Flanger (purple)
        Color(red: 0.8, green: 0.5, blue: 0.7),   // Phaser (pink)
        Color(red: 0.6, green: 0.8, blue: 0.5),   // Tremolo (green)
        Color(red: 0.9, green: 0.8, blue: 0.3),   // Bitcrusher (yellow)
        Theme.delayColor,                          // Delay
        Theme.reverbColor,                         // Reverb
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            // Preset bar
            HStack(spacing: 6) {
                Text("PRESET")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(Theme.textTertiary)

                Menu {
                    ForEach(audio.presetNames, id: \.self) { name in
                        Button(name) { audio.loadChainPreset(name: name) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("LOAD")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundColor(Theme.accent)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if audio.showPresetSave {
                    TextField("Name", text: $audio.presetSaveName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 100)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.surfaceInset)
                        .cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                        .onSubmit {
                            let n = audio.presetSaveName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !n.isEmpty { audio.saveChainPreset(name: n) }
                            audio.showPresetSave = false
                            audio.presetSaveName = ""
                        }
                    Button("OK") {
                        let n = audio.presetSaveName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !n.isEmpty { audio.saveChainPreset(name: n) }
                        audio.showPresetSave = false
                        audio.presetSaveName = ""
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.loopGreen)
                    .buttonStyle(.plain)
                } else {
                    Button("SAVE") {
                        audio.showPresetSave = true
                        audio.presetSaveName = ""
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundColor(Theme.loopGreen)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.loopGreen.opacity(0.3), lineWidth: 1))
                    .buttonStyle(.plain)
                }

                Spacer()

                if !audio.presetNames.isEmpty {
                    Menu {
                        ForEach(audio.presetNames, id: \.self) { name in
                            Button(role: .destructive) { audio.deleteChainPreset(name: name) } label: {
                                Label(name, systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)

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
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if index < audio.liveChain.count - 1 {
                        Button { audio.moveSlot(from: index, to: index + 1) } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 24)
                                .foregroundColor(Theme.textTertiary)
                                .contentShape(Rectangle())
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Delete
                Button { audio.removeSlot(at: index) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
                        .foregroundColor(Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

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
            VStack(spacing: 2) {
            HStack(spacing: 6) {
                tpBtn(icon: "arrow.uturn.backward", label: "UNDO",
                      fg: audio.canUndo ? Theme.textPrimary : Theme.textTertiary,
                      border: Theme.textPrimary.opacity(audio.canUndo ? 0.16 : 0.06)) {
                    audio.undo()
                }
                .disabled(!audio.canUndo)
                tpBtn(icon: "arrow.uturn.forward", label: "REDO",
                      fg: audio.canRedo ? Theme.textPrimary : Theme.textTertiary,
                      border: Theme.textPrimary.opacity(audio.canRedo ? 0.16 : 0.06)) {
                    audio.redo()
                }
                .disabled(!audio.canRedo)
                tpBtn(icon: audio.isPlaying ? "pause.fill" : "play.fill",
                      label: audio.isPlaying ? "PAUSE" : "PLAY",
                      fg: audio.isPlaying ? Theme.bg : Theme.accent,
                      bg: audio.isPlaying ? Theme.accent : Color.clear,
                      border: Theme.accent) {
                    if audio.isPlaying { audio.stopAll() } else { audio.playAll() }
                }

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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                tpBtn(icon: "stop.fill", label: "STOP",
                      fg: Theme.textPrimary, border: Theme.textPrimary.opacity(0.16)) { audio.stopAll() }

                Button { audio.clearAll() } label: {
                    Text("CLEAR").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
                        .frame(height: 44).padding(.horizontal, 18)
                        .foregroundColor(Theme.textSecondary)
                        .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { audio.bounceMixdown() } label: {
                    HStack(spacing: 6) {
                        if audio.bounceStatus != nil {
                            ProgressView().controlSize(.small)
                        }
                        Text("MIXDOWN").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
                    }
                    .frame(height: 44).padding(.horizontal, 18)
                    .foregroundColor(Theme.loopGreen)
                    .overlay(Rectangle().stroke(Theme.loopGreen.opacity(0.4), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(audio.bounceStatus != nil)
            }
            // Shortcut hints
            HStack(spacing: 14) {
                Text("\u{2318}Z UNDO").fixedSize()
                Text("SPACE PLAY").fixedSize()
                Text("R REC").fixedSize()
                Text("\u{21A9} STOP").fixedSize()
                Text("M MUTE").fixedSize()
                Text("S SOLO").fixedSize()
                Text("1\u{2013}8 TRK").fixedSize()
                Text(", MET").fixedSize()
                Text("TAB VIEW").fixedSize()
                Text("F FOLLOW").fixedSize()
                Text("\u{2318}+/- ZOOM").fixedSize()
                Text("\u{2318}T SPLIT").fixedSize()
                Text("\u{2318}D DUP").fixedSize()
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundColor(Theme.textTertiary.opacity(0.6))
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

                // Metronome volume
                Slider(value: Binding(
                    get: { audio.metronomeVolume },
                    set: { audio.setMetronomeVolume($0) }
                ), in: 0...1)
                .frame(width: 50)
                .tint(Theme.accent.opacity(0.5))

                // Count-in toggle: cycles 0 → 1 → 2 → 4 → 0
                Button {
                    switch audio.countInBars {
                    case 0: audio.countInBars = 1
                    case 1: audio.countInBars = 2
                    case 2: audio.countInBars = 4
                    default: audio.countInBars = 0
                    }
                } label: {
                    Text(audio.countInBars > 0 ? "\(audio.countInBars)IN" : "CIN")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .frame(width: 44, height: 44)
                        .foregroundColor(audio.countInBars > 0 ? Theme.bg : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: audio.countInBars > 0, filled: audio.countInBars > 0))
                ArcKnob(label: "IN", value: Binding(
                    get: { audio.inputVolume * 100 }, set: { audio.applyInputVolume($0 / 100) }
                ), range: 0...100, color: Theme.textSecondary, size: 38)
                ArcKnob(label: "OUT", value: Binding(
                    get: { audio.volume * 100 }, set: { audio.applyVolume($0 / 100) }
                ), range: 0...100, color: Theme.accent, size: 38)
                Button { audio.toggleMasterLimiter() } label: {
                    Text("LIM")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .frame(width: 36, height: 44)
                        .foregroundColor(audio.masterLimiterEnabled ? Theme.bg : Theme.textTertiary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.loopGreen, active: audio.masterLimiterEnabled, filled: audio.masterLimiterEnabled))
                .help(audio.masterLimiterEnabled ? "Master limiter active" : "Master limiter bypassed")
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
            .contentShape(Rectangle())
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
        HStack(alignment: .top, spacing: 16) {
            // Left: selected track info
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    // Boxed track number — rounded corners
                    Text(String(format: "%02d", audio.selectedTrack + 1))
                        .font(.system(size: 36, weight: .ultraLight, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .frame(width: 64, height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.textPrimary, lineWidth: 1.5))
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
                // Info grid: aligned 2×2 with fixed first column
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 20) {
                        infoItem("INPUT", audio.inputDevices.first { $0.id == audio.selectedInputID }?.name ?? "MBP MIC")
                            .frame(width: 100, alignment: .leading)
                        infoItem("OUTPUT", audio.outputDevices.first { $0.id == audio.selectedOutputID }?.name ?? "MBP SPK")
                    }
                    HStack(spacing: 20) {
                        infoItem("POSITION", "BAR \(barPosition)")
                            .frame(width: 100, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LOOP")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(Theme.textTertiary)
                            Text(audio.loopEnabled ? "BAR 05 \u{2192} 16" : "OFF")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(audio.loopEnabled ? Theme.loopGreen : Theme.textTertiary)
                        }
                    }
                }
            }
            .frame(minWidth: 200, alignment: .leading)
            .layoutPriority(-1)

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
                            .font(.system(size: 48, weight: .ultraLight, design: .monospaced))
                            .foregroundColor(audio.isRecording ? Theme.danger : Theme.textPrimary)
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)

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
                Button(action: { audio.setLoopEnabled(!audio.loopEnabled) }) {
                    Image(systemName: "repeat")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(audio.loopEnabled ? Theme.loopGreen : Theme.textTertiary)
                        .frame(width: 48, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(audio.loopEnabled ? Theme.loopGreen.opacity(0.4) : Theme.textTertiary.opacity(0.3), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)

            // Right: peak + tempo + meters
            HStack(spacing: 16) {
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
                HStack(spacing: 4) {
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
                .frame(height: 160)
            }
            .frame(minWidth: 180, alignment: .trailing)
            .layoutPriority(-1)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { audio.applyTrim() } label: {
                    Text("APPLY")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.bg)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Theme.gold)
                        .contentShape(Rectangle())
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
                                .contentShape(Rectangle())
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                // Clip editing
                VStack(alignment: .leading, spacing: 6) {
                    Text("CLIP EDIT")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)

                    HStack(spacing: 6) {
                        Button { audio.splitClipAtPlayhead(audio.selectedTrack) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "scissors")
                                    .font(.system(size: 9, weight: .bold))
                                Text("SPLIT")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .tracking(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundColor(audio.tracks[audio.selectedTrack].isPlaying && !audio.tracks[audio.selectedTrack].clips.isEmpty ? Theme.accent : Theme.textTertiary)
                            .background(Theme.surfaceInset)
                            .overlay(Rectangle().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!audio.tracks[audio.selectedTrack].isPlaying || audio.tracks[audio.selectedTrack].clips.isEmpty)

                        Button { audio.duplicateClip(audio.selectedTrack) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9, weight: .bold))
                                Text("DUP")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .tracking(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundColor(audio.tracks[audio.selectedTrack].clips.isEmpty ? Theme.textTertiary : Theme.accent)
                            .background(Theme.surfaceInset)
                            .overlay(Rectangle().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(audio.tracks[audio.selectedTrack].clips.isEmpty)
                    }

                    Button { audio.openTrimEditor(audio.selectedTrack) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "timeline.selection")
                                .font(.system(size: 9, weight: .bold))
                            Text("TRIM")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .tracking(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundColor(audio.tracks[audio.selectedTrack].clips.isEmpty ? Theme.textTertiary : Theme.gold)
                        .background(Theme.surfaceInset)
                        .overlay(Rectangle().stroke(Theme.gold.opacity(0.3), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(audio.tracks[audio.selectedTrack].clips.isEmpty)

                    Text("\u{2318}T SPLIT  \u{2318}D DUP")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textTertiary.opacity(0.6))
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

// ── Keyboard Shortcut Monitor ──────────────────────────────────────────────

final class KeyboardShortcutMonitor {
    private var monitor: Any?

    func install(audio: AudioManager) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore when a text field is focused (e.g. BPM entry, pickers)
            if let responder = event.window?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCmd = flags.contains(.command)
            let noMod = flags.isEmpty || flags == .capsLock

            switch event.keyCode {

            // Space — Toggle play/stop (all tracks)
            case 49 where noMod:
                DispatchQueue.main.async {
                    if audio.isPlaying { audio.stopAll() } else { audio.playAll() }
                }
                return nil

            // R — Toggle record on selected track
            case 15 where noMod:
                DispatchQueue.main.async { audio.toggleTrackRecord(audio.selectedTrack) }
                return nil

            // M — Toggle mute on selected track
            case 46 where noMod:
                DispatchQueue.main.async { audio.toggleMute(audio.selectedTrack) }
                return nil

            // S — Toggle solo on selected track
            case 1 where noMod:
                DispatchQueue.main.async { audio.toggleSolo(audio.selectedTrack) }
                return nil

            // 1–8 — Select/arm track (main number row keycodes)
            case 18 where noMod: DispatchQueue.main.async { audio.selectedTrack = 0 }; return nil
            case 19 where noMod: DispatchQueue.main.async { audio.selectedTrack = 1 }; return nil
            case 20 where noMod: DispatchQueue.main.async { audio.selectedTrack = 2 }; return nil
            case 21 where noMod: DispatchQueue.main.async { audio.selectedTrack = 3 }; return nil
            case 23 where noMod: DispatchQueue.main.async { audio.selectedTrack = 4 }; return nil
            case 22 where noMod: DispatchQueue.main.async { audio.selectedTrack = 5 }; return nil
            case 26 where noMod: DispatchQueue.main.async { audio.selectedTrack = 6 }; return nil
            case 28 where noMod: DispatchQueue.main.async { audio.selectedTrack = 7 }; return nil

            // Cmd+Z — Undo
            case 6 where hasCmd && !flags.contains(.shift):
                DispatchQueue.main.async { audio.undo() }
                return nil

            // Cmd+Shift+Z — Redo
            case 6 where hasCmd && flags.contains(.shift):
                DispatchQueue.main.async { audio.redo() }
                return nil

            // Cmd+S — Save project
            case 1 where hasCmd && !flags.contains(.shift):
                DispatchQueue.main.async { audio.saveProject() }
                return nil

            // Cmd+Shift+S — Save project as
            case 1 where hasCmd && flags.contains(.shift):
                DispatchQueue.main.async { audio.saveProjectAs() }
                return nil

            // Cmd+O — Open project
            case 31 where hasCmd:
                DispatchQueue.main.async { audio.openProject() }
                return nil

            // Cmd+E — Export selected track
            case 14 where hasCmd:
                DispatchQueue.main.async { audio.exportTrack(audio.selectedTrack) }
                return nil

            // Cmd+T — Split clip at playhead
            case 17 where hasCmd:
                DispatchQueue.main.async { audio.splitClipAtPlayhead(audio.selectedTrack) }
                return nil

            // Cmd+D — Duplicate last clip on selected track
            case 2 where hasCmd:
                DispatchQueue.main.async { audio.duplicateClip(audio.selectedTrack) }
                return nil

            // Return/Enter — Stop and return to start
            case 36 where noMod, 76 where noMod:
                DispatchQueue.main.async { audio.stopAll() }
                return nil

            // Comma (,) — Toggle metronome
            case 43 where noMod:
                DispatchQueue.main.async { audio.toggleMetronome() }
                return nil

            // Tab — Switch between Arrange and Monitor views
            case 48 where noMod:
                DispatchQueue.main.async { audio.viewMode = audio.viewMode == 0 ? 1 : 0 }
                return nil

            // Cmd+Plus — Zoom in timeline (= key is keyCode 24)
            case 24 where hasCmd:
                DispatchQueue.main.async { audio.zoomIn() }
                return nil

            // Cmd+Minus — Zoom out timeline (- key is keyCode 27)
            case 27 where hasCmd:
                DispatchQueue.main.async { audio.zoomOut() }
                return nil

            // F — Toggle playhead follow
            case 3 where noMod:
                DispatchQueue.main.async { audio.playheadFollow.toggle() }
                return nil

            default:
                return event
            }
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { remove() }
}

// ── Root View ───────────────────────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var audio = AudioManager()
    private let keyMonitor = KeyboardShortcutMonitor()

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

                        LoopGridView(audio: audio)
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
        .onAppear {
            audio.startMonitoring()
            keyMonitor.install(audio: audio)
        }
        .onDisappear {
            keyMonitor.remove()
        }
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
