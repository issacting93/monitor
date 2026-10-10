// ExampleEffect.swift — the smallest possible add-on: a gain knob.
//
// An add-on is a .bundle whose principal class conforms to XYEffectPlugin. It redeclares the two
// protocols below exactly as the app declares them (they are matched by name at load time), so it
// needs nothing from the app to compile.
//
// Build and install (not yet tried on a real machine; treat this as the starting recipe):
//   mkdir -p ExampleGain.bundle/Contents/MacOS
//   swiftc -emit-library -Xlinker -bundle -module-name ExampleGain \
//          -o ExampleGain.bundle/Contents/MacOS/ExampleGain ExampleEffect.swift
//   cp Info.plist ExampleGain.bundle/Contents/Info.plist
//   cp -R ExampleGain.bundle ~/Library/Application\ Support/OPXYMultitrack/Effects/

import AudioToolbox
import Foundation

@objc(XYEffectPlugin) public protocol XYEffectPlugin: NSObjectProtocol {
    var identifier: String { get }
    var displayName: String { get }
    var version: String { get }
    var parameterSpecs: [[String: Any]] { get }
    func makeKernel(sampleRate: Double, channelCount: Int) -> XYEffectPluginKernel
}

@objc(XYEffectPluginKernel) public protocol XYEffectPluginKernel: NSObjectProtocol {
    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frameCount: Int)
    func setParameter(_ id: String, value: Float)
    func reset()
}

@objc(ExampleGainPlugin) public final class ExampleGainPlugin: NSObject, XYEffectPlugin {
    public var identifier: String { "com.example.gain" }       // never change this once projects use it
    public var displayName: String { "Example Gain" }
    public var version: String { "1.0" }
    public var parameterSpecs: [[String: Any]] {
        [["id": "gain", "name": "Gain", "min": -24.0, "max": 12.0, "default": 0.0, "unit": "dB"]]
    }
    public func makeKernel(sampleRate: Double, channelCount: Int) -> XYEffectPluginKernel { ExampleGainKernel() }
}

final class ExampleGainKernel: NSObject, XYEffectPluginKernel {
    private var gain: Float = 1

    func setParameter(_ id: String, value: Float) {
        if id == "gain" { gain = powf(10, value / 20) }
    }

    func reset() {}

    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frameCount { data[i] *= gain }
        }
    }
}
