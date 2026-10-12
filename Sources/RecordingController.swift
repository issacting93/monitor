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

    // Capture pipeline. The dry tap runs on the audio render thread, so it must not do
    // file I/O or allocate; it copies interleaved stereo frames into a fixed ring instead.
    // A background queue drains that ring to disk. `capture` and `audioFile` are guarded
    // by `captureLock`; `capture.capturing` is the render thread's "record?" flag.
    private final class WriteRing {
        let capacity: Int
        var data: [Float]              // interleaved stereo, 2 * capacity
        var writeFrame = 0             // next frame slot to write
        var available = 0              // frames queued but not yet written to disk
        var dropped = 0                // frames dropped on overflow (writer fell behind)
        init(capacityFrames: Int) {
            capacity = max(1, capacityFrames)
            data = [Float](repeating: 0, count: capacity * 2)
        }
    }
    private final class CaptureState {
        var ring: WriteRing?
        var capturing = false
    }
    private let captureLock = UnfairLock()
    private let capture = CaptureState()
    private let writerQueue = DispatchQueue(label: "com.opxy.tape08.recording.writer", qos: .userInitiated)
    private var drainTimer: DispatchSourceTimer?

    init(manager: AudioManager) {
        self.manager = manager
    }

    deinit {
        recordingTimer?.invalidate()
        countInTimer?.invalidate()
        drainTimer?.cancel()
    }

    // MARK: - Graph handoff

    /// Installs the pre-FX recording tap: takes are captured dry (without effects).
    /// The tap only copies into the ring; it never touches the file.
    func attach(dryMixer: AVAudioMixerNode) {
        self.dryMixer = dryMixer
        dryMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.captureToRing(buf)
        }
    }

    func detach() {
        recordingTimer?.invalidate(); recordingTimer = nil
        countInTimer?.invalidate(); countInTimer = nil
        // Freeze the tap, flush what is queued, then drop the ring/file.
        captureLock.withLock { capture.capturing = false }
        stopDrainTimerAndFlush()
        captureLock.withLock { audioFile = nil; capture.ring = nil }
        dryMixer?.removeTap(onBus: 0)
        dryMixer = nil
    }

    // MARK: - Capture ring (render thread → background writer)

    /// Runs on the audio render thread. Copies the tap buffer into the ring; never
    /// blocks on I/O and never allocates per call.
    private func captureToRing(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buf.format.channelCount)
        captureLock.withLock {
            guard capture.capturing, let ring = capture.ring else { return }
            var w = ring.writeFrame
            for i in 0..<frames {
                if ring.available == ring.capacity { ring.dropped += 1; continue }
                let l = data[0][i]
                ring.data[w * 2]     = l
                ring.data[w * 2 + 1] = channels > 1 ? data[1][i] : l
                w += 1; if w == ring.capacity { w = 0 }
                ring.available += 1
            }
            ring.writeFrame = w
        }
    }

    private func startDrainTimer() {
        drainTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: writerQueue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.drainOnce() }
        drainTimer = t
        t.resume()
    }

    /// Cancels the periodic drain and flushes everything still queued, on the writer
    /// queue so it can't race an in-flight drain.
    private func stopDrainTimerAndFlush() {
        drainTimer?.cancel(); drainTimer = nil
        writerQueue.sync { self.drainOnce() }
    }

    /// Moves queued frames from the ring to the file. Runs on `writerQueue` only.
    private func drainOnce() {
        let chunk = 4096
        var l = [Float](repeating: 0, count: chunk)
        var r = [Float](repeating: 0, count: chunk)

        let n = captureLock.withLock { () -> Int in
            guard let ring = capture.ring else { return 0 }
            let count = min(chunk, ring.available)
            guard count > 0 else { return 0 }
            var read = ring.writeFrame - ring.available
            if read < 0 { read += ring.capacity }
            for i in 0..<count {
                l[i] = ring.data[read * 2]
                r[i] = ring.data[read * 2 + 1]
                read += 1; if read == ring.capacity { read = 0 }
            }
            ring.available -= count
            return count
        }
        guard n > 0, let file = captureLock.withLock({ audioFile }) else { return }
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(n)) else { return }
        out.frameLength = AVAudioFrameCount(n)
        if let ch = out.floatChannelData {
            for i in 0..<n {
                ch[0][i] = l[i]
                if out.format.channelCount > 1 { ch[1][i] = r[i] }
            }
        }
        try? file.write(from: out)
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
        let name = "\(uniqueFileStem("take")).wav"
        let url  = m.transport.trackFolder(m.selectedTrack).appendingPathComponent(name)
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            captureLock.withLock {
                audioFile = file
                capture.ring = WriteRing(capacityFrames: Int(fmt.sampleRate * 4))  // ~4 s cushion
                capture.capturing = true
            }
            startDrainTimer()
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
            // Include the destination so a write failure (e.g. missing permission on
            // the save location) is actionable rather than just "couldn't be saved".
            let dir = url.deletingLastPathComponent().path
            m.status = "Recording error: \(error.localizedDescription) — check write access to \(dir)"
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
        // Freeze the tap, flush queued frames to disk, then release the ring/file.
        captureLock.withLock { capture.capturing = false }
        stopDrainTimerAndFlush()
        let dropped = captureLock.withLock { capture.ring?.dropped ?? 0 }
        let saved = captureLock.withLock { () -> URL? in
            let u = audioFile?.url
            audioFile = nil
            capture.ring = nil
            return u
        }
        let dur   = m.recordingDuration
        let trk   = m.selectedTrack
        m.isRecording = false
        if !m.tracks.contains(where: { $0.isPlaying }) { m.metronome.stop() }

        guard let u = saved else { return }
        let peaks = computePeaks(url: u, count: Theme.clipPeaks)
        let clip  = TrackClip(url: u, duration: dur, peaks: peaks)
        let rec   = Recording(url: u, duration: dur, trackIndex: trk)

        let dest = "TRK \(String(format: "%02d", trk + 1))"
        m.status = dropped > 0
            ? "Saved \(u.lastPathComponent) → \(dest) (\(dropped) frames dropped)"
            : "Saved \(u.lastPathComponent) → \(dest)"
        DispatchQueue.main.async {
            m.transport.pushUndo()
            m.recordings.append(rec)
            m.tracks[trk].clips.append(clip)
            // Register only now that a clip references the file: pushUndo() above runs the
            // orphan sweep, so registering before the clip exists would delete the take.
            m.transport.registerSessionFile(u)
            m.transport.loadTrackBuffer(trk)
        }
    }
}
