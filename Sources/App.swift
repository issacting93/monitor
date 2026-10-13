// App.swift — app entry point, root view, keyboard shortcut monitor
//
// Extracted from the AudioManager mono-file. Pure move, no behaviour change.

#if os(macOS)
import SwiftUI
import AppKit
import Foundation

// ── Keyboard Shortcut Monitor ──────────────────────────────────────────────

final class KeyboardShortcutMonitor {
    private var monitor: Any?

    func install(audio: AudioManager) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore when a text field is focused (e.g. BPM entry, pickers)
            if let responder = event.window?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCmd = flags.contains(.command)
            let noMod = flags.isEmpty || flags == .capsLock

            // Match on the character the key produces, not on its physical position.
            // keyCode is an ANSI-layout position, so a switch on it binds Cmd+S to
            // whatever key sits where S does on a US board — on a QWERTZ keyboard that
            // is the key printed "S" only by coincidence, and the shortcuts silently
            // move. `charactersIgnoringModifiers` still applies Shift and Caps Lock, so
            // it is lowercased before matching and the shortcut pairs that differ only
            // by Shift (Cmd+S / Cmd+Shift+S, Cmd+Z / Cmd+Shift+Z) stay distinguished by
            // the flag test in their `where` clause.
            guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else {
                return event
            }

            switch key {

            // Space — Toggle play/stop (all tracks)
            case " " where noMod:
                DispatchQueue.main.async {
                    if audio.isPlaying { audio.stopAll() } else { audio.playAll() }
                }
                return nil

            // R — Toggle record on selected track
            case "r" where noMod:
                DispatchQueue.main.async { audio.toggleTrackRecord(audio.selectedTrack) }
                return nil

            // M — Toggle mute on selected track
            case "m" where noMod:
                DispatchQueue.main.async { audio.toggleMute(audio.selectedTrack) }
                return nil

            // S — Toggle solo on selected track
            case "s" where noMod:
                DispatchQueue.main.async { audio.toggleSolo(audio.selectedTrack) }
                return nil

            // 1–8 — Select/arm track
            case "1" where noMod: DispatchQueue.main.async { audio.selectedTrack = 0 }; return nil
            case "2" where noMod: DispatchQueue.main.async { audio.selectedTrack = 1 }; return nil
            case "3" where noMod: DispatchQueue.main.async { audio.selectedTrack = 2 }; return nil
            case "4" where noMod: DispatchQueue.main.async { audio.selectedTrack = 3 }; return nil
            case "5" where noMod: DispatchQueue.main.async { audio.selectedTrack = 4 }; return nil
            case "6" where noMod: DispatchQueue.main.async { audio.selectedTrack = 5 }; return nil
            case "7" where noMod: DispatchQueue.main.async { audio.selectedTrack = 6 }; return nil
            case "8" where noMod: DispatchQueue.main.async { audio.selectedTrack = 7 }; return nil

            // Cmd+1–8 — Select take N on the selected track (the plain numbers above are
            // taken by track selection, so the modifier is what distinguishes them)
            case "1" where hasCmd: DispatchQueue.main.async { audio.selectClip(number: 1) }; return nil
            case "2" where hasCmd: DispatchQueue.main.async { audio.selectClip(number: 2) }; return nil
            case "3" where hasCmd: DispatchQueue.main.async { audio.selectClip(number: 3) }; return nil
            case "4" where hasCmd: DispatchQueue.main.async { audio.selectClip(number: 4) }; return nil
            case "5" where hasCmd: DispatchQueue.main.async { audio.selectClip(number: 5) }; return nil
            case "6" where hasCmd: DispatchQueue.main.async { audio.selectClip(number: 6) }; return nil
            case "7" where hasCmd: DispatchQueue.main.async { audio.selectClip(number: 7) }; return nil
            case "8" where hasCmd: DispatchQueue.main.async { audio.selectClip(number: 8) }; return nil

            // Cmd+Z — Undo
            case "z" where hasCmd && !flags.contains(.shift):
                DispatchQueue.main.async { audio.undo() }
                return nil

            // Cmd+Shift+Z — Redo
            case "z" where hasCmd && flags.contains(.shift):
                DispatchQueue.main.async { audio.redo() }
                return nil

            // Cmd+S — Save project
            case "s" where hasCmd && !flags.contains(.shift):
                DispatchQueue.main.async { audio.saveProject() }
                return nil

            // Cmd+Shift+S — Save project as
            case "s" where hasCmd && flags.contains(.shift):
                DispatchQueue.main.async { audio.saveProjectAs() }
                return nil

            // Cmd+O — Open project
            case "o" where hasCmd:
                DispatchQueue.main.async { audio.openProject() }
                return nil

            // Cmd+E — Export selected track
            case "e" where hasCmd:
                DispatchQueue.main.async { audio.exportTrack(audio.selectedTrack) }
                return nil

            // Cmd+T — Split clip at playhead
            case "t" where hasCmd:
                DispatchQueue.main.async { audio.splitClipAtPlayhead(audio.selectedTrack) }
                return nil

            // Cmd+D — Duplicate last clip on selected track
            case "d" where hasCmd:
                DispatchQueue.main.async { audio.duplicateClip(audio.selectedTrack) }
                return nil

            // Return / Enter — Stop and return to start. Return sends CR; the numeric
            // keypad's Enter sends ETX, which is why both are listed here rather than
            // left to the character alone.
            case "\r" where noMod, "\u{3}" where noMod:
                DispatchQueue.main.async { audio.stopAll() }
                return nil

            // Comma (,) — Toggle metronome
            case "," where noMod:
                DispatchQueue.main.async { audio.toggleMetronome() }
                return nil

            // Tab — Switch between Arrange and Monitor views
            case "\t" where noMod:
                DispatchQueue.main.async { audio.viewMode = audio.viewMode == 0 ? 1 : 0 }
                return nil

            // Cmd+= / Cmd++ — Zoom in timeline (Shift turns = into +)
            case "=" where hasCmd, "+" where hasCmd:
                DispatchQueue.main.async { audio.zoomIn() }
                return nil

            // Cmd+- / Cmd+_ — Zoom out timeline
            case "-" where hasCmd, "_" where hasCmd:
                DispatchQueue.main.async { audio.zoomOut() }
                return nil

            // F — Toggle playhead follow
            case "f" where noMod:
                DispatchQueue.main.async { audio.playheadFollow.toggle() }
                return nil

            default:
                return event
            }
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { remove() }
}

