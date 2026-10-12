// MetronomeController.swift — sample-accurate click track + tap tempo
//
// Owns the metronome player node, its low-frequency queue-refill timer, the
// generated click buffers, and the sample-accurate scheduling state. The
// published metronome settings (enabled/BPM/volume/flash) stay on AudioManager
// so views keep binding to them; this controller reads and writes those through
// its `manager` reference, which keeps objectWillChange firing as before.

import Foundation
import AVFoundation

final class MetronomeController {
    private unowned let manager: AudioManager

    // Graph nodes, handed over after the engine builds them (see attach()).
    private var player: AVAudioPlayerNode?
    private var mixer:  AVAudioMixerNode?
    private var clickBuffer: AVAudioPCMBuffer?

    // Queue-refill timer + scheduling state
    private var timer: Timer?
    private var beatCount = 0
    private var nextBeatFrame: Double = 0
    private var scheduledBPM: Double = 0

    // Beat observation. Whatever needs to act *on* the beat — today the count-in — listens
    // here rather than running its own clock, so it acts on the grid instead of near it.
    private struct ScheduledBeat {
        let index: Int      // position in the bar: 0 is a downbeat
        let frame: Double   // the player node's own timeline
    }
    private var beatTable: [ScheduledBeat] = []
    private var observerTimer: Timer?
    private var onBeat: ((Int) -> Void)?

    // Tap tempo
    private var tapTimestamps: [Date] = []

    init(manager: AudioManager) {
        self.manager = manager
    }

    deinit {
        timer?.invalidate()
        observerTimer?.invalidate()
    }

    /// True while the refill timer is installed (i.e. the metronome is running).
    var isRunning: Bool { timer != nil }

    // MARK: - Graph handoff

    func attach(player: AVAudioPlayerNode, mixer: AVAudioMixerNode, sampleRate: Double) {
        self.player = player
        self.mixer = mixer
        self.clickBuffer = MetronomeController.generateClickBuffer(sampleRate: sampleRate, channels: 2)
        mixer.outputVolume = Float(manager.metronomeVolume)
    }

    func detach() {
        stop()
        player = nil
        mixer = nil
        clickBuffer = nil
    }

    // MARK: - Public controls (forwarded from AudioManager)

    func toggle() {
        manager.metronomeEnabled.toggle()
        if manager.tracks.contains(where: { $0.isPlaying }) {
            if manager.metronomeEnabled { start() } else { stop() }
        }
    }

    func setVolume(_ v: Double) {
        manager.metronomeVolume = v
        mixer?.outputVolume = Float(v)
    }

