// AudioDeviceProviding.swift — the platform seam for audio device I/O
//
// macOS drives CoreAudio HAL directly (device enumeration + AUHAL pinning); iOS has
// no HAL device model and instead uses AVAudioSession (a category/route system with
// a limited set of selectable input ports). Both are hidden behind this protocol so
// DeviceController and EngineController stay platform-neutral.

import Foundation
import AVFoundation

/// Why the device/route situation changed, so the controller can react appropriately.
enum DeviceChange {
    case listChanged         // macOS: hardware device list or default device changed
    case routeChanged        // iOS: audio route changed (USB plugged/unplugged, etc.)
    case interruptedBegan    // iOS: an interruption started (call, etc.)
    case interruptedEnded    // iOS: the interruption ended
    case mediaServicesReset  // iOS: media services were reset
}

protocol AudioDeviceProviding: AnyObject {
    /// macOS can pick an output device; iOS cannot (route is chosen by the system).
    var outputSelectionSupported: Bool { get }
    /// Human-readable name of the current output, for status lines / read-only labels.
    var currentOutputName: String { get }

    /// Called at the top of EngineController.start(), before anything reads the input format.
    /// iOS: configure + activate the AVAudioSession. macOS: no-op.
    func prepareForEngineStart() throws
    /// Called from EngineController.stop(). MVP: no-op on both platforms.
    func releaseAfterEngineStop()

    func loadDevices() -> (inputs: [AudioDevice], outputs: [AudioDevice])
    func displayName(for id: DeviceID) -> String
    func applyInputDevice(_ id: DeviceID, to engine: AVAudioEngine)
    func applyOutputDevice(_ id: DeviceID)

    func startObserving(_ onChange: @escaping (DeviceChange) -> Void)
    func stopObserving()
}
