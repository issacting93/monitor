// DeviceController.swift — audio device discovery/selection + MIDI track follow
//
// Owns device enumeration, the CoreAudio hardware-property listeners, output
// switching, and the CoreMIDI input port that follows the OP-XY's active track.
// The @Published device lists and selections stay on AudioManager so the pickers
// bind unchanged; this controller writes them through its `manager` reference.

import Foundation
import CoreAudio
import CoreMIDI

final class DeviceController {
    private unowned let manager: AudioManager

    private var midiClient: MIDIClientRef = 0
    private var midiPort:   MIDIPortRef   = 0

    init(manager: AudioManager) {
        self.manager = manager
    }

    deinit {
        if midiPort != 0 { MIDIPortDispose(midiPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }

    // MARK: - Device discovery

    func loadDevices() {
        let allIDs  = allAudioDevices()
        let inputs  = allIDs.filter { deviceChannelCount($0, input: true) > 0 }
                            .map { AudioDevice(id: $0, name: nameOfDevice($0)) }
        let outputs = allIDs.filter { deviceChannelCount($0, input: false) > 0 }
                            .map { AudioDevice(id: $0, name: nameOfDevice($0)) }

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

            let currentSysOut = getDefaultAudioDevice(input: false)
            if self.manager.selectedOutputID == nil
                || !outputs.contains(where: { $0.id == self.manager.selectedOutputID }) {
                self.manager.selectedOutputID = currentSysOut != 0 ? currentSysOut : outputs.first?.id
            }
        }
    }

    // Listeners are intentionally never removed: the process lives as long as the
    // app window, and rebuilding the graph on every device change would be worse.
    func setupHardwareListeners() {
        var devAddr = audioAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &devAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.loadDevices()
        }
        var outAddr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &outAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.loadDevices()
        }
    }

    func switchOutput(to id: AudioDeviceID) {
        manager.selectedOutputID = id
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
                let channel = Int(status & 0x0F)
                // Any channel voice message → select matching track
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
