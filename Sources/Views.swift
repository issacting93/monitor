// Views.swift — all TAPE 08 SwiftUI views
//
// Extracted from the AudioManager mono-file. Pure move, no behaviour change.

import SwiftUI
#if os(macOS)
import AppKit
#endif
import AVFoundation
import Foundation

// ── Dot Grid Background ─────────────────────────────────────────────────────

struct DotGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 16
            for x in stride(from: CGFloat(0), to: size.width, by: spacing) {
                for y in stride(from: CGFloat(0), to: size.height, by: spacing) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)),
                                 with: .color(Theme.textPrimary.opacity(0.07)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// ── RetroButtonStyle ────────────────────────────────────────────────────────

struct RetroButtonStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary
    var active: Bool = false
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(filled && active ? tint : Color.clear)
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(active ? tint : Theme.textPrimary.opacity(0.16), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}

// ── ArcKnob ─────────────────────────────────────────────────────────────────

struct ArcKnob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color
    var bipolar: Bool = false
    var size: CGFloat = 56

    @State private var dragStartNorm: Double = 0

    private let startAngle: Double = 135
    private let sweepAngle: Double = 270

    private var normalized: Double {
        (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001)
    }

    private var totalSize: CGFloat { size + 12 }
    private var center: CGPoint { CGPoint(x: totalSize / 2, y: totalSize / 2) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                // Background track
                arcPath(from: 0, to: 1)
                    .stroke(Theme.textPrimary.opacity(0.10), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                // Value arc
                if bipolar {
                    arcPath(from: 0.5, to: normalized)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                } else {
                    arcPath(from: 0, to: normalized)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }

                // Indicator dot at current position
                let a = angleForValue(normalized)
                let dotR = size / 2
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .position(x: center.x + cos(a) * dotR, y: center.y + sin(a) * dotR)

                // Center dot
                Circle()
                    .fill(Theme.textPrimary.opacity(0.15))
                    .frame(width: 3, height: 3)
                    .position(center)
            }
            .frame(width: totalSize, height: totalSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if abs(gesture.translation.height) < 1 && abs(gesture.translation.width) < 1 {
                            dragStartNorm = normalized
                        }
                        let delta = -gesture.translation.height / 150
                        let newNorm = min(max(dragStartNorm + delta, 0), 1)
                        value = range.lowerBound + newNorm * (range.upperBound - range.lowerBound)
                    }
            )

            Text(displayValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(Theme.textEngraved)
                .lineLimit(1)
        }
    }

    private var displayValue: String {
        let span = range.upperBound - range.lowerBound
        if bipolar {
            // Signed display: +12, -3, +0.0
            if span > 10 {
                let v = Int(value)
                return (v >= 0 ? "+" : "") + "\(v)"
            } else {
                let v = value
                return (v >= 0 ? "+" : "") + String(format: "%.1f", v)
            }
        }
        // Percentage for 0–1 ranges
        if range.lowerBound >= 0 && range.upperBound <= 1.01 {
            return "\(Int(value * 100))%"
        }
        // Large values: abbreviate
        if abs(value) >= 10000 {
            return String(format: "%.1fk", value / 1000)
        }
        // Integer display for ranges > 10
        if span >= 10 {
            return "\(Int(value))"
        }
        // Small decimal ranges
        return String(format: "%.2f", value)
    }

    private func angleForValue(_ v: Double) -> Double {
        (startAngle + sweepAngle * min(max(v, 0), 1)) * .pi / 180
    }

    private func arcPath(from: Double, to: Double) -> Path {
        let r = size / 2
        let s = min(from, to), e = max(from, to)
        return Path { p in
            p.addArc(center: center, radius: r,
                     startAngle: Angle(degrees: startAngle + sweepAngle * s),
                     endAngle: Angle(degrees: startAngle + sweepAngle * e),
                     clockwise: false)
        }
    }
}

// ── TrackFader ──────────────────────────────────────────────────────────────

struct TrackFader: View {
    @Binding var value: Double
    var onDragStart: (() -> Void)? = nil
    var onDragEnd: (() -> Void)? = nil
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track line
                Rectangle()
                    .fill(Theme.textPrimary.opacity(0.22))
                    .frame(height: 1)
                // Thumb
                Rectangle()
                    .fill(Theme.textPrimary)
                    .frame(width: 6, height: 16)
                    .offset(x: max(0, min(geo.size.width - 6, CGFloat(value) * (geo.size.width - 6))))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging { isDragging = true; onDragStart?() }
                        value = max(0, min(1, Double(g.location.x / geo.size.width)))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnd?()
                    }
            )
        }
    }
}

// ── TempoControl ────────────────────────────────────────────────────────────

struct TempoControl: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 0) {
            Button { audio.metronomeBPM = max(40, audio.metronomeBPM - 1) } label: {
                Text("\u{2212}")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 40, height: 44)
                    .foregroundColor(Theme.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))

            VStack(spacing: 2) {
                Text("\(Int(audio.metronomeBPM))")
                    .font(.system(size: 17, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.accent)
                    .monospacedDigit()
                Text("BPM")
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(width: 64, height: 44)
            .overlay(
                Rectangle().stroke(Theme.textPrimary.opacity(0.10), lineWidth: 1)
            )

            Button { audio.metronomeBPM = min(300, audio.metronomeBPM + 1) } label: {
                Text("+")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 40, height: 44)
                    .foregroundColor(Theme.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))

            Button { audio.tapTempo() } label: {
                Text("TAP")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .frame(width: 44, height: 44)
                    .foregroundColor(audio.tapTempoFlash ? Theme.bg : Theme.accent)
                    .background(audio.tapTempoFlash ? Theme.accent : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(audio.tapTempoFlash ? Theme.accent : Theme.textPrimary.opacity(0.16), lineWidth: 1))
            .animation(.easeOut(duration: 0.06), value: audio.tapTempoFlash)
        }
        .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
    }
}

#if os(macOS)
// ── TopBar (TAPE 08 header) ────────────────────────────────────────────────

struct TopBar: View {
    @ObservedObject var audio: AudioManager

    private var statusText: String {
        if audio.isRecording { return "REC" }
        if audio.isPlaying { return "PLAY" }
        return "IDLE"
    }
    private var statusColor: Color {
        if audio.isRecording { return Theme.danger }
        if audio.isPlaying { return Theme.accent }
        return Theme.textSecondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Brand
            HStack(spacing: 14) {
                // Reel icon
                Image(systemName: "circle.circle")
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(Theme.textPrimary)
                Text("TAPE 08")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(Theme.textPrimary)
                Text("MULTITRACK")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(Theme.textTertiary)
                // Project name
                Text(audio.projectName.uppercased() + (audio.projectDirty ? " *" : ""))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Theme.accent.opacity(0.8))
                    .lineLimit(1)
            }

            Spacer()

            // View tabs
            HStack(spacing: 4) {
                tabButton("ARRANGE", mode: 0)
                tabButton("MONITOR", mode: 1)
            }

            Spacer()

