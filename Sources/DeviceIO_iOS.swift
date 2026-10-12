// DeviceIO_iOS.swift — AVAudioSession implementation of AudioDeviceProviding

#if os(iOS)
import Foundation
import AVFoundation

// Owns the shared AVAudioSession. Must be configured and activated before the
// engine reads inputNode.inputFormat — otherwise the input format is 0 Hz / 0 ch.
enum TapeAudioSession {
    static func configureAndActivate() throws {
        let s = AVAudioSession.sharedInstance()
        // .defaultToSpeaker is required: without it .playAndRecord routes output to
        // the receiver (quiet, mono).
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? s.setPreferredSampleRate(48_000)
        try? s.setPreferredIOBufferDuration(0.005)
        try s.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

final class AVAudioSessionDeviceProvider: AudioDeviceProviding {
    private var observers: [NSObjectProtocol] = []

    // No output-device selection exists on iOS; the route is chosen by the system.
    var outputSelectionSupported: Bool { false }
    var defaultOutputID: DeviceID? { nil }

    var currentOutputName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "Speaker"
    }

    func prepareForEngineStart() throws { try TapeAudioSession.configureAndActivate() }

    // Keep the session active across graph rebuilds (every chain edit calls
    // stop/start); deactivating/reactivating would re-negotiate the route and glitch.
    func releaseAfterEngineStop() {}

    func loadDevices() -> (inputs: [AudioDevice], outputs: [AudioDevice]) {
        let session = AVAudioSession.sharedInstance()
        var inputs: [AudioDevice] = (session.availableInputs ?? [])
            .enumerated()
            .map { AudioDevice(id: DeviceID($0.offset + 1), name: $0.element.portName) }
        if inputs.isEmpty, let current = session.currentRoute.inputs.first {
            inputs = [AudioDevice(id: 0, name: current.portName)]
        }
        // A single, read-only output entry.
        return (inputs, [AudioDevice(id: 0, name: currentOutputName)])
    }

    func displayName(for id: DeviceID) -> String {
        let session = AVAudioSession.sharedInstance()
        let ports = session.availableInputs ?? []
        if id >= 1, Int(id) - 1 < ports.count { return ports[Int(id) - 1].portName }
        return session.currentRoute.inputs.first?.portName ?? "Input"
    }

    func applyInputDevice(_ id: DeviceID, to engine: AVAudioEngine) {
        let session = AVAudioSession.sharedInstance()
        guard id >= 1, let ports = session.availableInputs, Int(id) - 1 < ports.count else { return }
        try? session.setPreferredInput(ports[Int(id) - 1])
    }

    func applyOutputDevice(_ id: DeviceID, to engine: AVAudioEngine) {}

    func startObserving(_ onChange: @escaping (DeviceChange) -> Void) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: session, queue: .main) { _ in
            onChange(.routeChanged)
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began: onChange(.interruptedBegan)
            case .ended: onChange(.interruptedEnded)
            @unknown default: break
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { _ in
            onChange(.mediaServicesReset)
        })
    }

    func stopObserving() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }
}
#endif
