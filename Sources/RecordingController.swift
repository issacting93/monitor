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
    /// The beat the count ends on, in the metronome's own running count. Fixed by the
    /// first beat the count-in hears, since only that one says which beat of the bar we
    /// pressed REC on; nil while it is still being worked out.
    private var countInTargetBeat: Int?

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
        countInTargetBeat = nil
        // The metronome tears down alongside this, but the order is the engine's to
        // choose: leaving a beat observer installed would let a count-in start a take
        // against a node that no longer exists.
        manager.metronome.disarmBeats()
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
        // A second REC press is the stop, and the transport routes it to `stop()` before
        // it can reach here. Bailing keeps a stray call from opening a second file on top
        // of the take already rolling.
        guard !m.isRecording else { return }

        // Count-in: play metronome clicks for N bars before actually recording.
        //
        // The count rides the click grid rather than a wall clock. `observeBeats` hands
        // back each beat on the metronome's own timeline, so bar 1 of the count is a real
        // downbeat — accent and all — and the take starts on the downbeat that ends it,
        // instead of wherever `240 / BPM × bars` seconds of free-running timer landed.
        // A second press re-targets the next bar line without touching the node, which is
        // what used to pull the clicks out of phase with a track already looping.
        if m.countInBars > 0 {
            countInTimer?.invalidate(); countInTimer = nil
            countInTargetBeat = nil
            m.countingIn = true
            m.status = "Count-in..."
            if !m.metronome.isRunning { m.metronome.start() }
            if m.metronome.observeBeats({ [weak self] index in self?.countInBeat(index) }) {
                return
            }
            // No grid to ride: the count-in starts the metronome, but a user who has the
            // clicks switched off leaves no node to observe — and their count is silent
            // either way. Fall back to the wall clock, which is what this always was.
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

    /// One metronome beat while a count-in is pending.
    ///
    /// The first beat heard fixes the phase — the count has to begin on a bar line, and
    /// which beat of the bar we are on is the only thing standing between "count one bar"
    /// and "count one bar starting at the next downbeat". Every beat after that is a step
    /// towards the one the take starts on.
    private func countInBeat(_ index: Int) {
        let m = manager
        guard m.countingIn else { m.metronome.disarmBeats(); return }

        let target: Int
        if let t = countInTargetBeat {
            target = t
        } else {
            // Beats are counted 0, 1, 2, 3 per bar with 0 accented, so the next bar line
            // is the next beat whose index is a multiple of four — this one, if we are
            // already on it.
            let toNextBar = (4 - (index % 4)) % 4
            target = index + toNextBar + 4 * max(1, m.countInBars)
            countInTargetBeat = target
        }
        guard index >= target else { return }

        countInTargetBeat = nil
        m.countingIn = false
        m.metronome.disarmBeats()
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
            countInTargetBeat = nil
            // The beats are the metronome's to report, so it is told to stop reporting —
            // a count that kept listening after the cancel would start the take anyway.
            m.metronome.disarmBeats()
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
        let previousSelection = m.selectedClipID
        m.isRecording = false
        if !m.tracks.contains(where: { $0.isPlaying }) { m.metronome.stop() }

        guard let u = saved else { return }
        let epoch = m.transport.editEpoch

        // Measuring the take means reading the whole file back. The frames are already
        // safe on disk at this point, so the wait costs nothing but a status line.
        m.status = "Saving \(u.lastPathComponent)…"
        m.runOffMain(busy: "Saving take…") {
            computePeaks(url: u, count: Theme.clipPeaks)
        } apply: { [weak self] peaks in
            guard let self else { return }
            let m = self.manager
            // An undo, or a project load, replaced the clip set while the take was being
            // measured. Appending now would file it under a track the take was never
            // recorded against — and the file is the user's performance, so it is left
            // on disk and named rather than swept away.
            guard epoch == m.transport.editEpoch else {
                m.status = "Take left at \(u.lastPathComponent) — the session changed before it could be filed"
                return
            }
            let clip = TrackClip(url: u, duration: dur, peaks: peaks)

            m.transport.pushUndo()
            m.tracks[trk].clips.append(clip)
            // The take just captured is the one the user will want to trim or duplicate —
            // unless they picked a different one while it was being measured.
            m.transport.followSelection(ifUnchanged: previousSelection, to: clip.id, on: trk)
            // Register only now that a clip references the file: pushUndo() above runs the
            // orphan sweep, so registering before the clip exists would delete the take.
            m.transport.registerSessionFile(u)
            m.transport.loadTrackBuffer(trk)

            let dest = "TRK \(String(format: "%02d", trk + 1))"
            m.status = dropped > 0
                ? "Saved \(u.lastPathComponent) → \(dest) (\(dropped) frames dropped)"
                : "Saved \(u.lastPathComponent) → \(dest)"
        }
    }
}
