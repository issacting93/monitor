// monitor_ui.swift — OP-XY Monitor + Multitrack
// The monitor's design language with XYKit's 8-track engine underneath.

import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import XYKit

// ── Theme Extension ─────────────────────────────────────────────────────────

extension Theme {
    static var eqColor: Color { cycle }
    static var reverbColor: Color { trackColors[2] }
    static var delayColor: Color { trackColors[3] }
    static var waveGray: Color { hex(0x7A7E85) }
    static var waveformCount: Int { 140 }
}

// ── Models ──────────────────────────────────────────────────────────────────

struct Recording: Identifiable {
    let id: UUID
    let url: URL
    let duration: TimeInterval
    let trackIndex: Int
    var name: String { url.lastPathComponent }
    var durationString: String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}

private let reverbPresets: [(label: String, preset: AVAudioUnitReverbPreset)] = [
    ("Small Room",  .smallRoom),  ("Medium Room", .mediumRoom), ("Large Room",  .largeRoom),
    ("Medium Hall", .mediumHall), ("Large Hall",  .largeHall),  ("Plate",       .plate),
    ("Med Chamber", .mediumChamber), ("Lg Chamber",  .largeChamber), ("Cathedral", .cathedral),
]

private func reverbLabel(_ p: AVAudioUnitReverbPreset) -> String {
    reverbPresets.first { $0.preset.rawValue == p.rawValue }?.label ?? "Unknown"
}

// ── AudioManager ────────────────────────────────────────────────────────────

class AudioManager: ObservableObject {
    let store = ProjectStore()

    private var eqSlotID: UUID?
    private var reverbSlotID: UUID?
    private var delaySlotID: UUID?

