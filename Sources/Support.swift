// Support.swift — small free helpers shared across TAPE 08
//
// Extracted from the AudioManager mono-file. These were `private static`
// members of AudioManager; they are pure (no instance state) so they live
// as free functions here. Call sites updated from `Self.x` to `x`.

import Foundation
import AVFoundation
import os

// Small reference-type mutex for state shared between the audio render thread and the
// main/background threads. Held only for short, non-blocking critical sections (a few
// assignments, or a small copy) — never across file or device I/O.
final class UnfairLock {
    private var _lock = os_unfair_lock_s()
    func withLock<R>(_ body: () -> R) -> R {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }
}

let timestampFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
}()

// Monotonic per-process counter behind `uniqueFileStem`. Locked because recordings
// are named on the main thread while an edit's file work may not be.
private let uniqueStemLock = UnfairLock()
private var uniqueStemCounter: UInt64 = 0

// A filename stem that stays unique when two calls land in the same second. The
// timestamp alone is second-resolution, so duplicating a clip twice in quick
// succession — or a split landing in the same second as a trim — produced an
// identical destination path and the second write collided with the first. The
// timestamp still leads, so files sort chronologically in Finder.
func uniqueFileStem(_ prefix: String, at date: Date = Date()) -> String {
    let n = uniqueStemLock.withLock { () -> UInt64 in
        uniqueStemCounter += 1
        return uniqueStemCounter
    }
    return "\(prefix)_\(timestampFmt.string(from: date))_\(String(n, radix: 36))"
}

// Runs `work` on the background I/O queue and `apply` back on the main thread.
// Everything `work` reads must be captured by value *before* the call: the
// main-thread state it came from can change while it runs, and the result is only
// valid against the state it was captured from. Callers that can be superseded
// re-check a generation counter or an edit epoch inside `apply`.
func performOffMain<T>(work: @escaping () -> T, apply: @escaping (T) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let result = work()
        DispatchQueue.main.async { apply(result) }
    }
}

// Pure: applies an anti-click fade-in/out (seconds) to a decoded float buffer in
// place. Each ramp is capped at half the clip so a short clip can't ramp up and
// straight back down. No-op when the fade is non-positive or the buffer is empty.
// Free (no instance state) so it can run on the background decode queue.
func applyClipFades(_ buffer: AVAudioPCMBuffer, fadeIn: Double, fadeOut: Double) {
    guard let data = buffer.floatChannelData else { return }
    let n = Int(buffer.frameLength)
    let ch = Int(buffer.format.channelCount)
    let sr = buffer.format.sampleRate
    guard n > 0, ch > 0, sr > 0 else { return }
    let inN  = min(Int(fadeIn  * sr), n / 2)
    let outN = min(Int(fadeOut * sr), n / 2)
    for c in 0..<ch {
        let p = data[c]
        for i in 0..<inN  { p[i]     *= Float(i) / Float(inN) }   // 0 → 1 from the start
        for i in 0..<outN { p[n-1-i] *= Float(i) / Float(outN) }  // 0 → 1 back from the end
    }
}

// Pure: reads `url` and returns `count` peak buckets. Free (no instance state)
// so it can be called from a background queue during project load.
func computePeaks(url: URL, count: Int) -> [Double] {
    guard let file = try? AVAudioFile(forReading: url) else { return [] }
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
    else { return [] }
    try? file.read(into: buffer)
    guard let data = buffer.floatChannelData else { return [] }
    let n = Int(buffer.frameLength)
    let step = max(n / count, 1)
    var result: [Double] = []
    for i in 0..<count {
        let start = i * step
        let end = min(start + step, n)
        var pk: Float = 0
        for j in start..<end { pk = max(pk, abs(data[0][j])) }
        result.append(Double(min(pk, 1)))
    }
    return result
}
