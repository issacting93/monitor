// RecordingController.swift — count-in, dry take capture, and the take timer
//
// Owns the recording file handle, the pre-FX dry tap that writes into it, the
// count-in timer, and the elapsed-time timer. The published recording state
// (isRecording, countingIn, countInBars, recordingDuration) stays on AudioManager
// and is read/written through the `manager` reference, so views bind unchanged.

import Foundation
import AVFoundation

final class RecordingController {
    private unowned let manager: AudioManager

    private var dryMixer: AVAudioMixerNode?
    private var audioFile: AVAudioFile?
    private var recordingStart: Date?
    private var recordingTimer: Timer?
    private var countInTimer: Timer?

    init(manager: AudioManager) {
        self.manager = manager
    }

    deinit {
        recordingTimer?.invalidate()
        countInTimer?.invalidate()
    }

    // MARK: - Graph handoff

    /// Installs the pre-FX recording tap: takes are captured dry (without effects),
    /// and `audioFile` is nil whenever no take is in progress, so the tap is a no-op.
    func attach(dryMixer: AVAudioMixerNode) {
        self.dryMixer = dryMixer
        dryMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            if let file = self?.audioFile { try? file.write(from: buf) }
        }
    }

    func detach() {
        recordingTimer?.invalidate(); recordingTimer = nil
        countInTimer?.invalidate(); countInTimer = nil
        dryMixer?.removeTap(onBus: 0)
        dryMixer = nil
        audioFile = nil
    }

    // MARK: - Public controls (forwarded from AudioManager)

    func start() {
        let m = manager
        guard m.isMonitoring else { return }

        // Count-in: play metronome clicks for N bars before actually recording
        if m.countInBars > 0 && !m.countingIn {
            m.countingIn = true
            m.status = "Count-in..."
            if !m.metronome.isRunning { m.metronome.start() }
            let secsPerBar = 240.0 / m.metronomeBPM
            let countInDuration = secsPerBar * Double(m.countInBars)
            countInTimer = Timer.scheduledTimer(withTimeInterval: countInDuration, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.manager.countingIn = false
                    self.countInTimer = nil
                    self.begin()
                }
            }
            return
        }
        begin()
    }

    private func begin() {
        let m = manager
        guard let dryTap = dryMixer else { return }
        let fmt  = dryTap.outputFormat(forBus: 0)
        let name = "take_\(timestampFmt.string(from: Date())).wav"
        let url  = m.transport.trackFolder(m.selectedTrack).appendingPathComponent(name)
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            recordingStart    = Date()
            m.recordingDuration = 0
            m.isRecording       = true
            m.status            = "Recording TRK \(String(format: "%02d", m.selectedTrack + 1))"
            if m.metronomeEnabled && !m.metronome.isRunning { m.metronome.start() }
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let s = self.recordingStart else { return }
                DispatchQueue.main.async { self.manager.recordingDuration = Date().timeIntervalSince(s) }
            }
        } catch {
            m.status = "Recording error: \(error.localizedDescription)"
        }
    }

    func stop() {
        let m = manager
        // Cancel count-in if active
        if m.countingIn {
            countInTimer?.invalidate(); countInTimer = nil
            m.countingIn = false
            m.status = "Count-in cancelled"
            if !m.tracks.contains(where: { $0.isPlaying }) { m.metronome.stop() }
            return
        }
        recordingTimer?.invalidate(); recordingTimer = nil
        let saved = audioFile?.url
        let dur   = m.recordingDuration
        let trk   = m.selectedTrack
        audioFile = nil
        m.isRecording = false
        if !m.tracks.contains(where: { $0.isPlaying }) { m.metronome.stop() }

        guard let u = saved else { return }
        let peaks = computePeaks(url: u, count: Theme.clipPeaks)
        let clip  = TrackClip(url: u, duration: dur, peaks: peaks)
        let rec   = Recording(url: u, duration: dur, trackIndex: trk)

        m.status = "Saved \(u.lastPathComponent) → TRK \(String(format: "%02d", trk + 1))"
        DispatchQueue.main.async {
            m.transport.pushUndo()
            m.recordings.append(rec)
            m.tracks[trk].clips.append(clip)
            m.transport.loadTrackBuffer(trk)
        }
    }
}