    @Published var inputDevices:  [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID:  AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?
    @Published var isMonitoring = false
    @Published var isRecording  = false
    @Published var volume: Double = 0.9
    @Published var level:  Double = 0
    @Published var peak:   Double = 0
    @Published var levelL: Double = 0
    @Published var levelR: Double = 0
    @Published var peakL:  Double = 0
    @Published var peakR:  Double = 0
    @Published var peakDB: Double = -Double.infinity
    @Published var waveformSamples: [Double] = Array(repeating: 0, count: 140)
    @Published var recordingDuration: TimeInterval = 0
    @Published var status = "Ready"

    @Published var reverbEnabled = false
    @Published var reverbPreset: AVAudioUnitReverbPreset = .mediumHall
    @Published var reverbMix: Double = 40
    @Published var delayEnabled   = false
    @Published var delayTime:     Double = 0.25
    @Published var delayFeedback: Double = 30
    @Published var delayMix:      Double = 25
    @Published var eqEnabled = false
    @Published var eqLow:  Double = 0
    @Published var eqMid:  Double = 0
    @Published var eqHigh: Double = 0

    @Published var recordings: [Recording] = []

    /// Which track index (0-7) is selected in the track strip.
    @Published var selectedTrack: Int = 0

    private var displayTimer: Timer?
    private var recordingStart: Date?
    private var recordingTimer: Timer?
    private var peakHoldCount = 0

    init() {
        loadDevices()
        setupEffects()
    }

    deinit {
        displayTimer?.invalidate()
        recordingTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupEffects() {
        let track0 = store.project.tracks[0]
        if track0.fx.isEmpty {
            store.select(track: track0.id)
            store.addEffect("com.apple.eq3")
            eqSlotID = store.selectedSlotID
            store.addEffect("com.apple.reverb")
            reverbSlotID = store.selectedSlotID
            store.addEffect("com.apple.delay")
            delaySlotID = store.selectedSlotID
        } else {
            eqSlotID     = track0.fx.first { $0.moduleID == "com.apple.eq3" }?.id
            reverbSlotID = track0.fx.first { $0.moduleID == "com.apple.reverb" }?.id
            delaySlotID  = track0.fx.first { $0.moduleID == "com.apple.delay" }?.id
        }
        applyEQ()
        applyReverb()
        applyDelay()
    }

    // MARK: - Devices

    func loadDevices() {
        let all = CoreAudioDevices.all()
        inputDevices  = all.filter { CoreAudioDevices.channelCount($0.id, input: true) > 0 }
        outputDevices = all.filter { CoreAudioDevices.channelCount($0.id, input: false) > 0 }

        if selectedInputID == nil ||
           !inputDevices.contains(where: { $0.id == selectedInputID }) {
            selectedInputID =
                inputDevices.first(where: { $0.name.localizedCaseInsensitiveContains("XY") })?.id
                ?? inputDevices.first(where: { $0.name.localizedCaseInsensitiveContains("OP") })?.id
                ?? inputDevices.first?.id
        }
        if selectedOutputID == nil ||
           !outputDevices.contains(where: { $0.id == selectedOutputID }) {
            selectedOutputID = CoreAudioDevices.defaultDevice(input: false)
                ?? outputDevices.first(where: { !$0.name.localizedCaseInsensitiveContains("XY") })?.id
        }
    }

    // MARK: - Monitor

    func startMonitoring() {
        if inputDevices.isEmpty || selectedInputID == nil { loadDevices() }
        guard let inID = selectedInputID,
              let inDev = inputDevices.first(where: { $0.id == inID })
        else { status = "No input device \u{2014} connect OP-XY"; return }

        store.startAudio()
        store.engine.selectInput(inID)

        let trackID = store.project.tracks[selectedTrack].id
        if store.armedTrackID != trackID { store.toggleArm(trackID) }
        store.engine.monitorEnabled = true
        store.perform("vol") { $0.masterVolume = self.volume }

        isMonitoring = true
        let outName = selectedOutputID.map { CoreAudioDevices.name($0) } ?? "system output"
        status = "\(inDev.name) \u{2192} \(outName)"
        startDisplayTimer()
    }

    func stopMonitoring() {
        if isRecording { stopRecording() }
        store.engine.monitorEnabled = false
        if let armed = store.armedTrackID { store.toggleArm(armed) }
        store.engine.shutdown()
        isMonitoring = false
        displayTimer?.invalidate(); displayTimer = nil
        level = 0; peak = 0; peakHoldCount = 0
        levelL = 0; levelR = 0; peakL = 0; peakR = 0
        peakDB = -Double.infinity
        waveformSamples = Array(repeating: 0, count: Theme.waveformCount)
        status = "Stopped"
    }

    func selectTrack(_ index: Int) {
        selectedTrack = index
        let trackID = store.project.tracks[index].id
        store.select(track: trackID)
        if isMonitoring {
            if let armed = store.armedTrackID { store.toggleArm(armed) }
            store.toggleArm(trackID)
        }
    }

    func switchOutput(to id: AudioDeviceID) {
        selectedOutputID = id
        guard isMonitoring else { return }
        let wasRecording = isRecording
        if wasRecording { stopRecording() }
        store.engine.reload()
        let trackID = store.project.tracks[selectedTrack].id
        if store.armedTrackID != trackID { store.toggleArm(trackID) }
        store.engine.monitorEnabled = true
        if wasRecording { startRecording() }
        let inName  = inputDevices.first { $0.id == selectedInputID }?.name ?? "input"
        let outName = outputDevices.first { $0.id == id }?.name ?? "output"
        status = "\(inName) \u{2192} \(outName)"
    }

    func applyVolume(_ v: Double) {
        volume = v
        store.perform("vol") { $0.masterVolume = v }
    }

    // MARK: - Transport

    func togglePlay() { store.togglePlay() }
    func returnToStart() { store.returnToStart() }

    // MARK: - Display timer

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            let masterLevel = self.store.engine.meters.levels[MeterHub.master]
            let displayVal  = MeterHub.display(masterLevel)
            let smoothed = self.level * 0.72 + displayVal * 0.28
            self.level = smoothed

            if displayVal >= self.peak { self.peak = displayVal; self.peakHoldCount = 0 }
            else { self.peakHoldCount += 1; if self.peakHoldCount > 43 { self.peak *= 0.993 } }

            self.levelL = smoothed
            self.levelR = smoothed
            self.peakL  = self.peak
            self.peakR  = self.peak

            if masterLevel > 0 { self.peakDB = Double(20 * log10f(masterLevel)) }
            else { self.peakDB = -Double.infinity }

            var samples = self.waveformSamples
            samples.removeFirst()
            samples.append(smoothed)
            self.waveformSamples = samples

            if self.store.engine.isRecording != self.isRecording {
                self.isRecording = self.store.engine.isRecording
            }
        }
    }

    // MARK: - Effects

