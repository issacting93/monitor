// DeviceIO_macOS.swift — CoreAudio HAL implementation of AudioDeviceProviding

#if os(macOS)
import Foundation
import CoreAudio
import AVFoundation

final class CoreAudioDeviceProvider: AudioDeviceProviding {
    var outputSelectionSupported: Bool { true }
    var currentOutputName: String { nameOfDevice(getDefaultAudioDevice(input: false)) }

    func prepareForEngineStart() throws {}
    func releaseAfterEngineStop() {}

    func loadDevices() -> (inputs: [AudioDevice], outputs: [AudioDevice]) {
        let ids = allAudioDevices()
        let inputs = ids.filter { deviceChannelCount($0, input: true) > 0 }
                        .map { AudioDevice(id: $0, name: nameOfDevice($0)) }
        let outputs = ids.filter { deviceChannelCount($0, input: false) > 0 }
                         .map { AudioDevice(id: $0, name: nameOfDevice($0)) }
        return (inputs, outputs)
    }

    func displayName(for id: DeviceID) -> String { nameOfDevice(id) }

    func applyInputDevice(_ id: DeviceID, to engine: AVAudioEngine) { setEngineInputDevice(engine, id) }

    func applyOutputDevice(_ id: DeviceID) {}

    // Listeners are intentionally never removed (the process lives as long as the
    // app window); rebuilding the graph on every device change would be worse.
    func startObserving(_ onChange: @escaping (DeviceChange) -> Void) {
        var devAddr = audioAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &devAddr, DispatchQueue.main) { _, _ in
            onChange(.listChanged)
        }
        var outAddr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &outAddr, DispatchQueue.main) { _, _ in
            onChange(.listChanged)
        }
    }

    func stopObserving() {}
}
#endif