            // Status
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(3)
                        .foregroundColor(statusColor)
                }

                // The engine's status/routing string (or a failure reason). Without
                // this the app fails silently — e.g. "No usable input format".
                Text(audio.status.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(audio.isMonitoring ? Theme.textSecondary : Theme.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .leading)

                Text(audio.sampleRateString.uppercased())
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Theme.textSecondary)
            }

            // Device pickers
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("IN")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textTertiary)
                    Picker("", selection: $audio.selectedInputID) {
                        ForEach(audio.inputDevices) { d in
                            Text(d.name).tag(Optional(d.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                HStack(spacing: 4) {
                    Text("OUT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textTertiary)
                    Picker("", selection: $audio.selectedOutputID) {
                        ForEach(audio.outputDevices) { d in
                            Text(d.name).tag(Optional(d.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            // FX + Settings
            HStack(spacing: 6) {
                Button(action: { audio.showEffects.toggle() }) {
                    Text("FX")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundColor(audio.showEffects ? Theme.bg : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: audio.showEffects, filled: audio.showEffects))

                Button(action: { audio.showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .foregroundColor(audio.showSettings ? Theme.bg : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: audio.showSettings, filled: audio.showSettings))
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private func tabButton(_ label: String, mode: Int) -> some View {
        Button { audio.viewMode = mode } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(3)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundColor(audio.viewMode == mode ? Theme.textPrimary : Theme.textSecondary)
                .overlay(
                    Rectangle()
                        .fill(audio.viewMode == mode ? Theme.accent : Color.clear)
                        .frame(height: 1),
                    alignment: .bottom
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif

// ── Vertical Meter (TAPE 08 style) ──────────────────────────────────────────

struct VerticalMeter: View {
    let label: String
    let level: Double
    let peak: Double

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Theme.textPrimary.opacity(0.12))
                        .frame(width: 3)
                    Rectangle().fill(Theme.danger)
                        .frame(width: 3, height: max(0, CGFloat(level) * geo.size.height))
                    // Peak dot
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 8, height: 8)
                        .offset(y: -max(0, CGFloat(peak) * geo.size.height) + 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 14)
            Text(label)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
        }
    }
}

#if os(macOS)

// ── Waveform Lane (scrollable middle) ─────────────────────────────────────

struct WaveformLaneView: View {
    let index: Int
    let track: TrackInfo
    @ObservedObject var audio: AudioManager
    @ObservedObject var playhead: PlayheadState
    let totalBars: Int
    let secsPerBar: Double
    let laneWidth: CGFloat

    private var color: Color { Theme.trackColor(index) }
    private var isRecordingThis: Bool { audio.isRecording && audio.selectedTrack == index }
    private var hasClip: Bool { !track.clips.isEmpty }
    private var isSelected: Bool { audio.selectedTrack == index }

    var body: some View {
        let barWidth = laneWidth / CGFloat(totalBars)
        ZStack(alignment: .leading) {
            // Bar grid lines
            Path { path in
                for i in 1..<totalBars {
                    let x = CGFloat(i) * barWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 52))
                }
            }
            .stroke(Theme.textPrimary.opacity(0.04), lineWidth: 0.5)

            Path { path in
                for i in stride(from: 4, to: totalBars, by: 4) {
                    let x = CGFloat(i) * barWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 52))
                }
            }
            .stroke(Theme.textPrimary.opacity(0.08), lineWidth: 0.5)

            if hasClip {
                ForEach(Array(track.clips.enumerated()), id: \.element.id) { ci, clip in
                    let clipBars = clip.duration / secsPerBar
                    let clipW = CGFloat(clipBars) * barWidth
                    let prevOffset = track.clips.prefix(ci).reduce(0.0) { $0 + $1.duration }
                    let clipX = CGFloat(prevOffset / secsPerBar) * barWidth
                    // The take the edit buttons will act on, resolved the same way they
                    // resolve it — not by comparing `selectedClipID` directly. A stale id
                    // (undo replaced the clip it named) falls back to the last take for the
                    // edits, so comparing ids here would leave nothing highlighted while
                    // TRIM and DUP quietly acted on the last take.
                    let isThisSelected = isSelected && audio.editTargetIndex(on: index) == ci

                    ZStack(alignment: .topLeading) {
                        // Selected take, in the lane's own selected treatment one step
                        // stronger: a full-strength border plus a faint accent wash.
                        if isThisSelected {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.accent.opacity(0.10))
                        }
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isThisSelected ? color : color.opacity(0.4),
                                    lineWidth: isThisSelected ? 1.5 : 1)
                        Rectangle()
                            .fill(color)
                            .frame(height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.horizontal, 1)
                        if !clip.peaks.isEmpty {
                            Path { path in
                                let midY: CGFloat = 25
                                let drawW = max(clipW - 2, 1)
                                let stepX = drawW / CGFloat(clip.peaks.count)
                                for (j, peak) in clip.peaks.enumerated() {
                                    let x = CGFloat(j) * stepX + stepX / 2
                                    let h = max(0.5, CGFloat(peak) * midY * 0.8)
                                    path.move(to: CGPoint(x: x, y: midY - h))
                                    path.addLine(to: CGPoint(x: x, y: midY + h))
                                }
                            }
                            .stroke(color.opacity(0.9), lineWidth: 1)
                        }
                        Text("TAKE \(ci + 1)")
                            .font(.system(size: 7, weight: .regular, design: .monospaced))
                            .tracking(1.5)
                            .foregroundColor(Theme.textSecondary)
                            .padding(.leading, 4).padding(.top, 2)
                    }
                    .frame(width: max(clipW - 2, 4), height: 50)
                    .contentShape(Rectangle())
                    // minimumDistance 0 so an ordinary click counts, and the drag reports
                    // where in the clip it landed — the split point a later change needs.
                    // macOS ScrollViews pan with the wheel, not with a mouse drag, so this
                    // doesn't cost the lane its scrolling.
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { _ in
                            audio.selectedTrack = index
                            audio.selectedClipID = clip.id
                        }
                    )
                    .offset(x: clipX + 1, y: 1)
                }

                // Playhead. Drawn on a stopped track too while a position is parked on it:
                // that marker is the only feedback a ruler drag leaves behind, and it is
                // where PLAY will pick up from.
                let parked = audio.seekFraction
                if track.isPlaying || parked != nil {
                    let lastClip = track.clips.last
                    let clipDur = lastClip?.duration ?? 1
                    let fraction = track.isPlaying ? playhead.trackProgress[index] : (parked ?? 0)
                    let playX = CGFloat(fraction) * CGFloat(clipDur / secsPerBar) * barWidth
                    Rectangle()
                        .fill(Theme.textPrimary.opacity(track.isPlaying ? 1 : 0.5))
                        .frame(width: 1)
                        .offset(x: playX)
                        .frame(maxHeight: .infinity)
                }
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 26))
                    path.addLine(to: CGPoint(x: laneWidth, y: 26))
                }
                .stroke(Theme.textPrimary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                Text("\u{2014} EMPTY \u{2014}")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: laneWidth, height: 52)
            }

            if isRecordingThis {
                Rectangle()
                    .fill(Theme.danger.opacity(0.05))
                    .overlay(Rectangle().stroke(Theme.danger.opacity(0.4), lineWidth: 1))
            }
        }
        .frame(width: laneWidth, height: 52)
        .background(isSelected ? Theme.textPrimary.opacity(0.025) : Color.clear)
        .overlay(
            Rectangle().stroke(isSelected ? color.opacity(0.4) : Theme.textPrimary.opacity(0.10), lineWidth: 1)
        )
        .onDrop(of: [.audio, .fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                    guard let data = data as? Data,
                          let urlStr = String(data: data, encoding: .utf8),
                          let fileURL = URL(string: urlStr) else { return }
                    let ext = fileURL.pathExtension.lowercased()
                    guard ["wav", "aiff", "aif", "m4a", "caf", "mp3", "flac"].contains(ext) else { return }
                    DispatchQueue.main.async { audio.importAudioFile(fileURL, toTrack: index) }
                }
            }
            return true
        }
    }
}

// ── Track Controls (fixed right column) ───────────────────────────────────

struct TrackControlsView: View {
    let index: Int
    let track: TrackInfo
    @ObservedObject var audio: AudioManager
    @ObservedObject var trackMeters: TrackMeterState

    private var color: Color { Theme.trackColor(index) }

    var body: some View {
        HStack(spacing: 6) {
            Button { audio.toggleTrackPlayback(index) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .frame(width: 28, height: 28)
                    .foregroundColor(track.isPlaying ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: track.isPlaying))

            Button { audio.toggleMute(index) } label: {
                Text("M")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .frame(width: 28, height: 28)
                    .foregroundColor(track.muted ? Theme.bg : Theme.textSecondary)
            }
            .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: track.muted, filled: track.muted))

            Button { audio.toggleSolo(index) } label: {
                Text("S")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .frame(width: 28, height: 28)
                    .foregroundColor(track.solo ? Theme.bg : Theme.textSecondary)
            }
            .buttonStyle(RetroButtonStyle(tint: Color(red: 0x5C/255.0, green: 0xC8/255.0, blue: 0xE0/255.0), active: track.solo, filled: track.solo))

            TrackFader(
                value: Binding(
                    get: { track.volume },
                    set: { audio.setTrackVolume(index, $0) }
                ),
                onDragStart: { audio.beginUndoGesture() },
                onDragEnd: { audio.endUndoGesture() }
            )
            .frame(width: 80, height: 20)

            Text("\(Int(track.volume * 100))")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)

            Text("L")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Slider(value: Binding(
                get: { track.pan },
                set: { audio.setTrackPan(index, $0) }
            ), in: -1...1) { editing in
                if editing { audio.beginUndoGesture() } else { audio.endUndoGesture() }
            }
            .frame(width: 50)
            .tint(color.opacity(0.6))
            Text("R")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Text(track.pan == 0 ? "C" : (track.pan < 0 ? "L\(Int(abs(track.pan) * 100))" : "R\(Int(track.pan * 100))"))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 32, alignment: .trailing)

            GeometryReader { geo in
                let lvl = index < trackMeters.levels.count ? trackMeters.levels[index] : 0
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.surfaceInset)
                    Rectangle()
                        .fill(lvl > 0.9 ? Theme.danger : color.opacity(0.8))
                        .frame(width: max(0, CGFloat(lvl) * geo.size.width))
                }
            }
            .frame(width: 40, height: 6)
            .cornerRadius(4)
        }
        .padding(.horizontal, 10)
        .frame(width: 410)
    }
}

