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
            let noMod = flags.isEmpty || flags == .capsLock

            // Match on the character the key produces, not on its physical position.
            // keyCode is an ANSI-layout position, so a switch on it binds a shortcut to
            // whatever key sits in that spot on a US board — on a QWERTZ keyboard that is
            // the key printed with that letter only by coincidence, and the shortcuts
            // silently move. What remains here is all unmodified, so `noMod` is the only
            // modifier test left; the `where` clauses that used to separate the Shift
            // pairs (⌘S/⌘⇧S, ⌘Z/⌘⇧Z) went with those bindings to the menu bar.
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

            // Delete — Clear the selected track's takes
            //
            // Three code points, because the two delete keys do not arrive the way they
            // look like they should. Asked of the current layout, keyCode 51 (the key
            // labelled "delete") translates to U+0008 and keyCode 117 (fn+Delete) to
            // U+007F — the reverse of the usual ASCII names for BS and DEL, and neither
            // is U+F728. That last one is `NSDeleteFunctionKey`, which AppKit
            // substitutes for special keys in `characters` and may well be what the
            // NSEvent layer hands over for forward delete rather than the layout's own
            // output; it costs nothing to accept both spellings. Any of the three, with
            // no modifier, is a delete key and nothing else.
            //
            // Deliberately no menu key equivalent behind this, for the reason given on
            // `Tape08Commands`: a bare key handed to the menu bar is matched ahead of the
            // responder chain, so it would clear a track out from under a focused preset
            // name field. The guard above is the protection a menu item cannot express.
            case "\u{8}" where noMod, "\u{7F}" where noMod, "\u{F728}" where noMod:
                DispatchQueue.main.async { audio.clearTrack(audio.selectedTrack) }
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
            //
            // Still here rather than in the View menu for the reason given on
            // `Tape08Commands`: a bare key should not be handed to the menu bar until
            // it is known that the responder chain still lets a text field win. Note
            // Tab is macOS's focus-traversal key, so this binding and keyboard focus
            // navigation cannot both exist — the View menu is where that gets settled.
            case "\t" where noMod:
                DispatchQueue.main.async { audio.viewMode = audio.viewMode == 0 ? 1 : 0 }
                return nil

            // F — Toggle playhead follow
            case "f" where noMod:
                DispatchQueue.main.async { audio.playheadFollow.toggle() }
                return nil

            // Everything reached by a ⌘ chord has moved to the menu bar and is no longer
            // matched here: ⌘Z/⌘⇧Z, ⌘S/⌘⇧S, ⌘O, ⌘E, ⌘T, ⌘D, ⌘1–⌘8 and the ⌘-zoom pair.
            // They appear in `Tape08Commands` with their key equivalents, so leaving a
            // case for any of them would fire the command twice — once from the menu's
            // key equivalent and once from here.
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

// ── Menu commands ───────────────────────────────────────────────────────────

/// The app's commands, in the menu bar where they can be found.
///
/// The split between what carries a `.keyboardShortcut` here and what is left to
/// `KeyboardShortcutMonitor` is deliberate, and it is not a half-finished migration:
///
///   • **⌘-modified commands carry their key equivalent and have left the monitor.**
///     A ⌘ chord cannot be mistaken for typing, so a menu item may own it outright.
///   • **Bare-key commands (Space, R, M, S, 1–8, comma, Return, Tab, F) appear here
///     with no key equivalent and are still handled by the monitor.** AppKit
///     documents Space and friends as keys it treats specially around the responder
///     chain, and a focused text field is meant to win; but the app has BPM and
///     preset-name fields, and the monitor's explicit `NSTextView`/`NSTextField`
///     guard is exactly the protection a menu item cannot express. Giving these a key
///     equivalent is worth doing only after it has been seen at runtime that typing a
///     space in a focused field still types a space. Until then the menu still makes
///     every one of these commands *visible and clickable*, which is most of the win.
///
/// `Toggle` and `Picker` are used rather than `Button` where a control has state, so
/// the menu draws the platform checkmark instead of the app inventing one.
struct Tape08Commands: Commands {
    @ObservedObject var audio: AudioManager

    // MARK: Derived state the menu needs

    private var selectedClips: [TrackClip] { audio.tracks[audio.selectedTrack].clips }
    private var anyClips: Bool { audio.tracks.contains { !$0.clips.isEmpty } }
    private var busy: Bool { audio.busyEdit != nil }

    private var mutedBinding: Binding<Bool> {
        Binding(get: { audio.tracks[audio.selectedTrack].muted },
                set: { want in
                    if want != audio.tracks[audio.selectedTrack].muted {
                        audio.toggleMute(audio.selectedTrack)
                    }
                })
    }

    private var soloBinding: Binding<Bool> {
        Binding(get: { audio.tracks[audio.selectedTrack].solo },
                set: { want in
                    if want != audio.tracks[audio.selectedTrack].solo {
                        audio.toggleSolo(audio.selectedTrack)
                    }
                })
    }

