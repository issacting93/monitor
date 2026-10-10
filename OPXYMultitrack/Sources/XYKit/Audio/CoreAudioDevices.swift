// CoreAudioDevices.swift — device listing, default-input switching and latency queries.
// Ported from the helpers in monitor_ui.swift.

import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
}

public enum CoreAudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    public static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { AudioDevice(id: $0, name: name($0)) }
    }

    public static func inputs() -> [AudioDevice] { all().filter { channelCount($0.id, input: true) > 0 } }

    public static func name(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr,
              let value = ref?.takeRetainedValue() else { return "Unknown" }
        return value as String
    }

    public static func channelCount(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice
                                 : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr,
              id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    public static func setDefaultInput(_ id: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = id
        AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device)
    }

    /// Calls back on the main queue whenever a device is plugged in or removed.
    public static func onDeviceListChange(_ handler: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in handler() }
    }

    // MARK: Latency

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    public static func sampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    /// What one side of a device reports: its own latency, its safety offset and one I/O buffer.
    public static func latencySeconds(_ id: AudioDeviceID, input: Bool) -> Double {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        let rate = sampleRate(id)
        guard rate > 0 else { return 0 }
        let frames = uint32(id, kAudioDevicePropertyLatency, scope)
                   + uint32(id, kAudioDevicePropertySafetyOffset, scope)
                   + uint32(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        return Double(frames) / rate
    }
}
