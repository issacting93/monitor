// AppMain.swift — window, microphone permission, keyboard shortcuts and scroll handling.
// Uses the same plain-NSApplication startup as monitor_ui.swift, so `swift run` gives a real window.

import AppKit
import AVFoundation
import SwiftUI

private var appStore: ProjectStore?
private var interruptSource: DispatchSourceSignal?

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { appStore?.shutdown() }
}

private let appDelegate = AppDelegate()

public func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = appDelegate

    requestMicrophoneAccess()

    let store = ProjectStore()
    appStore = store

    let root = RootView().environmentObject(store).environmentObject(store.engine)
    let window = NSWindow(contentViewController: NSHostingController(rootView: root))
    window.title = "OP-XY Multitrack"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(width: 1280, height: 760))
    window.minSize = NSSize(width: 980, height: 520)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = NSColor(red: 0x26 / 255.0, green: 0x28 / 255.0, blue: 0x2B / 255.0, alpha: 1)
    window.appearance = NSAppearance(named: .darkAqua)
    window.center()
    window.setFrameAutosaveName("OPXYMultitrackMain")      // remembers size and position between launches
    window.makeKeyAndOrderFront(nil)

    _ = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { event in
        guard event.window === window else { return event }
        if event.type == .scrollWheel {
            handleScroll(event, store: store)
            return event
        }
        return handleKey(event, store: store) ? nil : event
    }

    // Ctrl+C in the terminal should quit cleanly so the Mac gets its previous default input back.
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    interruptSource = source

    store.startAudio()
    app.activate(ignoringOtherApps: true)
    app.run()
}

/// Ask before the engine starts, otherwise the input opens silent. Without access the app still plays back.
private func requestMicrophoneAccess() {
    var granted = false
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        granted = true
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) != .success {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
    default:
        granted = false
    }
    guard !granted else { return }

    let alert = NSAlert()
    alert.messageText = "Microphone access is off"
    alert.informativeText = "Recording from the OP-XY needs microphone access. Turn it on in System Settings > Privacy & Security > Microphone. You can carry on without it to play back and edit."
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Continue")
    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
        NSWorkspace.shared.open(url)
    }
}

private func handleScroll(_ event: NSEvent, store: ProjectStore) {
    let dx = Double(event.scrollingDeltaX)
    let dy = Double(event.scrollingDeltaY)
    if event.modifierFlags.contains(.command) {
        if dy != 0 { store.zoom(by: dy > 0 ? 1.06 : 0.94) }       // ⌘-scroll zooms
    } else {
        let delta = abs(dx) > abs(dy) ? dx : dy                    // the timeline only scrolls sideways
        if delta != 0 { store.scroll(byPoints: -delta) }
    }
}

/// Returns true when the key was used. Typing in a text field is left alone.
private func handleKey(_ event: NSEvent, store: ProjectStore) -> Bool {
    if NSApp.keyWindow?.firstResponder is NSTextView { return false }
    let flags = event.modifierFlags
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

    if flags.contains(.command) {
        switch key {
        case "z": if flags.contains(.shift) { store.redo() } else { store.undo() }
        case "s": if flags.contains(.shift) { store.saveAs() } else { store.save() }
        case "d": store.duplicateSelected()
        case "t": store.splitAtPlayhead()
        case "=", "+": store.zoom(by: 1.25)
        case "-": store.zoom(by: 0.8)
        case "o": store.openProject()
        case "n": store.newProject()
        case "e": store.export(.wav, cycleOnly: false)
        case "q": NSApp.terminate(nil)
        case "w": NSApp.keyWindow?.performClose(nil)
        default: return false
        }
        return true
    }

    switch event.keyCode {
    case 49: store.togglePlay()                                    // space
    case 36: store.returnToStart()                                 // return
    case 51, 117: store.deleteSelected()                           // delete, forward delete
    default:
        switch key {
        case "r": store.toggleRecord()
        case "c": store.perform { $0.cycle.enabled.toggle() }
        case "m":
            guard let index = store.selectedTrackIndex else { return false }
            store.perform { $0.tracks[index].mute.toggle() }
        case "s":
            guard let index = store.selectedTrackIndex else { return false }
            store.perform { $0.tracks[index].solo.toggle() }
        case "i": store.setView { $0.inspectorOpen.toggle() }
        default: return false
        }
    }
    return true
}
