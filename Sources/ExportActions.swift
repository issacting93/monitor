// ExportActions.swift — what you can do with a file the app has just written
//
// Stage 9 of §9. Before this, an export ended in a status string — "Exported →
// TRK03_…wav" — and then the string was overwritten by the next action and the file
// was somewhere the user had to go and find. These are the actions that act on it
// instead.
//
// Everything here works on the *last* thing the app wrote rather than on a
// selection, because by the time a WAV exists the save panel has closed and nothing
// on screen names it any more. `AudioManager.lastExportURL` is what remembers it.

#if os(macOS)
import AppKit

enum ExportActions {

    /// Shows the file in a Finder window, selected.
    ///
    /// `activateFileViewerSelecting` rather than opening the containing folder: an
    /// export usually lands in a folder full of takes, and "here is the folder" is not
    /// an answer to "where did that go". The app is sandboxed, but a URL that came back
    /// from an `NSSavePanel` carries its own access for as long as the app runs, so this
    /// reaches it without a bookmark.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif
