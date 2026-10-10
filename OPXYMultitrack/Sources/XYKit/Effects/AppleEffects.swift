// AppleEffects.swift — Apple's built-in units presented as chain slots.
// These do the transparent work (EQ, reverb, delay) for free; the character effects are in CharacterEffects.swift.

import AVFoundation

private let reverbPresets: [(String, AVAudioUnitReverbPreset)] = [
    ("Small Room", .smallRoom), ("Medium Room", .mediumRoom), ("Large Room", .largeRoom),
    ("Medium Hall", .mediumHall), ("Large Hall", .largeHall), ("Plate", .plate),
    ("Med Chamber", .mediumChamber), ("Lg Chamber", .largeChamber), ("Cathedral", .cathedral),
]

private final class EQInstance: EffectInstance {
    let eq = AVAudioUnitEQ(numberOfBands: 3)
    var node: AVAudioNode { eq }

    init() {
        let b = eq.bands
        b[0].filterType = .lowShelf;   b[0].frequency = 200;  b[0].bypass = false
        b[1].filterType = .parametric; b[1].frequency = 1000; b[1].bandwidth = 1; b[1].bypass = false
        b[2].filterType = .highShelf;  b[2].frequency = 8000; b[2].bypass = false
    }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "low": eq.bands[0].gain = value
        case "mid": eq.bands[1].gain = value
        case "high": eq.bands[2].gain = value
        default: break
        }
    }

    func setBypass(_ bypass: Bool) { eq.bypass = bypass }
}

private final class ReverbInstance: EffectInstance {
    let reverb = AVAudioUnitReverb()
    private var mix: Float = 30
    var node: AVAudioNode { reverb }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "preset":
            let index = min(max(Int(value.rounded()), 0), reverbPresets.count - 1)
            reverb.loadFactoryPreset(reverbPresets[index].1)
            reverb.wetDryMix = mix                         // loading a preset resets the mix
        case "mix":
            mix = value
            reverb.wetDryMix = value
        default: break
        }
    }

    func setBypass(_ bypass: Bool) { reverb.bypass = bypass }
}

private final class DelayInstance: EffectInstance {
    let delay = AVAudioUnitDelay()
    var node: AVAudioNode { delay }

    init() { delay.lowPassCutoff = 15_000 }

    func setParameter(_ id: String, value: Float) {
        switch id {
        case "time": delay.delayTime = TimeInterval(value) / 1000
        case "feedback": delay.feedback = value
        case "mix": delay.wetDryMix = value
        default: break
        }
    }

    func setBypass(_ bypass: Bool) { delay.bypass = bypass }
}

enum AppleEffects {
    static let descriptors: [EffectDescriptor] = [
        EffectDescriptor(
            id: "com.apple.eq3", name: "EQ", version: "1", category: "Utility",
            parameters: [
                EffectParameter(id: "low", name: "Low", min: -12, max: 12, defaultValue: 0, unit: "dB"),
                EffectParameter(id: "mid", name: "Mid", min: -12, max: 12, defaultValue: 0, unit: "dB"),
                EffectParameter(id: "high", name: "High", min: -12, max: 12, defaultValue: 0, unit: "dB"),
            ],
            make: { _ in EQInstance() }),
        EffectDescriptor(
            id: "com.apple.reverb", name: "Reverb", version: "1", category: "Utility",
            parameters: [
                EffectParameter(id: "preset", name: "Preset", min: 0, max: Float(reverbPresets.count - 1),
                                defaultValue: 3, choices: reverbPresets.map(\.0)),
                EffectParameter(id: "mix", name: "Mix", min: 0, max: 100, defaultValue: 30, unit: "%"),
            ],
            make: { _ in ReverbInstance() }),
        EffectDescriptor(
            id: "com.apple.delay", name: "Delay", version: "1", category: "Utility",
            parameters: [
                EffectParameter(id: "time", name: "Time", min: 10, max: 1000, defaultValue: 250, unit: "ms"),
                EffectParameter(id: "feedback", name: "Feedback", min: 0, max: 80, defaultValue: 30, unit: "%"),
                EffectParameter(id: "mix", name: "Mix", min: 0, max: 100, defaultValue: 25, unit: "%"),
            ],
            make: { _ in DelayInstance() }),
    ]
}
