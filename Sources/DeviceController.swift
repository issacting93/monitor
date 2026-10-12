// DeviceController.swift — audio device discovery/selection + MIDI track follow
//
// Platform-agnostic: all device/route work is delegated to an AudioDeviceProviding
// (CoreAudio HAL on macOS, AVAudioSession on iOS). This controller owns device
// enumeration, the change observers, output switching, and the CoreMIDI input port
// that follows the OP-XY's active track. The @Published device lists and selections
// stay on AudioManager so the pickers bind unchanged; this controller writes them
// through its `manager` reference.

import Foundation
import CoreMIDI

final class DeviceController {
    private unowned let manager: AudioManager

    /// The platform device-I/O implementation (macOS CoreAudio HAL / iOS AVAudioSession).
    let io: AudioDeviceProviding = {
        #if os(iOS)
        AVAudioSessionDeviceProvider()
        #else
        CoreAudioDeviceProvider()
        #endif
    }()

    private var midiClient: MIDIClientRef = 0
    private var midiPort:   MIDIPortRef   = 0

    init(manager: AudioManager) {
        self.manager = manager
    }

    deinit {
        io.stopObserving()
        if midiPort != 0 { MIDIPortDispose(midiPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }

    // MARK: - Device discovery

    func loadDevices() {
        let (inputs, outputs) = io.loadDevices()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.manager.inputDevices  = inputs
            self.manager.outputDevices = outputs

            if self.manager.selectedInputID == nil
                || !inputs.contains(where: { $0.id == self.manager.selectedInputID }) {
                self.manager.selectedInputID = inputs.first(where: { $0.name.localizedCaseInsensitiveContains("XY") })?.id
                    ?? inputs.first(where: { $0.name.localizedCaseInsensitiveContains("OP") })?.id
                    ?? inputs.first?.id
            }

            if self.manager.selectedOutputID == nil
                || !outputs.contains(where: { $0.id == self.manager.selectedOutputID }) {
                self.manager.selectedOutputID = self.io.defaultOutputID ?? outputs.first?.id
            }
        }
    }

    func setupHardwareListeners() {
        io.startObserving { [weak self] change in
            guard let self else { return }
            switch change {
            case .listChanged:
                // macOS: keep the list fresh; rebuilding the graph here would be worse.
                self.loadDevices()
            case .routeChanged:
                self.loadDevices()
                if self.manager.isMonitoring {
                    self.manager.stopMonitoring(); self.manager.startMonitoring()
                }
            case .interruptedBegan:
                // Finalise any take in progress, then release the engine.
                if self.manager.isRecording { self.manager.stopRecording() }
                self.manager.stopMonitoring()
            case .interruptedEnded:
                if !self.manager.isMonitoring { self.manager.startMonitoring() }
            case .mediaServicesReset:
                if self.manager.isMonitoring {
                    self.manager.stopMonitoring(); self.manager.startMonitoring()
                }
            }
        }
    }

    func switchOutput(to id: DeviceID) {
        guard io.outputSelectionSupported else { return }
        manager.selectedOutputID = id
        // On macOS the engine's input and output are the same AUHAL, so the output
        // device follows the selected INPUT device — the OUT picker only labels it.
        if manager.isMonitoring { manager.stopMonitoring(); manager.startMonitoring() }
    }

    // MARK: - MIDI (OP-XY track follow)

    func setupMIDI() {
        MIDIClientCreateWithBlock("Tape08" as CFString, &midiClient) { [weak self] _ in
            DispatchQueue.main.async { self?.connectMIDISources() }
        }
        MIDIInputPortCreateWithProtocol(midiClient, "Input" as CFString, ._1_0, &midiPort) { [weak self] eventList, _ in
            guard let self, self.manager.midiTrackFollow else { return }
            eventList.unsafeSequence().forEach { event in
                let word = event.pointee.words.0
                // MIDI 1.0 channel voice in UMP: type 0x2
                guard (word >> 28) & 0xF == 0x2 else { return }
                let status = (word >> 16) & 0xFF
                // Note-on only. Every other channel voice message — note-off, CC,
                // program change, aftertouch — names a channel too, and letting them
                // all select a track means a knob sweep or a release fights the user's
                // clicks. Velocity sits in the low byte; 0 is the running-status
                // note-off convention whatever the status nibble says.
                guard (status >> 4) & 0xF == 0x9, (word & 0xFF) > 0 else { return }
                let channel = Int(status & 0x0F)
                if channel < Theme.trackCount {
                    DispatchQueue.main.async { self.manager.selectedTrack = channel }
                }
            }
        }
        connectMIDISources()
    }

    private func connectMIDISources() {
        // Disconnect all first
        let sourceCount = MIDIGetNumberOfSources()
        for i in 0..<sourceCount {
            let src = MIDIGetSource(i)
            MIDIPortDisconnectSource(midiPort, src)
        }
        // Connect to all sources (OP-XY will be among them)
        for i in 0..<sourceCount {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(midiPort, src, nil)
        }
    }
}
