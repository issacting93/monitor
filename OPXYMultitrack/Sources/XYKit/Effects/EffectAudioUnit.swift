// EffectAudioUnit.swift — the one audio unit that hosts any kernel.
// Written once; every kernel-based effect, built in or downloaded, runs inside an instance of it.

import AVFoundation
import AudioToolbox

final class EffectAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCC("xyfx"),
        componentManufacturer: fourCC("OPXY"),
        componentFlags: 0,
        componentFlagsMask: 0)

    private static var registered = false

    /// Tell the system this subclass exists. In-process only; nothing is installed on the machine.
    static func registerIfNeeded() {
        guard !registered else { return }
        AUAudioUnit.registerSubclass(EffectAudioUnit.self, as: componentDescription,
                                     name: "OPXY: Effect Host", version: 1)
        registered = true
    }

    /// Everything the render block touches, kept in one object so the block never captures `self`.
    final class RenderState {
        var kernel: AudioEffectKernel?
        var buffer: AVAudioPCMBuffer?
        var bypass = false
    }

    let state = RenderState()
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        state.buffer = AVAudioPCMBuffer(pcmFormat: inputBus.format, frameCapacity: maximumFramesToRender)
        state.kernel?.reset()
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        state.buffer = nil
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = self.state
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock, let buffer = state.buffer, let storage = buffer.floatChannelData else {
                return kAudioUnitErr_NoConnection
            }
            guard frameCount <= buffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }

            // 1. Pull the upstream audio into our own buffer.
            let byteSize = frameCount * UInt32(MemoryLayout<Float>.size)
            let inputList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for i in 0..<inputList.count {
                inputList[i].mData = UnsafeMutableRawPointer(storage[i])
                inputList[i].mDataByteSize = byteSize
            }
            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, buffer.mutableAudioBufferList)
            if status != noErr { return status }

            // 2. Hand it to the output: point at it when the host gave us no memory, copy otherwise.
            let outputList = UnsafeMutableAudioBufferListPointer(outputData)
            guard inputList.count > 0 else { return noErr }
            for i in 0..<outputList.count {
                let source = inputList[min(i, inputList.count - 1)].mData
                if let destination = outputList[i].mData {
                    if let source, source != destination { memcpy(destination, source, Int(byteSize)) }
                } else {
                    outputList[i].mData = source
                }
                outputList[i].mDataByteSize = byteSize
            }

            // 3. Let the kernel work on the output in place.
            if !state.bypass, let kernel = state.kernel {
                kernel.process(outputList, frameCount: Int(frameCount))
            }
            return noErr
        }
    }
}

func fourCC(_ string: String) -> FourCharCode {
    string.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}

/// A kernel wrapped in an EffectAudioUnit and attached to an engine as an ordinary node.
final class KernelEffectInstance: EffectInstance {
    private let unit: AVAudioUnitEffect
    private let state: EffectAudioUnit.RenderState?
    var node: AVAudioNode { unit }

    init(kernel: AudioEffectKernel) {
        EffectAudioUnit.registerIfNeeded()
        unit = AVAudioUnitEffect(audioComponentDescription: EffectAudioUnit.componentDescription)
        state = (unit.auAudioUnit as? EffectAudioUnit)?.state
        state?.kernel = kernel
        if state == nil { print("[Effects] EffectAudioUnit did not load; this slot will pass audio through") }
    }

    func setParameter(_ id: String, value: Float) { state?.kernel?.setParameter(id, value: value) }
    func setBypass(_ bypass: Bool) { state?.bypass = bypass }
}

extension EffectDescriptor {
    /// Wrap a kernel-based module so the chain can use it like any other effect.
    init(module: AudioEffectModule.Type, category: String) {
        self.init(id: module.identifier, name: module.displayName, version: module.version,
                  category: category, parameters: module.parameters) { format in
            let kernel = module.makeKernel(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
            for p in module.parameters { kernel.setParameter(p.id, value: p.defaultValue) }
            return KernelEffectInstance(kernel: kernel)
        }
    }
}
