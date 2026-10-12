// Views_iOS.swift — iPad UI (MVP: monitor + looper + FX)
//
// A touch-first layout, not a port of the desktop screens. Reuses the shared
// primitives from Views.swift (ArcKnob, TrackFader, TempoControl, VerticalMeter,
// RetroButtonStyle, DotGridBackground) and the same AudioManager bindings.

#if os(iOS)
import SwiftUI

// ── Root ────────────────────────────────────────────────────────────────────

struct IOSRootView: View {
    @ObservedObject var audio: AudioManager
    @State private var showFX = false

    var body: some View {
        VStack(spacing: 0) {
            IOSTopBar(audio: audio, showFX: $showFX)
            Group {
                if audio.viewMode == 0 { IOSArrangeView(audio: audio) }
                else                  { IOSMonitorView(audio: audio) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            IOSTransportBar(audio: audio)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear { audio.startMonitoring() }
        .sheet(isPresented: $showFX) {
            IOSEffectsSheet(audio: audio)
        }
    }
}

// ── Top bar ─────────────────────────────────────────────────────────────────

struct IOSTopBar: View {
    @ObservedObject var audio: AudioManager
    @Binding var showFX: Bool

    private var statusColor: Color {
        if audio.isRecording { return Theme.danger }
        if audio.isPlaying   { return Theme.accent }
        return Theme.textSecondary
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("TAPE 08")
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .tracking(3)
                .foregroundColor(Theme.textPrimary)

            Text(audio.status.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundColor(statusColor)
                .lineLimit(1)

            Spacer()

            // View tabs
            HStack(spacing: 4) {
                tab("ARRANGE", 0); tab("MONITOR", 1)
            }

            Spacer()

            // Output is read-only on iPad (route chosen by the system).
            Text("OUT · \(audio.device.io.currentOutputName.uppercased())")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)

            Button { showFX = true } label: {
                Text("FX")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundColor(Theme.accent)
            }
            .buttonStyle(RetroButtonStyle(tint: Theme.accent))
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private func tab(_ label: String, _ mode: Int) -> some View {
        Button { audio.viewMode = mode } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(2)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundColor(audio.viewMode == mode ? Theme.accent : Theme.textSecondary)
                .overlay(Rectangle().fill(audio.viewMode == mode ? Theme.accent : .clear).frame(height: 2), alignment: .bottom)
        }
        .buttonStyle(.plain)
    }
}

// ── Arrange (8-track grid) ──────────────────────────────────────────────────

struct IOSArrangeView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<Theme.trackCount, id: \.self) { i in
                    IOSTrackRow(audio: audio, index: i)
                }
            }
            .padding(16)
        }
        .background(DotGridBackground())
    }
}

struct IOSTrackRow: View {
    @ObservedObject var audio: AudioManager
    let index: Int

    private var track: TrackInfo { audio.tracks[index] }
    private var color: Color { Theme.trackColor(index) }
    private var isSelected: Bool { audio.selectedTrack == index }

