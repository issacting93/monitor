// EffectsKernels.swift — built-in custom DSP kernels
//
// Passthrough, tape saturation, gain, distortion, chorus, compressor,
// flanger, phaser, tremolo, bitcrusher, and noise gate.
//
// Extracted from the AudioManager mono-file. Pure move, no behaviour change.

import Foundation
import AVFoundation
import Darwin

final class PassthroughKernel: AudioEffectKernel {
    required init(sampleRate: Double) {}
    func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {}
    func setParameter(_ id: String, value: Float) {}
    func reset() {}
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
