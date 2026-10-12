// DeviceIO_macOS.swift — CoreAudio HAL implementation of AudioDeviceProviding

#if os(macOS)
import Foundation
import CoreAudio
import AVFoundation

final class CoreAudioDeviceProvider: AudioDeviceProviding {
    var outputSelectionSupported: Bool { true }
    var defaultOutputID: DeviceID? {
        let id = getDefaultAudioDevice(input: false); return id != 0 ? id : nil
    }
    var currentOutputName: String { nameOfDevice(getDefaultAudioDevice(input: false)) }

    func prepareForEngineStart() throws {}
    func releaseAfterEngineStop() {}

    func loadDevices() -> (inputs: [AudioDevice], outputs: [AudioDevice]) {
        let ids = allAudioDevices().filter { !isOwnAggregate($0) }
        let inputs = ids.filter { deviceChannelCount($0, input: true) > 0 }
                        .map { AudioDevice(id: $0, name: nameOfDevice($0)) }
        let outputs = ids.filter { deviceChannelCount($0, input: false) > 0 }
                         .map { AudioDevice(id: $0, name: nameOfDevice($0)) }
        return (inputs, outputs)
    }

    func displayName(for id: DeviceID) -> String { nameOfDevice(id) }

    private var aggregateID: AudioDeviceID?

    /// The private aggregate we build for split input/output is visible to the HAL
    /// from this process, so it must not appear in the app's own device pickers.
    private func isOwnAggregate(_ id: AudioDeviceID) -> Bool {
        if id == aggregateID { return true }
        return deviceUID(id)?.hasPrefix("com.opxy.tape08.agg.") ?? false
    }

    func applyEngineDevices(input: DeviceID, output: DeviceID?, to engine: AVAudioEngine) -> String? {
        releaseEngineDevice()
        // The engine has one shared AUHAL. If input and output differ, pin it to a
        // private aggregate device (input + output) so both work. If the aggregate
        // can't be built, leave the AUHAL at the system default rather than pinning
        // it at an input-only device (which would leave no usable output) — but
        // report it, so the silent "monitoring the wrong device" case can't recur.
        guard let out = output, out != input else {
            setEngineInputDevice(engine, input)
            ensureMinimumIOBufferFrames(input)
            return nil
        }
        guard let agg = createAggregateDevice(input: input, output: out) else {
            return "Couldn't route \(nameOfDevice(input)) → \(nameOfDevice(out)) — using system default I/O"
        }
        aggregateID = agg
        // An input-only device (a mic) forces this aggregate path; its small default
        // buffer can starve the graph and stutter. Raise it before the engine starts.
        ensureMinimumIOBufferFrames(agg)
        setEngineInputDevice(engine, agg)
        // The input sub-device is listed first (required for input to appear), so a
        // full-duplex input device's output channels sit first in the aggregate and the
        // engine would play to the input device, not the chosen output. Remap the AUHAL's
        // output onto the output device's channels.
        if !routeEngineOutput(engine, aggregate: agg, inputDevice: input) {
            return "Monitoring through \(nameOfDevice(input)) — couldn't route output to \(nameOfDevice(out))"
        }
        return nil
    }

    func releaseEngineDevice() {
        if let agg = aggregateID { destroyAggregateDevice(agg); aggregateID = nil }
    }

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
