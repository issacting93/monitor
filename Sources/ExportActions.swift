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
import SwiftUI

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

    /// Pops the share picker for `url`, pointing at `anchor`.
    ///
    /// `NSSharingServicePicker` needs a real view and a rect inside it, which is why
    /// this takes one rather than being a one-liner. The in-window button passes its own
    /// view so the popover points at the button; the menu item has nothing to point at
    /// and falls back to the window's content view.
    ///
    /// Nothing may happen after the call: `show` runs its own event loop and does not
    /// return until the picker is dismissed.
    static func share(_ url: URL, from anchor: NSView? = nil) {
        guard let view = anchor ?? NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [url])
            .show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// Keeps a bare `NSView` in the hierarchy for the share picker to hang off.
///
/// SwiftUI has no equivalent that takes a file URL and pops the same menu, so the
/// button that wants a correctly-placed popover needs an AppKit view behind it. The
/// view draws nothing and is never hit-tested — its whole job is to exist in a window
/// so `show(relativeTo:of:preferredEdge:)` has something to point at.
///
/// Driven by a binding rather than a closure so the button can stay a plain `Button`:
/// setting the binding is what shows the picker, and `updateNSView` is where SwiftUI
/// tells this view that it happened.
struct ShareAnchor: NSViewRepresentable {
    @Binding var pending: URL?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let url = pending else { return }
        // Cleared before the picker is shown and on the next main-queue turn, not after
        // the call: `show` blocks until dismissal, so clearing afterwards would leave
        // the binding set the whole time the menu is open and a second press — or the
        // same view updating for an unrelated reason — would try to open it again.
        // Deferring to the next turn is what keeps this out of the middle of a view
        // update, where writing to the binding is not allowed.
        DispatchQueue.main.async {
            pending = nil
            ExportActions.share(url, from: view)
        }
    }
}
#endif
