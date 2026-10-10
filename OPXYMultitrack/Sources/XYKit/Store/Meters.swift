// Meters.swift — fast-changing values kept out of the main store.
// Meters and the playhead update 30 times a second; only the small views that watch these objects redraw.

import AVFoundation
import Accelerate

public final class MeterHub: ObservableObject {
    public static let master = Project.trackCount
    public static let input = Project.trackCount + 1
    public static let count = Project.trackCount + 2

    @Published public private(set) var levels = [Float](repeating: 0, count: MeterHub.count)
    private let raw: UnsafeMutablePointer<Float>

    public init() {
        raw = .allocate(capacity: MeterHub.count)
        raw.initialize(repeating: 0, count: MeterHub.count)
    }

    deinit { raw.deallocate() }

    /// Called from audio tap threads. A plain write the display timer reads later; a lost update is harmless.
    public func push(_ index: Int, buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[c], 1, &channelPeak, vDSP_Length(buffer.frameLength))
            peak = max(peak, channelPeak)
        }
        raw[index] = max(raw[index], peak)
    }

    /// Called on the main thread by the display timer: take the peaks seen since last time and let old ones fall.
    public func tick() {
        var next = levels
        var changed = false
        for i in 0..<MeterHub.count {
            let value = max(raw[i], next[i] * 0.82)
            raw[i] = 0
            let settled: Float = value < 0.0005 ? 0 : value
            if settled != next[i] { next[i] = settled; changed = true }
        }
        if changed { levels = next }
    }

    /// Linear peak mapped onto 0...1 across a 60 dB range, for drawing.
    public static func display(_ level: Float) -> Double {
        guard level > 0 else { return 0 }
        return Double(min(max((20 * log10f(level) + 60) / 60, 0), 1))
    }
}

public final class TransportClock: ObservableObject {
    /// Playhead position in seconds. Negative during a count-in.
    @Published public var position: Double = 0

    public init() {}
}

/// The take being recorded right now, for drawing a growing clip.
public struct RecordingPreview: Equatable {
    public var trackID: UUID
    public var start: Double
    public var duration: Double
    public var peaks: [Float]
}

/// A finished take handed from the engine to the store.
public struct Take {
    public var trackID: UUID
    public var asset: Asset
    public var start: Double
    public var peaks: [Float]
}
