// CoreAudioDevices.swift — CoreAudio device enumeration/selection helpers
//
// Extracted from the AudioManager mono-file. Pure move, no behaviour change.

#if os(macOS)
import Foundation
import CoreAudio
import AVFoundation

// ── CoreAudio Helpers ───────────────────────────────────────────────────────

let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

func audioAddress(_ selector: AudioObjectPropertySelector,
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

// Remap the AUHAL's output so the engine's audio reaches the *output* device
// inside an input+output aggregate.
//
// The aggregate must list the input sub-device first for AVAudioEngine to expose
// its input (see createAggregateDevice). Channel order in an aggregate follows
// sub-device list order, so when the input device is full-duplex (e.g. the OP-XY
// has 2 in + 2 out) its *output* channels occupy the aggregate's first output
// slots — the engine would then play to the input device, leaving the chosen
// output device silent (meters move, no sound). The channel map re-points the
// engine's output channels at the output device's slots instead.
//
// On the output scope the map has one entry per *device* output channel; each
// entry names the source (unit) channel feeding it, or -1 for silence.
@discardableResult
func routeEngineOutput(_ engine: AVAudioEngine, aggregate: AudioDeviceID, inputDevice: AudioDeviceID) -> Bool {
    guard let unit = engine.outputNode.audioUnit else { return false }
    // Output channels the input sub-device contributes, listed first → the offset
    // at which the output device's own channels begin.
    let offset = deviceChannelCount(inputDevice, input: false)
    guard offset > 0 else { return true }   // input device is not full-duplex: nothing to remap
    let total = deviceChannelCount(aggregate, input: false)
    guard total > offset else { return true }
    var sourceChannels = Int(engine.outputNode.inputFormat(forBus: 0).channelCount)
    if sourceChannels <= 0 { sourceChannels = 2 }
    var map = [Int32](repeating: -1, count: total)
    for i in 0..<sourceChannels where offset + i < total { map[offset + i] = Int32(i) }
    let err = map.withUnsafeBufferPointer { buf in
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap,
                             kAudioUnitScope_Output, 0,
                             buf.baseAddress, UInt32(buf.count * MemoryLayout<Int32>.size))
    }
    return err == noErr
}

func deviceUID(_ id: AudioDeviceID) -> String? {
    var addr = audioAddress(kAudioDevicePropertyDeviceUID)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr,
          let value = uid?.takeRetainedValue() else { return nil }
    return value as String
}

// AVAudioEngine exposes a single AUHAL for input and output, so pinning it to an
// input-only device leaves no output. Build a private aggregate device (input +
// output) and pin the AUHAL to that, so the engine captures from one device and
// plays to another without touching the system default devices.
func createAggregateDevice(input: AudioDeviceID, output: AudioDeviceID) -> AudioDeviceID? {
    guard let inUID = deviceUID(input), let outUID = deviceUID(output) else { return nil }
    // A unique UID per creation: start() tears the previous aggregate down and
    // rebuilds immediately, and reusing the same UID can fail if the HAL hasn't
    // released the old device yet (which would silently drop us to system default I/O).
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Tape 08 IO",
        kAudioAggregateDeviceUIDKey: "com.opxy.tape08.agg.\(inUID)_\(outUID)_\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceIsStackedKey: 0,
        // Clock master = the INPUT device. Many USB interfaces (e.g. the OP-XY) are
        // 44.1 kHz-only, so making the output device (which can run at 48 kHz) the master
        // forces the aggregate to 48 kHz and the drift compensator must continuously
        // resample the input 44.1→48 — an audible tremolo/wobble. Slaving to the input
        // instead lets the whole aggregate run at the input's native rate (the output
        // device supports it), so no resampling is needed.
        kAudioAggregateDeviceMainSubDeviceKey: inUID,
        // Order matters: the input sub-device must be listed FIRST. With the output
        // listed first, AVAudioEngine's inputNode reports 0 channels for the aggregate
        // (verified on macOS 15) — pinning to it then yields "No usable input format".
        // The non-main sub-device (the output) is drift-compensated to the input clock.
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: inUID,  kAudioSubDeviceDriftCompensationKey: 0],
            [kAudioSubDeviceUIDKey: outUID, kAudioSubDeviceDriftCompensationKey: 1],
        ],
    ]
    var aggID = AudioDeviceID(0)
    let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
    return err == noErr ? aggID : nil
}

func destroyAggregateDevice(_ id: AudioDeviceID) {
    AudioHardwareDestroyAggregateDevice(id)
}
#endif
