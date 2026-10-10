// CharacterEffects.swift — the four lo-fi effects as kernels.
//
// These are original, deliberately simple implementations so the plugin path works end to end.
// They are the slots where the Airwindows (MIT) and EffeTune (MIT) ports go: replace the body of
// process() and keep the identifier, and every saved project picks up the new sound.
// Parameters are not smoothed yet, so fast knob moves can zip.

import AVFoundation

private func channel(_ buffers: UnsafeMutableAudioBufferListPointer, _ index: Int) -> UnsafeMutablePointer<Float>? {
    buffers[index].mData?.assumingMemoryBound(to: Float.self)
}

private func dbToGain(_ db: Float) -> Float { powf(10, db / 20) }

// MARK: Tape saturation

final class TapeSaturationKernel: AudioEffectKernel {
    private let sampleRate: Float
    private var drive: Float = 2
    private var coefficient: Float = 1
    private var output: Float = 1
    private var mix: Float = 1
    private var lowpass: (Float, Float) = (0, 0)

    init(sampleRate: Double) { self.sampleRate = Float(sampleRate) }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "drive": drive = dbToGain(value)
        case "tone": coefficient = 1 - expf(-2 * .pi * value * 1000 / sampleRate)
        case "output": output = dbToGain(value)
        case "mix": mix = value / 100
        default: break
        }
    }

    func reset() { lowpass = (0, 0) }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let compensation = 1 / sqrtf(drive)                 // keeps loudness roughly level as drive rises
        for c in 0..<min(buffers.count, 2) {
            guard let data = channel(buffers, c) else { continue }
            var state = c == 0 ? lowpass.0 : lowpass.1
            for i in 0..<frameCount {
                let dry = data[i]
                let shaped = tanhf(dry * drive) * compensation
                state += coefficient * (shaped - state)     // one-pole lowpass: the tape's dull top end
                data[i] = dry * (1 - mix) + state * output * mix
            }
            if c == 0 { lowpass.0 = state } else { lowpass.1 = state }
        }
    }
}

enum TapeSaturation: AudioEffectModule {
    static let identifier = "com.opxy.tape-saturation"
    static let displayName = "Tape"
    static let version = "0.1"
    static let parameters = [
        EffectParameter(id: "drive", name: "Drive", min: 0, max: 24, defaultValue: 6, unit: "dB"),
        EffectParameter(id: "tone", name: "Tone", min: 1, max: 20, defaultValue: 12, unit: "kHz"),
        EffectParameter(id: "output", name: "Output", min: -12, max: 6, defaultValue: 0, unit: "dB"),
        EffectParameter(id: "mix", name: "Mix", min: 0, max: 100, defaultValue: 100, unit: "%"),
    ]
    static func makeKernel(sampleRate: Double, channelCount: Int) -> AudioEffectKernel {
        TapeSaturationKernel(sampleRate: sampleRate)
    }
}

// MARK: Bitcrusher

final class BitcrusherKernel: AudioEffectKernel {
    private var levels: Float = 512
    private var hold = 4
    private var mix: Float = 1
    private var held: (Float, Float) = (0, 0)
    private var counter: (Int, Int) = (0, 0)

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "bits": levels = powf(2, value.rounded() - 1)
        case "rate": hold = max(1, Int(value.rounded()))
        case "mix": mix = value / 100
        default: break
        }
    }

    func reset() { held = (0, 0); counter = (0, 0) }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        for c in 0..<min(buffers.count, 2) {
            guard let data = channel(buffers, c) else { continue }
            var value = c == 0 ? held.0 : held.1
            var count = c == 0 ? counter.0 : counter.1
            for i in 0..<frameCount {
                if count <= 0 {                              // sample-and-hold: the rate reduction
                    value = (data[i] * levels).rounded() / levels
                    count = hold
                }
                count -= 1
                data[i] = data[i] * (1 - mix) + value * mix
            }
            if c == 0 { held.0 = value; counter.0 = count } else { held.1 = value; counter.1 = count }
        }
    }
}

enum Bitcrusher: AudioEffectModule {
    static let identifier = "com.opxy.bitcrusher"
    static let displayName = "Crush"
    static let version = "0.1"
    static let parameters = [
        EffectParameter(id: "bits", name: "Bits", min: 2, max: 16, defaultValue: 10, unit: "bit"),
        EffectParameter(id: "rate", name: "Downsample", min: 1, max: 40, defaultValue: 4, unit: "x"),
        EffectParameter(id: "mix", name: "Mix", min: 0, max: 100, defaultValue: 100, unit: "%"),
    ]
    static func makeKernel(sampleRate: Double, channelCount: Int) -> AudioEffectKernel { BitcrusherKernel() }
}

// MARK: Wow and flutter