    var body: some View {
        let anySolo = audio.tracks.contains { $0.solo }
        let audible = anySolo ? track.solo : !track.muted

        HStack(spacing: 12) {
            // Select
            Button { audio.selectedTrack = index } label: {
                VStack(spacing: 2) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 22, weight: .light, design: .monospaced))
                        .foregroundColor(isSelected ? Theme.accent : Theme.textTertiary)
                    Text(track.clips.isEmpty ? "EMPTY" : "TAKE \(track.clips.count)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(width: 64, height: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(color).frame(width: 3, height: 44)

            // Clip name
            VStack(alignment: .leading, spacing: 3) {
                Text(track.clips.last?.name ?? "TRK \(String(format: "%02d", index + 1))")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                // Level bar
                GeometryReader { g in
                    let lvl = index < audio.trackLevels.count ? audio.trackLevels[index] : 0
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.surfaceInset)
                        Rectangle().fill(lvl > 0.9 ? Theme.danger : color.opacity(0.8))
                            .frame(width: max(0, CGFloat(lvl) * g.size.width))
                    }
                }
                .frame(height: 4)
                .cornerRadius(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Volume fader
            TrackFader(value: Binding(
                get: { track.volume },
                set: { audio.setTrackVolume(index, $0) }
            ), color: color, onDragStart: { audio.beginUndoGesture() }, onDragEnd: { audio.endUndoGesture() })
            .frame(width: 110, height: 26)

            Text("\(Int(track.volume * 100))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)

            // Controls
            IconToggle(label: "M", on: track.muted, tint: Theme.accent) { audio.toggleMute(index) }
            IconToggle(label: "S", on: track.solo, tint: Color(red: 0x5C/255, green: 0xC8/255, blue: 0xE0/255)) { audio.toggleSolo(index) }
            IconToggle(system: track.isPlaying ? "pause.fill" : "play.fill", on: track.isPlaying, tint: Theme.accent) {
                audio.toggleTrackPlayback(index)
            }
            IconToggle(system: "circle.fill", on: audio.isRecording && audio.selectedTrack == index, tint: Theme.danger) {
                audio.toggleTrackRecord(index)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isSelected ? Theme.surfaceRaised : Theme.surface)
        .opacity(audible ? 1 : 0.4)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? color.opacity(0.5) : Theme.line, lineWidth: 1))
    }
}

// Compact on/off button (≥44pt touch target).
struct IconToggle: View {
    var system: String? = nil
    var label: String? = nil
    let on: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let system {
                    Image(systemName: system).font(.system(size: 15, weight: .medium))
                } else if let label {
                    Text(label).font(.system(size: 14, weight: .bold, design: .monospaced))
                }
            }
            .frame(width: 46, height: 46)
            .foregroundColor(on ? Theme.bg : Theme.textSecondary)
            .background(on ? tint : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? tint : Theme.textPrimary.opacity(0.16), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// ── Monitor ─────────────────────────────────────────────────────────────────

struct IOSMonitorView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 24) {
            // Stereo meters
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    VerticalMeter(label: "L", level: audio.levelL, peak: audio.peakL)
                    VerticalMeter(label: "R", level: audio.levelR, peak: audio.peakR)
                }
                .frame(height: 220)
                Text(audio.peakDB.isFinite ? String(format: "%+.1f dB", audio.peakDB) : "−∞ dB")
                    .font(.system(size: 16, weight: .light, design: .monospaced))
                    .foregroundColor(audio.peakDB > -0.5 ? Theme.danger : Theme.textPrimary)
                    .monospacedDigit()
            }

            // Waveform
            GeometryReader { geo in
                let midY = geo.size.height / 2
                Path { path in
                    let count = audio.waveformSamples.count
                    guard count > 0 else { return }
                    let spacing = geo.size.width / CGFloat(count)
                    for (i, v) in audio.waveformSamples.enumerated() {
                        let x = CGFloat(i) * spacing + spacing / 2
                        let h = CGFloat(v) * (geo.size.height / 2.2)
                        path.addRect(CGRect(x: x - 1, y: midY - h, width: 2, height: h * 2))
                    }
                }
                .fill((audio.isRecording ? Theme.danger : Theme.accent).opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Gain
            HStack(spacing: 18) {
                ArcKnob(label: "IN", value: Binding(
                    get: { audio.inputVolume * 100 }, set: { audio.applyInputVolume($0 / 100) }
                ), range: 0...100, color: Theme.textSecondary, size: 66)
                ArcKnob(label: "OUT", value: Binding(
                    get: { audio.volume * 100 }, set: { audio.applyVolume($0 / 100) }
                ), range: 0...100, color: Theme.accent, size: 66)
            }
        }
        .padding(24)
        .background(DotGridBackground())
    }
}

// ── Transport ───────────────────────────────────────────────────────────────

struct IOSTransportBar: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 12) {
            barButton("arrow.uturn.backward", enabled: audio.canUndo) { audio.undo() }
            barButton("arrow.uturn.forward", enabled: audio.canRedo) { audio.redo() }

