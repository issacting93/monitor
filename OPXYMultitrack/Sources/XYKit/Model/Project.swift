// Project.swift — the whole song as plain Codable values.
// Nothing in here touches audio or UI, so it can be saved, diffed, snapshotted for undo, and tested.

import Foundation

public struct Project: Codable, Equatable {
    static let currentVersion = 1
    public static let trackCount = 8

    public var version = Project.currentVersion
    public var name = "Untitled"
    public var bpm: Double = 120
    public var beatsPerBar = 4
    public var sampleRate: Double = 48_000
    public var masterVolume: Double = 0.9
    public var metronome = true
    public var countIn = true
    public var snap = true
    /// Manual recording offset in milliseconds, added to the latency the devices report.
    /// Set it from the number Tools/latency_test.swift prints.
    public var latencyOffsetMs: Double = 0
    public var cycle = Cycle()
    public var tracks: [Track] = []
    public var assets: [Asset] = []
    public var view = ViewState()

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        self.tracks = (0..<Project.trackCount).map { Track(name: "Track \($0 + 1)", colorIndex: $0) }
    }

    public var timebase: Timebase { Timebase(bpm: bpm, beatsPerBar: beatsPerBar) }

    /// End of the last clip, in seconds.
    public var endTime: Double {
        tracks.flatMap(\.clips).map(\.end).max() ?? 0
    }

    public func asset(_ id: UUID) -> Asset? { assets.first { $0.id == id } }
    public func trackIndex(_ id: UUID?) -> Int? { tracks.firstIndex { $0.id == id } }
}

public struct Cycle: Codable, Equatable {
    public var enabled = false
    public var start: Double = 0
    public var end: Double = 8
}

public struct ViewState: Codable, Equatable {
    public var pixelsPerSecond: Double = 60
    public var scrollX: Double = 0          // seconds at the left edge of the timeline
    public var inspectorOpen = true
    public var headerWidth: Double = 230
}

/// One audio file inside the project package (Audio/<fileName>).
public struct Asset: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var fileName: String
    public var name: String
    public var duration: Double
}

public struct Track: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var colorIndex: Int
    public var volume: Double = 0.8
    public var pan: Double = 0              // -1 ... 1
    public var mute = false
    public var solo = false
    public var fx: [EffectSlot] = []
    public var clips: [Clip] = []
}

/// One place in a track's effect chain. The project stores only the module's ID and its values,
/// never the module itself, so a project stays readable when an add-on isn't installed.
public struct EffectSlot: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var moduleID: String
    public var values: [String: Float] = [:]
    public var bypass = false

    public init(moduleID: String) { self.moduleID = moduleID }
}

/// A window onto an asset, placed on the timeline. All times are seconds.
public struct Clip: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var assetID: UUID
    public var name: String
    public var start: Double                // position on the timeline
    public var offset: Double = 0           // where in the asset the clip begins
    public var length: Double               // length of one repetition
    public var loopCount = 1                // clip repeat (not the transport cycle)
    public var gain: Double = 1
    public var fadeIn: Double = 0.005
    public var fadeOut: Double = 0.005

    public var totalLength: Double { length * Double(max(1, loopCount)) }
    public var end: Double { start + totalLength }
}
