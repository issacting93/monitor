// EffectAPI.swift — the contract every effect meets, built in or downloaded.
//
// Three layers:
//   AudioEffectKernel   the DSP. Processes audio in place. Knows nothing about the app.
//   AudioEffectModule   describes a kernel: stable ID, name, version, parameters, and how to make one.
//   EffectDescriptor    what the registry hands the rest of the app. Apple's units and kernel-based
//                       modules both end up as one of these, so the chain treats them the same.

import AVFoundation

public struct EffectParameter: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var min: Float
    public var max: Float
    public var defaultValue: Float
    public var unit: String = ""
    /// For stepped parameters (a preset list): one label per whole-number value starting at `min`.
    public var choices: [String]? = nil

    public init(id: String, name: String, min: Float, max: Float, defaultValue: Float, unit: String = "", choices: [String]? = nil) {
        self.id = id; self.name = name; self.min = min; self.max = max
        self.defaultValue = defaultValue; self.unit = unit; self.choices = choices
    }
}

protocol AudioEffectKernel: AnyObject {
    /// Called on the audio thread. Process in place. No allocation, no locks, no Swift arrays that can grow.
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int)
    /// Called on the main thread while audio runs. Store the value in a plain field the audio thread reads.
    func setParameter(_ id: String, value: Float)
    func reset()
}

protocol AudioEffectModule {
    /// Stable forever: projects store this string. Reverse-DNS, e.g. "com.you.tape-saturation".
    static var identifier: String { get }
    static var displayName: String { get }
    static var version: String { get }
    static var parameters: [EffectParameter] { get }
    static func makeKernel(sampleRate: Double, channelCount: Int) -> AudioEffectKernel
}

/// A live effect sitting in an engine graph.
public protocol EffectInstance: AnyObject {
    var node: AVAudioNode { get }
    func setParameter(_ id: String, value: Float)
    func setBypass(_ bypass: Bool)
}

public struct EffectDescriptor: Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let category: String
    public let parameters: [EffectParameter]
    public let make: (AVAudioFormat) -> EffectInstance?

    public init(id: String, name: String, version: String, category: String, parameters: [EffectParameter], make: @escaping (AVAudioFormat) -> EffectInstance?) {
        self.id = id; self.name = name; self.version = version; self.category = category
        self.parameters = parameters; self.make = make
    }

    public func parameter(_ id: String) -> EffectParameter? { parameters.first { $0.id == id } }
}

extension EffectSlot {
    func value(for parameter: EffectParameter) -> Float {
        values[parameter.id] ?? parameter.defaultValue
    }
}
