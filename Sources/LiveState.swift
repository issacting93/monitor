// LiveState.swift — high-frequency display state
//
// Meters, the scrolling waveform and per-track playhead progress are written at
// 60 Hz by the display timer. Keeping them on AudioManager would fire
// objectWillChange for the entire view tree every frame (and mutate the `tracks`
// array continuously); they live here instead, so only the views that actually
// show meters / playheads re-render.
//
// They are deliberately three separate publishers rather than one: @ObservedObject
// invalidates on *any* @Published change of the object it holds, so a single object
// made every observer re-render on every tick regardless of which fields its body
// read. Each view now observes only the stream it draws.
//
// LiveState itself is a plain container — it publishes nothing, so holding a
// reference to it in a view body costs no observation. That is what lets a parent
// (LoopGridView) hand the focused objects down to small observing children while
// keeping its own body out of the per-frame path.

import SwiftUI

/// The post-FX stereo meter, peak-hold readout and scrolling waveform.
final class MeterState: ObservableObject {
    @Published var levelL: Double = 0
    @Published var levelR: Double = 0
    @Published var peakL:  Double = 0
    @Published var peakR:  Double = 0
    @Published var peakDB: Double = -Double.infinity
    @Published var waveformSamples: [Double] = Array(repeating: 0, count: Theme.waveformCount)
}

/// Per-track level meters (one bar per tape lane).
final class TrackMeterState: ObservableObject {
    @Published var levels: [Double] = Array(repeating: 0, count: Theme.trackCount)
}

/// Per-track playhead progress 0…1 (0 when stopped).
final class PlayheadState: ObservableObject {
    @Published var trackProgress: [Double] = Array(repeating: 0, count: Theme.trackCount)
}

final class LiveState {
    let meters      = MeterState()
    let trackMeters = TrackMeterState()
    let playhead    = PlayheadState()
}
