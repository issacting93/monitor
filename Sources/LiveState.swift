// LiveState.swift — high-frequency display state
//
// Meters, the scrolling waveform and per-track playhead progress are written at
// 60 Hz by the display timer. Keeping them on AudioManager would fire
// objectWillChange for the entire view tree every frame (and mutate the `tracks`
// array continuously); they live here instead, so only the views that actually
// show meters / playheads re-render.

import SwiftUI

final class LiveState: ObservableObject {
    @Published var levelL: Double = 0
    @Published var levelR: Double = 0
    @Published var peakL:  Double = 0
    @Published var peakR:  Double = 0
    @Published var peakDB: Double = -Double.infinity
    @Published var waveformSamples: [Double] = Array(repeating: 0, count: Theme.waveformCount)
    @Published var trackLevels: [Double] = Array(repeating: 0, count: Theme.trackCount)
    /// Per-track playhead progress 0…1 (0 when stopped).
    @Published var trackProgress: [Double] = Array(repeating: 0, count: Theme.trackCount)
}
