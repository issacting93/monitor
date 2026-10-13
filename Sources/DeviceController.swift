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
                // Remembered device first — ahead of the OP-XY heuristic, which is only
                // a guess at what the user wants, whereas this is what they said.
                self.manager.selectedInputID = self.remembered(in: inputs, uid: Preferences.inputDeviceUID)?.id
                    ?? inputs.first(where: { $0.name.localizedCaseInsensitiveContains("XY") })?.id
                    ?? inputs.first(where: { $0.name.localizedCaseInsensitiveContains("OP") })?.id
                    ?? inputs.first?.id
            }

            if self.manager.selectedOutputID == nil
                || !outputs.contains(where: { $0.id == self.manager.selectedOutputID }) {
                // The system default still comes first here: it is a fresh decision by the
                // user made in System Settings, and a remembered output that is plugged in
                // is more often the *monitor* pair they left selected than the interface
                // they meant to listen through. A remembered device is used only when this
                // Mac has no opinion of its own.
                self.manager.selectedOutputID = self.remembered(in: outputs, uid: Preferences.outputDeviceUID)?.id
                    ?? self.io.defaultOutputID
                    ?? outputs.first?.id
            }
        }
    }

    /// The listed device matching a remembered UID, or nil when nothing is remembered or
    /// that device isn't plugged in. An empty `uid` never matches anything, including an
    /// entry whose own UID couldn't be read — see `Preferences.inputDeviceUID`.
    private func remembered(in devices: [AudioDevice], uid: String) -> AudioDevice? {
        guard !uid.isEmpty else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// Records the device a picker settled on, so the next launch can restore it.
    ///
    /// Called from the selection paths only, never from `loadDevices`. That distinction is
    /// the whole point of the method: `loadDevices` runs its fallback whenever the
    /// remembered device is merely unplugged, so persisting from there would overwrite the
    /// user's choice with whatever the fallback landed on — permanently, and without them
    /// ever touching a picker.
    func rememberDevice(_ id: DeviceID?, input: Bool) {
        let listed = input ? manager.inputDevices : manager.outputDevices
        guard let id, let uid = listed.first(where: { $0.id == id })?.uid, !uid.isEmpty else { return }
        if input { Preferences.inputDeviceUID = uid } else { Preferences.outputDeviceUID = uid }
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
        // Remembered here rather than in `AudioManager.selectOutput`, so the monitor
        // view's output picker — which calls this directly — is covered too.
        rememberDevice(id, input: false)
        // Restart, because the restart is what makes a separate output real. The engine
        // holds one AUHAL, and `applyEngineDevices` is what reconciles that with an
        // output that differs from the input: it pins the engine to a private
        // input+output aggregate and remaps the AUHAL's output onto the chosen device.
        // Assigning `selectedOutputID` on its own would leave the audio where it was
        // while the picker said otherwise.
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