    func tapTempo() {
        let now = Date()
        // Reset if more than 2 seconds since last tap
        if let last = tapTimestamps.last, now.timeIntervalSince(last) > 2.0 {
            tapTimestamps.removeAll()
        }
        tapTimestamps.append(now)
        // Keep last 8 taps
        if tapTimestamps.count > 8 { tapTimestamps.removeFirst() }
        // Need at least 2 taps to calculate
        if tapTimestamps.count >= 2 {
            var totalInterval: TimeInterval = 0
            for i in 1..<tapTimestamps.count {
                totalInterval += tapTimestamps[i].timeIntervalSince(tapTimestamps[i - 1])
            }
            let avgInterval = totalInterval / Double(tapTimestamps.count - 1)
            let newBPM = 60.0 / avgInterval
            manager.metronomeBPM = min(300, max(40, newBPM.rounded()))
        }
        // Visual flash
        manager.tapTempoFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.manager.tapTempoFlash = false
        }
    }

    // MARK: - Scheduling

    func start() {
        guard manager.metronomeEnabled, let player = player, let click = clickBuffer else { return }
        let accentClick = MetronomeController.generateAccentClickBuffer(
            sampleRate: click.format.sampleRate, channels: click.format.channelCount) ?? click
        let sr = click.format.sampleRate

        beatCount = 0
        nextBeatFrame = 0
        scheduledBPM = manager.metronomeBPM
        player.stop()
        player.play()
        refill(accent: accentClick, click: click, sampleRate: sr)

        // Beats are queued sample-accurately ~2 s ahead, so this timer only tops up the
        // queue; its jitter is inaudible.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refill(accent: accentClick, click: click, sampleRate: sr)
        }
    }

    // Queues any beats that fall within the lookahead window at their exact frame
    // positions on the player node's timeline.
    private func refill(accent: AVAudioPCMBuffer, click: AVAudioPCMBuffer, sampleRate: Double) {
        guard let player = player, manager.metronomeEnabled else { return }

        // Tempo changed. The queue holds ~2 s of beats already spaced at the *old* tempo,
        // and nothing can re-space a queued buffer, so stopping the node is the only way
        // to flush it. Carry the beat phase across the restart instead of starting a new
        // bar: the node's timeline restarts at 0, so the remainder of the beat in progress
        // is expressed from there.
        if scheduledBPM != manager.metronomeBPM, scheduledBPM > 0 {
            let oldInterval = framesPerBeat(sampleRate: sampleRate, bpm: scheduledBPM)
            let newInterval = framesPerBeat(sampleRate: sampleRate, bpm: manager.metronomeBPM)
            // How far into the beat in progress we already are, 0…1. That beat began one
            // old interval before the next one is due.
            var phase: Double = 0
            if let oldInterval {
                let elapsed = playheadFrame(of: player) - (nextBeatFrame - oldInterval)
                phase = min(max(elapsed / oldInterval, 0), 1)
            }
            player.stop()
            player.play()
            scheduledBPM = manager.metronomeBPM
            nextBeatFrame = newInterval.map { (1 - phase) * $0 } ?? 0
            // beatCount is deliberately left alone: the accent pattern continues on the
            // same beats of the bar rather than restarting the bar under the user.
            //
            // The queued beats died with the old timeline, so their frames describe
            // nothing now. An observer would act on a beat that never sounds; refill
            // below repopulates from the new grid.
            beatTable.removeAll(keepingCapacity: true)
        }

        guard let interval = framesPerBeat(sampleRate: sampleRate, bpm: manager.metronomeBPM) else { return }

        // Current playhead position on the node's timeline (0 until it starts rendering).
        let nowFrame = playheadFrame(of: player)
        // If we've fallen behind (e.g. after a stall), resume just ahead of the playhead.
        if nextBeatFrame < nowFrame { nextBeatFrame = nowFrame }

        let horizon = nowFrame + sampleRate * 2.0
        while nextBeatFrame < horizon {
            let isAccent = beatCount % 4 == 0
            let at = AVAudioTime(sampleTime: AVAudioFramePosition(nextBeatFrame.rounded()),
                                 atRate: sampleRate)
            player.scheduleBuffer(isAccent ? accent : click, at: at, options: [], completionHandler: nil)
            // Recorded only while something is listening: the count-in is the only
            // observer, and a table nobody reads would grow for as long as the clicks run.
            if onBeat != nil {
                beatTable.append(ScheduledBeat(index: beatCount, frame: nextBeatFrame))
            }
            beatCount += 1
            nextBeatFrame += interval
        }
    }

    /// Frames in one beat at `bpm`, or nil when that is under a single frame or the tempo
    /// is not set — either way there is no grid to schedule against.
    private func framesPerBeat(sampleRate: Double, bpm: Double) -> Double? {
        guard bpm > 0 else { return nil }
        let frames = (60.0 / bpm) * sampleRate
        return frames >= 1 ? frames : nil
    }

    /// The player node's own sample clock, in frames: 0 until it starts rendering, and 0
    /// again after a stop/play, since the node's timeline restarts there.
    private func playheadFrame(of player: AVAudioPlayerNode) -> Double {
        guard let nodeTime = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(pt.sampleTime)
    }

    // MARK: - Beat observation

    /// Reports each beat to `handler` on the main thread, in order, as it sounds.
    ///
    /// Returns false when there is no grid to report from — the metronome is not running,
    /// which is the state a count-in finds when the user has the clicks switched off.
    /// Callers that need a beat either way have to bring their own clock.
    @discardableResult
    func observeBeats(_ handler: @escaping (Int) -> Void) -> Bool {
        guard isRunning, let player = player, let click = clickBuffer,
              let interval = framesPerBeat(sampleRate: click.format.sampleRate, bpm: scheduledBPM)
        else { return false }

        onBeat = handler
        rebuildBeatTable(from: playheadFrame(of: player), interval: interval)

        observerTimer?.invalidate()
        // Added in the common run-loop mode rather than the default one: a count-in that
        // stops counting because the user scrolled the timeline would start the take
        // whenever the scroll ended.
        let t = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.pollBeats() }
        RunLoop.main.add(t, forMode: .common)
        observerTimer = t
        // One pass now, so a beat that has just sounded is reported without waiting for
        // the first tick.
        pollBeats()
        return true
    }

    /// Stops reporting beats. Safe to call when nothing is observing.
    func disarmBeats() {
        observerTimer?.invalidate(); observerTimer = nil
        onBeat = nil
        beatTable.removeAll(keepingCapacity: true)
    }

    /// Fires the observer for every beat the player's clock has reached.
    private func pollBeats() {
        guard let player = player else { return }
        let now = playheadFrame(of: player)
        while let head = beatTable.first, head.frame <= now {
            beatTable.removeFirst()
            // Re-read every pass: the count-in disarms itself on the beat it was waiting
            // for, and a stall can leave several beats to catch up on in one pass.
            guard let handler = onBeat else { return }
            handler(head.index)
        }
    }

    /// Rebuilds the table from the beats `refill` has already queued.
    ///
    /// Without this the first beat an observer could ever see would be the one queued
    /// after the two-second lookahead drains — a bar of silence at the top of a count.
    private func rebuildBeatTable(from now: Double, interval: Double) {
        beatTable.removeAll(keepingCapacity: true)
        guard onBeat != nil else { return }

        // Walk back from the next unscheduled beat to the first that has not sounded. The
        // eighth-of-a-beat of slack is what makes a press landing within a 32nd note of a
        // click a press *on* that click; it also covers the frames between `play()` and the
        // node's clock reporting anything at all. Frames are rebuilt from `nextBeatFrame`
        // rather than by accumulating from the walk-back, so they land exactly on the beats
        // `refill` will schedule and no beat is reported twice.
        let slack = interval / 8
        let earliest = max(0, now - slack)
        var first = beatCount
        while first > 0 {
            // The beat before `first`, whose frame is `interval` below it.
            let previous = nextBeatFrame - Double(beatCount - first + 1) * interval
            guard previous >= earliest else { break }
            first -= 1
        }
        for i in first..<beatCount {
            beatTable.append(ScheduledBeat(index: i,
                                           frame: nextBeatFrame - Double(beatCount - i) * interval))
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop()
        beatCount = 0
        nextBeatFrame = 0
        scheduledBPM = 0
        // The beats in the table were frames on a timeline that no longer exists.
        disarmBeats()
    }

    // MARK: - Click generation

    private static func generateClickBuffer(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer? {
        let duration = 0.015
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard let data = buf.floatChannelData else { return nil }
        let freq: Float = 1000.0
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(sampleRate)
            let envelope = 1.0 - (Float(i) / Float(frames))
            let sample = sin(2.0 * .pi * freq * t) * envelope * 0.8
            for ch in 0..<Int(channels) { data[ch][i] = sample }
        }
        return buf
    }

    private static func generateAccentClickBuffer(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer? {
        let duration = 0.02
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard let data = buf.floatChannelData else { return nil }
        let freq: Float = 1500.0
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(sampleRate)
            let envelope = 1.0 - (Float(i) / Float(frames))
            let sample = sin(2.0 * .pi * freq * t) * envelope * 0.95
            for ch in 0..<Int(channels) { data[ch][i] = sample }
        }
        return buf
    }
}
