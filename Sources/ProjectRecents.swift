// ProjectRecents.swift — the File ▸ Open Recent list, and the only place it is written
//
// Stage 5 of §9. The app had no Open Recent at all, so the Open Project… panel asked you
// to navigate to the same folder every launch and remembered nothing. §9 called this out
// as "the kind of thing users notice immediately".
//
// `NSDocumentController` is the store. That reads oddly — this app is not document-based,
// it has one session and one window, which is the same reason the main scene is a `Window`
// and not a `WindowGroup`. But the *recent-documents list* is a `UserDefaults`-backed
// array with a LaunchServices registration attached, and `NSDocumentController` is the
// supported way to touch it: `noteNewRecentDocumentURL` feeds the shared list, which the
// system also surfaces in the Dock menu's Recent Items and in the app's own File menu
// when the system provides one. Hand-rolling a defaults array would give us the submenu
// and none of that.
//
// macOS-only, and so is everything that calls it: `NSDocumentController` is AppKit, and
// the iPad build has no Open panel to remember anything from (see `ProjectController.open`).
//
// The URL is the only thing stored. Reading a project back is `ProjectController.performLoad`
// — this file deliberately knows nothing about project packages beyond the extension it
// filters on, so there is one load path and not two.

#if os(macOS)
import AppKit

enum ProjectRecents {

    /// The recently opened projects, newest first, as the shared controller holds them.
    ///
    /// Filtered to `.xyproj` because the controller is a shared system store rather than
    /// ours: anything else the app ever hands it — and anything a future version notes —
    /// would otherwise appear in a submenu that can only open projects.
    static var all: [URL] {
        NSDocumentController.shared.recentDocumentURLs
            .filter { $0.pathExtension.caseInsensitiveCompare("xyproj") == .orderedSame }
    }

    /// Records a project as recently used. Called on a *successful* save or load only:
    /// noting a path because the user typed it into a save panel that then failed would
    /// put a URL in the menu that may never have held a project.
    static func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// The `nil` is the action's sender. `clearRecentDocuments` is an `@IBAction` — it is
    /// the target of the stock File ▸ Open Recent ▸ Clear Menu item, so it takes a sender
    /// it has no use for — and this is the only way to call it directly.
    static func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
#endif
