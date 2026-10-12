// TransportController.swift — playback, undo/redo, clip editing, track helpers
//
// Owns the per-track player/mixer nodes and their decoded buffers, the
// loop/one-shot scheduling logic, the undo/redo snapshot stacks, and every
// clip-level edit (trim, split, duplicate, import/export, mixdown) plus the
// mute/solo/volume/pan helpers. The @Published views state (tracks, isPlaying,
// selectedTrack, trimmingTrack, trim*, bounceStatus, timelineZoom, …) stays on
// AudioManager and is written through the `manager` reference.

import Foundation
#if os(macOS)
import AppKit
#endif
import AVFoundation
import UniformTypeIdentifiers

/// One file an off-main clip edit produced, ready to be installed as a clip.
private struct EditedClip {
    let url: URL
    let duration: Double
    let peaks: [Double]
}

/// What an off-main clip edit produced. `failed` carries the status message to
/// show, so the caller does not have to reconstruct why the edit did nothing.
private enum EditOutcome {
    case produced([EditedClip])   // one clip for trim/duplicate, two for split
    case failed(String)
}

/// A finished mixdown, waiting only to be written to the file the user picks.
private struct MixedDown {
    let buffer: AVAudioPCMBuffer
    let sampleRate: Double
    let channels: Int
}

final class TransportController {
    private unowned let manager: AudioManager

    private var playerNodes: [AVAudioPlayerNode] = []
    private var trackMixers: [AVAudioMixerNode] = []
    private var trackBuffers: [AVAudioPCMBuffer?] = Array(repeating: nil, count: Theme.trackCount)

    // Bumped on every (re)schedule so a stale one-shot completion handler can't stop
    // a later playback of the same track.
    private var playGenerations = [Int](repeating: 0, count: Theme.trackCount)

    // Undo/redo
    private var undoStack: [[TrackInfo]] = []
    private var redoStack: [[TrackInfo]] = []
    private var undoGestureActive = false   // debounce slider drags

    // Audio files this session created (takes, trims, splits, duplicates), by path.
    // Only these are eligible for cleanup — never the whole save folder, which is
    // shared across sessions and could lose a prior session's takes.
    private var sessionCreatedFiles: Set<String> = []

    // Files an edit has written but that no clip references *yet*. The orphan sweep
    // runs on every pushUndo, so without an exemption it could delete a file that is
    // about to be referenced. An edit drops the exemption once its clip exists.
    private var pendingFiles: Set<String> = []

    // Bumped on every (re)decode of a track's buffer, so a decode that has been
    // superseded can't publish over a newer one — the same idiom as `playGenerations`.
    private var loadGenerations = [Int](repeating: 0, count: Theme.trackCount)

    // Bumped by anything that replaces the clip set wholesale (undo, redo, restore,
    // clear). Every edit captures it on entry and re-checks it before applying, so work
    // dispatched before the change is dropped rather than landing on the new state.
    // Re-resolving by clip id is not enough on its own: undo and redo restore the very
    // same `TrackClip` values, UUIDs included, so an id can resolve again after a round
    // trip. Readable from outside so `RecordingController`, whose take-finish work also
    // runs off-main, can apply the same guard.
    private(set) var editEpoch = 0

    // Identifies the trim editor session an off-main apply belongs to. Bumped when the
    // editor opens *and* when it closes, so an apply that lands after the user cancelled
    // is dropped. The epoch can't do this job: cancel is not a wholesale clip-set change,
    // so it bumps nothing. Checking `trimmingTrack` is not enough either — cancelling and
    // re-opening TRIM on the same track restores the identical value, and the stale apply
    // would then trim the clip and wipe the waveform of the editor now on screen.
    private var trimSession = 0