// ── BarRulerView (scrollable ruler) ───────────────────────────────────────

struct BarRulerView: View {
    @ObservedObject var audio: AudioManager
    let totalBars: Int
    let secsPerBar: Double
    let rulerWidth: CGFloat

    /// Where the pointer is during a drag. The seek itself is committed on release:
    /// re-scheduling eight players on every drag event would restart them faster than
    /// they can render, and a scrub that stutters is worse than one that lands on release.
    @State private var dragFraction: Double? = nil

    var body: some View {
        let barWidth = rulerWidth / CGFloat(totalBars)
        let loopSpan = CGFloat(max(longestClipBars(), 1)) * barWidth

        ZStack(alignment: .leading) {
            ForEach(Array(stride(from: 1, through: totalBars, by: 4)), id: \.self) { bar in
                Text(String(format: "%02d", bar))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .position(x: CGFloat(bar - 1) * barWidth + barWidth / 2, y: 8)
            }

            if audio.loopEnabled {
                let longestBars = longestClipBars()
                if longestBars > 0 {
                    let lw = CGFloat(longestBars) * barWidth
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.loopGreen, lineWidth: 1.5)
                        .frame(width: lw, height: 12)
                        .position(x: lw / 2, y: 8)
                }
            }

            let currentBar = audio.recordingDuration / secsPerBar
            let playX = CGFloat(currentBar) * barWidth
            Path { p in
                p.move(to: CGPoint(x: playX, y: 2))
                p.addLine(to: CGPoint(x: playX + 5, y: 8))
                p.addLine(to: CGPoint(x: playX, y: 14))
                p.addLine(to: CGPoint(x: playX - 5, y: 8))
                p.closeSubpath()
            }
            .fill(Theme.textPrimary)

            // The dragged position, and the one a previous drag parked. Both are drawn
            // over the span the loop bracket occupies, which is what makes the pointer
            // and the playhead agree.
            if !audio.isRecording && !audio.countingIn, let marker = dragFraction ?? audio.seekFraction {
                let mx = CGFloat(marker) * loopSpan
                Path { p in
                    p.move(to: CGPoint(x: mx, y: 2))
                    p.addLine(to: CGPoint(x: mx + 5, y: 8))
                    p.addLine(to: CGPoint(x: mx, y: 14))
                    p.addLine(to: CGPoint(x: mx - 5, y: 8))
                    p.closeSubpath()
                }
                .fill(dragFraction != nil ? Theme.accent : Theme.textPrimary.opacity(0.6))
            }
        }
        .frame(width: rulerWidth, height: 18)
        .contentShape(Rectangle())
        // macOS ScrollViews pan with the wheel, not with a mouse drag, so this does not
        // cost the timeline its scrolling.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard !audio.isRecording, !audio.countingIn, loopSpan > 0 else { return }
                    dragFraction = min(max(Double(v.location.x / loopSpan), 0), 1)
                }
                .onEnded { v in
                    dragFraction = nil
                    guard !audio.isRecording, !audio.countingIn, loopSpan > 0 else { return }
                    audio.seek(toFraction: Double(v.location.x / loopSpan))
                }
        )
    }

    private func longestClipBars() -> Int {
        let maxDur = audio.tracks.flatMap(\.clips).map(\.duration).max() ?? 0
        guard maxDur > 0 else { return 0 }
        return Int(ceil(maxDur / secsPerBar))
    }
}

// ── LoopGridView (with ruler, zoom & playhead follow) ─────────────────────

struct LoopGridView: View {
    @ObservedObject var audio: AudioManager
    /// The per-frame streams are handed down to the small observing children below;
    /// this view deliberately observes none of them, so its body — the ruler, eight
    /// track headers, eight lanes, eight control strips and the zoom bar — is not
    /// re-evaluated on every 60 Hz display tick.
    let playhead: PlayheadState
    let trackMeters: TrackMeterState

    private var secsPerBar: Double { 240.0 / audio.metronomeBPM }
    private var totalBars: Int {
        let maxDur = audio.tracks.flatMap(\.clips).map(\.duration).max() ?? 0
        let barsFromClips = maxDur > 0 ? Int(ceil(maxDur / secsPerBar)) : 0
        let raw = max(8, barsFromClips + 4)
        return ((raw + 3) / 4) * 4
    }

    var body: some View {
        GeometryReader { outerGeo in
            let headerW: CGFloat = 200
            let controlsW: CGFloat = 410
            let hPad: CGFloat = 56
            let availableW = max(outerGeo.size.width - headerW - controlsW - hPad, 100)
            let laneWidth = availableW * CGFloat(audio.timelineZoom)

            HStack(spacing: 0) {
                // ── Fixed left: track headers + zoom/follow controls ──
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Button { audio.zoomOut() } label: {
                            Image(systemName: "minus.magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Text("\(Int(audio.timelineZoom * 100))%")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 36)

                        Button { audio.zoomIn() } label: {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button { audio.playheadFollow.toggle() } label: {
                            Image(systemName: "scope")
                                .font(.system(size: 10))
                                .foregroundColor(audio.playheadFollow ? Theme.accent : Theme.textTertiary)
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(audio.playheadFollow ? "Follow ON (F)" : "Follow OFF (F)")
                    }
                    .frame(width: headerW, height: 18)

                    ForEach(0..<Theme.trackCount, id: \.self) { i in
                        let trk = audio.tracks[i]
                        let anySolo = audio.tracks.contains { $0.solo }
                        let audible = anySolo ? trk.solo : !trk.muted
                        Button(action: { audio.selectedTrack = i }) {
                            HStack(spacing: 10) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(audio.selectedTrack == i ? Theme.danger : Theme.danger.opacity(0.3))
                                        .frame(width: 8, height: 8)
                                    Text(String(format: "%02d", i + 1))
                                        .font(.system(size: 18, weight: .light, design: .monospaced))
                                        .foregroundColor(audio.selectedTrack == i ? Theme.accent : Theme.textTertiary)
                                }
                                Rectangle()
                                    .fill(Theme.trackColor(i))
                                    .frame(width: 2, height: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(!trk.clips.isEmpty
                                         ? (audio.editTargetIndex(on: i).map { trk.clips[$0].name } ?? "CLIP")
                                         : "TRK \(String(format: "%02d", i + 1))")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .tracking(1.5)
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    // "n TAKES", not "TAKE n" — beside a lane that labels each
                                    // take TAKE 1…n, a bare count reads as an index.
                                    Text(!trk.clips.isEmpty
                                         ? (trk.clips.count == 1 ? "1 TAKE" : "\(trk.clips.count) TAKES")
                                         : "EMPTY")
                                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                                        .tracking(2)
                                        .foregroundColor(Theme.textTertiary)
                                }
                            }
                            .frame(width: headerW, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(height: 52)
                        .padding(.vertical, 6)
                        .opacity(audible ? 1 : 0.32)
                        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.07)).frame(height: 1), alignment: .bottom)
                    }
                }

                // ── Scrollable middle: ruler + waveform lanes ──
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 0) {
                            BarRulerView(audio: audio, totalBars: totalBars,
                                         secsPerBar: secsPerBar, rulerWidth: laneWidth)

                            ForEach(0..<Theme.trackCount, id: \.self) { i in
                                let trk = audio.tracks[i]
                                let anySolo = audio.tracks.contains { $0.solo }
                                let audible = anySolo ? trk.solo : !trk.muted
                                WaveformLaneView(index: i, track: trk, audio: audio, playhead: playhead,
                                                 totalBars: totalBars, secsPerBar: secsPerBar,
                                                 laneWidth: laneWidth)
                                    .padding(.vertical, 6)
                                    .opacity(audible ? 1 : 0.32)
                                    .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.07)).frame(height: 1), alignment: .bottom)
                            }

                            // Invisible anchor at the playhead position for scroll-to
                            PlayheadAnchorView(playhead: playhead, tracks: audio.tracks,
                                               totalBars: totalBars, secsPerBar: secsPerBar,
                                               laneWidth: laneWidth)
                        }
                    }
                    // Pin the middle column to the exact remaining width. The horizontal
                    // ScrollView otherwise reports a smaller intrinsic width, so the row
                    // stops short of the right edge and the track controls float left of it.
                    .frame(width: availableW)
                    // Zero-size: exists only to own the 60 Hz scroll-follow trigger, so
                    // LoopGridView's own body never reads the playhead. Inside the reader
                    // so the proxy is in scope.
                    .overlay(
                        PlayheadScrollFollower(playhead: playhead, tracks: audio.tracks,
                                               isPlaying: audio.isPlaying,
                                               followEnabled: audio.playheadFollow && audio.timelineZoom > 1.0,
                                               proxy: proxy)
                    )
                    .onChange(of: audio.isPlaying) {
                        if audio.isPlaying && audio.playheadFollow && audio.timelineZoom > 1.0 {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("playhead_anchor", anchor: .center)
                            }
                        }
                    }
                }
                .clipped()

                // ── Fixed right: track controls ──
                VStack(spacing: 0) {
                    Color.clear.frame(height: 18)
                    ForEach(0..<Theme.trackCount, id: \.self) { i in
                        let trk = audio.tracks[i]
                        let anySolo = audio.tracks.contains { $0.solo }
                        let audible = anySolo ? trk.solo : !trk.muted
                        TrackControlsView(index: i, track: trk, audio: audio,
                                          trackMeters: trackMeters)
                            .frame(height: 52)
                            .padding(.vertical, 6)
                            .opacity(audible ? 1 : 0.32)
                            .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.07)).frame(height: 1), alignment: .bottom)
                    }
                }
            }
            .padding(.horizontal, 28)
        }
    }

}

