// monitor.swift — pass a USB audio input (e.g. OP-XY) through to the Mac's current output.
//
// Run:    swift monitor.swift            (looks for an input whose name contains "XY")
//         swift monitor.swift "OP-1"     (or match a different device name)
// Stop:   Ctrl+C (restores previous default input)
//
// Instead of pinning the engine's audio unit to a device (which can silently
// redirect the output), this sets the OP-XY as the Mac's default input while
// running and lets AVAudioEngine use system defaults for both sides.

import AVFoundation
import CoreAudio
import Darwin

// ── CoreAudio helpers ───────────────────────────────────────────────────────

let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func name(of id: AudioDeviceID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var cfName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName) == noErr,
          let value = cfName?.takeRetainedValue() else { return "(unknown)" }
    return value as String
}

func channelCount(of id: AudioDeviceID, input: Bool) -> Int {
    let scope: AudioObjectPropertyScope = input
        ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func getDefaultDevice(input: Bool) -> AudioDeviceID {
    let sel: AudioObjectPropertySelector = input
        ? kAudioHardwarePropertyDefaultInputDevice
        : kAudioHardwarePropertyDefaultOutputDevice
    var addr = address(sel)
    var id: AudioDeviceID = 0
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &sz, &id)
    return id
}

func setDefaultDevice(_ id: AudioDeviceID, input: Bool) {
    let sel: AudioObjectPropertySelector = input
        ? kAudioHardwarePropertyDefaultInputDevice
        : kAudioHardwarePropertyDefaultOutputDevice
    var addr = address(sel)
    var dev = id
    AudioObjectSetPropertyData(system, &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}

func deviceOnUnit(_ au: AudioUnit) -> AudioDeviceID {
    var id: AudioDeviceID = 0
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                         kAudioUnitScope_Global, 0, &id, &sz)
    return id
}

// ── Find the input device ───────────────────────────────────────────────────

let query = CommandLine.arguments.dropFirst().first ?? "XY"
let inputs = allDevices().filter { channelCount(of: $0, input: true) > 0 }

guard let device = inputs.first(where: { name(of: $0).localizedCaseInsensitiveContains(query) }) else {
    print("No audio input matching \"\(query)\". Inputs found:")
    inputs.forEach { print("  - \(name(of: $0))") }
    exit(1)
}

// ── Check output isn't the same device ──────────────────────────────────────

let currentOutput = getDefaultDevice(input: false)
print("Input device:  \(name(of: device))")
print("Output device: \(name(of: currentOutput))")

if currentOutput == device {
    print("")
    print("ERROR: The Mac's output is set to \(name(of: device)).")
    print("Audio would loop back to the same device. Change the output in")
    print("System Settings > Sound > Output to speakers or headphones first.")
    exit(1)
}

// ── Set OP-XY as system default input (restored on exit) ────────────────────

let previousInput = getDefaultDevice(input: true)
setDefaultDevice(device, input: true)
print("Set default input: \(name(of: previousInput)) → \(name(of: device))")

func restore() {
    setDefaultDevice(previousInput, input: true)
    print("\nRestored default input: \(name(of: previousInput))")
}

// Handle Ctrl+C
signal(SIGINT) { _ in
    restore()
    exit(0)
}

// ── Build and start engine ──────────────────────────────────────────────────

let engine = AVAudioEngine()

// No AudioUnitSetProperty — the engine uses system defaults for both sides.
let inFmt = engine.inputNode.inputFormat(forBus: 0)
let inFormat = AVAudioFormat(standardFormatWithSampleRate: inFmt.sampleRate,
                             channels: inFmt.channelCount) ?? inFmt

guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
    print("Input has no usable format. Check microphone permission for Terminal")
    print("in System Settings > Privacy & Security.")
    restore()
    exit(1)
}

engine.connect(engine.inputNode, to: engine.mainMixerNode, format: inFormat)
engine.mainMixerNode.outputVolume = 1.0
engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

// Report actual devices on the engine's audio units
if let inAU = engine.inputNode.audioUnit, let outAU = engine.outputNode.audioUnit {
    let inDev  = deviceOnUnit(inAU)
    let outDev = deviceOnUnit(outAU)
    print("Engine units:  input=\(name(of: inDev))  output=\(name(of: outDev))")
}

do {
    try engine.start()
} catch {
    print("Could not start audio: \(error.localizedDescription)")
    restore()
    exit(1)
}

let outFmt = engine.outputNode.inputFormat(forBus: 0)
print("Monitoring \(name(of: device)) (\(Int(inFormat.sampleRate)) Hz) → \(name(of: currentOutput)) (\(Int(outFmt.sampleRate)) Hz)")
print("Ctrl+C to stop.")
print("")

// ── Live level meter ────────────────────────────────────────────────────────

var peakLevel: Float = 0

engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
    guard let ch = buf.floatChannelData?[0] else { return }
    var peak: Float = 0
    for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
    peakLevel = peak
}

Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
    let level = peakLevel
    let db = level > 0 ? 20 * log10(level) : -60.0 as Float
    let scaled = max(0.0, min(1.0, (db + 60.0) / 60.0))
    let barLen = Int(scaled * 40.0)
    let bar = String(repeating: "█", count: barLen) + String(repeating: "░", count: 40 - barLen)
    let dbStr = level > 0 ? String(format: "%+.1f dB", db) : "  -∞ dB"
    print("\r  [\(bar)] \(dbStr)  ", terminator: "")
    fflush(stdout)
}

RunLoop.main.run()