    func applyReverb() {
        guard let id = reverbSlotID else { return }
        store.updateSlot(id, key: "reverb") { slot in
            slot.values["mix"] = Float(self.reverbMix)
            slot.bypass = !self.reverbEnabled
        }
    }
    func changeReverbPreset(_ p: AVAudioUnitReverbPreset) {
        reverbPreset = p
        guard let id = reverbSlotID else { return }
        let idx = reverbPresets.firstIndex(where: { $0.preset.rawValue == p.rawValue }) ?? 3
        store.updateSlot(id, key: "reverb") { slot in
            slot.values["preset"] = Float(idx)
            slot.values["mix"] = Float(self.reverbMix)
            slot.bypass = !self.reverbEnabled
        }
    }
    func applyDelay() {
        guard let id = delaySlotID else { return }
        store.updateSlot(id, key: "delay") { slot in
            slot.values["time"] = Float(self.delayTime * 1000)
            slot.values["feedback"] = Float(self.delayFeedback)
            slot.values["mix"] = Float(self.delayMix)
            slot.bypass = !self.delayEnabled
        }
    }
    func applyEQ() {
        guard let id = eqSlotID else { return }
        store.updateSlot(id, key: "eq") { slot in
            slot.values["low"]  = Float(self.eqLow)
            slot.values["mid"]  = Float(self.eqMid)
            slot.values["high"] = Float(self.eqHigh)
            slot.bypass = !self.eqEnabled
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard isMonitoring else { return }
        store.toggleRecord()
        isRecording = store.engine.isRecording
        if isRecording {
            recordingStart = Date()
            recordingDuration = 0
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
                [weak self] _ in
                guard let self, let s = self.recordingStart else { return }
                DispatchQueue.main.async { self.recordingDuration = Date().timeIntervalSince(s) }
            }
            status = "Recording\u{2026}"
        }
    }
    func stopRecording() {
        recordingTimer?.invalidate(); recordingTimer = nil
        let assetCount = store.project.assets.count
        store.toggleRecord()
        isRecording = false
        if store.project.assets.count > assetCount, let asset = store.project.assets.last {
            let url = store.package.audioURL(asset)
            recordings.append(Recording(id: asset.id, url: url, duration: asset.duration,
                                        trackIndex: selectedTrack))
            status = "Saved \(asset.name)"
        }
    }
    func removeRecording(_ rec: Recording) {
        recordings.removeAll { $0.id == rec.id }
    }
}

// ── WaveformView ────────────────────────────────────────────────────────────

struct WaveformView: View {
    let samples: [Double]
    let isActive: Bool
    let isRecording: Bool

    var body: some View {
        Canvas { context, size in
            let midY  = size.height * 0.5
            let count = CGFloat(samples.count)
            let barW  = size.width / count
            let gap:  CGFloat = 1

            context.stroke(
                Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: size.width, y: midY)) },
                with: .color(Theme.line.opacity(0.6)), lineWidth: 0.5)

            for (i, sample) in samples.enumerated() {
                let h = midY * CGFloat(sample)
                guard h > 0.5 else { continue }
                let x = CGFloat(i) * barW
                let w = max(barW - gap, 1)
                let recentThreshold = Int(Double(samples.count) * 0.8)
                let color: Color
                let opacity: Double
                if i >= recentThreshold {
                    color = Theme.accent; opacity = 0.5 + sample * 0.5
                } else {
                    color = Theme.waveGray
                    let fadePos = Double(i) / Double(recentThreshold)
                    opacity = (0.15 + fadePos * 0.45) * (0.3 + sample * 0.7)
                }
                context.fill(Path(CGRect(x: x, y: midY - h, width: w, height: h)), with: .color(color.opacity(opacity)))
                context.fill(Path(CGRect(x: x, y: midY, width: w, height: h)), with: .color(color.opacity(opacity)))
            }
            if isActive {
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: size.width - 1, y: 0)); p.addLine(to: CGPoint(x: size.width - 1, y: size.height)) },
                    with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
            if isRecording {
                let markerX = size.width - 60
                context.fill(Path(CGRect(x: markerX, y: 4, width: 52, height: 16)), with: .color(Theme.danger.opacity(0.85)))
                context.draw(
                    Text("REC IN").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.white),
                    at: CGPoint(x: markerX + 26, y: 12))
            }
        }
        .background(Theme.bg)

        HStack {
            Text("\u{2212}40s"); Spacer(); Text("\u{2212}30s"); Spacer()
            Text("\u{2212}20s"); Spacer(); Text("\u{2212}10s"); Spacer(); Text("now")
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 4)
    }
}

// ── HorizontalMeter ─────────────────────────────────────────────────────────

struct HorizontalMeter: View {
    let label: String
    let level: Double
    let peak: Double
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 12, alignment: .trailing)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isActive ? Theme.accent : Theme.waveGray.opacity(0.4))
                        .frame(width: g.size.width * max(level, 0))
                        .animation(.linear(duration: 0.03), value: level)
                    if peak > 0.01 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(peak > 0.85 ? Theme.danger : .white.opacity(0.9))
                            .frame(width: 2, height: g.size.height)
                            .offset(x: g.size.width * max(peak, 0) - 1)
                            .animation(.linear(duration: 0.05), value: peak)
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

// ── KnobView ────────────────────────────────────────────────────────────────