// ── LoopGrid 60 Hz children ─────────────────────────────────────────────────
//
// These exist purely so LoopGridView's body — eight headers, eight lanes, eight
// control strips and the ruler — is not re-evaluated on every display tick. Each
// observes PlayheadState itself and reads nothing else that updates at 60 Hz.

/// The invisible scroll-to target sitting at the playhead's x position. Its
/// `.id` is what `PlayheadScrollFollower` scrolls to.
private struct PlayheadAnchorView: View {
    @ObservedObject var playhead: PlayheadState
    let tracks: [TrackInfo]
    let totalBars: Int
    let secsPerBar: Double
    let laneWidth: CGFloat

    /// Playhead position as a fraction of the whole timeline. Playback decodes a
    /// track's last clip only, so that clip's progress is scaled into the timeline.
    private var fraction: Double {
        guard let idx = tracks.firstIndex(where: { $0.isPlaying && !$0.clips.isEmpty }),
              let lastClip = tracks[idx].clips.last, totalBars > 0 else { return 0 }
        let clipBars = lastClip.duration / secsPerBar
        return playhead.trackProgress[idx] * clipBars / Double(totalBars)
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .id("playhead_anchor")
            .offset(x: CGFloat(fraction) * laneWidth - laneWidth / 2)
    }
}

/// Zero-size driver for scroll-follow. Quantizes the playhead to ~20 steps per
/// loop so `.onChange` fires a handful of times per second instead of 60.
private struct PlayheadScrollFollower: View {
    @ObservedObject var playhead: PlayheadState
    let tracks: [TrackInfo]
    let isPlaying: Bool
    let followEnabled: Bool
    let proxy: ScrollViewProxy

    private var tick: Int {
        guard let idx = tracks.firstIndex(where: { $0.isPlaying && !$0.clips.isEmpty }) else { return 0 }
        return Int(playhead.trackProgress[idx] * 20)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: tick) {
                guard isPlaying && followEnabled else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo("playhead_anchor", anchor: .center)
                }
            }
    }
}

// ── SideEffectsPanelView (Chain Editor) ─────────────────────────────────────

struct SideEffectsPanelView: View {
    @ObservedObject var audio: AudioManager

    private let slotColors: [Color] = [
        Color(red: 0.9, green: 0.4, blue: 0.3),  // Gate (red)
        Theme.eqColor,                             // EQ
        Color(red: 0.5, green: 0.7, blue: 0.9),   // Compressor (blue)
        Color(red: 0.9, green: 0.6, blue: 0.2),   // Distortion (orange)
        Theme.tapeColor,                           // Tape Sat
        Color(red: 0.4, green: 0.8, blue: 0.7),   // Chorus (teal)
        Color(red: 0.7, green: 0.5, blue: 0.9),   // Flanger (purple)
        Color(red: 0.8, green: 0.5, blue: 0.7),   // Phaser (pink)
        Color(red: 0.6, green: 0.8, blue: 0.5),   // Tremolo (green)
        Color(red: 0.9, green: 0.8, blue: 0.3),   // Bitcrusher (yellow)
        Theme.delayColor,                          // Delay
        Theme.reverbColor,                         // Reverb
    ]
    private func slotColor(_ i: Int) -> Color { slotColors[i % slotColors.count] }

