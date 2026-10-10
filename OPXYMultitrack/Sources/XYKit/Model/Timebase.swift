// Timebase.swift — bars, beats and the one shared snapping helper.

import Foundation

public struct Timebase: Equatable {
    public var bpm: Double
    public var beatsPerBar: Int

    public var secondsPerBeat: Double { 60.0 / max(bpm, 1) }
    public var secondsPerBar: Double { secondsPerBeat * Double(beatsPerBar) }

    /// Grid spacing in beats that stays readable at this zoom. The ruler draws it and snapping uses it,
    /// so what you see is what clips snap to.
    public func gridBeats(pixelsPerSecond: Double) -> Double {
        let bar = Double(beatsPerBar)
        let candidates: [Double] = [0.25, 0.5, 1, bar, bar * 2, bar * 4, bar * 8, bar * 16]
        for beats in candidates where beats * secondsPerBeat * pixelsPerSecond >= 14 {
            return beats
        }
        return bar * 32
    }

    public func snap(_ seconds: Double, pixelsPerSecond: Double) -> Double {
        let step = gridBeats(pixelsPerSecond: pixelsPerSecond) * secondsPerBeat
        return max(0, (seconds / step).rounded() * step)
    }

    /// "bar.beat" with both counted from 1. Negative time (count-in) shows as bar 0 and below.
    public func barBeat(_ seconds: Double) -> String {
        let beats = (seconds / secondsPerBeat + 1e-6).rounded(.down)
        let bar = (beats / Double(beatsPerBar)).rounded(.down)
        let beat = beats - bar * Double(beatsPerBar)
        return "\(Int(bar) + 1).\(Int(beat) + 1)"
    }

    public static func clock(_ seconds: Double) -> String {
        let t = max(0, seconds)
        let whole = Int(t)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((t - Double(whole)) * 10))
    }
}