struct KnobView: View {
    let value: Double
    let bipolar: Bool
    let color: Color
    let label: String
    let displayValue: String
    private let startAngle: Double = 135
    private let sweepAngle: Double = 270
    private let size: CGFloat = 64

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                arcPath(from: 0, to: 1).stroke(Theme.line, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                if bipolar {
                    arcPath(from: 0.5, to: value).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                } else {
                    arcPath(from: 0, to: value).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                Circle().fill(Theme.surface).frame(width: size * 0.4, height: size * 0.4)
                indicatorLine().stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .frame(width: size, height: size)
            Text(displayValue).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.system(size: 9, design: .default)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func angleForValue(_ v: Double) -> Double { (startAngle + sweepAngle * min(max(v, 0), 1)) * .pi / 180 }
    private func arcPath(from: Double, to: Double) -> Path {
        let r = size / 2 - 4, c = CGPoint(x: size / 2, y: size / 2)
        return Path { p in p.addArc(center: c, radius: r,
            startAngle: Angle(degrees: startAngle + sweepAngle * min(from, to)),
            endAngle: Angle(degrees: startAngle + sweepAngle * max(from, to)), clockwise: false) }
    }
    private func indicatorLine() -> Path {
        let a = angleForValue(value), c = CGPoint(x: size / 2, y: size / 2)
        return Path { p in
            p.move(to: CGPoint(x: c.x + size * 0.2 * cos(a), y: c.y + size * 0.2 * sin(a)))
            p.addLine(to: CGPoint(x: c.x + (size / 2 - 4) * cos(a), y: c.y + (size / 2 - 4) * sin(a)))
        }
    }
}

// ── TrackStrip ──────────────────────────────────────────────────────────────
// Compact 8-track strip in the monitor's design language.

struct TrackStrip: View {
    @EnvironmentObject var audio: AudioManager
    let trackCount = Project.trackCount

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<trackCount, id: \.self) { index in
                let track = audio.store.project.tracks[index]
                let isSelected = audio.selectedTrack == index
                let isArmed = audio.store.armedTrackID == track.id
                let hasClips = !track.clips.isEmpty
                let trackLevel = MeterHub.display(audio.store.engine.meters.levels[index])

                Button { audio.selectTrack(index) } label: {
                    VStack(spacing: 3) {
                        // Track number
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)

                        // Mini meter bar
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isArmed && audio.isMonitoring
                                  ? Theme.accent
                                  : Theme.track(index).opacity(trackLevel > 0.01 ? 0.8 : 0.2))
                            .frame(width: 4, height: 16)
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Theme.track(index))
                                    .frame(width: 4, height: max(0, 16 * trackLevel))
                            }