    /// The take an edit would act on, so this names the same clip TRIM / DUP / EXPORT
    /// use rather than always the track's last one.
    private var selectedTrackName: String {
        let t = audio.tracks[audio.selectedTrack]
        guard let i = audio.editTargetIndex(on: audio.selectedTrack) else {
            return "TRK \(String(format: "%02d", audio.selectedTrack + 1))"
        }
        return "TAKE \(i + 1) \u{00B7} \(t.clips[i].name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FX CHAIN")
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textPrimary)
                    Text("TRK \(String(format: "%02d", audio.selectedTrack + 1)) \u{00B7} \(selectedTrackName)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Menu {
                    ForEach(EffectRegistry.shared.all, id: \.identifier) { mod in
                        Button(mod.displayName) { audio.addSlot(moduleID: mod.identifier) }
                    }
                } label: {
                    Text("+ ADD")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundColor(Theme.accent)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                        .cornerRadius(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            // Preset bar
            HStack(spacing: 6) {
                Text("PRESET")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(Theme.textTertiary)

                Menu {
                    ForEach(audio.presetNames, id: \.self) { name in
                        Button(name) { audio.loadChainPreset(name: name) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("LOAD")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundColor(Theme.accent)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if audio.showPresetSave {
                    TextField("Name", text: $audio.presetSaveName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 100)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.surfaceInset)
                        .cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                        .onSubmit {
                            let n = audio.presetSaveName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !n.isEmpty { audio.saveChainPreset(name: n) }
                            audio.showPresetSave = false
                            audio.presetSaveName = ""
                        }
                    Button("OK") {
                        let n = audio.presetSaveName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !n.isEmpty { audio.saveChainPreset(name: n) }
                        audio.showPresetSave = false
                        audio.presetSaveName = ""
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.loopGreen)
                    .buttonStyle(.plain)
                } else {
                    Button("SAVE") {
                        audio.showPresetSave = true
                        audio.presetSaveName = ""
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundColor(Theme.loopGreen)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.loopGreen.opacity(0.3), lineWidth: 1))
                    .buttonStyle(.plain)
                }

                Spacer()

                if !audio.presetNames.isEmpty {
                    Menu {
                        ForEach(audio.presetNames, id: \.self) { name in
                            Button(role: .destructive) { audio.deleteChainPreset(name: name) } label: {
                                Label(name, systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // IN label
                    HStack(spacing: 6) {
                        Circle().fill(Theme.textTertiary).frame(width: 6, height: 6)
                        Text("IN \u{00B7} \(audio.inputDevices.first { $0.id == audio.selectedInputID }?.name.uppercased() ?? "MBP MIC")")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.leading, 16).padding(.bottom, 8)

                    ForEach(Array(audio.liveChain.enumerated()), id: \.element.id) { index, slot in
                        if let mod = EffectRegistry.shared.module(for: slot.moduleID) {
                            HStack(alignment: .top, spacing: 0) {
                                // Signal flow spine
                                VStack(spacing: 0) {
                                    // Dotted line above
                                    Path { p in
                                        p.move(to: CGPoint(x: 3, y: 0))
                                        p.addLine(to: CGPoint(x: 3, y: 16))
                                    }
                                    .stroke(slotColor(index).opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .frame(width: 6, height: 16)
                                    // Colored square node
                                    Rectangle()
                                        .fill(slot.enabled ? slotColor(index) : Theme.textTertiary)
                                        .frame(width: 6, height: 6)
                                    // Dotted line below
                                    GeometryReader { geo in
                                        Path { p in
                                            p.move(to: CGPoint(x: 3, y: 0))
                                            p.addLine(to: CGPoint(x: 3, y: geo.size.height))
                                        }
                                        .stroke(slotColor(index).opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    }
                                    .frame(width: 6)
                                }
                                .padding(.leading, 16)

                                effectCard(index: index, slot: slot, mod: mod, color: slotColor(index))
                                    .padding(.leading, 8)
                            }
                            .padding(.bottom, 8)
                        }
                    }

                    // OUT label
                    HStack(spacing: 6) {
                        Circle().fill(Theme.textTertiary).frame(width: 6, height: 6)
                        Text("OUT \u{00B7} TRK \(String(format: "%02d", audio.selectedTrack + 1)) FADER")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.leading, 16).padding(.top, 4)
                }
                .padding(.horizontal, 8).padding(.bottom, 16)
            }
        }
        .frame(width: 400)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(width: 1), alignment: .trailing)
    }

    @ViewBuilder
    private func effectCard(index: Int, slot: ChainSlot, mod: EffectModule, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: index dot, name, controls
            HStack(spacing: 8) {
                // Index badge
                ZStack {
                    Circle()
                        .stroke(slot.enabled ? color : Theme.textTertiary, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(slot.enabled ? color : Theme.textTertiary)
                }

                Text(mod.displayName.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(slot.enabled ? Theme.textPrimary : Theme.textEngraved)

                Spacer()

                // Move buttons
                HStack(spacing: 2) {
                    if index > 0 {
                        Button { audio.moveSlot(from: index, to: index - 1) } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 24)
                                .foregroundColor(Theme.textTertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if index < audio.liveChain.count - 1 {
                        Button { audio.moveSlot(from: index, to: index + 1) } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 24)
                                .foregroundColor(Theme.textTertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // ON/BYP pill toggle
                Button { audio.toggleSlotBypass(index) } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(slot.enabled ? color : Theme.textTertiary)
                            .frame(width: 6, height: 6)
                        Text(slot.enabled ? "ON" : "BYP")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(slot.enabled ? color : Theme.textTertiary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(slot.enabled ? color.opacity(0.5) : Theme.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Delete
                Button { audio.removeSlot(at: index) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
                        .foregroundColor(Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            // Parameter knobs — fixed 4-column grid
            if !mod.parameters.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 0), count: 4), alignment: .leading, spacing: 6) {
                    ForEach(mod.parameters) { param in
                        ArcKnob(
                            label: param.name.uppercased(),
                            value: audio.paramBinding(slot: index, param: param.id),
                            range: Double(param.min)...Double(param.max),
                            color: color,
                            bipolar: param.min < 0,
                            size: 42
                        )
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
                .opacity(slot.enabled ? 1 : 0.2)
            }
        }
        .background(Theme.surfaceRaised)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(slot.enabled ? color.opacity(0.25) : Theme.line.opacity(0.5), lineWidth: 1)
        )
    }
}

// ── TransportBar (TAPE 08 footer) ───────────────────────────────────────────

struct TransportBar: View {
    @ObservedObject var audio: AudioManager

    /// The take the edit keys act on, out of the selected track's total. Resolved through
    /// `editTargetIndex` so it agrees with the lane highlight and the FX header.
    private var takeLabel: String {
        let clips = audio.tracks[audio.selectedTrack].clips
        guard let i = audio.editTargetIndex(on: audio.selectedTrack) else { return "EMPTY" }
        return "TAKE \(i + 1)/\(clips.count)"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: selected track
            HStack(spacing: 12) {
                Rectangle().fill(Theme.accent).frame(width: 10, height: 10)
                HStack(spacing: 4) {
                    Text("TRK \(String(format: "%02d", audio.selectedTrack + 1))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(2).foregroundColor(Theme.accent)
                    Text("/ \(takeLabel)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .tracking(2).foregroundColor(Theme.textTertiary)
                }
            }
            .frame(minWidth: 200, alignment: .leading)

            Spacer()

            // Center: transport buttons
            VStack(spacing: 2) {
            HStack(spacing: 6) {
                tpBtn(icon: "arrow.uturn.backward", label: "UNDO",
                      fg: audio.canUndo ? Theme.textPrimary : Theme.textTertiary,
                      border: Theme.textPrimary.opacity(audio.canUndo ? 0.16 : 0.06)) {
                    audio.undo()
                }
                .disabled(!audio.canUndo)
                tpBtn(icon: "arrow.uturn.forward", label: "REDO",
                      fg: audio.canRedo ? Theme.textPrimary : Theme.textTertiary,
                      border: Theme.textPrimary.opacity(audio.canRedo ? 0.16 : 0.06)) {
                    audio.redo()
                }
                .disabled(!audio.canRedo)
                tpBtn(icon: audio.isPlaying ? "pause.fill" : "play.fill",
                      label: audio.isPlaying ? "PAUSE" : "PLAY",
                      fg: audio.isPlaying ? Theme.bg : Theme.accent,
                      bg: audio.isPlaying ? Theme.accent : Color.clear,
                      border: Theme.accent) {
                    if audio.isPlaying { audio.stopAll() } else { audio.playAll() }
                }

                Button {
                    if audio.isRecording { audio.stopRecording(); audio.startTrackLoop(audio.selectedTrack) }
                    else { audio.startRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(audio.isRecording ? Theme.bg : Theme.danger).frame(width: 10, height: 10)
                        // Reads IN while a count-in is pending, so the press that re-arms
                        // the count is visibly doing something. Fixed width because the two
                        // labels are different lengths and the transport must not shift
                        // under the pointer.
                        Text(audio.countingIn ? "IN" : "REC")
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
                            .frame(width: 30)
                    }
                    .frame(height: 44).padding(.horizontal, 26)
                    .foregroundColor(audio.isRecording ? Theme.bg : Theme.danger)
                    .background(audio.isRecording ? Theme.danger : Color.clear)
                    .overlay(Rectangle().stroke(Theme.danger, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                tpBtn(icon: "stop.fill", label: "STOP",
                      fg: Theme.textPrimary, border: Theme.textPrimary.opacity(0.16)) { audio.stopAll() }

                Button { audio.clearAll() } label: {
                    Text("CLEAR").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
                        .frame(height: 44).padding(.horizontal, 18)
                        .foregroundColor(Theme.textSecondary)
                        .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { audio.bounceMixdown() } label: {
                    HStack(spacing: 6) {
                        if audio.bounceStatus != nil {
                            ProgressView().controlSize(.small)
                        }
                        Text("MIXDOWN").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
                    }
                    .frame(height: 44).padding(.horizontal, 18)
                    .foregroundColor(Theme.loopGreen)
                    .overlay(Rectangle().stroke(Theme.loopGreen.opacity(0.4), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(audio.bounceStatus != nil || audio.busyEdit != nil)
            }
            // Shortcut hints
            HStack(spacing: 14) {
                Text("\u{2318}Z UNDO").fixedSize()
                Text("SPACE PLAY").fixedSize()
                Text("R REC").fixedSize()
                Text("\u{21A9} STOP").fixedSize()
                Text("M MUTE").fixedSize()
                Text("S SOLO").fixedSize()
                Text("1\u{2013}8 TRK").fixedSize()
                Text(", MET").fixedSize()
                Text("TAB VIEW").fixedSize()
                Text("F FOLLOW").fixedSize()
                Text("\u{2318}+/- ZOOM").fixedSize()
                Text("\u{2318}T SPLIT").fixedSize()
                Text("\u{2318}D DUP").fixedSize()
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundColor(Theme.textTertiary.opacity(0.6))
            }

            Spacer()

            // Right: BPM, metronome, VOL, monitor
            HStack(spacing: 10) {
                TempoControl(audio: audio)
                Button { audio.toggleMetronome() } label: {
                    Image(systemName: "metronome.fill").font(.system(size: 12, weight: .medium))
                        .frame(width: 44, height: 44)
                        .foregroundColor(audio.metronomeEnabled ? Theme.bg : Theme.textPrimary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: audio.metronomeEnabled, filled: audio.metronomeEnabled))

                // Metronome volume
                Slider(value: Binding(
                    get: { audio.metronomeVolume },
                    set: { audio.setMetronomeVolume($0) }
                ), in: 0...1)
                .frame(width: 50)
                .tint(Theme.accent.opacity(0.5))

                // Count-in toggle: cycles 0 → 1 → 2 → 4 → 0
                Button {
                    switch audio.countInBars {
                    case 0: audio.countInBars = 1
                    case 1: audio.countInBars = 2
                    case 2: audio.countInBars = 4
                    default: audio.countInBars = 0
                    }
                } label: {
                    Text(audio.countInBars > 0 ? "\(audio.countInBars)IN" : "CIN")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .frame(width: 44, height: 44)
                        .foregroundColor(audio.countInBars > 0 ? Theme.bg : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: audio.countInBars > 0, filled: audio.countInBars > 0))
                ArcKnob(label: "IN", value: Binding(
                    get: { audio.inputVolume * 100 }, set: { audio.applyInputVolume($0 / 100) }
                ), range: 0...100, color: Theme.textSecondary, size: 38)
                ArcKnob(label: "OUT", value: Binding(
                    get: { audio.volume * 100 }, set: { audio.applyVolume($0 / 100) }
                ), range: 0...100, color: Theme.accent, size: 38)
                Button { audio.toggleMasterLimiter() } label: {
                    Text("LIM")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .frame(width: 36, height: 44)
                        .foregroundColor(audio.masterLimiterEnabled ? Theme.bg : Theme.textTertiary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.loopGreen, active: audio.masterLimiterEnabled, filled: audio.masterLimiterEnabled))
                .help(audio.masterLimiterEnabled ? "Master limiter active" : "Master limiter bypassed")
                Button {
                    if audio.isMonitoring { audio.stopMonitoring() } else { audio.startMonitoring() }
                } label: {
                    ZStack {
                        Circle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1).frame(width: 40, height: 40)
                        Image(systemName: "headphones").font(.system(size: 14, weight: .medium))
                            .foregroundColor(audio.isMonitoring ? Theme.textPrimary : Theme.textSecondary)
                    }
                    .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .top)
    }

    @ViewBuilder
    private func tpBtn(icon: String, label: String, fg: Color, bg: Color = .clear,
                        border: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
            }
            .frame(height: 44).padding(.horizontal, 18)
            .foregroundColor(fg).background(bg)
            .overlay(Rectangle().stroke(border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// ── Reel SVG ────────────────────────────────────────────────────────────────

struct ReelView: View {
    let spinning: Bool
    let fast: Bool

    var body: some View {
        ZStack {
            // Outer rim
            Circle()
                .stroke(Theme.textPrimary, lineWidth: 1.5)
                .frame(width: 90, height: 90)
            // Hub
            Circle()
                .stroke(Theme.textPrimary, lineWidth: 1.5)
                .frame(width: 22, height: 22)
            Circle()
                .stroke(Theme.textPrimary, lineWidth: 1.5)
                .frame(width: 10, height: 10)
            Circle()
                .fill(Theme.textPrimary)
                .frame(width: 3, height: 3)
            // 3 spokes
            ForEach(0..<3, id: \.self) { i in
                let angle = Angle.degrees(Double(i) * 120 - 90)
                Path { p in
                    p.move(to: CGPoint(x: 45 + 11 * cos(angle.radians),
                                       y: 45 + 11 * sin(angle.radians)))
                    p.addLine(to: CGPoint(x: 45 + 39 * cos(angle.radians),
                                          y: 45 + 39 * sin(angle.radians)))
                }
                .stroke(Theme.textPrimary, lineWidth: 1.5)
            }
        }
        .frame(width: 90, height: 90)
        .rotationEffect(spinning ? .degrees(360) : .zero)
        .animation(spinning ? .linear(duration: fast ? 1.4 : 2.6).repeatForever(autoreverses: false) : .default, value: spinning)
    }
}

// ── ArrangeHeadUnit (TAPE 08 head section) ──────────────────────────────────

struct ArrangeHeadUnit: View {
    @ObservedObject var audio: AudioManager
    @ObservedObject var meters: MeterState

    private var timerText: String {
        let t = audio.recordingDuration
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let tenths = Int((t - floor(t)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }
    private var statusText: String {
        audio.isRecording ? "REC" : (audio.isPlaying ? "PLAY" : "IDLE")
    }
    private var barPosition: String {
        let bpm = audio.metronomeBPM
        let secsPerBar = 240.0 / bpm  // 4 beats per bar
        let bar = Int(audio.recordingDuration / secsPerBar) + 1
        let beat = Int((audio.recordingDuration.truncatingRemainder(dividingBy: secsPerBar)) / (secsPerBar / 4)) + 1
        return String(format: "%03d.%d", bar, beat)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left: selected track info
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    // Boxed track number — rounded corners
                    Text(String(format: "%02d", audio.selectedTrack + 1))
                        .font(.system(size: 36, weight: .ultraLight, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .frame(width: 64, height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.textPrimary, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SELECTED\nTRACK")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(Theme.textSecondary)
                            .lineSpacing(2)
                        Text(audio.editTargetIndex(on: audio.selectedTrack)
                                .map { audio.tracks[audio.selectedTrack].clips[$0].name }
                             ?? "TRK \(String(format: "%02d", audio.selectedTrack + 1))")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Text("\u{25CF} ARMED")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(Theme.danger)
                    }
                }

                // Info grid: 2×2
                // Info grid: aligned 2×2 with fixed first column
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 20) {
                        infoItem("INPUT", audio.inputDevices.first { $0.id == audio.selectedInputID }?.name ?? "MBP MIC")
                            .frame(width: 100, alignment: .leading)
                        infoItem("OUTPUT", audio.outputDevices.first { $0.id == audio.selectedOutputID }?.name ?? "MBP SPK")
                    }
                    HStack(spacing: 20) {
                        infoItem("POSITION", "BAR \(barPosition)")
                            .frame(width: 100, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LOOP")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(Theme.textTertiary)
                            Text(audio.loopEnabled ? "BAR 05 \u{2192} 16" : "OFF")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(audio.loopEnabled ? Theme.loopGreen : Theme.textTertiary)
                        }
                    }
                }
            }
            .frame(minWidth: 200, alignment: .leading)
            .layoutPriority(-1)

            // Center: reels + timecode
            VStack(spacing: 0) {
                ZStack {
                    // Reels
                    HStack(spacing: 0) {
                        ReelView(spinning: audio.isPlaying || audio.isRecording, fast: audio.isRecording)
                        Spacer()
                        ReelView(spinning: audio.isPlaying || audio.isRecording, fast: audio.isRecording)
                    }
                    .padding(.horizontal, 20)

                    // Timecode overlay
                    VStack(spacing: 6) {
                        Text("TRK \(String(format: "%02d", audio.selectedTrack + 1)) \u{00B7} \(statusText)")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(4)
                            .foregroundColor(Theme.textSecondary)
                        Text(timerText)
                            .font(.system(size: 48, weight: .ultraLight, design: .monospaced))
                            .foregroundColor(audio.isRecording ? Theme.danger : Theme.textPrimary)
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)

                        // Bar position below timecode
                        Text("BAR \(barPosition)")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                // Tape path
                HStack(spacing: 0) {
                    Spacer()
                    // Rollers + head
                    HStack(spacing: 20) {
                        Circle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 12, height: 12)
                        Circle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 18, height: 18)
                            .overlay(Circle().fill(Theme.textPrimary).frame(width: 5, height: 5))
                        // Playhead/tape guide
                        VStack(spacing: 2) {
                            Rectangle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 18, height: 16)
                            Rectangle().fill(Theme.accent).frame(width: 1.5, height: 10)
                        }
                        Circle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 18, height: 18)
                            .overlay(
                                Path { p in
                                    p.move(to: CGPoint(x: 4, y: 14)); p.addLine(to: CGPoint(x: 14, y: 4))
                                }.stroke(Theme.textPrimary, lineWidth: 1.5)
                            )
                        Circle().stroke(Theme.textPrimary, lineWidth: 1.5).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                .padding(.top, 4)

                // Loop toggle
                Button(action: { audio.setLoopEnabled(!audio.loopEnabled) }) {
                    Image(systemName: "repeat")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(audio.loopEnabled ? Theme.loopGreen : Theme.textTertiary)
                        .frame(width: 48, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(audio.loopEnabled ? Theme.loopGreen.opacity(0.4) : Theme.textTertiary.opacity(0.3), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)

            // Right: peak + tempo + meters
            HStack(spacing: 16) {
                VStack(alignment: .trailing, spacing: 16) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("PEAK")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(Theme.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(meters.peakDB.isFinite ? String(format: "%.1f", meters.peakDB) : "\u{2212}\u{221E}")
                                .font(.system(size: 28, weight: .light, design: .monospaced))
                                .foregroundColor(meters.peakDB > -0.5 ? Theme.danger : Theme.textPrimary)
                                .monospacedDigit()
                            Text("dB")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("TEMPO / SIG")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(Theme.textSecondary)
                        Text("\(Int(audio.metronomeBPM)) \u{00B7} 4/4")
                            .font(.system(size: 20, weight: .light, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                    }
                }

                // Vertical L/R meters
                HStack(spacing: 4) {
                    VerticalMeter(label: "L", level: meters.levelL, peak: meters.peakL)
                    VerticalMeter(label: "R", level: meters.levelR, peak: meters.peakR)
                    VStack {
                        Text("0").frame(maxHeight: .infinity, alignment: .top)
                        Text("-6").frame(maxHeight: .infinity)
                        Text("-12").frame(maxHeight: .infinity)
                        Text("-24").frame(maxHeight: .infinity)
                        Text("-36").frame(maxHeight: .infinity)
                        Text("-60").frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                }
                .frame(height: 160)
            }
            .frame(minWidth: 180, alignment: .trailing)
            .layoutPriority(-1)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
    }
}

// ── MonitorView (live signal display) ───────────────────────────────────────

struct MonitorView: View {
    @ObservedObject var audio: AudioManager
    @ObservedObject var meters: MeterState

    private var timerText: String {
        let t = audio.recordingDuration
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let tenths = Int((t - floor(t)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }
    private var barColor: Color {
        if audio.isRecording { return Theme.danger }
        return audio.isMonitoring ? Theme.accent : Theme.textTertiary
    }
    private var inputName: String {
        audio.inputDevices.first { $0.id == audio.selectedInputID }?.name ?? "No Input"
    }
    private var outputName: String {
        audio.outputDevices.first { $0.id == audio.selectedOutputID }?.name ?? "No Output"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status + timecode
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(audio.isRecording ? Theme.danger : (audio.isMonitoring ? Theme.accent : Theme.textTertiary))
                        .frame(width: 6, height: 6)
                    Text(audio.isRecording ? "REC" : (audio.isMonitoring ? "LIVE" : "IDLE"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(4)
                        .foregroundColor(audio.isRecording ? Theme.danger : (audio.isMonitoring ? Theme.accent : Theme.textTertiary))
                    Text("\(inputName) \u{2192} \(outputName)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textSecondary)
                }

                Text(timerText)
                    .font(.system(size: 60, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(audio.isRecording ? Theme.danger : Theme.textPrimary)
                    .monospacedDigit()

                // Signal chain breadcrumb
                HStack(spacing: 8) {
                    Text("In").foregroundColor(Theme.accent)
                    ForEach(Array(audio.liveChain.enumerated()), id: \.element.id) { _, slot in
                        Text("\u{2192}").foregroundColor(Theme.textTertiary)
                        Circle()
                            .fill(slot.enabled ? Theme.accent : Theme.textTertiary)
                            .frame(width: 6, height: 6)
                        Text(EffectRegistry.shared.module(for: slot.moduleID)?.displayName ?? slot.moduleID)
                            .foregroundColor(slot.enabled ? Theme.textPrimary : Theme.textTertiary)
                    }
                    Text("\u{2192}").foregroundColor(Theme.textTertiary)
                    Text("Out").foregroundColor(Theme.accent)
                }
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            // Scrolling waveform (hero)
            GeometryReader { geo in
                let midY = geo.size.height / 2
                ZStack {
                    // Grid lines
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: midY))
                        p.addLine(to: CGPoint(x: geo.size.width, y: midY))
                    }
                    .stroke(Theme.textPrimary.opacity(0.08), lineWidth: 0.5)

                    // Recording marker
                    if audio.isRecording {
                        let recX = geo.size.width * 0.5
                        Path { p in
                            p.move(to: CGPoint(x: recX, y: 0))
                            p.addLine(to: CGPoint(x: recX, y: geo.size.height))
                        }
                        .stroke(Theme.danger, lineWidth: 1)
                        Text("REC IN")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(Theme.danger)
                            .position(x: recX, y: 12)
                    }

                    // Waveform bars
                    Path { path in
                        let count = meters.waveformSamples.count
                        guard count > 0 else { return }
                        let barWidth: CGFloat = 3
                        let spacing = geo.size.width / CGFloat(count)
                        for (i, val) in meters.waveformSamples.enumerated() {
                            let x = CGFloat(i) * spacing + spacing / 2
                            let h = CGFloat(val) * (geo.size.height / 2.2)
                            let rect = CGRect(x: x - barWidth / 2, y: midY - h,
                                              width: barWidth, height: h * 2)
                            path.addRect(rect)
                        }
                    }
                    .fill(barColor.opacity(0.85))
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 28)
            .background(Theme.bg)

            // Time axis
            HStack {
                Text("-40s"); Spacer(); Text("-30s"); Spacer()
                Text("-20s"); Spacer(); Text("-10s"); Spacer(); Text("now")
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 32).padding(.vertical, 4)

            // Horizontal L/R meters
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    hMeter(label: "L", level: meters.levelL, peak: meters.peakL)
                    hMeter(label: "R", level: meters.levelR, peak: meters.peakR)
                    // dB scale
                    GeometryReader { geo in
                        ZStack {
                            let marks: [(String, Double)] = [("-60", 0), ("-36", 0.24), ("-24", 0.40),
                                                              ("-12", 0.60), ("-6", 0.80), ("0 dB", 1.0)]
                            ForEach(marks, id: \.0) { mark in
                                Text(mark.0)
                                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .position(x: 14 + CGFloat(mark.1) * (geo.size.width - 28), y: 6)
                            }
                        }
                    }
                    .frame(height: 14)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text("PEAK")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textTertiary)
                    Text(meters.peakDB.isFinite ? String(format: "%+.1f dB", meters.peakDB) : "\u{2212}\u{221E} dB")
                        .font(.system(size: 22, weight: .light, design: .monospaced))
                        .foregroundColor(meters.peakDB > -0.5 ? Theme.danger : Theme.textPrimary)
                        .monospacedDigit()
                }
                .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)

            // Device pickers + routing
            HStack(spacing: 24) {
                HStack(spacing: 6) {
                    Text("Input").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                    Picker("", selection: Binding(
                        get: { audio.selectedInputID },
                        set: { audio.selectedInputID = $0; audio.startMonitoring() }
                    )) {
                        ForEach(audio.inputDevices) { dev in Text(dev.name).tag(Optional(dev.id)) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                HStack(spacing: 6) {
                    Text("Output").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                    Picker("", selection: Binding(
                        get: { audio.selectedOutputID },
                        set: { if let id = $0 { audio.switchOutput(to: id) } }
                    )) {
                        ForEach(audio.outputDevices) { dev in Text(dev.name).tag(Optional(dev.id)) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                Spacer()
                Text("Volume")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                Text("\(Int(audio.volume * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(.horizontal, 28).padding(.vertical, 10)
            .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(height: 1), alignment: .top)
        }
    }

    @ViewBuilder
    private func hMeter(label: String, level: Double, peak: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary).frame(width: 8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.surfaceInset)
                    Rectangle()
                        .fill(level > 0.95 ? Theme.danger : Theme.accent)
                        .frame(width: max(0, CGFloat(level) * geo.size.width))
                    Rectangle()
                        .fill(Theme.textPrimary)
                        .frame(width: 2)
                        .offset(x: max(0, min(geo.size.width - 2, CGFloat(peak) * geo.size.width)))
                }
            }
            .frame(height: 6)
        }
    }
}

// ── Trim Editor ─────────────────────────────────────────────────────────────

struct TrimEditorView: View {
    @ObservedObject var audio: AudioManager

    private func timeString(_ fraction: Double) -> String {
        let t = fraction * audio.trimClipDuration
        let m = Int(t) / 60
        let s = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 100)
        return String(format: "%d:%02d.%02d", m, s, ms)
    }

    private var trimmedDuration: String {
        let d = (audio.trimEnd - audio.trimStart) * audio.trimClipDuration
        let m = Int(d) / 60
        let s = Int(d) % 60
        let ms = Int((d - Double(Int(d))) * 100)
        return String(format: "%d:%02d.%02d", m, s, ms)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("TRIM")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(Theme.gold)
                // Name the take being trimmed: since the editor can open on any take,
                // not just the last one, "TRK NN" alone no longer says what APPLY will cut.
                if let ti = audio.trimmingTrack, ti < audio.tracks.count {
                    let take = audio.trimClipID
                        .flatMap { id in audio.tracks[ti].clips.firstIndex { $0.id == id } }
                    Text(take.map { "TRK \(String(format: "%02d", ti + 1)) \u{00B7} TAKE \($0 + 1)" }
                         ?? "TRK \(String(format: "%02d", ti + 1))")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.gold.opacity(0.6))
                }
                Spacer()
                Text(trimmedDuration)
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundColor(Theme.gold)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Rectangle().fill(Theme.gold.opacity(0.2)).frame(height: 1)

            // Waveform with trim handles
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let leftX = CGFloat(audio.trimStart) * w
                let rightX = CGFloat(audio.trimEnd) * w

                ZStack(alignment: .topLeading) {
                    // Grid lines
                    Path { path in
                        for i in 1..<8 {
                            let x = w * CGFloat(i) / 8
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: h))
                        }
                        path.move(to: CGPoint(x: 0, y: h / 2))
                        path.addLine(to: CGPoint(x: w, y: h / 2))
                    }
                    .stroke(Theme.gold.opacity(0.08), lineWidth: 0.5)

                    // Dimmed regions outside trim
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: max(0, leftX))
                        .frame(maxHeight: .infinity, alignment: .leading)
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: max(0, w - rightX))
                        .frame(maxHeight: .infinity, alignment: .trailing)
                        .position(x: (rightX + w) / 2, y: h / 2)

                    // Waveform bars
                    if !audio.trimPeaks.isEmpty {
                        Path { path in
                            let midY = h / 2
                            let barW = w / CGFloat(audio.trimPeaks.count)
                            for (j, peak) in audio.trimPeaks.enumerated() {
                                let x = CGFloat(j) * barW + barW / 2
                                let barH = CGFloat(peak) * midY * 0.85
                                path.move(to: CGPoint(x: x, y: midY - barH))
                                path.addLine(to: CGPoint(x: x, y: midY + barH))
                            }
                        }
                        .stroke(Theme.gold.opacity(0.7), lineWidth: max(1, w / CGFloat(audio.trimPeaks.count) - 1))
                    }

                    // Left handle
                    Rectangle()
                        .fill(Theme.gold)
                        .frame(width: 2, height: h)
                        .position(x: leftX, y: h / 2)
                    Path { p in
                        p.move(to: CGPoint(x: leftX, y: h / 2 - 14))
                        p.addLine(to: CGPoint(x: leftX + 10, y: h / 2))
                        p.addLine(to: CGPoint(x: leftX, y: h / 2 + 14))
                        p.closeSubpath()
                    }
                    .fill(Theme.gold)

                    // Right handle
                    Rectangle()
                        .fill(Theme.gold)
                        .frame(width: 2, height: h)
                        .position(x: rightX, y: h / 2)
                    Path { p in
                        p.move(to: CGPoint(x: rightX, y: h / 2 - 14))
                        p.addLine(to: CGPoint(x: rightX - 10, y: h / 2))
                        p.addLine(to: CGPoint(x: rightX, y: h / 2 + 14))
                        p.closeSubpath()
                    }
                    .fill(Theme.gold)

                    // Time labels at handles
                    Text(timeString(audio.trimStart))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.gold)
                        .position(x: leftX + 28, y: 10)
                    Text(timeString(audio.trimEnd))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.gold)
                        .position(x: rightX - 28, y: 10)

                    // Drag zones
                    Color.clear
                        .frame(width: 30, height: h)
                        .contentShape(Rectangle())
                        .position(x: leftX, y: h / 2)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { g in
                                    let frac = max(0, min(audio.trimEnd - 0.01, Double(g.location.x / w)))
                                    audio.trimStart = frac
                                }
                        )
                    Color.clear
                        .frame(width: 30, height: h)
                        .contentShape(Rectangle())
                        .position(x: rightX, y: h / 2)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { g in
                                    let frac = min(1, max(audio.trimStart + 0.01, Double(g.location.x / w)))
                                    audio.trimEnd = frac
                                }
                        )
                }
            }
            .frame(height: 100)
            .background(Theme.surfaceInset)
            .padding(.horizontal, 16).padding(.top, 8)

            Rectangle().fill(Theme.gold.opacity(0.2)).frame(height: 1)
                .padding(.top, 8)

            // Buttons
            HStack(spacing: 12) {
                Spacer()
                Button { audio.cancelTrim() } label: {
                    Text("CANCEL")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.surface)
                        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { audio.applyTrim() } label: {
                    Text(audio.busyEdit == nil ? "APPLY" : "WORKING\u{2026}")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.bg)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Theme.gold)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(audio.busyEdit != nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.bg)
        .overlay(Rectangle().stroke(Theme.gold.opacity(0.3), lineWidth: 1))
    }
}

// ── Settings Panel ──────────────────────────────────────────────────────────

struct SettingsPanel: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(16)
            Rectangle().fill(Theme.accent.opacity(0.15)).frame(height: 1)

            VStack(alignment: .leading, spacing: 16) {
                // Save location
                VStack(alignment: .leading, spacing: 6) {
                    Text("SAVE LOCATION")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)
                    HStack(spacing: 8) {
                        Text(audio.saveLocation.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { audio.changeSaveLocation() } label: {
                            Text("CHANGE")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .tracking(1)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .foregroundColor(Theme.accent)
                                .background(Theme.surfaceInset)
                                .overlay(Rectangle().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                // Audio info
                VStack(alignment: .leading, spacing: 6) {
                    Text("AUDIO")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)

                    settingsRow("Sample Rate", audio.sampleRateString)

                    if let inputName = audio.inputDevices.first(where: { $0.id == audio.selectedInputID })?.name {
                        settingsRow("Input", inputName)
                    }
                    if let outputName = audio.outputDevices.first(where: { $0.id == audio.selectedOutputID })?.name {
                        settingsRow("Output", outputName)
                    }
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                // Export
                VStack(alignment: .leading, spacing: 6) {
                    Text("EXPORT")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)

                    Button { audio.exportTrack(audio.selectedTrack) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 10, weight: .bold))
                            Text("EXPORT TRK \(String(format: "%02d", audio.selectedTrack + 1))")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .tracking(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(Theme.accent)
                        .background(Theme.surfaceInset)
                        .overlay(Rectangle().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(audio.busyEdit != nil)
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                // Clip editing
                VStack(alignment: .leading, spacing: 6) {
                    Text("CLIP EDIT")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)

                    HStack(spacing: 6) {
                        // SPLIT reads the playhead, so it needs one: either a running
                        // track, or a position parked on a stopped one by dragging the
                        // bar ruler. Without the second case the button would refuse a
                        // cut that ⌘T performs, since ⌘T has no such check.
                        let splitReady = audio.hasEditableClip
                            && (audio.tracks[audio.selectedTrack].isPlaying || audio.seekFraction != nil)
                        Button { audio.splitClipAtPlayhead(audio.selectedTrack) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "scissors")
                                    .font(.system(size: 9, weight: .bold))
                                Text("SPLIT")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .tracking(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundColor(splitReady ? Theme.accent : Theme.textTertiary)
                            .background(Theme.surfaceInset)
                            .overlay(Rectangle().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!splitReady || audio.busyEdit != nil)

                        Button { audio.duplicateClip(audio.selectedTrack) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9, weight: .bold))
                                Text("DUP")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .tracking(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundColor(audio.tracks[audio.selectedTrack].clips.isEmpty ? Theme.textTertiary : Theme.accent)
                            .background(Theme.surfaceInset)
                            .overlay(Rectangle().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!audio.hasEditableClip || audio.busyEdit != nil)
                    }

                    Button { audio.openTrimEditor(audio.selectedTrack) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "timeline.selection")
                                .font(.system(size: 9, weight: .bold))
                            Text("TRIM")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .tracking(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundColor(audio.tracks[audio.selectedTrack].clips.isEmpty ? Theme.textTertiary : Theme.gold)
                        .background(Theme.surfaceInset)
                        .overlay(Rectangle().stroke(Theme.gold.opacity(0.3), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!audio.hasEditableClip || audio.busyEdit != nil)

                    Text("\u{2318}T SPLIT  \u{2318}D DUP  \u{2318}1\u{2013}8 TAKE")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textTertiary.opacity(0.6))
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                // Session info
                VStack(alignment: .leading, spacing: 6) {
                    Text("SESSION")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textEngraved)

                    let clipCount = audio.tracks.reduce(0) { $0 + $1.clips.count }
                    settingsRow("Clips", "\(clipCount)")
                    settingsRow("Tracks Used", "\(audio.tracks.filter { !$0.clips.isEmpty }.count) / \(Theme.trackCount)")
                    settingsRow("Effects", "\(audio.liveChain.filter { $0.enabled }.count) active")
                }
            }
            .padding(16)

            Spacer()
        }
        .frame(width: 260)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.textPrimary.opacity(0.10)).frame(width: 1), alignment: .trailing)
    }

    private func settingsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
    }
}

// ── First-run save location ─────────────────────────────────────────────────

/// Shown once on first launch of the sandboxed build, so the user can pick where
/// takes are saved. Choosing a folder stores a security-scoped bookmark (see
/// `SaveLocation`) so the choice survives relaunch; "Not now" keeps the app's own
/// Documents folder as a always-writable fallback.
struct SaveLocationSheet: View {
    @ObservedObject var audio: AudioManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WHERE SHOULD TAPES BE SAVED?")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.textSecondary)

            Text("TAPE 08 records your takes into a folder you choose. Pick one now, or keep the default and change it later in Settings.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text(displayPath)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.surfaceInset)

            HStack(spacing: 10) {
                Button {
                    SaveLocation.markPrompted()
                    dismiss()
                } label: { sheetButton("NOT NOW", accent: false) }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    audio.changeSaveLocation()
                    dismiss()
                } label: { sheetButton("CHOOSE FOLDER\u{2026}", accent: true) }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.bg)
    }

    private var displayPath: String {
        audio.saveLocation.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func sheetButton(_ title: String, accent: Bool) -> some View {
        let tint = accent ? Theme.accent : Theme.textSecondary
        return Text(title)
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(1)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundColor(tint)
            .background(Theme.surfaceInset)
            .overlay(Rectangle().stroke(tint.opacity(0.3), lineWidth: 1))
            .contentShape(Rectangle())
    }
}
#endif
