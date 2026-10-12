// SaveLocation.swift — the take/import root, remembered across launches
//
// The Mac App Store build runs inside the App Sandbox, where a hardcoded
// ~/Desktop path is unwritable. macOS grants access to a user-chosen folder via a
// security-scoped bookmark, which we store in UserDefaults and re-resolve on every
// launch. The ad-hoc `package.sh` build is not sandboxed, so it keeps the plain
// ~/Desktop default and never prompts.

import Foundation

#if os(macOS)
enum SaveLocation {
    private static let bookmarkKey = "saveLocationBookmark"
    private static let pathKey     = "saveLocationPath"
    private static let promptedKey = "saveLocationPrompted"

    /// True when running inside the App Sandbox (which sets this env var).
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Always-writable location inside the app container — used when the user
    /// declines to choose a folder, or a stored bookmark can't be resolved.
    static var fallback: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OP-XY Monitor/Tracks")
    }

    /// Sandboxed, no folder remembered, and the user hasn't been asked yet.
    static var needsSelection: Bool {
        let d = UserDefaults.standard
        return isSandboxed && !d.bool(forKey: promptedKey) && d.data(forKey: bookmarkKey) == nil
    }

    /// Resolve the remembered folder, re-activating its security scope for the
    /// app's lifetime. Returns nil when nothing is stored (caller uses a default).
    static func restore() -> URL? {
        let d = UserDefaults.standard
        if let data = d.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                if stale { remember(url) }   // refresh the bookmark before it expires
                return url
            }
            d.removeObject(forKey: bookmarkKey)
        }
        // Non-sandboxed dev build: a plain path is enough.
        if let path = d.string(forKey: pathKey) { return URL(fileURLWithPath: path) }
        return nil
    }

    /// Persist a user-chosen folder so it survives relaunch. Also marks the
    /// first-run prompt as handled.
    static func remember(_ url: URL) {
        let d = UserDefaults.standard
        d.set(url.path, forKey: pathKey)
        d.set(true, forKey: promptedKey)
        if isSandboxed,
           let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            d.set(data, forKey: bookmarkKey)
        }
        _ = url.startAccessingSecurityScopedResource()
    }

    /// Record that the first-run prompt was shown so we don't ask on every launch
    /// (used when the user picks "Not now" and keeps the container fallback).
    static func markPrompted() { UserDefaults.standard.set(true, forKey: promptedKey) }
}
#endif