                        // Clip count dot
                        if hasClips {
                            Circle().fill(Theme.track(index)).frame(width: 4, height: 4)
                        } else {
                            Circle().stroke(Theme.line, lineWidth: 0.5).frame(width: 4, height: 4)
                        }
                    }
                    .frame(width: 28, height: 42)
                    .background(isSelected ? Theme.surface : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        isArmed ? Theme.danger.opacity(0.6) : (isSelected ? Theme.line : Color.clear)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// ── ContentView ─────────────────────────────────────────────────────────────

struct ContentView: View {
    @EnvironmentObject var audio: AudioManager
    @State private var recBlink = false
    @State private var selectedEffect: String = "reverb"

    private var inputName: String {
        audio.inputDevices.first(where: { $0.id == audio.selectedInputID })?.name ?? "No Input"
    }
    private var outputName: String {
        audio.outputDevices.first(where: { $0.id == audio.selectedOutputID })?.name ?? "No Output"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header Row ──────────────────────────────────────
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OP-XY")
                        .font(.system(size: 18, weight: .bold, design: .default))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Multitrack")
                        .font(.system(size: 13, design: .default))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    // Transport
                    HStack(spacing: 4) {
                        transportButton(symbol: "backward.end.fill", active: false) { audio.returnToStart() }
                        transportButton(symbol: audio.store.engine.isPlaying ? "stop.fill" : "play.fill",
                                        active: audio.store.engine.isPlaying) { audio.togglePlay() }
                    }

                    // Position readout
                    Text(Timebase.clock(audio.store.engine.clock.position))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.surface)
                        .clipShape(Capsule())

                    Button { audio.loadDevices() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Theme.surface)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Rescan audio devices")
                }
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)

            // ── Source Row ──────────────────────────────────────
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(audio.isRecording ? Theme.danger :
                              (audio.isMonitoring ? Theme.accent : Theme.textTertiary))
                        .frame(width: 6, height: 6)
                    HStack(spacing: 2) {
                        Text("Live").foregroundStyle(audio.isMonitoring && !audio.isRecording ? Theme.textPrimary : Theme.textTertiary)
                        Text("/").foregroundStyle(Theme.textTertiary)
                        Text("Rec").foregroundStyle(audio.isRecording ? Theme.danger : Theme.textTertiary)
                    }
                    .font(.system(size: 11, weight: .medium, design: .default))
                }
                Text("  \u{2192}  ").foregroundStyle(Theme.textTertiary).font(.system(size: 11))
                Menu {
                    ForEach(audio.inputDevices) { d in Button(d.name) { audio.selectedInputID = d.id } }
                } label: {
                    Text(inputName).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(audio.isMonitoring).opacity(audio.isMonitoring ? 0.7 : 1)

                Text("  \u{203A}  ").foregroundStyle(Theme.textTertiary).font(.system(size: 11))
                Menu {
                    ForEach(audio.outputDevices) { d in
                        Button(d.name) { if audio.isMonitoring { audio.switchOutput(to: d.id) } else { audio.selectedOutputID = d.id } }
                    }
                } label: {
                    Text(outputName).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize()

                Spacer()

                HStack(spacing: 4) {
                    Text("In").foregroundStyle(Theme.textTertiary)
                    effectDot(enabled: audio.eqEnabled, color: Theme.eqColor)
                    Text("EQ").foregroundStyle(Theme.textTertiary)
                    effectDot(enabled: audio.reverbEnabled, color: Theme.reverbColor)
                    Text("Rev").foregroundStyle(Theme.textTertiary)
                    effectDot(enabled: audio.delayEnabled, color: Theme.delayColor)
                    Text("Dly").foregroundStyle(Theme.textTertiary)
                    Text("\u{2192}").foregroundStyle(Theme.textTertiary)
                    Text("Out").foregroundStyle(Theme.textTertiary)
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 24).padding(.vertical, 6)
            .background(Theme.surface.opacity(0.3))

            // ── Waveform ────────────────────────────────────────
            VStack(spacing: 2) {
                WaveformView(samples: audio.waveformSamples, isActive: audio.isMonitoring, isRecording: audio.isRecording)
                    .frame(height: 120)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 4)

            // ── Meters ──────────────────────────────────────────
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    HorizontalMeter(label: "L", level: audio.levelL, peak: audio.peakL, isActive: audio.isMonitoring)
                    HorizontalMeter(label: "R", level: audio.levelR, peak: audio.peakR, isActive: audio.isMonitoring)
                    HStack(spacing: 0) {
                        Text(" ").frame(width: 20)
                        HStack {
                            Text("-60"); Spacer(); Text("-36"); Spacer(); Text("-24"); Spacer()
                            Text("-12"); Spacer(); Text("-6"); Spacer(); Text("0 dB")
                        }
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    }
                }
                VStack(spacing: 2) {
                    Text("PEAK").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    Text(audio.peakDB > -100 ? String(format: "%.1f", audio.peakDB) : "-\u{221E}")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(audio.peakDB > -6 ? Theme.danger : Theme.textPrimary)
                    Text("dB").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                }
                .frame(width: 70)
            }
            .padding(.horizontal, 24).padding(.vertical, 6)

            // ── Track Strip ─────────────────────────────────────
            thinDivider()
            HStack(spacing: 12) {
                Text("TRACKS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(1.5)
                TrackStrip()
                Spacer()
                Text("Trk \(audio.selectedTrack + 1)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.track(audio.selectedTrack))
                Circle()
                    .fill(Theme.track(audio.selectedTrack))
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 24).padding(.vertical, 8)

            // ── Controls Section ────────────────────────────────
            thinDivider()

            HStack(alignment: .top, spacing: 0) {
                // Left column: Routing
                VStack(alignment: .leading, spacing: 10) {
                    routingRow(label: "Input") {
                        Menu {
                            ForEach(audio.inputDevices) { d in Button(d.name) { audio.selectedInputID = d.id } }
                        } label: {
                            Text(inputName).font(.system(size: 11)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .menuStyle(.borderlessButton).fixedSize().disabled(audio.isMonitoring)
                    }
                    routingRow(label: "Output") {
                        Menu {
                            ForEach(audio.outputDevices) { d in
                                Button(d.name) { if audio.isMonitoring { audio.switchOutput(to: d.id) } else { audio.selectedOutputID = d.id } }
                            }
                        } label: {
                            Text(outputName).font(.system(size: 11)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    routingRow(label: "Volume") {
                        HStack(spacing: 4) {
                            Button { audio.applyVolume(max(audio.volume - 0.05, 0)) } label: {
                                Text("\u{2212}").font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22)
                                    .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2).fill(Theme.surface)
                                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: g.size.width * audio.volume)
                                }
                            }.frame(width: 60, height: 6)
                            Button { audio.applyVolume(min(audio.volume + 0.05, 1)) } label: {
                                Text("+").font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22)
                                    .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain)
                            Text("\(Int(audio.volume * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)

                Rectangle().fill(Theme.line).frame(width: 0.5)

                // Middle column: Effects list
                VStack(alignment: .leading, spacing: 8) {
                    Text("EFFECTS").font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary).tracking(1.5)
                    effectButton(name: "EQ", color: Theme.eqColor, enabled: audio.eqEnabled, key: "eq")
                    effectButton(name: "Reverb", color: Theme.reverbColor, enabled: audio.reverbEnabled, key: "reverb")
                    effectButton(name: "Delay", color: Theme.delayColor, enabled: audio.delayEnabled, key: "delay")
                }
                .frame(width: 140).padding(16)

                Rectangle().fill(Theme.line).frame(width: 0.5)

                // Right column: Effect params
                VStack(alignment: .leading, spacing: 12) {
                    if selectedEffect == "eq" { eqParamsView() }
                    else if selectedEffect == "reverb" { reverbParamsView() }
                    else { delayParamsView() }
                }
                .frame(maxWidth: .infinity).padding(16)
            }
            .fixedSize(horizontal: false, vertical: true)

            thinDivider()

            // ── Transport + Recordings ──────────────────────────
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(formatTimerDuration(audio.recordingDuration))
                        .font(.system(size: 44, weight: .light, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 5) {
                        if audio.isRecording {
                            Circle().fill(Theme.danger).frame(width: 6, height: 6).opacity(recBlink ? 1 : 0.3)
                            Text("REC \u{2192} Track \(audio.selectedTrack + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.danger)
                        } else if audio.isMonitoring {
                            Text("READY").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                        } else {
                            Text("IDLE").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer().frame(height: 4)
                    HStack(spacing: 8) {
                        Button { audio.isMonitoring ? audio.stopMonitoring() : audio.startMonitoring() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: audio.isMonitoring ? "stop.fill" : "waveform").font(.system(size: 11))
                                Text(audio.isMonitoring ? "Stop" : "Monitor").font(.system(size: 12, weight: .semibold))
                            }
                            .frame(width: 120).padding(.vertical, 8)
                            .background(audio.isMonitoring ? Theme.surface : Theme.accent)
                            .foregroundStyle(audio.isMonitoring ? Theme.textPrimary : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)

                        Button { audio.isRecording ? audio.stopRecording() : audio.startRecording() } label: {
                            HStack(spacing: 6) {
                                Circle().fill(audio.isRecording ? Theme.danger : Theme.danger.opacity(0.6)).frame(width: 8, height: 8)
                                Text(audio.isRecording ? "Stop Rec" : "Record").font(.system(size: 12, weight: .semibold))
                            }
                            .frame(width: 120).padding(.vertical, 8)
                            .background(audio.isRecording ? Theme.danger.opacity(0.2) : .clear)
                            .foregroundStyle(audio.isMonitoring ? (audio.isRecording ? Theme.danger : Theme.textPrimary) : Theme.textTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(audio.isRecording ? Theme.danger : Theme.line))
                        }
                        .buttonStyle(.plain).disabled(!audio.isMonitoring).opacity(audio.isMonitoring ? 1 : 0.5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)

                Rectangle().fill(Theme.line).frame(width: 0.5)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("RECORDINGS / \(String(format: "%02d", audio.recordings.count))")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary).tracking(1.5)
                        Spacer()
                        Text("WAV \u{00B7} 48 kHz").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    }
                    if audio.recordings.isEmpty {
                        Text("No recordings yet").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(.top, 8)
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(audio.recordings) { rec in
                                    HStack(spacing: 8) {
                                        Circle().fill(Theme.track(rec.trackIndex)).frame(width: 5, height: 5)
                                        Text("T\(rec.trackIndex + 1)")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Theme.track(rec.trackIndex))
                                        Text(rec.name).font(.system(size: 11)).foregroundStyle(Theme.textPrimary)
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(rec.durationString).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                        Button {
                                            NSWorkspace.shared.selectFile(rec.url.path, inFileViewerRootedAtPath: "")
                                        } label: {
                                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                                        }.buttonStyle(.plain)
                                        Button { audio.removeRecording(rec) } label: {
                                            Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.textTertiary)
                                        }.buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(Theme.surface.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line.opacity(0.5)))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .fixedSize(horizontal: false, vertical: true)

            // ── Status Footer ───────────────────────────────────
            thinDivider()
            HStack(spacing: 6) {
                Circle()
                    .fill(audio.isRecording ? Theme.danger :
                          (audio.isMonitoring ? Theme.accent : Theme.textTertiary.opacity(0.4)))
                    .frame(width: 6, height: 6)
                Text(audio.status).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("In \u{2192} EQ \u{2192} Reverb \u{2192} Delay \u{2192} Out")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
        }
        .background(Theme.bg)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { recBlink = true }
        }
    }

    // MARK: - Helpers

    private func thinDivider() -> some View { Rectangle().fill(Theme.line).frame(height: 0.5) }

    private func effectDot(enabled: Bool, color: Color) -> some View {
        ZStack {
            if enabled { Circle().fill(color).frame(width: 6, height: 6) }
            else { Circle().stroke(color.opacity(0.5), lineWidth: 1).frame(width: 6, height: 6) }
        }
    }

    private func routingRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textTertiary).frame(width: 50, alignment: .trailing)
            content()
        }
    }

    private func effectButton(name: String, color: Color, enabled: Bool, key: String) -> some View {
        Button { selectedEffect = key } label: {
            HStack(spacing: 8) {
                ZStack {
                    if enabled { Circle().fill(color).frame(width: 8, height: 8) }
                    else { Circle().stroke(color.opacity(0.5), lineWidth: 1).frame(width: 8, height: 8) }
                }
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(selectedEffect == key ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selectedEffect == key ? Theme.surface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }

    private func transportButton(symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }

    // MARK: - Effect params

    @ViewBuilder
    private func eqParamsView() -> some View {
        HStack(spacing: 20) {
            knobWithDrag(label: "Low", value: audio.eqLow, range: -12...12, bipolar: true, color: Theme.eqColor,
                         display: { ($0 >= 0 ? "+" : "") + "\(Int($0)) dB" }, setter: { audio.eqLow = $0; audio.applyEQ() })
            knobWithDrag(label: "Mid", value: audio.eqMid, range: -12...12, bipolar: true, color: Theme.eqColor,
                         display: { ($0 >= 0 ? "+" : "") + "\(Int($0)) dB" }, setter: { audio.eqMid = $0; audio.applyEQ() })
            knobWithDrag(label: "High", value: audio.eqHigh, range: -12...12, bipolar: true, color: Theme.eqColor,
                         display: { ($0 >= 0 ? "+" : "") + "\(Int($0)) dB" }, setter: { audio.eqHigh = $0; audio.applyEQ() })
        }
        .opacity(audio.eqEnabled ? 1 : 0.35).frame(maxWidth: .infinity)
        effectToggle(name: "EQ", subtitle: "200 Hz \u{00B7} 1 kHz \u{00B7} 8 kHz", color: Theme.eqColor,
                     enabled: Binding(get: { audio.eqEnabled }, set: { audio.eqEnabled = $0; audio.applyEQ() }))
    }

    @ViewBuilder
    private func reverbParamsView() -> some View {
        HStack(spacing: 16) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        let idx = reverbPresets.firstIndex(where: { $0.preset.rawValue == audio.reverbPreset.rawValue }) ?? 0
                        audio.changeReverbPreset(reverbPresets[(idx - 1 + reverbPresets.count) % reverbPresets.count].preset)
                    } label: { Text("\u{2039}").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textSecondary) }.buttonStyle(.plain)
                    Text(reverbLabel(audio.reverbPreset)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textPrimary).frame(width: 90)
                    Button {
                        let idx = reverbPresets.firstIndex(where: { $0.preset.rawValue == audio.reverbPreset.rawValue }) ?? 0
                        audio.changeReverbPreset(reverbPresets[(idx + 1) % reverbPresets.count].preset)
                    } label: { Text("\u{203A}").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textSecondary) }.buttonStyle(.plain)
                }
                Text("Preset").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            }
            knobWithDrag(label: "Wet", value: audio.reverbMix, range: 0...100, bipolar: false, color: Theme.reverbColor,
                         display: { "\(Int($0))%" }, setter: { audio.reverbMix = $0; audio.applyReverb() })
        }
        .opacity(audio.reverbEnabled ? 1 : 0.35).frame(maxWidth: .infinity)
        effectToggle(name: "Reverb", subtitle: reverbLabel(audio.reverbPreset), color: Theme.reverbColor,
                     enabled: Binding(get: { audio.reverbEnabled }, set: { audio.reverbEnabled = $0; audio.applyReverb() }))
    }

    @ViewBuilder
    private func delayParamsView() -> some View {
        HStack(spacing: 20) {
            knobWithDrag(label: "Time", value: audio.delayTime, range: 0...1, bipolar: false, color: Theme.delayColor,
                         display: { "\(Int($0 * 1000)) ms" }, setter: { audio.delayTime = $0; audio.applyDelay() })
            knobWithDrag(label: "Feedback", value: audio.delayFeedback, range: 0...80, bipolar: false, color: Theme.delayColor,
                         display: { "\(Int($0))%" }, setter: { audio.delayFeedback = $0; audio.applyDelay() })
            knobWithDrag(label: "Mix", value: audio.delayMix, range: 0...100, bipolar: false, color: Theme.delayColor,
                         display: { "\(Int($0))%" }, setter: { audio.delayMix = $0; audio.applyDelay() })
        }
        .opacity(audio.delayEnabled ? 1 : 0.35).frame(maxWidth: .infinity)
        effectToggle(name: "Delay", subtitle: "\(Int(audio.delayTime * 1000)) ms \u{00B7} \(Int(audio.delayFeedback))% fb",
                     color: Theme.delayColor,
                     enabled: Binding(get: { audio.delayEnabled }, set: { audio.delayEnabled = $0; audio.applyDelay() }))
    }

    private func effectToggle(name: String, subtitle: String, color: Color, enabled: Binding<Bool>) -> some View {
        Button { enabled.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    if enabled.wrappedValue { Circle().fill(color).frame(width: 8, height: 8) }
                    else { Circle().stroke(color.opacity(0.5), lineWidth: 1).frame(width: 8, height: 8) }
                }
                Text(enabled.wrappedValue ? "On" : "Off").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(enabled.wrappedValue ? Theme.textPrimary : Theme.textTertiary)
                Text("\u{00B7}").foregroundStyle(Theme.textTertiary)
                Text(name).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text(subtitle).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(enabled.wrappedValue ? color.opacity(0.1) : Theme.surface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(enabled.wrappedValue ? color.opacity(0.3) : Theme.line))
        }.buttonStyle(.plain)
    }

    private func knobWithDrag(label: String, value: Double, range: ClosedRange<Double>,
                              bipolar: Bool, color: Color, display: (Double) -> String,
                              setter: @escaping (Double) -> Void) -> some View {
        let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return KnobView(value: normalized, bipolar: bipolar, color: color, label: label, displayValue: display(value))
            .gesture(DragGesture(minimumDistance: 1).onChanged { gesture in
                let delta = -gesture.translation.height / 150
                let newNorm = min(max(normalized + delta, 0), 1)
                setter(range.lowerBound + newNorm * (range.upperBound - range.lowerBound))
            })
    }

    private func formatTimerDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60, tenths = Int((t - Double(Int(t))) * 10)
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }
}

