// MeterController.swift — render-thread meter taps + 60 Hz display smoothing
//
// Owns the lock-guarded raw meter snapshot the render-thread taps write into and
// the main-thread display timer that reads it, smooths, and publishes the values
// back onto AudioManager's @Published meter outputs. Keeping the two roles apart
// is what stops the render thread from racing the main thread on shared meter
// state: the taps only write `meters` under a lock; the timer owns everything else.

import Foundation
import AVFoundation
import os

final class MeterController {
    private unowned let manager: AudioManager

    // Render-thread taps publish raw levels into `meters` under a lock (cheap,
    // uncontended, no allocation); the display timer reads that snapshot on the main
    // thread, which owns all smoothing / peak-hold state.
    private struct MeterSnapshot {
        var levelL: Float = 0
        var levelR: Float = 0
        var track: [Float] = Array(repeating: 0, count: Theme.trackCount)
    }
    private let meters = OSAllocatedUnfairLock(initialState: MeterSnapshot())

    // Main-thread-only meter smoothing / peak-hold state
    private var rawPeakL:  Float = 0
    private var rawPeakR:  Float = 0
    private var peakHoldL: Int   = 0
    private var peakHoldR: Int   = 0

    private var displayTimer: Timer?
    private var postFXNode: AVAudioMixerNode?
    private var trackTapMixers: [AVAudioMixerNode] = []

    init(manager: AudioManager) {
        self.manager = manager
    }

    deinit {
        displayTimer?.invalidate()
    }

    // MARK: - Graph handoff

    /// Installs the post-FX metering tap on `liveMix` (meters show effected output).
    func attach(postFX: AVAudioMixerNode) {
        postFXNode = postFX
        postFX.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.processTap(buf)
        }
    }

    func installTrackTaps(_ mixers: [AVAudioMixerNode]) {
        trackTapMixers = mixers
        for i in 0..<mixers.count {
            mixers[i].installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
                guard let self, let data = buf.floatChannelData else { return }
                let n = Int(buf.frameLength)
                guard n > 0 else { return }
                var peak: Float = 0
                for s in 0..<n { peak = max(peak, abs(data[0][s])) }
                if buf.format.channelCount > 1 {
                    for s in 0..<n { peak = max(peak, abs(data[1][s])) }
                }
                let peakValue = peak
                self.meters.withLock { $0.track[i] = peakValue }
            }
        }
    }

    /// Removes every tap, stops the display timer, and zeroes the internal state.
    func detach() {
        displayTimer?.invalidate(); displayTimer = nil
        postFXNode?.removeTap(onBus: 0)
        postFXNode = nil
        for mixer in trackTapMixers { mixer.removeTap(onBus: 0) }
        trackTapMixers = []
        meters.withLock { $0 = MeterSnapshot() }
        rawPeakL = 0; rawPeakR = 0; peakHoldL = 0; peakHoldR = 0
    }

    // MARK: - Taps (render thread)

    /// Post-FX tap. Runs on the render thread — only publishes raw RMS into the
    /// locked snapshot; all smoothing happens later on the display timer.
    private func processTap(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        let channels = Int(buf.format.channelCount)

        var sumL: Float = 0
        for i in 0..<n { sumL += data[0][i] * data[0][i] }
        let rmsL = sqrt(sumL / Float(n))

        let rmsR: Float
        if channels > 1 {
            var sumR: Float = 0
            for i in 0..<n { sumR += data[1][i] * data[1][i] }
            rmsR = sqrt(sumR / Float(n))
        } else { rmsR = rmsL }

        meters.withLock { $0.levelL = rmsL; $0.levelR = rmsR }
    }

    // MARK: - Display timer (main thread)

    func startDisplayTimer() {
        displayTimer?.invalidate()
        // Timer fires on the main run loop, so all smoothing / peak-hold below is
        // main-thread state; the render thread only writes the locked snapshot.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Clears the live meter outputs (called on stop, after `detach`).
    func resetDisplay() {
        let m = manager.live.meters
        m.levelL = 0; m.levelR = 0; m.peakL = 0; m.peakR = 0
        m.peakDB = -Double.infinity
        m.waveformSamples = Array(repeating: 0, count: Theme.waveformCount)
        for i in 0..<Theme.trackCount {
            manager.live.trackMeters.levels[i] = 0
            manager.live.playhead.trackProgress[i] = 0
        }
    }

    private func tick() {
        let m  = manager.live.meters
        let tm = manager.live.trackMeters
        let snap = meters.withLock { $0 }

        let scaledL = Double(min(snap.levelL * 4.5, 1))
        let scaledR = Double(min(snap.levelR * 4.5, 1))

        // Peak hold (main-thread only)
        if snap.levelL >= rawPeakL { rawPeakL = snap.levelL; peakHoldL = 0 }
        else { peakHoldL += 1; if peakHoldL > 30 { rawPeakL *= 0.94 } }
        if snap.levelR >= rawPeakR { rawPeakR = snap.levelR; peakHoldR = 0 }
        else { peakHoldR += 1; if peakHoldR > 30 { rawPeakR *= 0.94 } }

        let scaledPeakL = Double(min(rawPeakL * 4.5, 1))
        let scaledPeakR = Double(min(rawPeakR * 4.5, 1))
        let maxPeak     = Double(max(rawPeakL, rawPeakR))

        m.levelL = m.levelL * 0.70 + scaledL * 0.30
        m.levelR = m.levelR * 0.70 + scaledR * 0.30
        m.peakL  = scaledPeakL
        m.peakR  = scaledPeakR
        m.peakDB = maxPeak > 0 ? 20.0 * log10(maxPeak) : -Double.infinity

        var samples = m.waveformSamples
        samples.removeFirst()
        samples.append((m.levelL + m.levelR) / 2.0)
        m.waveformSamples = samples

        // Update per-track meters
        for i in 0..<Theme.trackCount {
            let raw = Double(min(snap.track[i] * 4.5, 1))
            tm.levels[i] = tm.levels[i] * 0.7 + raw * 0.3
        }

        // Update track loop progress
        manager.transport.updatePlaybackProgress()
    }
}
