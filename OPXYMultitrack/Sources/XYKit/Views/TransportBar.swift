// TransportBar.swift — the strip across the top: transport, position, tempo, meters, file and export.

import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var engine: AudioEngine

    var body: some View {
        let project = store.project
        HStack(spacing: 10) {
            fileMenu

            HStack(spacing: 4) {
                IconButton(symbol: "backward.end.fill", help: "Return to start (Return)") { store.returnToStart() }
                IconButton(symbol: engine.isPlaying ? "stop.fill" : "play.fill",
                           tint: Theme.accent, filled: engine.isPlaying, help: "Play / stop (Space)") { store.togglePlay() }
                IconButton(symbol: "record.circle", tint: Theme.danger, filled: engine.isRecording,
                           help: "Record onto the armed track (R)") { store.toggleRecord() }
                IconButton(symbol: "repeat", tint: Theme.cycle, filled: project.cycle.enabled,
                           help: "Cycle (C). Option-drag in the ruler to set the range") {
                    store.perform { $0.cycle.enabled.toggle() }
                }
            }

            PositionReadout(clock: engine.clock, timebase: project.timebase, recording: engine.isRecording)

            tempo(project)

            HStack(spacing: 4) {
                Chip(text: "CLICK", isOn: project.metronome, width: nil) { store.perform { $0.metronome.toggle() } }
                Chip(text: "COUNT-IN", isOn: project.countIn, width: nil) { store.perform { $0.countIn.toggle() } }
                Chip(text: "SNAP", isOn: project.snap, width: nil) { store.perform { $0.snap.toggle() } }
            }

            Spacer(minLength: 8)

            inputSection

            VStack(alignment: .leading, spacing: 3) {
                Text("MASTER").font(Theme.label).foregroundStyle(Theme.textTertiary)
                MeterBar(hub: engine.meters, index: MeterHub.master).frame(width: 90, height: 5)
                DragBar(value: project.masterVolume, range: 0...1.2, color: Theme.textSecondary,
                        onChange: { v in store.perform("master", reschedule: false) { $0.masterVolume = v } },
                        onEnd: { store.endGesture() })
                    .frame(width: 90)
            }

            exportMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.bg)
    }

    private var fileMenu: some View {
        Menu {
            Button("New Project") { store.newProject() }
            Button("Open…") { store.openProject() }
            Divider()
            Button("Save") { store.save() }
            Button("Save As…") { store.saveAs() }
            Divider()
            Button("Undo") { store.undo() }.disabled(!store.canUndo)
            Button("Redo") { store.redo() }.disabled(!store.canRedo)
        } label: {
            HStack(spacing: 5) {
                Text(store.project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Circle().fill(store.isDirty ? Theme.accent : Color.clear).frame(width: 5, height: 5)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: 170, alignment: .leading)
    }

    private func tempo(_ project: Project) -> some View {
        HStack(spacing: 4) {
            Button { store.perform("bpm") { $0.bpm = max(40, $0.bpm - 1) } } label: { stepLabel("−") }
                .buttonStyle(.plain)
            VStack(spacing: 0) {
                Text("\(Int(project.bpm))")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Text("BPM").font(Theme.label).foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 38)
            Button { store.perform("bpm") { $0.bpm = min(240, $0.bpm + 1) } } label: { stepLabel("+") }
                .buttonStyle(.plain)
            Chip(text: "TAP", isOn: false, width: nil) { store.tapTempo() }
        }
    }

    private func stepLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 20, height: 20)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Menu {
                    Button("No input (playback only)") { engine.selectInput(nil) }
                    Divider()
                    ForEach(engine.inputDevices) { device in
                        Button(device.name) { engine.selectInput(device.id) }
                    }
                } label: {
                    Text(engine.inputDevices.first { $0.id == engine.selectedInputID }?.name ?? "No input")
                        .font(Theme.label)
                        .foregroundStyle(engine.hasInput ? Theme.textSecondary : Theme.textTertiary)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(engine.isRecording)
                Chip(text: "MON", isOn: engine.monitorEnabled, width: nil) { engine.monitorEnabled.toggle() }
                    .help("Hear the input through the armed track's effects")
            }
            MeterBar(hub: engine.meters, index: MeterHub.input, color: Theme.textSecondary)
                .frame(width: 150, height: 5)
        }
    }

    private var exportMenu: some View {
        Menu {
            Button("Song as WAV…") { store.export(.wav, cycleOnly: false) }
            Button("Song as M4A…") { store.export(.m4a, cycleOnly: false) }
            Divider()
            Button("Cycle range as WAV…") { store.export(.wav, cycleOnly: true) }
        } label: {
            Text(store.isExporting ? "EXPORTING" : "EXPORT")
                .font(Theme.label)
                .foregroundStyle(Theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.isExporting)
    }
}

/// Bars.beats and clock time. Its own view so only these two labels redraw as the playhead moves.
struct PositionReadout: View {
    @ObservedObject var clock: TransportClock
    let timebase: Timebase
    let recording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(timebase.barBeat(clock.position))
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(recording ? Theme.danger : Theme.textPrimary)
            Text(clock.position < 0 ? "count-in" : Timebase.clock(clock.position))
                .font(Theme.mono)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(width: 78, alignment: .leading)
    }
}
