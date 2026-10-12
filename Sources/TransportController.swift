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

    init(manager: AudioManager) {
        self.manager = manager
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Track mixer nodes, in track order (used by the metering taps).
    var mixers: [AVAudioMixerNode] { trackMixers }

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
                        manager.live.trackProgress[i] = cur / total
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
        manager.live.trackProgress[i] = 0
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
            manager.live.trackProgress[i] = 0
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
        manager.status = "Undo"
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(manager.tracks)
        if undoStack.count > 30 { undoStack.removeFirst() }
        restoreTracks(snapshot)
        manager.status = "Redo"
    }

    private func restoreTracks(_ snapshot: [TrackInfo]) {
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
            manager.live.trackProgress[i] = 0
        }
        manager.isPlaying = false
        refreshTrackMixers()
    }

    func clearAll() {
        pushUndo()
        stopAll()
        for i in 0..<manager.tracks.count {
            manager.tracks[i].clips.removeAll()
            trackBuffers[i] = nil
        }
        manager.recordings.removeAll()
        manager.status = "All tracks cleared"
    }

    // MARK: - Trim Editor

    func openTrimEditor(_ trackIndex: Int) {
        guard trackIndex < manager.tracks.count, let clip = manager.tracks[trackIndex].clips.last else { return }
        if manager.tracks[trackIndex].isPlaying { stopTrackLoop(trackIndex) }
        manager.trimClipDuration = clip.duration
        manager.trimPeaks = computePeaks(url: clip.url, count: 256)
        manager.trimStart = 0
        manager.trimEnd = 1
        manager.trimmingTrack = trackIndex
    }

    func cancelTrim() {
        manager.trimmingTrack = nil
        manager.trimPeaks = []
    }

    func applyTrim() {
        guard let ti = manager.trimmingTrack, ti < manager.tracks.count,
              let clip = manager.tracks[ti].clips.last else { return }
        pushUndo()
        guard let srcFile = try? AVAudioFile(forReading: clip.url) else { return }
        let totalFrames = Int64(srcFile.length)
        let startFrame = Int64(manager.trimStart * Double(totalFrames))
        let endFrame = Int64(manager.trimEnd * Double(totalFrames))
        let trimmedFrames = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard trimmedFrames > 0 else { return }

        // Read the source region
        srcFile.framePosition = startFrame
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFile.processingFormat, frameCapacity: trimmedFrames) else { return }
        do { try srcFile.read(into: readBuf, frameCount: trimmedFrames) } catch { return }

        // Write trimmed file
        let dir = clip.url.deletingLastPathComponent()
        let trimName = "trim_\(timestampFmt.string(from: Date())).wav"
        let trimURL = dir.appendingPathComponent(trimName)
        do {
            let outFile = try AVAudioFile(forWriting: trimURL, settings: srcFile.fileFormat.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
            try outFile.write(from: readBuf)
        } catch { manager.status = "Trim error: \(error.localizedDescription)"; return }

        // Replace clip
        let dur = Double(trimmedFrames) / srcFile.fileFormat.sampleRate
        let peaks = computePeaks(url: trimURL, count: Theme.clipPeaks)
        manager.tracks[ti].clips[manager.tracks[ti].clips.count - 1] = TrackClip(url: trimURL, duration: dur, peaks: peaks)
        trackBuffers[ti] = nil
        loadTrackBuffer(ti)
        manager.trimmingTrack = nil
        manager.trimPeaks = []
        manager.status = "Trimmed → \(trimName)"
    }

    // MARK: - Split & Duplicate

    func splitClipAtPlayhead(_ trackIndex: Int) {
        guard trackIndex < manager.tracks.count, !manager.tracks[trackIndex].clips.isEmpty else {
            manager.status = "No clip to split on TRK \(String(format: "%02d", trackIndex + 1))"
            return
        }
        let progress = manager.live.trackProgress[trackIndex]
        guard progress > 0.001 && progress < 0.999 else {
            manager.status = "Move playhead inside clip to split"
            return
        }

        let clipIndex = manager.tracks[trackIndex].clips.count - 1
        let clip = manager.tracks[trackIndex].clips[clipIndex]
        guard let srcFile = try? AVAudioFile(forReading: clip.url) else {
            manager.status = "Cannot read clip file"; return
        }
        let totalFrames = Int64(srcFile.length)
        let splitFrame = Int64(progress * Double(totalFrames))
        let framesA = AVAudioFrameCount(splitFrame)
        let framesB = AVAudioFrameCount(totalFrames - splitFrame)
        guard framesA > 0 && framesB > 0 else {
            manager.status = "Split point too close to edge"; return
        }

        let wasPlaying = manager.tracks[trackIndex].isPlaying
        if wasPlaying { stopTrackLoop(trackIndex) }

        let dir = clip.url.deletingLastPathComponent()
        let ts = timestampFmt.string(from: Date())

        // Part A: frames 0..<splitFrame
        srcFile.framePosition = 0
        guard let bufA = AVAudioPCMBuffer(pcmFormat: srcFile.processingFormat, frameCapacity: framesA) else { return }
        do { try srcFile.read(into: bufA, frameCount: framesA) } catch { manager.status = "Split read error"; return }
        let urlA = dir.appendingPathComponent("split_A_\(ts).wav")
        do {
            let outA = try AVAudioFile(forWriting: urlA, settings: srcFile.fileFormat.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try outA.write(from: bufA)
        } catch { manager.status = "Split write error: \(error.localizedDescription)"; return }

        // Part B: frames splitFrame..<totalFrames
        srcFile.framePosition = splitFrame
        guard let bufB = AVAudioPCMBuffer(pcmFormat: srcFile.processingFormat, frameCapacity: framesB) else { return }
        do { try srcFile.read(into: bufB, frameCount: framesB) } catch { manager.status = "Split read error"; return }
        let urlB = dir.appendingPathComponent("split_B_\(ts).wav")
        do {
            let outB = try AVAudioFile(forWriting: urlB, settings: srcFile.fileFormat.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try outB.write(from: bufB)
        } catch { manager.status = "Split write error: \(error.localizedDescription)"; return }

        let sr = srcFile.fileFormat.sampleRate
        let clipA = TrackClip(url: urlA, duration: Double(framesA) / sr,
                              peaks: computePeaks(url: urlA, count: Theme.clipPeaks))
        let clipB = TrackClip(url: urlB, duration: Double(framesB) / sr,
                              peaks: computePeaks(url: urlB, count: Theme.clipPeaks))

        pushUndo()
        manager.tracks[trackIndex].clips.remove(at: clipIndex)
        manager.tracks[trackIndex].clips.insert(clipA, at: clipIndex)
        manager.tracks[trackIndex].clips.insert(clipB, at: clipIndex + 1)

        trackBuffers[trackIndex] = nil
        loadTrackBuffer(trackIndex)
        manager.projectDirty = true
        manager.status = "Split TRK \(String(format: "%02d", trackIndex + 1)) at \(Int(progress * 100))%"
    }

    func duplicateClip(_ trackIndex: Int, clipIndex: Int? = nil) {
        guard trackIndex < manager.tracks.count, !manager.tracks[trackIndex].clips.isEmpty else {
            manager.status = "No clip to duplicate on TRK \(String(format: "%02d", trackIndex + 1))"
            return
        }
        let ci = clipIndex ?? (manager.tracks[trackIndex].clips.count - 1)
        guard ci >= 0 && ci < manager.tracks[trackIndex].clips.count else { return }
        let clip = manager.tracks[trackIndex].clips[ci]

        let fm = FileManager.default
        let dir = clip.url.deletingLastPathComponent()
        let base = clip.url.deletingPathExtension().lastPathComponent
        let ext = clip.url.pathExtension
        let ts = timestampFmt.string(from: Date())
        let dupURL = dir.appendingPathComponent("\(base)_dup_\(ts).\(ext)")
        do {
            try fm.copyItem(at: clip.url, to: dupURL)
        } catch {
            manager.status = "Duplicate error: \(error.localizedDescription)"; return
        }

        let peaks = computePeaks(url: dupURL, count: Theme.clipPeaks)
        let newClip = TrackClip(url: dupURL, duration: clip.duration, peaks: peaks,
                                fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
        pushUndo()
        manager.tracks[trackIndex].clips.insert(newClip, at: ci + 1)
        trackBuffers[trackIndex] = nil
        loadTrackBuffer(trackIndex)
        manager.projectDirty = true
        manager.status = "Duplicated clip → \(dupURL.lastPathComponent)"
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
        panel.begin { [weak self] response in
            guard response == .OK, let destURL = panel.url else { return }
            do {
                try FileManager.default.copyItem(at: clip.url, to: destURL)
                DispatchQueue.main.async { self?.manager.status = "Exported → \(destURL.lastPathComponent)" }
            } catch {
                DispatchQueue.main.async { self?.manager.status = "Export error: \(error.localizedDescription)" }
            }
        }
        #else
        manager.status = "Export is not available on iPad yet"
        #endif
    }

    func importAudioFile(_ url: URL, toTrack trackIndex: Int) {
        guard trackIndex < manager.tracks.count else { return }
        let fm = FileManager.default

        // Validate it's a readable audio file
        guard let file = try? AVAudioFile(forReading: url) else {
            manager.status = "Cannot read audio file: \(url.lastPathComponent)"
            return
        }

        // Copy into track directory
        let trackDir = manager.saveLocation.appendingPathComponent("Track \(String(format: "%02d", trackIndex + 1))")
        try? fm.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let destURL = trackDir.appendingPathComponent(url.lastPathComponent)
        if !fm.fileExists(atPath: destURL.path) {
            do { try fm.copyItem(at: url, to: destURL) }
            catch { manager.status = "Import error: \(error.localizedDescription)"; return }
        }

        let duration = Double(file.length) / file.fileFormat.sampleRate
        let peaks = computePeaks(url: destURL, count: Theme.clipPeaks)
        let clip = TrackClip(url: destURL, duration: duration, peaks: peaks)
        pushUndo()
        manager.tracks[trackIndex].clips.append(clip)
        loadTrackBuffer(trackIndex)
        manager.projectDirty = true
        manager.status = "Imported \(url.lastPathComponent) → TRK \(String(format: "%02d", trackIndex + 1))"
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
        // Collect audible tracks with audio
        var sources: [(buffer: AVAudioPCMBuffer, volume: Float, pan: Float)] = []
        for (_, t) in manager.tracks.enumerated() {
            let audible = t.solo || (!anySolo && !t.muted)
            guard audible, let clip = t.clips.last else { continue }
            guard let file = try? AVAudioFile(forReading: clip.url) else { continue }
            let frames = AVAudioFrameCount(file.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { continue }
            do { try file.read(into: buf) } catch { continue }
            sources.append((buf, Float(t.volume), Float(t.pan)))
        }
        guard !sources.isEmpty else { manager.status = "No audible tracks to bounce"; return }

        // Find the longest track duration
        let maxFrames = sources.map { Int($0.buffer.frameLength) }.max()!
        let fmt = sources[0].buffer.format
        let sr = fmt.sampleRate
        let channels = Int(fmt.channelCount)

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(maxFrames)) else { return }
        outBuf.frameLength = AVAudioFrameCount(maxFrames)

        // Zero the output
        for ch in 0..<channels {
            let ptr = outBuf.floatChannelData![ch]
            for f in 0..<maxFrames { ptr[f] = 0 }
        }

        manager.bounceStatus = "Mixing..."

        // Mix each source into the output
        for src in sources {
            let srcLen = Int(src.buffer.frameLength)
            let vol = src.volume
            // Simple equal-power pan: left = cos(angle), right = sin(angle)
            let angle = (src.pan + 1.0) * 0.5 * Float.pi * 0.5  // 0..pi/2
            let gainL = vol * cosf(angle)
            let gainR = vol * sinf(angle)
            let gains = channels >= 2 ? [gainL, gainR] : [vol]

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

        // Present save panel
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.wav]
        panel.nameFieldStringValue = "Mixdown_\(timestampFmt.string(from: Date())).wav"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                DispatchQueue.main.async { self?.manager.bounceStatus = nil }
                return
            }
            do {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sr,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                ]
                let outFile = try AVAudioFile(forWriting: url, settings: settings,
                                               commonFormat: .pcmFormatFloat32, interleaved: false)
                try outFile.write(from: outBuf)
                DispatchQueue.main.async {
                    self?.manager.bounceStatus = nil
                    self?.manager.status = "Mixdown exported → \(url.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.manager.bounceStatus = nil
                    self?.manager.status = "Mixdown error: \(error.localizedDescription)"
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded: AVAudioPCMBuffer?
            if let file = try? AVAudioFile(forReading: url) {
                let frames = AVAudioFrameCount(file.length)
                if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) {
                    try? file.read(into: buffer)
                    loaded = buffer
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let loaded, i < self.trackBuffers.count { self.trackBuffers[i] = loaded }
                completion?(loaded != nil)
            }
        }
    }

    func trackFolder(_ index: Int) -> URL {
        let dir = manager.saveLocation.appendingPathComponent("Track \(index + 1)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
