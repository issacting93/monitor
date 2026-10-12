// PlatformPaths.swift — platform-specific file-system roots
//
// Shared by macOS and iOS. Keeps the two `~/…` defaults out of the controllers so
// the iOS build (which has no home directory) compiles cleanly.

import Foundation

enum PlatformPaths {
    /// Root for recorded takes, imports and clip edits. User-visible.
    /// macOS: ~/Desktop/OP-XY Monitor/Tracks — iOS: Documents/OP-XY Monitor/Tracks
    static let tracksRoot: URL = {
        #if os(iOS)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #else
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        #endif
        return base.appendingPathComponent("OP-XY Monitor/Tracks")
    }()

    /// Save location to use at launch. On macOS this is the folder the user chose
    /// (restored from a security-scoped bookmark) when running sandboxed; otherwise
    /// it falls back to `tracksRoot`.
    static var initialSaveLocation: URL {
        #if os(macOS)
        return SaveLocation.restore() ?? tracksRoot
        #else
        return tracksRoot
        #endif
    }

    /// Directory for effect-chain presets. App-private.
    /// macOS: ~/Library/Application Support/Tape08/Presets — iOS: Application Support/Tape08/Presets
    static let presetsDir: URL = {
        #if os(iOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #else
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        #endif
        let dir = base.appendingPathComponent("Tape08/Presets")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
