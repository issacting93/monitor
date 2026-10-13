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

    /// Minimum target size. Draws nothing: the label keeps its own (smaller) frame, so
    /// the border, fill and press animation are all unchanged, and the box only adds
    /// transparent hit area around it. Set it where the visual is deliberately small but
    /// a pointer still has to find it — a 28 pt square is a fine thing to look at and a
    /// poor thing to aim at.
    var hit: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        let face = configuration.label
            .background(filled && active ? tint : Color.clear)
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(active ? tint : Theme.textPrimary.opacity(0.16), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)

        return Group {
            if let hit {
                // The press animation is already inside `face`, so it moves the 28 pt
                // square and not the target around it.
                face.frame(width: hit, height: hit).contentShape(Rectangle())
            } else {
                face
            }
        }
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
        // One element, not three. The drawn arc, the numeric readout and the label are
        // one control to everyone except VoiceOver, which would otherwise announce a
        // stray value and a stray word beside an unlabelled group. The adjustable action
        // is what makes the knob *usable* rather than merely described: it is a drag
        // target with no keyboard affordance of its own, so VoiceOver's increment and
        // decrement are the only way to move it without a pointer. The step is 1 % of
        // the range, which is fine enough for a knob and coarse enough not to need
        // hundreds of swipes.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(displayValue)
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 100
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
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
        // The fader is a bare drag target with nothing to read, so it gets the same
        // treatment as `ArcKnob`: one element, a value, and an adjustable action. The
        // label comes from the caller, which is the only place that knows which track
        // this is. The 2 % step matches what a drag of a few points would do.
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.02)
            case .decrement: value = max(0, value - 0.02)
            @unknown default: break
            }
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
            .accessibilityLabel("Decrease tempo")
            .help("Slower by 1 BPM")

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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tempo")
            .accessibilityValue("\(Int(audio.metronomeBPM)) BPM")

            Button { audio.metronomeBPM = min(300, audio.metronomeBPM + 1) } label: {
                Text("+")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 40, height: 44)
                    .foregroundColor(Theme.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
            .accessibilityLabel("Increase tempo")
            .help("Faster by 1 BPM")

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
            .accessibilityLabel("Tap tempo")
            .accessibilityHint("Tap repeatedly to set the tempo")
            .help("Tap in time with the music to set the tempo")
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
                    .accessibilityHidden(true)
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
                    // Routed through `selectInput` rather than bound straight to the
                    // published property: the engine only reads the selection at start
                    // time, so a direct binding would relabel the header and leave the
                    // graph on the old device.
                    Picker("", selection: Binding(
                        get: { audio.selectedInputID },
                        set: { audio.selectInput($0) }
                    )) {
                        ForEach(audio.inputDevices) { d in
                            Text(d.name).tag(Optional(d.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .accessibilityLabel("Input device")
                }
                HStack(spacing: 4) {
                    Text("OUT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.textTertiary)
                    // Same reason as the input picker above: selecting an output is what
                    // makes the engine build a private aggregate, and that only happens
                    // on a restart.
                    Picker("", selection: Binding(
                        get: { audio.selectedOutputID },
                        set: { audio.selectOutput($0) }
                    )) {
                        ForEach(audio.outputDevices) { d in
                            Text(d.name).tag(Optional(d.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .accessibilityLabel("Output device")
                }
            }

            // FX is the one drawer left; Settings moved out to the ⌘, window, so the two
            // no longer share a slot or a mutual-exclusion rule.
            HStack(spacing: 6) {
                Button(action: { audio.toggleEffectsDrawer() }) {
                    Text("FX")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundColor(audio.showEffects ? Theme.bg : Theme.textSecondary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: audio.showEffects, filled: audio.showEffects))

                // `SettingsLink`, not a button that opens a panel: it is the platform's
                // own way to open the scene, which makes the gear and the app menu's
                // "Settings…" the same command rather than two implementations of one.
                // No `active`/`filled` state, because a window is not open or closed by
                // this view and there is no flag left to draw it from.
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.accent))
                .accessibilityLabel("Settings")
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
        // The active tab is drawn as a coloured underline only; the trait is what says
        // which one it is when the colour cannot.
        .accessibilityAddTraits(audio.viewMode == mode ? [.isSelected] : [])
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
        // A bar that moves at frame rate is noise to a screen reader, and the number it
        // stands for is already on screen in text: the PEAK readout on macOS, the dB line
        // on iPad. Hidden whole rather than labelled, so VoiceOver does not sit on it.
        .accessibilityHidden(true)
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

    /// True while the pointer is over this lane holding something draggable.
    ///
    /// The lane has accepted drops since it was written, but `isTargeted` was passed
    /// `nil`, so a drag produced no feedback beyond the system's own cursor: nothing on
    /// the lane said it would take the file, and nothing said *which* of the eight would.
    /// §9 stage 8's "no hover affordances" note, on the one control where it matters — a
    /// drop is the only way to get audio in without an OP-XY on the other end.
    @State private var dropTargeted = false

    /// The lane's tooltip. "Nothing here yet" and "something can land here" are the two
    /// things a lane's shape cannot say by itself.
    private var laneHelp: String {
        hasClip
            ? "Drag an audio file here to add another take to track \(index + 1)"
            : "Empty \u{2014} drag an audio file here, or press R to record onto track \(index + 1)"
    }

    /// Makes `clip` the take that edits resolve to, exactly as clicking it does.
    ///
    /// The clip's context menu needs this because a right-click does not run the click
    /// gesture below, and every command in that menu resolves through `editTargetIndex`,
    /// which reads the selection — so without it they would act on whichever take was
    /// selected before the right-click, while appearing to act on the one under the
    /// pointer.
    private func target(_ clip: TrackClip) {
        audio.selectedTrack = index
        audio.selectedClipID = clip.id
    }

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
                    // A take is a real target — click it to select, right-click for the
                    // edit menu — so it stays in the tree rather than being hidden as
                    // decoration. Its context menu items become VoiceOver actions by
                    // themselves; only the click-to-select needs stating.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Track \(index + 1) take \(ci + 1)")
                    .accessibilityValue("\(Int(clip.duration.rounded())) seconds"
                                        + (isThisSelected ? ", selected" : ""))
                    .accessibilityAddTraits(isThisSelected ? [.isButton, .isSelected] : [.isButton])
                    .accessibilityAction {
                        audio.selectedTrack = index
                        audio.selectedClipID = clip.id
                    }
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
                    // The menu-bar commands, cut down to the ones a take can answer —
                    // per §9.5 a context menu is the relevant subset of those, not a
                    // second command set that has to be kept in step by hand.
                    .contextMenu {
                        Button("Trim…") { target(clip); audio.openTrimEditor(index) }
                            .disabled(audio.busyEdit != nil)
                        Button("Split at Playhead") { target(clip); audio.splitClipAtPlayhead(index) }
                            .disabled(audio.busyEdit != nil)
                        // Duplicate takes the index, so it needs no re-targeting and
                        // cannot be pointed at the wrong take.
                        Button("Duplicate") { audio.duplicateClip(index, clipIndex: ci) }
                            .disabled(audio.busyEdit != nil)
                        // The track's export, not the take's: there is no per-take export,
                        // so the label says track rather than implying one exists.
                        Button("Export Track…") { audio.exportTrack(index) }
                            .disabled(audio.busyEdit != nil)

                        Divider()

                        Menu("Select Take") {
                            ForEach(1...8, id: \.self) { n in
                                Button("Take \(n)") {
                                    target(clip)
                                    audio.selectClip(number: n)
                                }
                                .disabled(n > track.clips.count)
                            }
                        }
                    }
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
                .stroke(dropTargeted ? Theme.accent.opacity(0.7)
                                     : Theme.textPrimary.opacity(0.12),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // Empty reads as "nothing here yet", not as "this is broken", and while a
                // file is over the lane it says what dropping it would do.
                Text(dropTargeted ? "DROP TO IMPORT" : "\u{2014} EMPTY \u{2014}")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(dropTargeted ? Theme.accent : Theme.textTertiary)
                    .frame(width: laneWidth, height: 52)
            }

            if isRecordingThis {
                Rectangle()
                    .fill(Theme.danger.opacity(0.05))
                    .overlay(Rectangle().stroke(Theme.danger.opacity(0.4), lineWidth: 1))
            }
        }
        .frame(width: laneWidth, height: 52)
        .background(dropTargeted
                    ? Theme.accent.opacity(0.10)
                    : (isSelected ? Theme.textPrimary.opacity(0.025) : Color.clear))
        .overlay(
            Rectangle().stroke(dropTargeted
                               ? Theme.accent.opacity(0.8)
                               : (isSelected ? color.opacity(0.4) : Theme.textPrimary.opacity(0.10)),
                               lineWidth: 1)
        )
        .help(laneHelp)
        .onDrop(of: [.audio, .fileURL], isTargeted: $dropTargeted) { providers in
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
            .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: track.isPlaying, hit: 44))
            // "play.fill" alone would be announced as "play button" for every one of the
            // eight rows, with nothing to say which track or whether it is already
            // running. The track number in the label and the state in the value are what
            // make the row's four controls tell apart.
            .accessibilityLabel("Track \(index + 1) playback")
            .accessibilityValue(track.isPlaying ? "Playing" : "Stopped")
            .help(track.clips.isEmpty
                  ? "Nothing recorded on track \(index + 1) yet"
                  : (track.isPlaying ? "Stop track \(index + 1)"
                                     : "Play track \(index + 1) on its own"))

            Button { audio.toggleMute(index) } label: {
                // The `filled:` state below already inverts this button in greyscale —
                // gold fill with dark text, against a transparent box with grey text —
                // so mute was not *purely* colour. The strike is a second, text-level
                // difference on top of it: it survives Increase Contrast and any
                // adjustment that washes the fill out, and it says "cut" in the same
                // breath as the mixer vocabulary the rest of the app uses.
                Text("M")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .strikethrough(track.muted)
                    .frame(width: 28, height: 28)
                    .foregroundColor(track.muted ? Theme.bg : Theme.textSecondary)
            }
            .buttonStyle(RetroButtonStyle(tint: Theme.accent, active: track.muted, filled: track.muted, hit: 44))
            .accessibilityLabel("Mute track \(index + 1)")
            .accessibilityValue(track.muted ? "Muted" : "Not muted")
            .accessibilityAddTraits(track.muted ? [.isSelected] : [])
            .help("Mute track \(index + 1) (M)")

            Button { audio.toggleSolo(index) } label: {
                // Underline rather than a strike, so solo and mute are distinguishable
                // from each other without colour as well as from their own other state.
                Text("S")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .underline(track.solo)
                    .frame(width: 28, height: 28)
                    .foregroundColor(track.solo ? Theme.bg : Theme.textSecondary)
            }
            .buttonStyle(RetroButtonStyle(tint: Color(red: 0x5C/255.0, green: 0xC8/255.0, blue: 0xE0/255.0), active: track.solo, filled: track.solo, hit: 44))
            .accessibilityLabel("Solo track \(index + 1)")
            .accessibilityValue(track.solo ? "Soloed" : "Not soloed")
            .accessibilityAddTraits(track.solo ? [.isSelected] : [])
            .help("Solo track \(index + 1) (S) \u{2014} silences every other track")

            TrackFader(
                value: Binding(
                    get: { track.volume },
                    set: { audio.setTrackVolume(index, $0) }
                ),
                onDragStart: { audio.beginUndoGesture() },
                onDragEnd: { audio.endUndoGesture() }
            )
            .frame(width: 80, height: 20)
            .accessibilityLabel("Track \(index + 1) volume")
            .help("How loud track \(index + 1) sits in the mix")

            // Same as the pan readout below: the fader to its left already speaks this
            // number, so reading it again would just say it twice.
            Text("\(Int(track.volume * 100))")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
                .accessibilityHidden(true)

            // "L" and "R" are axis marks for the slider between them, not content; the
            // slider says its own value and the "C"/"L40"/"R40" readout follows it.
            Text("L")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { track.pan },
                set: { audio.setTrackPan(index, $0) }
            ), in: -1...1) { editing in
                if editing { audio.beginUndoGesture() } else { audio.endUndoGesture() }
            }
            .frame(width: 50)
            .tint(color.opacity(0.6))
            .accessibilityLabel("Track \(index + 1) pan")
            .accessibilityValue(track.pan == 0
                                ? "Centre"
                                : (track.pan < 0 ? "\(Int(abs(track.pan) * 100)) percent left"
                                                 : "\(Int(track.pan * 100)) percent right"))
            .help("Where track \(index + 1) sits between the speakers")
            Text("R")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(track.pan == 0 ? "C" : (track.pan < 0 ? "L\(Int(abs(track.pan) * 100))" : "R\(Int(track.pan * 100))"))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 32, alignment: .trailing)
                .accessibilityHidden(true)

            // A live meter is not something VoiceOver can usefully read — it changes 60
            // times a second — so it is hidden rather than exposed as a value that would
            // be stale before it finished being spoken. The head unit's PEAK readout is
            // the speakable form of the same number.
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
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(width: Theme.controlsColumnWidth)
        // The same Track commands the menu bar carries, minus the ones that only make
        // sense for the selected track as a whole. "Clear All Tracks" is deliberately
        // absent: this menu is about one track, and offering a command that wipes all
        // eight from here would be a trap. Clearing *this* track is not, and names the
        // track it will clear rather than acting on the selection.
        .contextMenu {
            // Reading the global flag rather than the track's own state, because
            // `toggleTrackRecord` stops whatever take is running wherever it is — so if
            // anything is recording, the honest label is "Stop Recording".
            Button(audio.isRecording ? "Stop Recording" : "Record on This Track") {
                audio.toggleTrackRecord(index)
            }
            .disabled(audio.busyEdit != nil)

            Divider()

            // Toggles rather than assignments: `toggleMute`/`toggleSolo` are what push
            // undo and refresh the mixers, so the binding's new value is discarded.
            Toggle("Mute", isOn: Binding(
                get: { track.muted },
                set: { _ in audio.toggleMute(index) }
            ))
            Toggle("Solo", isOn: Binding(
                get: { track.solo },
                set: { _ in audio.toggleSolo(index) }
            ))

            Divider()

            Menu("Select Take") {
                ForEach(1...8, id: \.self) { n in
                    Button("Take \(n)") {
                        // `selectClip` works on the selected track, so the track has to
                        // be selected first for a right-click here to mean this one.
                        audio.selectedTrack = index
                        audio.selectClip(number: n)
                    }
                    .disabled(n > track.clips.count)
                }
            }

            Divider()

            // Destructive, so it sits on its own at the bottom rather than next to the
            // toggles. `clearTrack` reads the index it is given, so the track is named
            // outright and does not depend on this being the selected one.
            Button("Clear Track") { audio.clearTrack(index) }
                .disabled(track.clips.isEmpty || audio.busyEdit != nil)
        }
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
        // The ruler is the grid's only seek affordance and it is a bare drag strip with
        // nothing focusable on it, so the same seek is exposed as an adjustable element —
        // 1 % of the loop span per step, which is finer than the drag's own resolution.
        // Making it one element means the bar numbers stop being read out; they are a
        // positional aid for the eye, and the value below states the position in words.
        .accessibilityElement()
        .accessibilityLabel("Timeline position")
        .accessibilityValue("\(Int((audio.seekFraction ?? 0) * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let current = audio.seekFraction ?? 0
            switch direction {
            case .increment: audio.seek(toFraction: min(1, current + 0.01))
            case .decrement: audio.seek(toFraction: max(0, current - 0.01))
            @unknown default: break
            }
        }
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

    /// Reduce Motion is honoured where the app animates *motion*, and only there: a
    /// timeline scroll that flies across the whole grid, and (in `ReelView`) a reel that
    /// turns forever. The 3 % press scale in `RetroButtonStyle` and the 60 ms colour
    /// fades are deliberately left alone — they are far below what the setting is for,
    /// and suppressing them would only make the controls feel dead rather than calm.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var secsPerBar: Double { 240.0 / audio.metronomeBPM }
    private var totalBars: Int {
        let maxDur = audio.tracks.flatMap(\.clips).map(\.duration).max() ?? 0
        let barsFromClips = maxDur > 0 ? Int(ceil(maxDur / secsPerBar)) : 0
        let raw = max(8, barsFromClips + 4)
        return ((raw + 3) / 4) * 4
    }

    /// The spoken form of a track header's state. Eight headers draw the same shape, so
    /// without this VoiceOver reaches eight buttons called "01"…"08" and cannot say which
    /// one is selected, which are muted, or which hold anything.
    private func headerValue(_ i: Int, _ trk: TrackInfo) -> String {
        var parts = [audio.selectedTrack == i ? "Selected" : "Not selected"]
        parts.append(trk.clips.isEmpty
                     ? "Empty"
                     : (trk.clips.count == 1 ? "1 take" : "\(trk.clips.count) takes"))
        if trk.muted { parts.append("Muted") }
        if trk.solo { parts.append("Soloed") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { outerGeo in
            let headerW: CGFloat = 200
            let controlsW = Theme.controlsColumnWidth
            let hPad: CGFloat = 56
            let availableW = max(outerGeo.size.width - headerW - controlsW - hPad, 100)
            let laneWidth = availableW * CGFloat(audio.timelineZoom)

            HStack(spacing: 0) {
                // ── Fixed left: track headers + zoom/follow controls ──
                VStack(spacing: 0) {
                    // Zoom / follow. The row keeps its 18 pt height — it is the grid's
                    // vertical rhythm and a taller one would push all eight track rows
                    // down — so the targets grow along the width it has spare (92 pt of
                    // it) and not vertically: above the row is the grid's top edge and
                    // below it is track 1's own select button, which being the later
                    // sibling would win the hit test in any overlap. The result is a
                    // 44 × 18 target: full-width, still short of HIG's 44 pt on the
                    // short axis, and honest about it.
                    HStack(spacing: 4) {
                        Button { audio.zoomOut() } label: {
                            Image(systemName: "minus.magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 44, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zoom timeline out")
                        .help("Fit more of the timeline on screen (\u{2318}\u{2212})")

                        Text("\(Int(audio.timelineZoom * 100))%")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 36)

                        Button { audio.zoomIn() } label: {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 44, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zoom timeline in")
                        .help("See the waveform in finer detail (\u{2318}+)")

                        Spacer()

                        Button { audio.playheadFollow.toggle() } label: {
                            Image(systemName: "scope")
                                .font(.system(size: 10))
                                .foregroundColor(audio.playheadFollow ? Theme.accent : Theme.textTertiary)
                                .frame(width: 44, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(audio.playheadFollow ? "Follow ON (F)" : "Follow OFF (F)")
                        .accessibilityLabel("Playhead follow")
                        .accessibilityValue(audio.playheadFollow ? "On" : "Off")
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
                        // `.ignore` rather than `.combine`: the header's children are the
                        // number, the identity bar and two lines of text, and combining
                        // them would read "01, TRK 01, EMPTY" — the same facts twice, in
                        // the drawing's order rather than a useful one.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Track \(i + 1)")
                        .accessibilityValue(headerValue(i, trk))
                        .accessibilityAddTraits(audio.selectedTrack == i ? [.isSelected] : [])
                        // The row dims to 32 % when it is inaudible. That is a real cue
                        // ("this is muted or another track is soloed") and hiding it would
                        // lose it for everyone else, so it is carried into the value the
                        // same way, in words.
                        .accessibilityHint(audible ? "" : "Inaudible")
                        .help("Select track \(String(format: "%02d", i + 1)) \u{2014} the transport, FX chain and edit keys act on it (\u{2318}\(i + 1))")
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
                            // Jump rather than glide under Reduce Motion. This one scroll
                            // can travel the whole timeline in a single step, which is
                            // exactly the large movement the setting exists to suppress.
                            if reduceMotion {
                                proxy.scrollTo("playhead_anchor", anchor: .center)
                            } else {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    proxy.scrollTo("playhead_anchor", anchor: .center)
                                }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tick: Int {
        guard let idx = tracks.firstIndex(where: { $0.isPlaying && !$0.clips.isEmpty }) else { return 0 }
        return Int(playhead.trackProgress[idx] * 20)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: tick) {
                guard isPlaying && followEnabled else { return }
                // As at the play-start scroll above: follow still happens, it just stops
                // being animated. The timeline has to keep up with the audio either way,
                // so this is a jump and not a no-op.
                if reduceMotion {
                    proxy.scrollTo("playhead_anchor", anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo("playhead_anchor", anchor: .center)
                    }
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
                .help("Add an effect to the end of track \(audio.selectedTrack + 1)'s chain")
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
                .accessibilityLabel("Load preset")
                .accessibilityValue(audio.presetNames.isEmpty ? "None saved" : "")
                .accessibilityHint("Chooses a saved effect chain")
                .help(audio.presetNames.isEmpty
                      ? "No saved chains yet \u{2014} SAVE stores the current one"
                      : "Replace this chain with a saved one")

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
                    .help("Store this chain under a name you can load later")
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
                    .accessibilityLabel("Delete a saved preset")
                    .help("Forget a saved chain")
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
        .frame(width: Theme.effectsDrawerWidth)
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
                                .frame(width: 32, height: 32)
                                .foregroundColor(Theme.textTertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Move \(mod.displayName) earlier in the chain")
                        .help("Move \(mod.displayName) earlier \u{2014} nearer the input")
                    }
                    if index < audio.liveChain.count - 1 {
                        Button { audio.moveSlot(from: index, to: index + 1) } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 32, height: 32)
                                .foregroundColor(Theme.textTertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Move \(mod.displayName) later in the chain")
                        .help("Move \(mod.displayName) later \u{2014} nearer the fader")
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
                .accessibilityLabel("\(mod.displayName) enabled")
                .accessibilityValue(slot.enabled ? "On" : "Bypassed")
                .accessibilityHint("Toggles this effect")
                .help(slot.enabled
                      ? "Bypass \(mod.displayName) without removing it"
                      : "Bring \(mod.displayName) back into the chain")

                // Delete
                Button { audio.removeSlot(at: index) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 32, height: 32)
                        .foregroundColor(Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(mod.displayName) from the chain")
                .help("Remove \(mod.displayName) from the chain")
            }
            // 5 rather than 10/8: the row's tallest child just went from 24 to 32 pt, and
            // a 12-slot chain cannot afford to grow 8 pt per slot. The padding pays for it,
            // so the row's height is what it was and the panel below it does not move.
            .padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 5)

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
                .help("Undo the last edit (\u{2318}Z)")
                tpBtn(icon: "arrow.uturn.forward", label: "REDO",
                      fg: audio.canRedo ? Theme.textPrimary : Theme.textTertiary,
                      border: Theme.textPrimary.opacity(audio.canRedo ? 0.16 : 0.06)) {
                    audio.redo()
                }
                .disabled(!audio.canRedo)
                .help("Redo the last undone edit (\u{21E7}\u{2318}Z)")
                tpBtn(icon: audio.isPlaying ? "pause.fill" : "play.fill",
                      label: audio.isPlaying ? "PAUSE" : "PLAY",
                      fg: audio.isPlaying ? Theme.bg : Theme.accent,
                      bg: audio.isPlaying ? Theme.accent : Color.clear,
                      border: Theme.accent) {
                    if audio.isPlaying { audio.stopAll() } else { audio.playAll() }
                }
                .help(audio.isPlaying ? "Pause playback (Space)" : "Play every unmuted track (Space)")

                Button {
                    if audio.isRecording { audio.stopRecording(loopWhenFiled: true) }
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
                .accessibilityLabel(audio.isRecording ? "Stop recording" : "Record")
                .accessibilityValue(audio.countingIn ? "Counting in" : "")
                .help(audio.isRecording
                      ? "Finish this take and file it (R)"
                      : (audio.countingIn
                         ? "Press again to restart the count-in"
                         : "Record onto track \(audio.selectedTrack + 1) (R)"))

                tpBtn(icon: "stop.fill", label: "STOP",
                      fg: Theme.textPrimary, border: Theme.textPrimary.opacity(0.16)) { audio.stopAll() }
                .help("Stop playback and return to the start (\u{21A9})")

                Button { audio.clearAll() } label: {
                    Text("CLEAR").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
                        .frame(height: 44).padding(.horizontal, 18)
                        .foregroundColor(Theme.textSecondary)
                        .overlay(Rectangle().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete every take on all eight tracks")

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
                .help("Mix every audible track down to one WAV file")
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
            // The transport half of the Transport menu. Return to Start earns its place
            // here because it now seeks rather than stopping, so it is genuinely a
            // different command from Play/Stop.
            .contextMenu {
                Button(audio.isPlaying ? "Stop" : "Play") {
                    if audio.isPlaying { audio.stopAll() } else { audio.playAll() }
                }
                Button("Record") { audio.toggleTrackRecord(audio.selectedTrack) }
                    .disabled(audio.busyEdit != nil)

                Divider()

                Button("Return to Start") { audio.seek(toFraction: 0) }
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
                .accessibilityLabel("Metronome")
                .accessibilityValue(audio.metronomeEnabled ? "On" : "Off")
                .help(audio.metronomeEnabled ? "Turn the click off (,)" : "Turn the click on (,)")

                // Metronome volume
                Slider(value: Binding(
                    get: { audio.metronomeVolume },
                    set: { audio.setMetronomeVolume($0) }
                ), in: 0...1)
                .frame(width: 50)
                .tint(Theme.accent.opacity(0.5))
                .accessibilityLabel("Metronome volume")
                .accessibilityValue("\(Int(audio.metronomeVolume * 100)) percent")
                .help("How loud the click is, against the tracks")

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
                // The printed label is an abbreviation ("CIN", "2IN"); spoken, the bar
                // count is the fact that matters, so it goes in the value.
                .accessibilityLabel("Count-in")
                .accessibilityValue(audio.countInBars > 0
                                    ? (audio.countInBars == 1 ? "1 bar" : "\(audio.countInBars) bars")
                                    : "Off")
                .accessibilityHint("Cycles off, 1, 2 and 4 bars")
                .help(audio.countInBars == 0
                      ? "No count-in: recording starts the moment you press REC"
                      : "Counts in \(audio.countInBars == 1 ? "1 bar" : "\(audio.countInBars) bars") of click before recording starts")
                ArcKnob(label: "IN", value: Binding(
                    get: { audio.inputVolume * 100 }, set: { audio.applyInputVolume($0 / 100) }
                ), range: 0...100, color: Theme.textSecondary, size: 38)
                .help("Input gain: how hot the interface's signal arrives")
                ArcKnob(label: "OUT", value: Binding(
                    get: { audio.volume * 100 }, set: { audio.applyVolume($0 / 100) }
                ), range: 0...100, color: Theme.accent, size: 38)
                .help("Output level: how loud the mix leaves the app")
                Button { audio.toggleMasterLimiter() } label: {
                    Text("LIM")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .frame(width: 36, height: 44)
                        .foregroundColor(audio.masterLimiterEnabled ? Theme.bg : Theme.textTertiary)
                }
                .buttonStyle(RetroButtonStyle(tint: Theme.loopGreen, active: audio.masterLimiterEnabled, filled: audio.masterLimiterEnabled))
                .help(audio.masterLimiterEnabled ? "Master limiter active" : "Master limiter bypassed")
                .accessibilityLabel("Master limiter")
                .accessibilityValue(audio.masterLimiterEnabled ? "On" : "Bypassed")
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
                .accessibilityLabel("Input monitoring")
                .accessibilityValue(audio.isMonitoring ? "On" : "Off")
                .help(audio.isMonitoring
                      ? "Stop passing the interface's input straight to the output"
                      : "Hear the input, with the chain, without recording")
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
                // The glyph is decoration: VoiceOver would otherwise read the SF Symbol's
                // own description as well as the word beside it ("Play, PLAY"). The button
                // takes the printed label as its name instead.
                Image(systemName: icon).font(.system(size: 12))
                    .accessibilityHidden(true)
                Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
            }
            .frame(height: 44).padding(.horizontal, 18)
            .foregroundColor(fg).background(bg)
            .overlay(Rectangle().stroke(border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// ── Reel SVG ────────────────────────────────────────────────────────────────

struct ReelView: View {
    let spinning: Bool
    let fast: Bool

    /// A reel that turns forever is continuous motion, and it is the one thing on this
    /// screen that never stops while audio plays — so it is suppressed outright under
    /// Reduce Motion rather than merely slowed. The reel still reads as a reel; it just
    /// does not turn.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .rotationEffect(reduceMotion ? .zero : (spinning ? .degrees(360) : .zero))
        .animation(reduceMotion
                   ? nil
                   : (spinning ? .linear(duration: fast ? 1.4 : 2.6).repeatForever(autoreverses: false) : .default),
                   value: spinning)
        // Two drawn circles that mean "a tape is moving". Nothing to read out, and the
        // transport state it depicts is already spoken by the Rec button and the status
        // line, so it is decoration.
        .accessibilityHidden(true)
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
                .accessibilityLabel("Loop")
                .accessibilityValue(audio.loopEnabled ? "On" : "Off")
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

            // Scrolling waveform (hero), or — when there is nothing in the project and
            // nothing live to show — an empty state.
            //
            // §9 stage 8 asks for a `ContentUnavailableView` on an empty project, so that
            // an empty app does not read the same as a broken one. It goes here rather
            // than over the lane grid, which is where the finding pointed: the lanes are
            // the app's only file-drop target, and covering them would take away the one
            // way to import audio without an OP-XY. This pane is the region that is
            // genuinely blank — a hairline and nothing else — so it is where the message
            // costs nothing and says something.
            //
            // The condition is the meter's own: with the engine stopped `resetDisplay`
            // has already zeroed the waveform, so this replaces a flat line, never a
            // trace.
            if audio.tracks.allSatisfy({ $0.clips.isEmpty })
                && !audio.isMonitoring && !audio.isRecording {
                ContentUnavailableView {
                    Label("No takes yet", systemImage: "waveform")
                } description: {
                    Text("Press REC in the transport to record onto the selected track, or "
                         + "drag an audio file from Finder onto a track.")
                } actions: {
                    // The two ways out. Recording is the transport's own button, so it is
                    // named rather than duplicated; monitoring is one press and is why
                    // this pane is blank in the first place.
                    Button("Monitor the Input") { audio.startMonitoring() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            } else {
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
            }

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
                        // The only input picker that assigned the property itself. It is
                        // routed through `selectInput` now so the choice is remembered
                        // like the header's and the Settings window's; the explicit start
                        // below keeps this picker's own behaviour — it always (re)starts,
                        // because this is the view where you are setting up to listen.
                        set: { id in
                            audio.selectInput(id)
                            if !audio.isMonitoring { audio.startMonitoring() }
                        }
                    )) {
                        ForEach(audio.inputDevices) { dev in Text(dev.name).tag(Optional(dev.id)) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .accessibilityLabel("Input device")
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
                    .accessibilityLabel("Output device")
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
                        // The handles are invisible 30 pt boxes: the trim points have no
                        // focusable control at all, and the two edges have to be told
                        // apart. Each becomes an adjustable element, 1 % of the clip per
                        // step, in the same units the readouts above use.
                        .accessibilityElement()
                        .accessibilityLabel("Trim start")
                        .accessibilityValue(timeString(audio.trimStart))
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: audio.trimStart = min(audio.trimEnd - 0.01, audio.trimStart + 0.01)
                            case .decrement: audio.trimStart = max(0, audio.trimStart - 0.01)
                            @unknown default: break
                            }
                        }
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
                        .accessibilityElement()
                        .accessibilityLabel("Trim end")
                        .accessibilityValue(timeString(audio.trimEnd))
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: audio.trimEnd = min(1, audio.trimEnd + 0.01)
                            case .decrement: audio.trimEnd = max(audio.trimStart + 0.01, audio.trimEnd - 0.01)
                            @unknown default: break
                            }
                        }
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
