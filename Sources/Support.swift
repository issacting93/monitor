// Support.swift — small free helpers shared across TAPE 08
//
// Extracted from the AudioManager mono-file. These were `private static`
// members of AudioManager; they are pure (no instance state) so they live
// as free functions here. Call sites updated from `Self.x` to `x`.

import Foundation
import AVFoundation

let timestampFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
}()

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
