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

// Raise a device's IO buffer to at least `floor` frames. CoreAudio negotiates the IO
// buffer per device: a USB mic often reports a much smaller buffer (e.g. 128 frames)
// than a hardwired interface (512). The render graph here (input → dry tap → FX chain
// → live mixer → master → limiter, plus 8 track players, the metronome and 11 taps)
// can miss its deadline at a small buffer, which is audible as periodic stuttering.
// Devices already at or above the floor are left untouched; failures are ignored.
func ensureMinimumIOBufferFrames(_ id: AudioDeviceID, floor: UInt32 = 512) {
    var addr = audioAddress(kAudioDevicePropertyBufferFrameSize)
    var current: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &current) == noErr,
          current > 0, current < floor else { return }
    var want = floor
    AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &want)
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

func currentSampleRate(_ id: AudioDeviceID) -> Double {
    var addr = audioAddress(kAudioDevicePropertyNominalSampleRate)
    var rate: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
    return rate
}

func setSampleRate(_ id: AudioDeviceID, _ rate: Double) {
    guard rate > 0 else { return }
    var addr = audioAddress(kAudioDevicePropertyNominalSampleRate)
    var r = rate
    AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &r)
}

/// Whether a device can run at `rate`. A device advertises its rates as ranges, so a
/// single entry may cover a span; a rate inside any advertised range counts.
func deviceSupportsSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
    guard rate > 0 else { return false }
    var addr = audioAddress(kAudioDevicePropertyAvailableNominalSampleRates)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let count = Int(size) / MemoryLayout<AudioValueRange>.size
    var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return false }
    return ranges.contains { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 }
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

    // Clock master selection. The aggregate runs at the master's rate, and the other
    // sub-device is drift-compensated (continuously resampled). Default is the INPUT:
    // many USB interfaces (e.g. the OP-XY) are 44.1 kHz-only, so slaving to the input
    // lets the whole aggregate run at its native rate with no input resampling.
    //
    // But that default breaks the mirror case — a mic (typically 48 kHz, flexible) as
    // input with a rate-constrained output (the OP-XY, 44.1 kHz-only). Forcing the
    // aggregate to 48 kHz then makes the HAL resample the output continuously, which is
    // audible as stuttering. So: if the output can't run at the input's rate while the
    // input CAN follow the output's rate, promote the OUTPUT to clock master instead.
    let inRate = currentSampleRate(input)
    var masterUID  = inUID
    var masterRate = inRate
    if inRate > 0, !deviceSupportsSampleRate(output, inRate) {
        let outRate = currentSampleRate(output)
        if outRate > 0, deviceSupportsSampleRate(input, outRate) {
            masterUID  = outUID
            masterRate = outRate
        }
    }

    // A unique UID per creation: start() tears the previous aggregate down and
    // rebuilds immediately, and reusing the same UID can fail if the HAL hasn't
    // released the old device yet (which would silently drop us to system default I/O).
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Tape 08 IO",
        kAudioAggregateDeviceUIDKey: "com.opxy.tape08.agg.\(inUID)_\(outUID)_\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceIsStackedKey: 0,
        kAudioAggregateDeviceMainSubDeviceKey: masterUID,
        // Order matters: the input sub-device must be listed FIRST. With the output
        // listed first, AVAudioEngine's inputNode reports 0 channels for the aggregate
        // (verified on macOS 15) — pinning to it then yields "No usable input format".
        // Only the non-master sub-device is drift-compensated to the master clock.
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: inUID,  kAudioSubDeviceDriftCompensationKey: masterUID == inUID ? 0 : 1],
            [kAudioSubDeviceUIDKey: outUID, kAudioSubDeviceDriftCompensationKey: masterUID == outUID ? 0 : 1],
        ],
    ]
    var aggID = AudioDeviceID(0)
    let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
    guard err == noErr else { return nil }
    // Pin the aggregate to the master's rate so it can't default to a rate the other
    // sub-device would have to resample against.
    setSampleRate(aggID, masterRate)
    return aggID
}

func destroyAggregateDevice(_ id: AudioDeviceID) {
    AudioHardwareDestroyAggregateDevice(id)
}
#endif