final class WowFlutterKernel: AudioEffectKernel {
    private let sampleRate: Float
    private let size = 8192
    private let line: UnsafeMutablePointer<Float>            // two delay lines, back to back
    private var writeIndex = 0
    private var wowPhase: Float = 0
    private var flutterPhase: Float = 0
    private var wowDepth: Float = 0
    private var wowRate: Float = 0.6
    private var flutterDepth: Float = 0
    private var flutterRate: Float = 9

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        line = .allocate(capacity: size * 2)
        line.initialize(repeating: 0, count: size * 2)
    }

    deinit { line.deallocate() }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "wow": wowDepth = value / 100 * 0.003 * sampleRate           // up to 3 ms of swing
        case "wowRate": wowRate = value
        case "flutter": flutterDepth = value / 100 * 0.0004 * sampleRate  // up to 0.4 ms
        case "flutterRate": flutterRate = value
        default: break
        }
    }

    func reset() {
        line.update(repeating: 0, count: size * 2)
        writeIndex = 0
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let channels = min(buffers.count, 2)
        guard channels > 0 else { return }
        let base = 0.005 * sampleRate                                      // 5 ms centre delay
        let wowStep = 2 * Float.pi * wowRate / sampleRate
        let flutterStep = 2 * Float.pi * flutterRate / sampleRate
        let mask = size - 1
        for i in 0..<frameCount {
            let delay = base + sinf(wowPhase) * wowDepth + sinf(flutterPhase) * flutterDepth
            wowPhase += wowStep
            flutterPhase += flutterStep
            if wowPhase > 2 * .pi { wowPhase -= 2 * .pi }
            if flutterPhase > 2 * .pi { flutterPhase -= 2 * .pi }

            let position = Float(writeIndex) - max(1, delay)
            let whole = position.rounded(.down)
            let fraction = position - whole
            let a = (Int(whole) + size) & mask
            let b = (a + 1) & mask
            for c in 0..<channels {
                guard let data = channel(buffers, c) else { continue }
                let lineC = line + c * size
                lineC[writeIndex] = data[i]
                data[i] = lineC[a] + (lineC[b] - lineC[a]) * fraction      // read between two samples
            }
            writeIndex = (writeIndex + 1) & mask
        }
    }
}

enum WowFlutter: AudioEffectModule {
    static let identifier = "com.opxy.wow-flutter"
    static let displayName = "Wow & Flutter"
    static let version = "0.1"
    static let parameters = [
        EffectParameter(id: "wow", name: "Wow", min: 0, max: 100, defaultValue: 30, unit: "%"),
        EffectParameter(id: "wowRate", name: "Wow Rate", min: 0.1, max: 4, defaultValue: 0.6, unit: "Hz"),
        EffectParameter(id: "flutter", name: "Flutter", min: 0, max: 100, defaultValue: 20, unit: "%"),
        EffectParameter(id: "flutterRate", name: "Flut Rate", min: 4, max: 20, defaultValue: 9, unit: "Hz"),
    ]
    static func makeKernel(sampleRate: Double, channelCount: Int) -> AudioEffectKernel {
        WowFlutterKernel(sampleRate: sampleRate)
    }
}

// MARK: Hiss

final class NoiseKernel: AudioEffectKernel {
    private let sampleRate: Float
    private var level: Float = 0.003
    private var coefficient: Float = 0.5
    private var seed: UInt32 = 22_222
    private var lowpass: (Float, Float) = (0, 0)

    init(sampleRate: Double) { self.sampleRate = Float(sampleRate) }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "level": level = dbToGain(value)
        case "tone": coefficient = 1 - expf(-2 * .pi * value * 1000 / sampleRate)
        default: break
        }
    }

    func reset() { lowpass = (0, 0) }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        for c in 0..<min(buffers.count, 2) {
            guard let data = channel(buffers, c) else { continue }
            var state = c == 0 ? lowpass.0 : lowpass.1
            for i in 0..<frameCount {
                seed = seed &* 1_664_525 &+ 1_013_904_223           // cheap random numbers, safe on the audio thread
                let white = Float(seed >> 8) / 8_388_608 - 1        // -1 ... 1
                state += coefficient * (white - state)
                data[i] += state * level
            }
            if c == 0 { lowpass.0 = state } else { lowpass.1 = state }
        }
    }
}

enum Noise: AudioEffectModule {
    static let identifier = "com.opxy.hiss"
    static let displayName = "Hiss"
    static let version = "0.1"
    static let parameters = [
        EffectParameter(id: "level", name: "Level", min: -80, max: -20, defaultValue: -50, unit: "dB"),
        EffectParameter(id: "tone", name: "Tone", min: 1, max: 20, defaultValue: 6, unit: "kHz"),
    ]
    static func makeKernel(sampleRate: Double, channelCount: Int) -> AudioEffectKernel {
        NoiseKernel(sampleRate: sampleRate)
    }
}