// ── Window configuration ────────────────────────────────────────────────────

/// Reaches the AppKit window for the handful of things a SwiftUI scene still cannot
/// express: the window's title, the edited dot in the close button, the represented file,
/// and a frame that survives a relaunch. Zero-sized and non-interactive — it only ever
/// runs `apply`.
///
/// The work is deferred a turn because `makeNSView` runs before the view is in a window,
/// so `nsView.window` is still nil at that point.
private struct WindowConfigurator: NSViewRepresentable {
    let title: String
    let edited: Bool
    let representedURL: URL?
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.title = title
        window.isDocumentEdited = edited
        window.representedURL = representedURL
        // Setting the autosave name installs the restoration behaviour and is not
        // idempotent in the way the other three are, so it is set once.
        if window.frameAutosaveName != autosaveName {
            window.setFrameAutosaveName(autosaveName)
        }
    }
}

// ── Root View ───────────────────────────────────────────────────────────────

struct ContentView: View {
    // Owned by the App scene rather than by this view. The window can be created more
    // than once, and one AudioManager per window would mean two engines on one audio
    // device; it also lets the app delegate reach the session state it needs to decide
    // whether quitting would lose work.
    @ObservedObject var audio: AudioManager
    private let keyMonitor = KeyboardShortcutMonitor()
    @State private var showSaveLocationSheet = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(audio: audio)