    init(manager: AudioManager) {
        self.manager = manager
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Track mixer nodes, in track order (used by the metering taps).
    var mixers: [AVAudioMixerNode] { trackMixers }

    // MARK: - Background Work Invalidation

    /// Invalidates every in-flight background operation. Called whenever the clip set
    /// is replaced wholesale: a decode started before that would otherwise publish a
    /// buffer for a clip that no longer exists.
    private func invalidatePendingWork() {
        editEpoch += 1
        for i in 0..<loadGenerations.count { loadGenerations[i] += 1 }
    }

    /// Resolves a clip's current position on a track. Edits capture the clip's `id`
    /// rather than its index before doing their work, because the array can be
    /// reordered or replaced while that work runs.
    private func indexOfClip(_ id: UUID, on trackIndex: Int) -> Int? {
        guard trackIndex < manager.tracks.count else { return nil }
        return manager.tracks[trackIndex].clips.firstIndex { $0.id == id }
    }

    // MARK: - Graph handoff

    func attach(players: [AVAudioPlayerNode], mixers: [AVAudioMixerNode]) {
        playerNodes = players
        trackMixers = mixers
    }

    /// Drops the graph node references on teardown. Decoded buffers are intentionally
    /// kept: they survive a stop/start cycle so playback resumes without re-decoding.
    func detach() {
        playerNodes = []
        trackMixers = []
    }

    /// Drops every decoded buffer (e.g. after a project load replaces the clip set).
    func resetTrackBuffers() {
        invalidatePendingWork()
        trackBuffers = Array(repeating: nil, count: Theme.trackCount)
    }

    /// The per-track playhead progress, read from the display timer (Stage 12).
    func updatePlaybackProgress() {
        for i in 0..<manager.tracks.count where manager.tracks[i].isPlaying {
            if i < playerNodes.count, let buffer = trackBuffers[i] {
                if let nodeTime = playerNodes[i].lastRenderTime,
                   nodeTime.isSampleTimeValid,
                   let playerTime = playerNodes[i].playerTime(forNodeTime: nodeTime) {
                    let total = Double(buffer.frameLength)
                    if total > 0 {
                        let cur = abs(Double(playerTime.sampleTime)).truncatingRemainder(dividingBy: total)
                        manager.live.playhead.trackProgress[i] = cur / total
                    }
                }
            }
        }
    }

    // MARK: - Per-Track Playback

    // Toggles loop mode and re-schedules any currently-playing tracks so the change
    // takes effect immediately instead of at the next play.
    func setLoopEnabled(_ enabled: Bool) {
        guard enabled != manager.loopEnabled else { return }
        manager.loopEnabled = enabled
        for i in 0..<manager.tracks.count where manager.tracks[i].isPlaying {
            guard let buffer = trackBuffers[i] else { continue }
            scheduleTrackBuffer(i, buffer: buffer)
        }
        manager.projectDirty = true
    }

    // Schedules a track's buffer respecting `loopEnabled`: loop mode repeats forever,
    // one-shot mode plays once and marks the track stopped (on main) when it ends.
    private func scheduleTrackBuffer(_ i: Int, buffer: AVAudioPCMBuffer) {
        guard i < playerNodes.count else { return }
        let player = playerNodes[i]
        player.stop()
        if manager.loopEnabled {
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        } else {
            playGenerations[i] += 1
            let gen = playGenerations[i]
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, gen == self.playGenerations[i] else { return }
                    self.stopTrackLoop(i)
                }
            })
        }
        player.play()
    }

    func startTrackLoop(_ i: Int) {
        guard manager.isMonitoring, i < playerNodes.count else { return }
        // An empty track has nothing to play. Bailing here also stops the
        // load → start → load recursion below from spinning forever on an empty
        // track (which previously caused a stack overflow).
        guard !manager.tracks[i].clips.isEmpty else { return }
        if trackBuffers[i] == nil {
            // Buffer not decoded yet — load it off-main, then start once it's ready.
            loadTrackBuffer(i) { [weak self] ok in
                if ok { self?.startTrackLoop(i) }
                else { self?.manager.status = "Could not load clip for TRK \(String(format: "%02d", i + 1))" }
            }
            return
        }
        guard let buffer = trackBuffers[i] else { return }
        scheduleTrackBuffer(i, buffer: buffer)
        manager.tracks[i].isPlaying = true
        refreshTrackMixers()
        if manager.metronomeEnabled && !manager.metronome.isRunning { manager.metronome.start() }
        manager.isPlaying = true
        manager.status = "Looping TRK \(String(format: "%02d", i + 1))"
    }

    func stopTrackLoop(_ i: Int) {
        guard i < playerNodes.count else { return }
        playGenerations[i] += 1
        playerNodes[i].stop()
        manager.tracks[i].isPlaying = false
        manager.live.playhead.trackProgress[i] = 0
        if !manager.tracks.contains(where: { $0.isPlaying }) {
            manager.metronome.stop()
            manager.isPlaying = false
            manager.status = "Stopped"
        }
    }

    func toggleTrackPlayback(_ i: Int) {
        if manager.tracks[i].isPlaying { stopTrackLoop(i) } else { startTrackLoop(i) }
    }

    func toggleTrackRecord(_ i: Int) {
        manager.selectedTrack = i
        if manager.countingIn {
            // Count-in is pending (isRecording is still false) — cancel it instead
            // of starting a second recording on top of the scheduled one.
            manager.stopRecording()
        } else if manager.isRecording {
            manager.stopRecording()
            startTrackLoop(i)
        } else {
            manager.startRecording()
        }
    }

    func playAll() {
        guard manager.isMonitoring else { return }
        // Decode any missing buffers off-main first, then re-enter to schedule.
        let missing = (0..<manager.tracks.count).filter { !manager.tracks[$0].clips.isEmpty && trackBuffers[$0] == nil }
        if !missing.isEmpty {
            let group = DispatchGroup()
            for i in missing {
                group.enter()
                loadTrackBuffer(i) { _ in group.leave() }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                // Re-enter only if every buffer actually loaded; otherwise the loop
                // would retry unreadable clips forever.
                let stillMissing = missing.filter { self.trackBuffers[$0] == nil }
                if stillMissing.isEmpty { self.playAll() }
                else { self.manager.status = "Could not load \(stillMissing.count) clip(s)" }
            }
            return
        }
        for i in 0..<manager.tracks.count where !manager.tracks[i].clips.isEmpty {
            guard let buffer = trackBuffers[i] else { continue }
            scheduleTrackBuffer(i, buffer: buffer)
            manager.tracks[i].isPlaying = true
        }
        refreshTrackMixers()
        manager.isPlaying = true
        manager.metronome.start()
        manager.status = "Playing all tracks"
    }

    func stopAll() {
        manager.metronome.stop()
        for i in 0..<manager.tracks.count {
            if i < playerNodes.count { playerNodes[i].stop() }
            manager.tracks[i].isPlaying = false
            manager.live.playhead.trackProgress[i] = 0
        }
        manager.isPlaying = false
        manager.status = "Stopped"
    }

    // MARK: - Undo/Redo

    func pushUndo() {
        undoStack.append(manager.tracks)
        redoStack.removeAll()
        if undoStack.count > 30 { undoStack.removeFirst() }
        manager.projectDirty = true
        collectOrphanedFiles()
    }

    /// Push undo only once per gesture (for sliders/continuous controls).
    func beginUndoGesture() { undoGestureActive = false }
    func pushUndoIfNeeded() {
        if !undoGestureActive {
            undoGestureActive = true
            pushUndo()
        }
    }
    func endUndoGesture() { undoGestureActive = false }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(manager.tracks)
        if redoStack.count > 30 { redoStack.removeFirst() }
        restoreTracks(snapshot)
        collectOrphanedFiles()
        manager.status = "Undo"
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(manager.tracks)
        if undoStack.count > 30 { undoStack.removeFirst() }
        restoreTracks(snapshot)
        collectOrphanedFiles()
        manager.status = "Redo"
    }

    private func restoreTracks(_ snapshot: [TrackInfo]) {
        invalidatePendingWork()
        for i in 0..<manager.tracks.count {
            if manager.tracks[i].isPlaying && i < playerNodes.count {
                playerNodes[i].stop()
            }
        }
        manager.tracks = snapshot
        for i in 0..<manager.tracks.count {
            trackBuffers[i] = nil
            if !manager.tracks[i].clips.isEmpty { loadTrackBuffer(i) }
            manager.tracks[i].isPlaying = false
            manager.live.playhead.trackProgress[i] = 0
        }
        manager.isPlaying = false
        refreshTrackMixers()
    }

    func clearAll() {
        pushUndo()
        stopAll()
        invalidatePendingWork()
        for i in 0..<manager.tracks.count {
            manager.tracks[i].clips.removeAll()
            trackBuffers[i] = nil
        }
        manager.recordings.removeAll()
        manager.status = "All tracks cleared"
    }

    // MARK: - Orphaned File Cleanup

    /// Records a file the app just created (a take, trim, split part, or duplicate) so
    /// it becomes eligible for cleanup once nothing references it. Imported originals
    /// are never registered, so they are never deleted.
    func registerSessionFile(_ url: URL) {
        sessionCreatedFiles.insert(url.standardizedFileURL.path)
        pendingFiles.remove(url.standardizedFileURL.path)
    }

    /// Marks a file as written-but-not-yet-referenced, exempting it from the orphan
    /// sweep until `registerSessionFile` promotes it (or `abandonPendingFile` drops
    /// it). An edit that writes a file and only later installs the clip that
    /// references it must call this in between — pushUndo() runs the sweep, and it
    /// would otherwise delete the file the edit is about to attach.
    func registerPendingFile(_ url: URL) {
        pendingFiles.insert(url.standardizedFileURL.path)
        sessionCreatedFiles.insert(url.standardizedFileURL.path)
    }

    /// Deletes a file an edit wrote but will never reference (its apply was
    /// superseded) and forgets it, so it neither leaks on disk nor lingers in the
    /// sweep's pending set.
    func abandonPendingFile(_ url: URL) {
        let path = url.standardizedFileURL.path
        pendingFiles.remove(path)
        sessionCreatedFiles.remove(path)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Deletes session-created audio files that no remaining clip references. The
    /// referenced set spans the current tracks plus every undo/redo snapshot — undo and
    /// redo are the only paths that can restore a clip, so a file absent from their
    /// union is unreachable and safe to remove. Runs when that union shrinks (undo-stack
    /// eviction, redo invalidation), which is why a trim/split/clear stays undoable: its
    /// pre-op snapshot still holds the file until it ages out of the 30-deep stack.
    /// Files an in-flight edit has written but not yet referenced are exempt (see
    /// `registerPendingFile`).
    func collectOrphanedFiles() {
        guard !sessionCreatedFiles.isEmpty else { return }
        var referenced = Set<String>()
        func add(_ tracks: [TrackInfo]) {
            for t in tracks { for c in t.clips {
                referenced.insert(c.url.standardizedFileURL.path)
            } }
        }
        add(manager.tracks)
        for snapshot in undoStack { add(snapshot) }
        for snapshot in redoStack { add(snapshot) }

        let fm = FileManager.default
        for path in sessionCreatedFiles.filter({ !referenced.contains($0) && !pendingFiles.contains($0) }) {
            try? fm.removeItem(atPath: path)
            sessionCreatedFiles.remove(path)
        }
    }

    // MARK: - Trim Editor

    func openTrimEditor(_ trackIndex: Int) {
        guard trackIndex < manager.tracks.count, let clip = manager.tracks[trackIndex].clips.last else { return }
        if manager.tracks[trackIndex].isPlaying { stopTrackLoop(trackIndex) }
        // The editor opens on the clip's duration straight away; the waveform needs a
        // full read of the file, so it arrives off-main a moment later.
        manager.trimClipDuration = clip.duration
        manager.trimPeaks = []
        manager.trimStart = 0
        manager.trimEnd = 1
        manager.trimmingTrack = trackIndex
        trimSession += 1
        let session = trimSession
        let url = clip.url
        let epoch = editEpoch
        manager.runOffMain(busy: "Reading waveform…") {
            computePeaks(url: url, count: 256)
        } apply: { [weak self] peaks in
            guard let self, epoch == self.editEpoch else { return }
            // Bail if the editor was cancelled, or closed and re-opened, while the read
            // ran — otherwise a stale waveform lands in the editor now on screen.
            guard session == self.trimSession else { return }
            self.manager.trimPeaks = peaks
        }
    }

    func cancelTrim() {
        // Bump first: an apply already in flight re-checks the token on the main thread,
        // so this is what makes the cancel take effect.
        trimSession += 1
        manager.trimmingTrack = nil
        manager.trimPeaks = []
    }

    func applyTrim() {
        guard let ti = manager.trimmingTrack, ti < manager.tracks.count,
              let clip = manager.tracks[ti].clips.last else { return }
        // Capture what the work needs by value, plus the identities to re-check it
        // against before applying: the editor session (the user may cancel while this
        // runs), the clip's id (its index is not stable) and the edit epoch (the whole
        // clip set can be replaced under us).
        let session = trimSession
        let epoch = editEpoch
        let clipID = clip.id
        let srcURL = clip.url
        let startFrac = manager.trimStart
        let endFrac = manager.trimEnd

        manager.runOffMain(busy: "Trimming…") { () -> EditOutcome in
            guard let srcFile = try? AVAudioFile(forReading: srcURL) else {
                return .failed("Cannot read clip file")
            }
            let totalFrames = Int64(srcFile.length)
            let startFrame = Int64(startFrac * Double(totalFrames))
            let endFrame = Int64(endFrac * Double(totalFrames))
            let trimmedFrames = AVAudioFrameCount(max(0, endFrame - startFrame))
            guard trimmedFrames > 0 else { return .failed("Trim range is empty") }

            // Read the source region
            srcFile.framePosition = startFrame
            guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFile.processingFormat,
                                                 frameCapacity: trimmedFrames) else {
                return .failed("Cannot allocate a buffer for the trim")
            }
            do { try srcFile.read(into: readBuf, frameCount: trimmedFrames) }
            catch { return .failed("Trim read error: \(error.localizedDescription)") }

            // Write the trimmed file
            let trimURL = srcURL.deletingLastPathComponent()
                .appendingPathComponent("\(uniqueFileStem("trim")).wav")
            do {
                let outFile = try AVAudioFile(forWriting: trimURL, settings: srcFile.fileFormat.settings,
                                              commonFormat: .pcmFormatFloat32, interleaved: false)
                try outFile.write(from: readBuf)
            } catch {
                try? FileManager.default.removeItem(at: trimURL)   // a failed write can leave a partial file
                return .failed("Trim error: \(error.localizedDescription)")
            }
            return .produced([EditedClip(url: trimURL,
                                         duration: Double(trimmedFrames) / srcFile.fileFormat.sampleRate,
                                         peaks: computePeaks(url: trimURL, count: Theme.clipPeaks))])
        } apply: { [weak self] outcome in
            guard let self else { return }
            let m = self.manager
            guard case .produced(let made) = outcome, let trimmed = made.first else {
                if case .failed(let message) = outcome { m.status = message }
                return
            }
            // Exempt the new file from the orphan sweep that `pushUndo` is about to run:
            // written, but no clip references it until the lines below.
            self.registerPendingFile(trimmed.url)
            guard session == self.trimSession else {
                // CANCEL was pressed while this ran. The user's instruction is the later
                // one, so the trim is dropped — including the file it wrote.
                self.abandonPendingFile(trimmed.url)
                m.status = "Trim cancelled"
                return
            }
            guard epoch == self.editEpoch, let ci = self.indexOfClip(clipID, on: ti) else {
                self.abandonPendingFile(trimmed.url)
                m.status = "Trim cancelled — the clip changed while it ran"
                return
            }
            self.pushUndo()
            m.tracks[ti].clips[ci] = TrackClip(url: trimmed.url, duration: trimmed.duration,
                                               peaks: trimmed.peaks)
            self.registerSessionFile(trimmed.url)   // now referenced, so it can be swept again
            self.trackBuffers[ti] = nil
            self.loadTrackBuffer(ti)
            // Closing the editor ends this session too, so the waveform read opened with
            // it can't land on whatever the user opens next.
            self.trimSession += 1
            m.trimmingTrack = nil
            m.trimPeaks = []
            m.status = "Trimmed → \(trimmed.url.lastPathComponent)"
        }
    }

    // MARK: - Split & Duplicate

    func splitClipAtPlayhead(_ trackIndex: Int) {
        guard trackIndex < manager.tracks.count, !manager.tracks[trackIndex].clips.isEmpty else {
            manager.status = "No clip to split on TRK \(String(format: "%02d", trackIndex + 1))"
            return
        }
        // Read the split point first: stopping the loop below resets this track's
        // playhead to zero, and a running loop would keep advancing it.
        let progress = manager.live.playhead.trackProgress[trackIndex]
        guard progress > 0.001 && progress < 0.999 else {
            manager.status = "Move playhead inside clip to split"
            return
        }

        let epoch = editEpoch
        let clipIndex = manager.tracks[trackIndex].clips.count - 1
        let clip = manager.tracks[trackIndex].clips[clipIndex]
        let clipID = clip.id
        let srcURL = clip.url
        let wasPlaying = manager.tracks[trackIndex].isPlaying
        if wasPlaying { stopTrackLoop(trackIndex) }

        manager.runOffMain(busy: "Splitting…") { () -> EditOutcome in
            guard let srcFile = try? AVAudioFile(forReading: srcURL) else {
                return .failed("Cannot read clip file")
            }
            let totalFrames = Int64(srcFile.length)
            let splitFrame = Int64(progress * Double(totalFrames))
            let framesA = AVAudioFrameCount(splitFrame)
            let framesB = AVAudioFrameCount(totalFrames - splitFrame)
            guard framesA > 0 && framesB > 0 else {
                return .failed("Split point too close to edge")
            }

            let dir = srcURL.deletingLastPathComponent()
            let sr = srcFile.fileFormat.sampleRate

            // Part A: frames 0..<splitFrame. Nothing is registered as a session file
            // until the apply below installs the clips, so a failure here only has to
            // delete what it wrote.
            srcFile.framePosition = 0
            guard let bufA = AVAudioPCMBuffer(pcmFormat: srcFile.processingFormat,
                                              frameCapacity: framesA) else {
                return .failed("Cannot allocate a buffer for the split")
            }
            do { try srcFile.read(into: bufA, frameCount: framesA) }
            catch { return .failed("Split read error") }
            let urlA = dir.appendingPathComponent("\(uniqueFileStem("split_A")).wav")
            do {
                let outA = try AVAudioFile(forWriting: urlA, settings: srcFile.fileFormat.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                try outA.write(from: bufA)
            } catch {
                try? FileManager.default.removeItem(at: urlA)   // a failed write can leave a partial file
                return .failed("Split write error: \(error.localizedDescription)")
            }

            // Part B: frames splitFrame..<totalFrames
            srcFile.framePosition = splitFrame
            guard let bufB = AVAudioPCMBuffer(pcmFormat: srcFile.processingFormat,
                                              frameCapacity: framesB) else {
                try? FileManager.default.removeItem(at: urlA)
                return .failed("Cannot allocate a buffer for the split")
            }
            do { try srcFile.read(into: bufB, frameCount: framesB) } catch {
                try? FileManager.default.removeItem(at: urlA)
                return .failed("Split read error")
            }
            let urlB = dir.appendingPathComponent("\(uniqueFileStem("split_B")).wav")
            do {
                let outB = try AVAudioFile(forWriting: urlB, settings: srcFile.fileFormat.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                try outB.write(from: bufB)
            } catch {
                try? FileManager.default.removeItem(at: urlB)
                try? FileManager.default.removeItem(at: urlA)
                return .failed("Split write error: \(error.localizedDescription)")
            }

            return .produced([
                EditedClip(url: urlA, duration: Double(framesA) / sr,
                           peaks: computePeaks(url: urlA, count: Theme.clipPeaks)),
                EditedClip(url: urlB, duration: Double(framesB) / sr,
                           peaks: computePeaks(url: urlB, count: Theme.clipPeaks)),
            ])
        } apply: { [weak self] outcome in
            guard let self else { return }
            let m = self.manager
            guard case .produced(let made) = outcome, made.count == 2 else {
                if case .failed(let message) = outcome { m.status = message }
                // The track was stopped before the file work began, so put it back the
                // way it was found — a split that didn't happen shouldn't stop playback.
                if wasPlaying { self.startTrackLoop(trackIndex) }
                return
            }
            let (partA, partB) = (made[0], made[1])
            self.registerPendingFile(partA.url)   // exempt from the sweep `pushUndo` runs
            self.registerPendingFile(partB.url)
            guard epoch == self.editEpoch, let ci = self.indexOfClip(clipID, on: trackIndex) else {
                self.abandonPendingFile(partA.url)
                self.abandonPendingFile(partB.url)
                m.status = "Split cancelled — the clip changed while it ran"
                return
            }

            self.pushUndo()
            m.tracks[trackIndex].clips.remove(at: ci)
            m.tracks[trackIndex].clips.insert(
                TrackClip(url: partA.url, duration: partA.duration, peaks: partA.peaks), at: ci)
            m.tracks[trackIndex].clips.insert(
                TrackClip(url: partB.url, duration: partB.duration, peaks: partB.peaks), at: ci + 1)
            self.registerSessionFile(partA.url)   // now referenced, so they can be swept again
            self.registerSessionFile(partB.url)

            self.trackBuffers[trackIndex] = nil
            self.loadTrackBuffer(trackIndex)
            m.projectDirty = true
            m.status = "Split TRK \(String(format: "%02d", trackIndex + 1)) at \(Int(progress * 100))%"
        }
    }

    func duplicateClip(_ trackIndex: Int, clipIndex: Int? = nil) {
        guard trackIndex < manager.tracks.count, !manager.tracks[trackIndex].clips.isEmpty else {
            manager.status = "No clip to duplicate on TRK \(String(format: "%02d", trackIndex + 1))"
            return
        }
        let epoch = editEpoch
        let ci = clipIndex ?? (manager.tracks[trackIndex].clips.count - 1)
        guard ci >= 0 && ci < manager.tracks[trackIndex].clips.count else { return }
        let clip = manager.tracks[trackIndex].clips[ci]
        let clipID = clip.id

        let dir = clip.url.deletingLastPathComponent()
        let base = clip.url.deletingPathExtension().lastPathComponent
        let ext = clip.url.pathExtension
        // Name the copy on the main thread, at tap time, so two quick duplicates are
        // numbered in the order they were asked for.
        let dupURL = dir.appendingPathComponent("\(uniqueFileStem("\(base)_dup")).\(ext)")

        manager.runOffMain(busy: "Duplicating…") { () -> EditOutcome in
            do { try FileManager.default.copyItem(at: clip.url, to: dupURL) }
            catch { return .failed("Duplicate error: \(error.localizedDescription)") }
            return .produced([EditedClip(url: dupURL, duration: clip.duration,
                                         peaks: computePeaks(url: dupURL, count: Theme.clipPeaks))])
        } apply: { [weak self] outcome in
            guard let self else { return }
            let m = self.manager
            guard case .produced(let made) = outcome, let copy = made.first else {
                if case .failed(let message) = outcome { m.status = message }
                return
            }
            self.registerPendingFile(copy.url)   // exempt from the sweep `pushUndo` runs
            guard epoch == self.editEpoch, let at = self.indexOfClip(clipID, on: trackIndex) else {
                self.abandonPendingFile(copy.url)
                m.status = "Duplicate cancelled — the clip changed while it ran"
                return
            }
            self.pushUndo()
            // The copy keeps the original's fades, and is the clip that ends up selected.
            m.tracks[trackIndex].clips.insert(
                TrackClip(url: copy.url, duration: copy.duration, peaks: copy.peaks,
                          fadeIn: clip.fadeIn, fadeOut: clip.fadeOut), at: at + 1)
            self.registerSessionFile(copy.url)   // now referenced, so it can be swept again
            self.trackBuffers[trackIndex] = nil
            self.loadTrackBuffer(trackIndex)
            m.projectDirty = true
            m.status = "Duplicated clip → \(copy.url.lastPathComponent)"
        }
    }

    // MARK: - Export

    func exportTrack(_ trackIndex: Int) {
        guard trackIndex < manager.tracks.count, let clip = manager.tracks[trackIndex].clips.last else {
            manager.status = "No clip to export on TRK \(String(format: "%02d", trackIndex + 1))"
            return
        }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "TRK\(String(format: "%02d", trackIndex + 1))_\(timestampFmt.string(from: Date())).wav"
        panel.title = "Export Track \(trackIndex + 1)"
        let srcURL = clip.url
        panel.begin { [weak self] response in
            guard let self, response == .OK, let destURL = panel.url else { return }
            self.manager.runOffMain(busy: "Exporting…") { () -> String? in
                do { try FileManager.default.copyItem(at: srcURL, to: destURL); return nil }
                catch { return error.localizedDescription }
            } apply: { [weak self] error in
                guard let self else { return }
                self.manager.status = error.map { "Export error: \($0)" }
                    ?? "Exported → \(destURL.lastPathComponent)"
            }
        }
        #else
        manager.status = "Export is not available on iPad yet"
        #endif
    }

    func importAudioFile(_ url: URL, toTrack trackIndex: Int) {
        guard trackIndex < manager.tracks.count else { return }

        // The destination is fixed here so the copy and the peaks read below can run
        // off-main against a path that no longer depends on the save location.
        let trackDir = manager.saveLocation.appendingPathComponent("Track \(String(format: "%02d", trackIndex + 1))")
        let destURL = trackDir.appendingPathComponent(url.lastPathComponent)
        let epoch = editEpoch

        manager.runOffMain(busy: "Importing…") { () -> EditOutcome in
            let fm = FileManager.default
            // Validate it's a readable audio file
            guard let file = try? AVAudioFile(forReading: url) else {
                return .failed("Cannot read audio file: \(url.lastPathComponent)")
            }
            // Copy into track directory. A file already sitting at the destination is
            // reused as-is — it may not be ours to overwrite.
            try? fm.createDirectory(at: trackDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: destURL.path) {
                do { try fm.copyItem(at: url, to: destURL) }
                catch { return .failed("Import error: \(error.localizedDescription)") }
            }
            return .produced([EditedClip(url: destURL,
                                         duration: Double(file.length) / file.fileFormat.sampleRate,
                                         peaks: computePeaks(url: destURL, count: Theme.clipPeaks))])
        } apply: { [weak self] outcome in
            guard let self else { return }
            let m = self.manager
            guard case .produced(let made) = outcome, let imported = made.first else {
                if case .failed(let message) = outcome { m.status = message }
                return
            }
            // Deliberately not registered as a session file: it is the user's own audio
            // copied in, and the name came from their file, so the orphan sweep must
            // never decide it is spare. See `sessionCreatedFiles`.
            guard epoch == self.editEpoch else {
                m.status = "Import cancelled — the session changed while it ran"
                return
            }
            self.pushUndo()
            m.tracks[trackIndex].clips.append(
                TrackClip(url: imported.url, duration: imported.duration, peaks: imported.peaks))
            self.loadTrackBuffer(trackIndex)
            m.projectDirty = true
            m.status = "Imported \(url.lastPathComponent) → TRK \(String(format: "%02d", trackIndex + 1))"
        }
    }

    func changeSaveLocation() {
        #if os(macOS)
        let fm = FileManager.default
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose where TAPE 08 saves takes"
        panel.prompt = "Choose"
        // Start at the current folder when it exists; otherwise suggest the standard
        // Desktop location so a first-run user lands somewhere sensible.
        let current = manager.saveLocation
        let suggested = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/OP-XY Monitor")
        if fm.fileExists(atPath: current.path) { panel.directoryURL = current }
        else if fm.fileExists(atPath: suggested.path) { panel.directoryURL = suggested }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                // Remembering the choice (a security-scoped bookmark when sandboxed)
                // is what lets the folder survive relaunch.
                SaveLocation.remember(url)
                self?.manager.saveLocation = url
                self?.manager.status = "Save location → \(url.path)"
            }
        }
        #else
        manager.status = "Save location is fixed to the app's Documents folder on iPad"
        #endif
    }

    // MARK: - Mixdown Export

    func bounceMixdown() {
        #if os(macOS)
        let anySolo = manager.tracks.contains { $0.solo }
        // Capture the audible tracks on the main thread; the mix below reads only this
        // snapshot, so an edit landing mid-bounce can't change what is being mixed.
        var sources: [(url: URL, volume: Float, pan: Float, fadeIn: Double, fadeOut: Double)] = []
        for t in manager.tracks {
            let audible = t.solo || (!anySolo && !t.muted)
            guard audible, let clip = t.clips.last else { continue }
            sources.append((clip.url, Float(t.volume), Float(t.pan), clip.fadeIn, clip.fadeOut))
        }
        guard !sources.isEmpty else { manager.status = "No audible tracks to bounce"; return }

        // The spinner covers the whole bounce — reading every clip and mixing it is the
        // slow part, and it is what the button being disabled is telling the user about.
        manager.bounceStatus = "Mixing..."
        manager.runOffMain(busy: "Mixing…") { () -> MixedDown? in
            // Read each source in full, fading its ends first. A track shorter than the
            // mix is loop-filled in the mix loop below, so its fade repeats each pass.
            var loaded: [(buffer: AVAudioPCMBuffer, volume: Float, pan: Float)] = []
            for src in sources {
                guard let file = try? AVAudioFile(forReading: src.url) else { continue }
                let frames = AVAudioFrameCount(file.length)
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: frames) else { continue }
                do { try file.read(into: buf) } catch { continue }
                applyClipFades(buf, fadeIn: src.fadeIn, fadeOut: src.fadeOut)
                loaded.append((buf, src.volume, src.pan))
            }
            guard !loaded.isEmpty else { return nil }

            let maxFrames = loaded.map { Int($0.buffer.frameLength) }.max()!
            let fmt = loaded[0].buffer.format
            let channels = Int(fmt.channelCount)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                                                frameCapacity: AVAudioFrameCount(maxFrames)) else { return nil }
            outBuf.frameLength = AVAudioFrameCount(maxFrames)

            // Zero the output before accumulating into it
            for ch in 0..<channels {
                let ptr = outBuf.floatChannelData![ch]
                for f in 0..<maxFrames { ptr[f] = 0 }
            }

            // Mix each source into the output
            for src in loaded {
                let srcLen = Int(src.buffer.frameLength)
                // Simple equal-power pan: left = cos(angle), right = sin(angle)
                let angle = (src.pan + 1.0) * 0.5 * Float.pi * 0.5  // 0..pi/2
                let gainL = src.volume * cosf(angle)
                let gainR = src.volume * sinf(angle)
                let gains = channels >= 2 ? [gainL, gainR] : [src.volume]

                for ch in 0..<min(channels, 2) {
                    let outPtr = outBuf.floatChannelData![ch]
                    let srcPtr = src.buffer.floatChannelData![min(ch, Int(src.buffer.format.channelCount) - 1)]
                    let g = gains[ch]
                    for f in 0..<maxFrames {
                        let srcFrame = f % srcLen  // loop shorter tracks
                        outPtr[f] += srcPtr[srcFrame] * g
                    }
                }
            }

            // Soft-clip via tanh to prevent digital overs
            for ch in 0..<channels {
                let ptr = outBuf.floatChannelData![ch]
                for f in 0..<maxFrames { ptr[f] = tanhf(ptr[f]) }
            }

            return MixedDown(buffer: outBuf, sampleRate: fmt.sampleRate, channels: channels)
        } apply: { [weak self] mixed in
            guard let self else { return }
            let m = self.manager
            guard let mixed else {
                m.bounceStatus = nil
                m.status = "No readable tracks to bounce"
                return
            }

            // Present save panel
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType.wav]
            panel.nameFieldStringValue = "Mixdown_\(timestampFmt.string(from: Date())).wav"
            panel.begin { [weak self] response in
                guard let self, response == .OK, let url = panel.url else {
                    self?.manager.bounceStatus = nil
                    return
                }
                self.manager.runOffMain(busy: "Exporting mixdown…") { () -> String? in
                    do {
                        let settings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: mixed.sampleRate,
                            AVNumberOfChannelsKey: mixed.channels,
                            AVLinearPCMBitDepthKey: 32,
                            AVLinearPCMIsFloatKey: true,
                            AVLinearPCMIsNonInterleaved: true,
                        ]
                        let outFile = try AVAudioFile(forWriting: url, settings: settings,
                                                      commonFormat: .pcmFormatFloat32, interleaved: false)
                        try outFile.write(from: mixed.buffer)
                        return nil
                    } catch { return error.localizedDescription }
                } apply: { [weak self] error in
                    guard let self else { return }
                    self.manager.bounceStatus = nil
                    self.manager.status = error.map { "Mixdown error: \($0)" }
                        ?? "Mixdown exported → \(url.lastPathComponent)"
                }
            }
        }
        #else
        manager.status = "Mixdown is not available on iPad yet"
        #endif
    }

    // MARK: - Track Helpers

    func toggleMute(_ i: Int) { pushUndo(); manager.tracks[i].muted.toggle(); refreshTrackMixers() }
    func toggleSolo(_ i: Int) { pushUndo(); manager.tracks[i].solo.toggle(); refreshTrackMixers() }
    func setTrackVolume(_ i: Int, _ v: Double) { pushUndoIfNeeded(); manager.tracks[i].volume = v; refreshTrackMixers() }
    func setTrackPan(_ i: Int, _ p: Double) { pushUndoIfNeeded(); manager.tracks[i].pan = p; refreshTrackMixers() }

    func refreshTrackMixers() {
        let anySolo = manager.tracks.contains { $0.solo }
        for i in 0..<manager.tracks.count where i < trackMixers.count {
            let t = manager.tracks[i]
            let audible = t.solo || (!anySolo && !t.muted)
            trackMixers[i].outputVolume = audible ? Float(t.volume) : 0
            trackMixers[i].pan = Float(t.pan)
        }
    }

    // Decodes the track's last clip off the main thread (long recordings are tens of
    // MB), then publishes the buffer back on main. `completion` runs on the main
    // thread once the buffer is ready (or immediately if there was nothing to load),
    // so playback callers can defer scheduling until the read finishes.
    func loadTrackBuffer(_ i: Int, completion: ((Bool) -> Void)? = nil) {
        guard i < manager.tracks.count, let lastClip = manager.tracks[i].clips.last else {
            completion?(false)
            return
        }
        let url = lastClip.url
        let fadeIn = lastClip.fadeIn
        let fadeOut = lastClip.fadeOut
        // Claim a generation before the decode starts, so a load that is superseded
        // while it runs can tell that its result is stale.
        loadGenerations[i] += 1
        let gen = loadGenerations[i]
        performOffMain { () -> AVAudioPCMBuffer? in
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            let frames = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
            else { return nil }
            try? file.read(into: buffer)
            // Bake the clip's anti-click fades in once, so playback and loop
            // re-scheduling reuse a faded buffer (and the loop seam is clean).
            applyClipFades(buffer, fadeIn: fadeIn, fadeOut: fadeOut)
            return buffer
        } apply: { [weak self] loaded in
            guard let self else { return }
            // Another load — a later edit, or a restore that replaced the clip set —
            // has superseded this one. Publishing now would install a buffer for a
            // clip that is no longer the track's last.
            guard gen == self.loadGenerations[i] else { completion?(false); return }
            if let loaded, i < self.trackBuffers.count { self.trackBuffers[i] = loaded }
            completion?(loaded != nil)
        }
    }

    func trackFolder(_ index: Int) -> URL {
        let dir = manager.saveLocation.appendingPathComponent("Track \(index + 1)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
