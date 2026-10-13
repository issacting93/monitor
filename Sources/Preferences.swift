// Preferences.swift — the settings that outlive a launch
//
// Stage 2's Settings window holds *preferences*: what the app should do next
// launch. A preference that forgets itself is not one, so these are stored, while
// everything else on `AudioManager` stays session state — which is exactly the
// line the drawer/scene split is drawn along.
//
// A plain UserDefaults wrapper rather than a settings framework: every entry is
// one scalar with a factory value, and these two dozen lines are shorter than the
// conformance a framework would want. Nothing here is a store anyone else reads.
//
// `object(forKey:)` rather than `integer(forKey:)`/`double(forKey:)`, because those
// answer 0 for a key that was never written, and 0 is a real value for two of these
// — count-in off, and a timeline at its widest zoom-out. Absent has to be
// distinguishable from zero, so the default is applied here rather than by the
// accessor.
//
// The live value *is* the preference; there is no second "default tempo" beside the
// tempo. Load a project saved at 90 BPM and 90 becomes what the next launch starts
// at, which is the honest reading of a settings window that shows the current value.

import Foundation

enum Preferences {
    private static let d = UserDefaults.standard

    private enum Key {
        static let countInBars     = "pref.countInBars"
        static let masterLimiter   = "pref.masterLimiter"
        static let metronomeBPM    = "pref.metronomeBPM"
        static let metronomeVolume = "pref.metronomeVolume"
        static let loopEnabled     = "pref.loopEnabled"
        static let timelineZoom    = "pref.timelineZoom"
        static let playheadFollow  = "pref.playheadFollow"
        static let inputDevice     = "pref.inputDeviceUID"
        static let outputDevice    = "pref.outputDeviceUID"
    }

    /// Bars of count-in before a take starts. 0 = off.
    ///
    /// Validated on the way out, because the Settings window draws this as a `Picker`
    /// over 0/1/2/4 and a selection matching no tag renders as an empty control. The
    /// file is user-writable, so "can't happen" is not good enough.
    static var countInBars: Int {
        get {
            let v = d.object(forKey: Key.countInBars) as? Int ?? 0
            return [0, 1, 2, 4].contains(v) ? v : 0
        }
        set { d.set(newValue, forKey: Key.countInBars) }
    }

    /// Whether the master limiter is engaged rather than bypassed.
    static var masterLimiterEnabled: Bool {
        get { d.object(forKey: Key.masterLimiter) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.masterLimiter) }
    }

    /// Click tempo, 40–300.
    static var metronomeBPM: Double {
        get { d.object(forKey: Key.metronomeBPM) as? Double ?? 120 }
        set { d.set(newValue, forKey: Key.metronomeBPM) }
    }

    /// Click level, 0–1.
    static var metronomeVolume: Double {
        get { d.object(forKey: Key.metronomeVolume) as? Double ?? 0.45 }
        set { d.set(newValue, forKey: Key.metronomeVolume) }
    }

    /// Whether a track's buffer repeats when it reaches the end.
    static var loopEnabled: Bool {
        get { d.object(forKey: Key.loopEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.loopEnabled) }
    }

    /// Timeline magnification, 0.5–4.0.
    static var timelineZoom: Double {
        get { d.object(forKey: Key.timelineZoom) as? Double ?? 1.0 }
        set { d.set(newValue, forKey: Key.timelineZoom) }
    }

    /// Whether the lanes scroll to keep the playhead in view.
    static var playheadFollow: Bool {
        get { d.object(forKey: Key.playheadFollow) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.playheadFollow) }
    }

    /// The input device the user last chose, by CoreAudio UID.
    ///
    /// Empty means "nothing remembered", which is both the factory state and what iOS
    /// always reads, since its session exposes no UID. `DeviceController` is the only
    /// writer and `loadDevices` the only reader, and both skip an empty string: a device
    /// whose UID couldn't be read is stored as empty, so treating empty as a value to
    /// match would let one unreadable device silently claim to be the remembered one.
    static var inputDeviceUID: String {
        get { d.object(forKey: Key.inputDevice) as? String ?? "" }
        set { d.set(newValue, forKey: Key.inputDevice) }
    }

    /// The output device the user last chose, by CoreAudio UID. See `inputDeviceUID`.
    static var outputDeviceUID: String {
        get { d.object(forKey: Key.outputDevice) as? String ?? "" }
        set { d.set(newValue, forKey: Key.outputDevice) }
    }
}