            barButton(audio.isPlaying ? "pause.fill" : "play.fill", enabled: true, tint: Theme.accent) {
                if audio.isPlaying { audio.stopAll() } else { audio.playAll() }
            }
            barButton("stop.fill", enabled: true) { audio.stopAll() }

            // Record (uses the transport's own path, not the per-track arm)
            Button {
                if audio.isRecording { audio.stopRecording(); audio.startTrackLoop(audio.selectedTrack) }
                else { audio.startRecording() }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(audio.isRecording ? Theme.bg : Theme.danger).frame(width: 10, height: 10)
                    Text("REC").font(.system(size: 13, weight: .bold, design: .monospaced))
                }
                .frame(height: 46).padding(.horizontal, 18)
                .foregroundColor(audio.isRecording ? Theme.bg : Theme.danger)
                .background(audio.isRecording ? Theme.danger : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { audio.clearAll() } label: {
                Text("CLEAR").font(.system(size: 13, weight: .bold, design: .monospaced))
                    .frame(height: 46).padding(.horizontal, 14)
                    .foregroundColor(Theme.textSecondary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            TempoControl(audio: audio)

            IconToggle(system: "metronome.fill", on: audio.metronomeEnabled, tint: Theme.accent) {
                audio.toggleMetronome()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .top)
    }

    @ViewBuilder
    private func barButton(_ system: String, enabled: Bool, tint: Color = Theme.textPrimary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 52, height: 46)
                .foregroundColor(enabled ? tint : Theme.textTertiary)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.textPrimary.opacity(enabled ? 0.16 : 0.06), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// ── Effects sheet ───────────────────────────────────────────────────────────

struct IOSEffectsSheet: View {
    @ObservedObject var audio: AudioManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(audio.liveChain.enumerated()), id: \.element.id) { index, slot in
                        if let mod = EffectRegistry.shared.module(for: slot.moduleID) {
                            IOSEffectCard(audio: audio, index: index, slot: slot, mod: mod)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("FX CHAIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(EffectRegistry.shared.all, id: \.identifier) { mod in
                            Button(mod.displayName) { audio.addSlot(moduleID: mod.identifier) }
                        }
                    } label: { Text("ADD") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct IOSEffectCard: View {
    @ObservedObject var audio: AudioManager
    let index: Int
    let slot: ChainSlot
    let mod: EffectModule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .stroke(slot.enabled ? Theme.accent : Theme.textTertiary, lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                    .overlay(Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(slot.enabled ? Theme.accent : Theme.textTertiary))
                Text(mod.displayName.uppercased())
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(slot.enabled ? Theme.textPrimary : Theme.textEngraved)
                Spacer()
                if index > 0 {
                    Button { audio.moveSlot(from: index, to: index - 1) } label: { Image(systemName: "chevron.up").frame(width: 40, height: 40) }
                        .buttonStyle(.plain).foregroundColor(Theme.textTertiary)
                }
                if index < audio.liveChain.count - 1 {
                    Button { audio.moveSlot(from: index, to: index + 1) } label: { Image(systemName: "chevron.down").frame(width: 40, height: 40) }
                        .buttonStyle(.plain).foregroundColor(Theme.textTertiary)
                }
                Button { audio.toggleSlotBypass(index) } label: {
                    Text(slot.enabled ? "ON" : "BYP")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .frame(width: 52, height: 40)
                        .foregroundColor(slot.enabled ? Theme.accent : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                Button { audio.removeSlot(at: index) } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                    .buttonStyle(.plain).foregroundColor(Theme.textTertiary)
            }

            if !mod.parameters.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(mod.parameters) { p in
                        ArcKnob(label: p.name.uppercased(),
                                value: audio.paramBinding(slot: index, param: p.id),
                                range: Double(p.min)...Double(p.max),
                                color: Theme.accent,
                                bipolar: p.min < 0,
                                size: 54)
                    }
                }
                .opacity(slot.enabled ? 1 : 0.25)
            }
        }
        .padding(14)
        .background(Theme.surfaceRaised)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(slot.enabled ? Theme.accent.opacity(0.25) : Theme.line, lineWidth: 1))
    }
}
#endif
