// SettingsView.swift — the ⌘, Settings window
//
// Stage 2 of §9's macOS conformance pass. What the floating drawer held was, by
// HIG definition, preferences, and the platform already has a window for those: a
// `Settings` scene, which is also what puts "Settings…" and its ⌘, in the app
// menu. The scene is declared in App.swift; this file is what it draws.
//
// The split the drawer could not express is deliberate and is not a half-finished
// move. This window holds *preferences* — what the app should do next launch. The
// effects panel stays a drawer, because a chain is a live performance surface
// rather than a setting, and it goes on being opened from the toolbar.
//
// A stock `Form` with `.formStyle(.grouped)` rather than the app's dark retro
// surface: §9.5's HIG rules ask for a Settings window that is opaque and behaves
// the way the platform's does, and the grouped form is what supplies that. The
// theme is for the instrument, not for the preferences that configure it.

#if os(macOS)
import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        Form {
            audioSection
            recordingSection
            playbackSection
            timelineSection
            sessionSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        // Window-chrome rules the scene does not apply on its own; see the type.
        .background(SettingsWindowConfigurator())
    }

    // MARK: - Sections

    /// Note which controls are bound through a method and which are bound with `$`,
    /// because the difference is not cosmetic. `selectInput`, `toggleMasterLimiter`
    /// and `setMetronomeVolume` each do something beyond assigning the property —
    /// restart the engine, move a node's bypass, set a mixer's gain — so a direct
    /// binding would move the control and leave the audio where it was. That is the
    /// bug the header's device pickers were fixed for (`AudioManager.selectInput`).
    /// The properties whose setter *is* the assignment — `countInBars`,
    /// `metronomeBPM`, `timelineZoom`, `playheadFollow` — are bound with `$`.
    @ViewBuilder
    private var audioSection: some View {
        Section("Audio") {
            Picker("Input", selection: Binding(
                get: { audio.selectedInputID },
                set: { audio.selectInput($0) }
            )) {
                ForEach(audio.inputDevices) { d in
                    Text(d.name).tag(Optional(d.id))
                }
            }

            Picker("Output", selection: Binding(
                get: { audio.selectedOutputID },
                set: { audio.selectOutput($0) }
            )) {
                ForEach(audio.outputDevices) { d in
                    Text(d.name).tag(Optional(d.id))
                }
            }

            LabeledContent("Sample Rate", value: audio.sampleRateString)

            Toggle("Master Limiter", isOn: Binding(
                get: { audio.masterLimiterEnabled },
                set: { want in
                    if want != audio.masterLimiterEnabled { audio.toggleMasterLimiter() }
                }
            ))
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        Section("Recording") {
            LabeledContent("Save Location") {
                HStack(spacing: 8) {
                    Text(shortSavePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change\u{2026}") { audio.changeSaveLocation() }
                }
            }

            Picker("Count-In", selection: $audio.countInBars) {
                Text("Off").tag(0)
                Text("1 Bar").tag(1)
                Text("2 Bars").tag(2)
                Text("4 Bars").tag(4)
            }

            // Not a control, and the one thing here worth stating outright: the
            // recording tap is pre-FX, so a take is the instrument dry whatever the
            // chain is doing. A preferences window is where a user asks this.
            LabeledContent("Takes") {
                Text("Recorded dry \u{2014} the effects chain is what you monitor through, not what lands in the file.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var playbackSection: some View {
        Section("Playback") {
            LabeledContent("Tempo") {
                HStack(spacing: 8) {
                    Slider(value: $audio.metronomeBPM, in: 40...300, step: 1)
                    Text("\(Int(audio.metronomeBPM)) BPM")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 68, alignment: .trailing)
                }
            }

            LabeledContent("Metronome Volume") {
                Slider(value: Binding(
                    get: { audio.metronomeVolume },
                    set: { audio.setMetronomeVolume($0) }
                ), in: 0...1)
            }

            Toggle("Loop by Default", isOn: Binding(
                get: { audio.loopEnabled },
                set: { audio.setLoopEnabled($0) }
            ))
        }
    }

    @ViewBuilder
    private var timelineSection: some View {
        Section("Timeline") {
            LabeledContent("Zoom") {
                HStack(spacing: 8) {
                    Slider(value: $audio.timelineZoom, in: 0.5...4.0, step: 0.25)
                    Text("\(Int((audio.timelineZoom * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 68, alignment: .trailing)
                }
            }

            Toggle("Follow Playhead", isOn: $audio.playheadFollow)
        }
    }

    /// Not preferences, and the one section here that is not in Stage 2's list.
    /// These three counts lived only in the drawer, so retiring the drawer would
    /// have deleted the only place they were visible anywhere in the app. Losing
    /// information is worse than a read-only section in a window about settings;
    /// the title says which it is.
    @ViewBuilder
    private var sessionSection: some View {
        Section("Current Session") {
            LabeledContent("Clips", value: "\(clipCount)")
            LabeledContent("Tracks Used", value: "\(tracksUsed) / \(Theme.trackCount)")
            LabeledContent("Effects", value: "\(activeEffects) active")
        }
    }

    // MARK: - Derived

    private var shortSavePath: String {
        audio.saveLocation.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private var clipCount: Int { audio.tracks.reduce(0) { $0 + $1.clips.count } }

    private var tracksUsed: Int { audio.tracks.filter { !$0.clips.isEmpty }.count }

    private var activeEffects: Int { audio.liveChain.filter { $0.enabled }.count }
}

/// The window-chrome rule §9.5 quotes that a SwiftUI `Settings` scene does not
/// apply for us: the traffic lights must be *present but disabled*.
///
/// In AppKit that is what clearing `.miniaturizable` and `.resizable` from the
/// style mask produces — the buttons stay on screen and draw dimmed rather than
/// being removed. It is applied on every update on purpose: setting it is
/// idempotent, and SwiftUI is free to re-apply its own mask when the content
/// changes height.
///
/// Escape-to-close needs no code. Nothing here installs a handler for it and
/// there is no cancel button to press, so Escape is already inert — which is the
/// rule. `ContentView.onExitCommand`, which does close things, cannot reach this
/// window either: it is a modifier on the main window, and this is another one.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Deferred a turn: `makeNSView` runs before the view has a window, so
        // `view.window` is still nil at this point.
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.styleMask.remove([.miniaturizable, .resizable])
    }
}
#endif
