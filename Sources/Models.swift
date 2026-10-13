// Models.swift — TAPE 08 value types, project persistence DTOs, reverb presets
//
// Extracted from the AudioManager mono-file. Pure move, no behaviour change.

import Foundation
import CoreAudio
import AVFoundation

// ── Models ──────────────────────────────────────────────────────────────────

// A device identifier. On macOS this is the CoreAudio HAL device id; on iOS
// there is no HAL device id, so it is a synthetic index into the audio session's
// available inputs (0 = the current output). See AudioDeviceProviding.
#if os(macOS)
typealias DeviceID = AudioDeviceID
#else
typealias DeviceID = UInt32
#endif

struct AudioDevice: Identifiable, Hashable {
    let id: DeviceID
    let name: String
    /// The CoreAudio device UID, which is the only handle on a device that survives a
    /// relaunch. `id` does not: the HAL hands those out in enumeration order and reuses
    /// one after its device disappears, so a remembered id can come back pointing at
    /// something else — or at nothing — the next time the interface is plugged in.
    ///
    /// Empty where no UID exists: on iOS, whose session numbers its ports by index, and
    /// on a macOS device whose UID property couldn't be read. The preference layer
    /// treats empty as "don't remember, don't restore", so neither case changes
    /// behaviour — it just doesn't get the convenience.
    var uid: String = ""
}

struct TrackClip: Identifiable {
    let id = UUID()
    let url: URL
    let duration: TimeInterval
    var peaks: [Double] = []
    var fadeIn: Double = 0.01   // seconds — anti-click fade
    var fadeOut: Double = 0.01  // seconds — anti-click fade
    var name: String { url.lastPathComponent }
}

struct TrackInfo: Identifiable {
    let id: Int
    var clips: [TrackClip] = []
    var volume: Double = 0.8
    var pan: Double = 0.0
    var muted = false
    var solo = false
    var isPlaying = false
}

// ── Project Persistence (Codable) ──────────────────────────────────────────

struct ProjectClipData: Codable {
    let relativePath: String
    let duration: TimeInterval
    var fadeIn: Double = 0.01
    var fadeOut: Double = 0.01
}

struct ProjectTrackData: Codable {
    let index: Int
    var clips: [ProjectClipData]
    var volume: Double
    var pan: Double
    var muted: Bool
    var solo: Bool
}

struct ProjectChainSlotData: Codable {
    let moduleID: String
    var enabled: Bool
    var parameters: [String: Float]
}

struct ProjectData: Codable {
    let version: Int
    var bpm: Double
    var metronomeEnabled: Bool
    var metronomeVolume: Double?
    var quantizeMode: Int
    var countInBars: Int
    var loopEnabled: Bool
    var masterVolume: Double
    var inputVolume: Double
    var selectedTrack: Int
    var tracks: [ProjectTrackData]
    var effectChain: [ProjectChainSlotData]
    var masterLimiterEnabled: Bool?

    init(bpm: Double = 120, metronomeEnabled: Bool = true, metronomeVolume: Double = 0.45, quantizeMode: Int = 0,
         countInBars: Int = 0, loopEnabled: Bool = true, masterVolume: Double = 0.3,
         inputVolume: Double = 0.3, selectedTrack: Int = 0,
         tracks: [ProjectTrackData] = [], effectChain: [ProjectChainSlotData] = [],
         masterLimiterEnabled: Bool = true) {
        self.version = 1
        self.bpm = bpm
        self.metronomeEnabled = metronomeEnabled
        self.metronomeVolume = metronomeVolume
        self.quantizeMode = quantizeMode
        self.countInBars = countInBars
        self.loopEnabled = loopEnabled
        self.masterVolume = masterVolume
        self.inputVolume = inputVolume
        self.selectedTrack = selectedTrack
        self.tracks = tracks
        self.effectChain = effectChain
        self.masterLimiterEnabled = masterLimiterEnabled
    }
}
