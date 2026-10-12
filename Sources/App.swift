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

            switch event.keyCode {

            // Space — Toggle play/stop (all tracks)
            case 49 where noMod:
                DispatchQueue.main.async {
                    if audio.isPlaying { audio.stopAll() } else { audio.playAll() }
                }
                return nil

            // R — Toggle record on selected track
            case 15 where noMod:
                DispatchQueue.main.async { audio.toggleTrackRecord(audio.selectedTrack) }
                return nil

            // M — Toggle mute on selected track
            case 46 where noMod:
                DispatchQueue.main.async { audio.toggleMute(audio.selectedTrack) }
                return nil

            // S — Toggle solo on selected track
            case 1 where noMod:
                DispatchQueue.main.async { audio.toggleSolo(audio.selectedTrack) }
                return nil

            // 1–8 — Select/arm track (main number row keycodes)
            case 18 where noMod: DispatchQueue.main.async { audio.selectedTrack = 0 }; return nil
            case 19 where noMod: DispatchQueue.main.async { audio.selectedTrack = 1 }; return nil
            case 20 where noMod: DispatchQueue.main.async { audio.selectedTrack = 2 }; return nil
            case 21 where noMod: DispatchQueue.main.async { audio.selectedTrack = 3 }; return nil
            case 23 where noMod: DispatchQueue.main.async { audio.selectedTrack = 4 }; return nil
            case 22 where noMod: DispatchQueue.main.async { audio.selectedTrack = 5 }; return nil
            case 26 where noMod: DispatchQueue.main.async { audio.selectedTrack = 6 }; return nil
            case 28 where noMod: DispatchQueue.main.async { audio.selectedTrack = 7 }; return nil

            // Cmd+Z — Undo
            case 6 where hasCmd && !flags.contains(.shift):
                DispatchQueue.main.async { audio.undo() }
                return nil

            // Cmd+Shift+Z — Redo
            case 6 where hasCmd && flags.contains(.shift):
                DispatchQueue.main.async { audio.redo() }
                return nil

            // Cmd+S — Save project
            case 1 where hasCmd && !flags.contains(.shift):
                DispatchQueue.main.async { audio.saveProject() }
                return nil

            // Cmd+Shift+S — Save project as
            case 1 where hasCmd && flags.contains(.shift):
                DispatchQueue.main.async { audio.saveProjectAs() }
                return nil

            // Cmd+O — Open project
            case 31 where hasCmd:
                DispatchQueue.main.async { audio.openProject() }
                return nil

            // Cmd+E — Export selected track
            case 14 where hasCmd:
                DispatchQueue.main.async { audio.exportTrack(audio.selectedTrack) }
                return nil

            // Cmd+T — Split clip at playhead
            case 17 where hasCmd:
                DispatchQueue.main.async { audio.splitClipAtPlayhead(audio.selectedTrack) }
                return nil

            // Cmd+D — Duplicate last clip on selected track
            case 2 where hasCmd:
                DispatchQueue.main.async { audio.duplicateClip(audio.selectedTrack) }
                return nil

            // Return/Enter — Stop and return to start
            case 36 where noMod, 76 where noMod:
                DispatchQueue.main.async { audio.stopAll() }
                return nil

            // Comma (,) — Toggle metronome
            case 43 where noMod:
                DispatchQueue.main.async { audio.toggleMetronome() }
                return nil

            // Tab — Switch between Arrange and Monitor views
            case 48 where noMod:
                DispatchQueue.main.async { audio.viewMode = audio.viewMode == 0 ? 1 : 0 }
                return nil

            // Cmd+Plus — Zoom in timeline (= key is keyCode 24)
            case 24 where hasCmd:
                DispatchQueue.main.async { audio.zoomIn() }
                return nil

            // Cmd+Minus — Zoom out timeline (- key is keyCode 27)
            case 27 where hasCmd:
                DispatchQueue.main.async { audio.zoomOut() }
                return nil

            // F — Toggle playhead follow
            case 3 where noMod:
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

// ── Root View ───────────────────────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var audio = AudioManager()
    private let keyMonitor = KeyboardShortcutMonitor()
    @State private var showSaveLocationSheet = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(audio: audio)

            HStack(spacing: 0) {
                if audio.viewMode == 0 {
                    // Arrange view
                    VStack(spacing: 0) {
                        ArrangeHeadUnit(audio: audio, live: audio.live)

                        // Track label
                        HStack {
                            Text("TRACKS \u{00B7} \(String(format: "%02d", Theme.trackCount))")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .tracking(3)
                                .foregroundColor(Theme.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 6)

                        LoopGridView(audio: audio, live: audio.live)
                            .frame(maxHeight: .infinity)

                        if audio.trimmingTrack != nil {
                            TrimEditorView(audio: audio)
                                .padding(.horizontal, 28).padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Monitor view
                    MonitorView(audio: audio, live: audio.live)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Settings / FX are inspector drawers that float over the content, so
            // showing them never squeezes (and clips) the tape grid at any window width.
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
        .background(WindowAccessor { _ in })
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1060, minHeight: 720)
                .background(Theme.bg)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