    var body: some Commands {

        // ── File ────────────────────────────────────────────────────────────
        // `.newItem` is the placement SwiftUI reserves for the top of the File menu.
        // `Window`, not `WindowGroup`, means there is no New Window to replace.
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") { audio.openProject() }
                .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Save") { audio.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { audio.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("Export Track…") { audio.exportTrack(audio.selectedTrack) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(selectedClips.isEmpty || busy)

            Button("Bounce Mixdown…") { audio.bounceMixdown() }
                .disabled(!anyClips || busy)
        }

        // ── Edit ────────────────────────────────────────────────────────────
        // Replaces the stock Undo/Redo, which were bound to a responder-chain
        // `undoManager` this app never feeds — they showed as greyed and dead while
        // the monitor quietly answered ⌘Z.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { audio.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!audio.canUndo)
            Button("Redo") { audio.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!audio.canRedo)
        }

        // ── Transport ───────────────────────────────────────────────────────
        CommandMenu("Transport") {
            Button(audio.isPlaying ? "Stop" : "Play") {
                if audio.isPlaying { audio.stopAll() } else { audio.playAll() }
            }
            Button("Record") { audio.toggleTrackRecord(audio.selectedTrack) }
                .disabled(busy)

            Divider()

            // `stopAll` already returns to the start, so wiring this to it made the
            // item a second Stop under a different name. Seeking is what the label
            // promises: the playhead goes back to the top and playback carries on.
            Button("Return to Start") { audio.seek(toFraction: 0) }

            // Routed through the controller rather than bound straight to the flag.
            // `toggleMetronome` is also what starts and stops the click generator, and
            // the toolbar button that does the same job already calls it — a bare
            // assignment here would flip the state and leave up to two seconds of
            // already-scheduled beats playing after the user switched it off.
            Toggle("Metronome", isOn: Binding(
                get: { audio.metronomeEnabled },
                set: { want in
                    if want != audio.metronomeEnabled { audio.toggleMetronome() }
                }
            ))
            Button("Tap Tempo") { audio.tapTempo() }
            Button("Quantize") { audio.cycleQuantize() }
            Toggle("Loop", isOn: $audio.loopEnabled)

            Picker("Count-In", selection: $audio.countInBars) {
                Text("Off").tag(0)
                Text("1 Bar").tag(1)
                Text("2 Bars").tag(2)
                Text("4 Bars").tag(4)
            }
        }

        // ── Track ───────────────────────────────────────────────────────────
        CommandMenu("Track") {
            Toggle("Mute Selected Track", isOn: mutedBinding)
            Toggle("Solo Selected Track", isOn: soloBinding)

            Divider()

            Button("Split at Playhead") { audio.splitClipAtPlayhead(audio.selectedTrack) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(selectedClips.isEmpty || busy)
            Button("Duplicate Last Clip") { audio.duplicateClip(audio.selectedTrack) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(selectedClips.isEmpty || busy)

            Divider()

            // A Picker in a menu draws as a submenu with the platform checkmark, which
            // is why tracks use one and takes (no published selection index exists for
            // them) are plain buttons carrying their ⌘-number.
            Picker("Select Track", selection: $audio.selectedTrack) {
                ForEach(0..<Theme.trackCount, id: \.self) { i in
                    Text("Track \(i + 1)").tag(i)
                }
            }

            Menu("Select Take") {
                ForEach(1...8, id: \.self) { n in
                    Button("Take \(n)") { audio.selectClip(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }

            Divider()

            Button("Clear Track") { audio.clearTrack(audio.selectedTrack) }
                .disabled(selectedClips.isEmpty || busy)
            Button("Clear All Tracks") { audio.clearAll() }
                .disabled(!anyClips)
        }

        // ── View additions ──────────────────────────────────────────────────
        // `.toolbar` is the placement inside the *stock* View menu, so these land
        // there rather than creating a second menu with the same name.
        CommandGroup(after: .toolbar) {
            Picker("Layout", selection: $audio.viewMode) {
                Text("Arrange").tag(0)
                Text("Monitor").tag(1)
            }

            Divider()

            Toggle("Effects Chain", isOn: $audio.showEffects)
            Toggle("Follow Playhead", isOn: $audio.playheadFollow)

            Divider()

            Button("Zoom In") { audio.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { audio.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
        }
    }
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
        // Escape backs out of the innermost thing that is open, one press each: the trim
        // editor, then a drawer, then the take selection. `.onExitCommand` rather than a
        // case in KeyboardShortcutMonitor, because the monitor hands back every event it
        // doesn't claim and a focused text field has first call on Escape — a raw NSEvent
        // branch would cancel a trim out from under a field the user is mid-way through.
        .onExitCommand {
            if audio.trimmingTrack != nil {
                audio.cancelTrim()
            } else if audio.showEffects || audio.showSettings {
                audio.closeOpenDrawer()
            } else {
                // Last resort, and safe when nothing is selected: clearing an already-nil
                // selection publishes a change but leaves the resolved edit target on the
                // track's last take, which is what it would have been anyway.
                audio.selectedClipID = nil
            }
        }
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
        .commands { Tape08Commands(audio: audio) }
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