// ── Keyboard & scroll ───────────────────────────────────────────────────────

func handleKey(_ event: NSEvent, audio: AudioManager) -> Bool {
    if NSApp.keyWindow?.firstResponder is NSTextView { return false }
    let flags = event.modifierFlags
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

    if flags.contains(.command) {
        switch key {
        case "z": if flags.contains(.shift) { audio.store.redo() } else { audio.store.undo() }
        case "s": if flags.contains(.shift) { audio.store.saveAs() } else { audio.store.save() }
        case "d": audio.store.duplicateSelected()
        case "t": audio.store.splitAtPlayhead()
        case "o": audio.store.openProject()
        case "n": audio.store.newProject()
        case "e": audio.store.export(.wav, cycleOnly: false)
        case "q": NSApp.terminate(nil)
        case "w": NSApp.keyWindow?.performClose(nil)
        default: return false
        }
        return true
    }

    switch event.keyCode {
    case 49: audio.togglePlay()                                    // space
    case 36: audio.returnToStart()                                 // return
    case 51, 117: audio.store.deleteSelected()                     // delete
    default:
        switch key {
        case "r": audio.isRecording ? audio.stopRecording() : audio.startRecording()
        case "m": audio.isMonitoring ? audio.stopMonitoring() : audio.startMonitoring()
        case "1"..."8":
            if let n = Int(key) { audio.selectTrack(n - 1) }
        default: return false
        }
    }
    return true
}