            HStack(spacing: 0) {
                if audio.viewMode == 0 {
                    // Arrange view
                    VStack(spacing: 0) {
                        ArrangeHeadUnit(audio: audio, meters: audio.live.meters)

                        // Track label
                        HStack {
                            Text("TRACKS \u{00B7} \(String(format: "%02d", Theme.trackCount))")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .tracking(3)
                                .foregroundColor(Theme.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 6)

                        LoopGridView(audio: audio, playhead: audio.live.playhead,
                                     trackMeters: audio.live.trackMeters)
                            .frame(maxHeight: .infinity)

                        if audio.trimmingTrack != nil {
                            TrimEditorView(audio: audio)
                                .padding(.horizontal, 28).padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Monitor view
                    MonitorView(audio: audio, meters: audio.live.meters)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // The drawer gets its own space rather than covering the tape: the workspace
            // slides right by exactly the open drawer's width and the panel floats in the
            // gap. Both are applied here, outside LoopGridView's GeometryReader, so the
            // grid measures the reduced width and the lane arithmetic needs no change.
            //
            // Showing a panel still never *squeezes* the grid, which is what the overlay
            // alone used to get wrong in the other direction — 660 pt of panel over a
            // 1060 pt window sat on top of the track headers and the head unit.
            .padding(.leading, audio.openDrawerWidth)
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    if audio.showSettings { SettingsPanel(audio: audio) }
                    if audio.showEffects  { SideEffectsPanelView(audio: audio) }
                }
                .shadow(color: .black.opacity(0.55), radius: 16, x: 6, y: 0)
            }

            TransportBar(audio: audio)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DotGridBackground())
        .background(Theme.bg)
        // The project name, the edited dot and the window's remembered frame. The title
        // bar is hidden, so none of this is drawn as text — but the title still reaches
        // the Window menu and Mission Control, and the dot still reaches the close button.
        .background(WindowConfigurator(title: audio.projectName,
                                       edited: audio.projectDirty,
                                       representedURL: audio.projectURL,
                                       autosaveName: "Tape08MainWindow"))
        .onAppear {
            audio.startMonitoring()
            keyMonitor.install(audio: audio)
            // Sandboxed first run: ask where takes should go.
            if SaveLocation.needsSelection { showSaveLocationSheet = true }
        }
        .sheet(isPresented: $showSaveLocationSheet) {
            SaveLocationSheet(audio: audio)
        }
        .onDisappear {
            keyMonitor.remove()
        }
    }
}

// ── App Entry Point ─────────────────────────────────────────────────────────

@main
struct MonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var audio = AudioManager()

    var body: some Scene {
        // `Window`, not `WindowGroup`: this app holds one session, and a group hands out
        // ⌘N, which would put a second window on the same tracks — two views of one
        // engine, and nothing good to say about which one the user is editing.
        Window("TAPE 08", id: "main") {
            ContentView(audio: audio)
                // 1280 rather than 1060: with the widest drawer open the workspace is
                // pushed right by 400 pt, and the track-header column (200) plus the
                // control column (`Theme.controlsColumnWidth`, 460) and their gutters
                // have to survive that before the lane region gets anything. At 1060 the
                // lanes fell to their floor. This is the *minimum*; the opening size is
                // `defaultSize` below, and after the first run, the autosaved frame.
                .frame(minWidth: 1280, minHeight: 720)
                .background(Theme.bg)
                .onAppear { appDelegate.audio = audio }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the scene on appear; nil only before the first window has been shown.
    weak var audio: AudioManager?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting must not discard a session. `projectDirty` was maintained but never read
    /// on the way out, and the title bar is hidden, so ⌘W or ⌘Q threw away a recording
    /// with no prompt and no visible sign that there was anything to lose.
    ///
    /// Returns `.terminateLater` whenever a prompt may be needed, and answers with
    /// `reply(toApplicationShouldTerminate:)` once the user has decided — the reply has to
    /// wait for the save to actually finish, which is why a cancelled save panel and a
    /// write error both come back as "do not quit" rather than as a silent success.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let audio, audio.projectDirty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Save changes to “\(audio.projectName)” before quitting?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")        // first added = default (return)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")  // destructive, last
        alert.alertStyle = .warning

        let finish: (Bool) -> Void = { sender.reply(toApplicationShouldTerminate: $0) }
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:  audio.saveProject { finish($0) }
            case .alertThirdButtonReturn:  finish(true)    // Don't Save
            default:                       finish(false)   // Cancel
            }
        }

        if let window = sender.mainWindow ?? sender.windows.first {
            alert.beginSheetModal(for: window, completionHandler: decide)
        } else {
            // No window to hang a sheet on — ⌘Q from the Dock menu after the window has
            // already closed. Modal is the only option left, and there is nothing to
            // block. The decision is deferred a turn on purpose: `reply` must *follow*
            // the `.terminateLater` returned below, never precede it.
            let response = alert.runModal()
            DispatchQueue.main.async { decide(response) }
        }
        return .terminateLater
    }
}
#endif