// ── Entry Point ─────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Mic permission
do {
    var granted = false
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: granted = true
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; sem.signal() }
        while sem.wait(timeout: .now()) != .success {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
    default: break
    }
    if !granted {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "OP-XY Monitor needs microphone access to receive audio from your USB input.\n\nGo to System Settings > Privacy & Security > Microphone and enable it for this app."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
        exit(1)
    }
}

let audioManager = AudioManager()
let rootView = ContentView().environmentObject(audioManager)
let controller = NSHostingController(rootView: rootView)
let window = NSWindow(contentViewController: controller)
window.title = "OP-XY Monitor"
window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
window.setContentSize(NSSize(width: 1200, height: 780))
window.minSize = NSSize(width: 800, height: 500)
window.center()
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.backgroundColor = NSColor(red: 0x26/255.0, green: 0x28/255.0, blue: 0x2B/255.0, alpha: 1)
window.appearance = NSAppearance(named: .darkAqua)
window.isMovableByWindowBackground = true
window.setFrameAutosaveName("OPXYMonitorMain")
window.makeKeyAndOrderFront(nil)

_ = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
    guard event.window === window else { return event }
    return handleKey(event, audio: audioManager) ? nil : event
}

signal(SIGINT, SIG_IGN)
let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSource.setEventHandler { NSApp.terminate(nil) }
sigSource.resume()

class AppDelegate: NSObject, NSApplicationDelegate {
    var audioManager: AudioManager?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { audioManager?.store.shutdown() }
}
let appDelegate = AppDelegate()
appDelegate.audioManager = audioManager
app.delegate = appDelegate

app.activate(ignoringOtherApps: true)
app.run()
