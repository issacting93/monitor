// monitor_ui.swift — OP-XY Monitor: USB audio monitoring, effects, multitrack & recording
//
// Build:  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
//         swiftc monitor_ui.swift -o monitor_ui
// Run:    ./monitor_ui

import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import Darwin

// ── Theme ────────────────────────────────────────────────────────────────────

enum Theme {
    static let bg            = Color(red: 0x14/255.0, green: 0x15/255.0, blue: 0x17/255.0)
    static let surface       = Color(red: 0x1A/255.0, green: 0x1B/255.0, blue: 0x1E/255.0)
    static let surfaceRaised = Color(red: 0x24/255.0, green: 0x26/255.0, blue: 0x2A/255.0)
    static let surfaceInset  = Color(red: 0x0F/255.0, green: 0x10/255.0, blue: 0x12/255.0)
    static let line          = Color(red: 0x2A/255.0, green: 0x2C/255.0, blue: 0x30/255.0)
    static let bezel         = Color(red: 0x38/255.0, green: 0x3B/255.0, blue: 0x42/255.0)
    static let accent        = Color(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x1F/255.0)
    static let accentDim     = Color(red: 0xCC/255.0, green: 0x55/255.0, blue: 0x18/255.0)
    static let textPrimary   = Color(red: 0xEC/255.0, green: 0xEA/255.0, blue: 0xE6/255.0)
    static let textSecondary = Color(red: 0x8F/255.0, green: 0x93/255.0, blue: 0x9A/255.0)
    static let textTertiary  = Color(red: 0x4A/255.0, green: 0x4D/255.0, blue: 0x53/255.0)
    static let danger        = Color(red: 0xF2/255.0, green: 0x47/255.0, blue: 0x3F/255.0)
    static let eqColor       = Color(red: 0xC9/255.0, green: 0xB4/255.0, blue: 0x5C/255.0)
    static let reverbColor   = Color(red: 0x7F/255.0, green: 0xCF/255.0, blue: 0xB6/255.0)
    static let delayColor    = Color(red: 0x8C/255.0, green: 0x96/255.0, blue: 0xF7/255.0)
    static let waveGray      = Color(red: 0x4A/255.0, green: 0x4E/255.0, blue: 0x56/255.0)

    static let waveformCount = 200
    static let trackCount    = 8
    static let clipPeaks     = 64

    static let trackColors: [Color] = [
        Color(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x1F/255.0),
        Color(red: 0xC9/255.0, green: 0xB4/255.0, blue: 0x5C/255.0),
        Color(red: 0x7F/255.0, green: 0xCF/255.0, blue: 0xB6/255.0),
        Color(red: 0x8C/255.0, green: 0x96/255.0, blue: 0xF7/255.0),
        Color(red: 0xE0/255.0, green: 0x6B/255.0, blue: 0x74/255.0),
        Color(red: 0x9A/255.0, green: 0xCC/255.0, blue: 0x5A/255.0),
        Color(red: 0xC4/255.0, green: 0x8C/255.0, blue: 0xDB/255.0),
        Color(red: 0x5C/255.0, green: 0xB8/255.0, blue: 0xDB/255.0),
    ]
    static func trackColor(_ i: Int) -> Color { trackColors[i % trackColors.count] }
}

// ── Models ───────────────────────────────────────────────────────────────────

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

struct Recording: Identifiable {
    let id = UUID()
    let url: URL
    let duration: TimeInterval
    let trackIndex: Int
    var name: String { url.lastPathComponent }
    var durationString: String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}

struct TrackClip: Identifiable {
    let id = UUID()
    let url: URL
    let duration: TimeInterval
    var peaks: [Double] = []
    var name: String { url.lastPathComponent }
}

struct TrackInfo: Identifiable {
    let id: Int
    var clips: [TrackClip] = []
    var volume: Double = 0.8
    var muted = false
    var solo = false
}

let reverbPresets: [(label: String, preset: AVAudioUnitReverbPreset)] = [
    ("Small Room",  .smallRoom),
    ("Medium Room", .mediumRoom),
    ("Large Room",  .largeRoom),
    ("Medium Hall", .mediumHall),
    ("Large Hall",  .largeHall),
    ("Plate",       .plate),
    ("Med Chamber", .mediumChamber),
    ("Lg Chamber",  .largeChamber),
    ("Cathedral",   .cathedral),
]

func reverbLabel(_ p: AVAudioUnitReverbPreset) -> String {
    reverbPresets.first { $0.preset.rawValue == p.rawValue }?.label ?? "Unknown"
}

// ── CoreAudio Global Helpers (from monitor.swift) ────────────────────────────

private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

private func audioAddress(_ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allAudioDevices() -> [AudioDeviceID] {
    var addr = audioAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObjectID, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObjectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func nameOfDevice(_ id: AudioDeviceID) -> String {
    var addr = audioAddress(kAudioObjectPropertyName)
    var cfName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName) == noErr,
          let value = cfName?.takeRetainedValue() else { return "(unknown)" }
    return value as String
}

func deviceChannelCount(_ id: AudioDeviceID, input: Bool) -> Int {
    let scope: AudioObjectPropertyScope = input
        ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    var addr = audioAddress(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func getDefaultAudioDevice(input: Bool) -> AudioDeviceID {
    let sel: AudioObjectPropertySelector = input
        ? kAudioHardwarePropertyDefaultInputDevice
        : kAudioHardwarePropertyDefaultOutputDevice
    var addr = audioAddress(sel)
    var id: AudioDeviceID = 0
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObjectID, &addr, 0, nil, &sz, &id)
    return id
}

func setDefaultAudioDevice(_ id: AudioDeviceID, input: Bool) {
    let sel: AudioObjectPropertySelector = input
        ? kAudioHardwarePropertyDefaultInputDevice
        : kAudioHardwarePropertyDefaultOutputDevice
    var addr = audioAddress(sel)
    var dev = id
    AudioObjectSetPropertyData(systemObjectID, &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}

// ── AudioManager ─────────────────────────────────────────────────────────────

class AudioManager: ObservableObject {
    @Published var inputDevices:     [AudioDevice] = []
    @Published var outputDevices:    [AudioDevice] = []
    @Published var selectedInputID:  AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?
    @Published var isMonitoring = false
    @Published var isRecording  = false
    @Published var volume: Double = 0.85
    @Published var level:  Double = 0
    @Published var peak:   Double = 0
    @Published var levelL: Double = 0
    @Published var levelR: Double = 0
    @Published var peakL:  Double = 0
    @Published var peakR:  Double = 0
    @Published var peakDB: Double = -Double.infinity
    @Published var waveformSamples: [Double] = Array(repeating: 0, count: Theme.waveformCount)
    @Published var recordingDuration: TimeInterval = 0
    @Published var status = "Ready"
    @Published var sampleRateString = "48 kHz · 24-bit · Stereo"

    // Effects
    @Published var eqEnabled = false
    @Published var eqLow:  Double = 0
    @Published var eqMid:  Double = 0
    @Published var eqHigh: Double = 0

    @Published var reverbEnabled = false
    @Published var reverbPreset: AVAudioUnitReverbPreset = .mediumHall
    @Published var reverbMix: Double = 40

    @Published var delayEnabled   = false
    @Published var delayTime:     Double = 0.25
    @Published var delayFeedback: Double = 30
    @Published var delayMix:      Double = 25

    @Published var showEffects = false

    // Multitrack
    @Published var recordings: [Recording] = []
    @Published var tracks: [TrackInfo] = (0..<Theme.trackCount).map { TrackInfo(id: $0) }
    @Published var selectedTrack: Int = 0
    @Published var isPlaying = false

    // Internal Audio Engine
    private var engine:       AVAudioEngine?
    private var reverbNode:   AVAudioUnitReverb?
    private var delayNode:    AVAudioUnitDelay?
    private var eqNode:       AVAudioUnitEQ?
    private var outMixer:     AVAudioMixerNode?
    private var masterMixer:  AVAudioMixerNode?
    private var audioFile:    AVAudioFile?
    private var previousDefaultInput: AudioDeviceID?
    private var playerNodes:  [AVAudioPlayerNode] = []
    private var trackMixers:  [AVAudioMixerNode] = []

    // Metering
    private var rawLevelL: Float = 0
    private var rawLevelR: Float = 0
    private var rawPeakL:  Float = 0
    private var rawPeakR:  Float = 0
    private var peakHoldL: Int   = 0
    private var peakHoldR: Int   = 0

    private var recordingStart: Date?
    private var displayTimer:   Timer?
    private var recordingTimer: Timer?

    private static let timestampFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()

    private static let tracksBaseURL: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/OP-XY Monitor/Tracks")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    init() {
        loadDevices()
        setupHardwareListeners()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Device Discovery

    func loadDevices() {
        let allIDs  = allAudioDevices()
        let inputs  = allIDs.filter { deviceChannelCount($0, input: true) > 0 }
                            .map { AudioDevice(id: $0, name: nameOfDevice($0)) }
        let outputs = allIDs.filter { deviceChannelCount($0, input: false) > 0 }
                            .map { AudioDevice(id: $0, name: nameOfDevice($0)) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inputDevices  = inputs
            self.outputDevices = outputs

            if self.selectedInputID == nil || !inputs.contains(where: { $0.id == self.selectedInputID }) {
                self.selectedInputID = inputs.first(where: { $0.name.localizedCaseInsensitiveContains("XY") })?.id
                    ?? inputs.first(where: { $0.name.localizedCaseInsensitiveContains("OP") })?.id
                    ?? inputs.first?.id
            }

            let currentSysOut = getDefaultAudioDevice(input: false)
            if self.selectedOutputID == nil || !outputs.contains(where: { $0.id == self.selectedOutputID }) {
                self.selectedOutputID = currentSysOut != 0 ? currentSysOut : outputs.first?.id
            }
        }
    }

    private func setupHardwareListeners() {
        var devAddr = audioAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &devAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.loadDevices()
        }

        var outAddr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &outAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.loadDevices()
        }
    }

    // MARK: - Monitoring Engine

    func startMonitoring() {
        if inputDevices.isEmpty { loadDevices() }

        guard let inID = selectedInputID,
              let inDev = inputDevices.first(where: { $0.id == inID }) else {
            status = "No input device selected"
            return
        }

        // Loopback Safeguard (from monitor.swift)
        let currentOutID = getDefaultAudioDevice(input: false)
        if currentOutID == inID {
            status = "Output set to \(inDev.name) — change output in System Settings to avoid loopback"
            return
        }

        // Set OP-XY as default system input (temporarily)
        previousDefaultInput = getDefaultAudioDevice(input: true)
        setDefaultAudioDevice(inID, input: true)

        let eng = AVAudioEngine()
        let hwFmt = eng.inputNode.inputFormat(forBus: 0)

        guard hwFmt.sampleRate > 0, hwFmt.channelCount > 0 else {
            status = "No usable input format — check Microphone permissions"
            restoreDefaultInput()
            return
        }

        let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: hwFmt.sampleRate, channels: 2) ?? hwFmt

        // Pipeline: inputNode -> mainMixer -> EQ -> Reverb -> Delay -> liveMix (tap) -> masterMixer -> outputNode
        let eq      = buildEQ()
        let reverb  = buildReverb()
        let delay   = buildDelay()
        let liveMix = AVAudioMixerNode()
        let master  = AVAudioMixerNode()

        eng.attach(eq); eng.attach(reverb); eng.attach(delay)
        eng.attach(liveMix); eng.attach(master)

        eng.connect(eng.inputNode,     to: eng.mainMixerNode, format: hwFmt)
        eng.mainMixerNode.outputVolume = 1.0
        eng.connect(eng.mainMixerNode, to: eq,                format: stereoFmt)
        eng.connect(eq,                to: reverb,            format: stereoFmt)
        eng.connect(reverb,            to: delay,             format: stereoFmt)
        eng.connect(delay,             to: liveMix,           format: stereoFmt)
        eng.connect(liveMix,           to: master,            format: stereoFmt)

        var players: [AVAudioPlayerNode] = []
        var trkMixers: [AVAudioMixerNode] = []
        for i in 0..<Theme.trackCount {
            let player = AVAudioPlayerNode()
            let trkMix = AVAudioMixerNode()
            eng.attach(player); eng.attach(trkMix)
            eng.connect(player, to: trkMix, format: stereoFmt)
            eng.connect(trkMix, to: master, format: stereoFmt)
            trkMix.outputVolume = Float(tracks[i].volume)
            players.append(player)
            trkMixers.append(trkMix)
        }

        eng.connect(master, to: eng.outputNode, format: nil)
        master.outputVolume = Float(volume)

        liveMix.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.processTap(buf)
        }

        eng.prepare()
        do {
            try eng.start()
        } catch {
            status = "Engine failure: \(error.localizedDescription)"
            restoreDefaultInput()
            return
        }

        engine       = eng
        reverbNode   = reverb
        delayNode    = delay
        eqNode       = eq
        outMixer     = liveMix
        masterMixer  = master
        playerNodes  = players
        trackMixers  = trkMixers
        isMonitoring = true

        let outName = nameOfDevice(currentOutID)
        status = "\(inDev.name) → \(outName)"
        sampleRateString = "\(Int(hwFmt.sampleRate / 1000)) kHz · 24-bit · Stereo"
        startDisplayTimer()
    }

    func stopMonitoring() {
        if isRecording { stopRecording() }
        if isPlaying   { stopPlayback() }
        teardown()
        restoreDefaultInput()
        isMonitoring = false
        displayTimer?.invalidate(); displayTimer = nil
        level = 0; peak = 0; levelL = 0; levelR = 0; peakL = 0; peakR = 0
        peakDB = -Double.infinity
        waveformSamples = Array(repeating: 0, count: Theme.waveformCount)
        status = "Stopped"
    }

    func switchOutput(to id: AudioDeviceID) {
        selectedOutputID = id
        if isMonitoring {
            stopMonitoring()
            startMonitoring()
        }
    }

    func applyVolume(_ v: Double) {
        volume = v
        masterMixer?.outputVolume = Float(v)
    }

    private func teardown() {
        outMixer?.removeTap(onBus: 0)
        engine?.stop()
        engine      = nil
        reverbNode  = nil
        delayNode   = nil
        eqNode      = nil
        outMixer    = nil
        masterMixer = nil
        playerNodes = []
        trackMixers = []
    }

    private func restoreDefaultInput() {
        if let prev = previousDefaultInput {
            setDefaultAudioDevice(prev, input: true)
            previousDefaultInput = nil
        }
    }

    // MARK: - Metering Processors

    private func processTap(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        let channels = Int(buf.format.channelCount)

        var sumL: Float = 0
        for i in 0..<n { sumL += data[0][i] * data[0][i] }
        let rmsL = sqrt(sumL / Float(n))

        let rmsR: Float
        if channels > 1 {
            var sumR: Float = 0
            for i in 0..<n { sumR += data[1][i] * data[1][i] }
            rmsR = sqrt(sumR / Float(n))
        } else {
            rmsR = rmsL
        }

        rawLevelL = rmsL
        rawLevelR = rmsR

        if rmsL >= rawPeakL { rawPeakL = rmsL; peakHoldL = 0 }
        else { peakHoldL += 1; if peakHoldL > 30 { rawPeakL *= 0.94 } }

        if rmsR >= rawPeakR { rawPeakR = rmsR; peakHoldR = 0 }
        else { peakHoldR += 1; if peakHoldR > 30 { rawPeakR *= 0.94 } }

        if let file = audioFile { try? file.write(from: buf) }
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let scaledL     = Double(min(self.rawLevelL * 4.5, 1))
            let scaledR     = Double(min(self.rawLevelR * 4.5, 1))
            let scaledPeakL = Double(min(self.rawPeakL * 4.5, 1))
            let scaledPeakR = Double(min(self.rawPeakR * 4.5, 1))
            let maxPeak     = Double(max(self.rawPeakL, self.rawPeakR))

            DispatchQueue.main.async {
                self.levelL = self.levelL * 0.70 + scaledL * 0.30
                self.levelR = self.levelR * 0.70 + scaledR * 0.30
                self.peakL  = scaledPeakL
                self.peakR  = scaledPeakR
                self.peakDB = maxPeak > 0 ? 20.0 * log10(maxPeak) : -Double.infinity

                var samples = self.waveformSamples
                samples.removeFirst()
                samples.append((self.levelL + self.levelR) / 2.0)
                self.waveformSamples = samples
            }
        }
    }

    // MARK: - Effects Controls

    private func buildEQ() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let b = eq.bands
        b[0].filterType = .lowShelf;   b[0].frequency = 200;  b[0].gain = Float(eqLow);  b[0].bypass = false
        b[1].filterType = .parametric; b[1].frequency = 1000; b[1].gain = Float(eqMid);  b[1].bandwidth = 1; b[1].bypass = false
        b[2].filterType = .highShelf;  b[2].frequency = 8000; b[2].gain = Float(eqHigh); b[2].bypass = false
        eq.bypass = !eqEnabled
        return eq
    }

    private func buildReverb() -> AVAudioUnitReverb {
        let r = AVAudioUnitReverb()
        r.loadFactoryPreset(reverbPreset)
        r.wetDryMix = Float(reverbMix)
        r.bypass    = !reverbEnabled
        return r
    }

    private func buildDelay() -> AVAudioUnitDelay {
        let d = AVAudioUnitDelay()
        d.delayTime     = delayTime
        d.feedback      = Float(delayFeedback)
        d.wetDryMix     = Float(delayMix)
        d.lowPassCutoff = 15000
        d.bypass        = !delayEnabled
        return d
    }

    func applyReverb() { reverbNode?.wetDryMix = Float(reverbMix); reverbNode?.bypass = !reverbEnabled }
    func changeReverbPreset(_ p: AVAudioUnitReverbPreset) {
        reverbPreset = p
        reverbNode?.loadFactoryPreset(p)
        reverbNode?.wetDryMix = Float(reverbMix)
    }
    func applyDelay() {
        delayNode?.delayTime = delayTime; delayNode?.feedback = Float(delayFeedback)
        delayNode?.wetDryMix = Float(delayMix); delayNode?.bypass = !delayEnabled
    }
    func applyEQ() {
        eqNode?.bands[0].gain = Float(eqLow); eqNode?.bands[1].gain = Float(eqMid)
        eqNode?.bands[2].gain = Float(eqHigh); eqNode?.bypass = !eqEnabled
    }

    // MARK: - Recording & Playback

    func startRecording() {
        guard isMonitoring, let eng = engine else { return }
        let fmt  = eng.mainMixerNode.outputFormat(forBus: 0)
        let name = "take_\(Self.timestampFmt.string(from: Date())).wav"
        let url  = trackFolder(selectedTrack).appendingPathComponent(name)
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            recordingStart    = Date()
            recordingDuration = 0
            isRecording       = true
            status            = "Recording TRK \(String(format: "%02d", selectedTrack + 1))"
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let s = self.recordingStart else { return }
                DispatchQueue.main.async { self.recordingDuration = Date().timeIntervalSince(s) }
            }
        } catch {
            status = "Recording error: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate(); recordingTimer = nil
        let saved = audioFile?.url
        let dur   = recordingDuration
        let trk   = selectedTrack
        audioFile   = nil
        isRecording = false

        guard let u = saved else { return }
        let peaks = computePeaks(url: u, count: Theme.clipPeaks)
        let clip  = TrackClip(url: u, duration: dur, peaks: peaks)
        let rec   = Recording(url: u, duration: dur, trackIndex: trk)

        status = "Saved \(u.lastPathComponent) → TRK \(String(format: "%02d", trk + 1))"
        DispatchQueue.main.async {
            self.recordings.append(rec)
            self.tracks[trk].clips.append(clip)
        }
    }

    func startPlayback() {
        guard isMonitoring, !isPlaying else { return }

        for (i, track) in tracks.enumerated() where i < playerNodes.count {
            let player = playerNodes[i]
            player.stop()
            for clip in track.clips {
                if let file = try? AVAudioFile(forReading: clip.url) {
                    player.scheduleFile(file, at: nil, completionHandler: nil)
                }
            }
        }

        for (i, player) in playerNodes.enumerated() where i < tracks.count && !tracks[i].clips.isEmpty {
            player.play()
        }

        isPlaying = true
        let count = tracks.reduce(0) { $0 + $1.clips.count }
        status = count == 0 ? "Nothing to play" : "Playing multitrack"
    }

    func stopPlayback() {
        playerNodes.forEach { $0.stop() }
        isPlaying = false
        status = "Playback stopped"
    }

    func toggleMute(_ i: Int) { tracks[i].muted.toggle(); refreshTrackMixers() }
    func toggleSolo(_ i: Int) { tracks[i].solo.toggle(); refreshTrackMixers() }
    func setTrackVolume(_ i: Int, _ v: Double) { tracks[i].volume = v; refreshTrackMixers() }

    private func refreshTrackMixers() {
        let anySolo = tracks.contains { $0.solo }
        for i in 0..<tracks.count where i < trackMixers.count {
            let t = tracks[i]
            let audible = t.solo || (!anySolo && !t.muted)
            trackMixers[i].outputVolume = audible ? Float(t.volume) : 0
        }
    }

    private func trackFolder(_ index: Int) -> URL {
        let dir = Self.tracksBaseURL.appendingPathComponent("Track \(index + 1)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func computePeaks(url: URL, count: Int) -> [Double] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return [] }
        try? file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength)
        let step = max(n / count, 1)
        var result: [Double] = []
        for i in 0..<count {
            let start = i * step
            let end = min(start + step, n)
            var peak: Float = 0
            for j in start..<end { peak = max(peak, abs(data[0][j])) }
            result.append(Double(min(peak, 1)))
        }
        return result
    }
}

// ── Views ────────────────────────────────────────────────────────────────────

struct HeaderBar: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text("OP-XY")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(Theme.accent)
                Text("|")
                    .font(.system(size: 16, weight: .thin, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                Text("MONITOR")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: { audio.showEffects.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("FX")
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(audio.showEffects ? Theme.accent : Theme.surfaceRaised)
                    .foregroundColor(audio.showEffects ? Theme.bg : Theme.textSecondary)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Circle()
                        .fill(audio.isMonitoring ? Color.green : Theme.danger)
                        .frame(width: 6, height: 6)
                    Text(audio.sampleRateString)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.surfaceInset)
                .cornerRadius(12)

                Button(action: { audio.loadDevices() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bg)
    }
}

struct SignalBar: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack {
            // Input Device Selector
            HStack(spacing: 4) {
                Text("IN")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.accent)
                Picker("", selection: Binding(
                    get: { audio.selectedInputID },
                    set: { audio.selectedInputID = $0; audio.startMonitoring() }
                )) {
                    ForEach(audio.inputDevices) { dev in
                        Text(dev.name).tag(Optional(dev.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Spacer()

            // Signal Graph Nodes
            HStack(spacing: 16) {
                SignalNode(label: "I", active: audio.isMonitoring, color: Theme.accent)
                SignalLine(active: audio.isMonitoring)
                SignalNode(label: "E", active: audio.eqEnabled, color: Theme.eqColor)
                SignalLine(active: audio.isMonitoring)
                SignalNode(label: "R", active: audio.reverbEnabled, color: Theme.reverbColor)
                SignalLine(active: audio.isMonitoring)
                SignalNode(label: "D", active: audio.delayEnabled, color: Theme.delayColor)
                SignalLine(active: audio.isMonitoring)
                SignalNode(label: "O", active: audio.isMonitoring, color: Theme.accent)
            }

            Spacer()

            // Output Device Selector
            HStack(spacing: 4) {
                Picker("", selection: Binding(
                    get: { audio.selectedOutputID },
                    set: { if let id = $0 { audio.switchOutput(to: id) } }
                )) {
                    ForEach(audio.outputDevices) { dev in
                        Text(dev.name).tag(Optional(dev.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Text("OUT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.surface)
    }
}

struct SignalNode: View {
    let label: String
    let active: Bool
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(active ? color : Theme.surfaceInset)
                .overlay(Circle().stroke(active ? color : Theme.bezel, lineWidth: 1.5))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(active ? Theme.textPrimary : Theme.textTertiary)
        }
    }
}

struct SignalLine: View {
    let active: Bool

    var body: some View {
        Rectangle()
            .fill(active ? Theme.bezel : Theme.line)
            .frame(width: 12, height: 1)
    }
}

struct WaveformScopeView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    // Grid Lines
                    VStack {
                        Spacer()
                        Divider().background(Theme.line.opacity(0.3))
                        Spacer()
                        Divider().background(Theme.line.opacity(0.3))
                        Spacer()
                    }

                    // Oscilloscope Trace
                    Path { path in
                        let midY = geo.size.height / 2
                        let stepX = geo.size.width / CGFloat(audio.waveformSamples.count - 1)

                        for (i, val) in audio.waveformSamples.enumerated() {
                            let x = CGFloat(i) * stepX
                            let h = CGFloat(val) * (geo.size.height / 2.2)
                            let y = midY - h

                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Theme.accent, lineWidth: 1.2)

                    // Time Scale Overlay
                    HStack {
                        Text("-40s").font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.textTertiary)
                        Spacer()
                        Text("-30s").font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.textTertiary)
                        Spacer()
                        Text("-20s").font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.textTertiary)
                        Spacer()
                        Text("-10s").font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.textTertiary)
                        Spacer()
                        Text("now").font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.textSecondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
            .frame(height: 180)
            .background(Theme.surfaceInset)
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

struct LevelMeterView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 16) {
            // Stereo Meter Bars
            VStack(spacing: 6) {
                HorizontalBarMeter(channel: "L", level: audio.levelL, peak: audio.peakL)
                HorizontalBarMeter(channel: "R", level: audio.levelR, peak: audio.peakR)

                // Scale ticks
                HStack {
                    Text("-60").frame(width: 30, alignment: .leading)
                    Spacer()
                    Text("-36")
                    Spacer()
                    Text("-24")
                    Spacer()
                    Text("-12")
                    Spacer()
                    Text("-6")
                    Spacer()
                    Text("0 dB").frame(width: 30, alignment: .trailing)
                }
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .padding(.leading, 16)
            }

            // PEAK Card Box
            VStack(spacing: 2) {
                Text("PEAK")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                Text(audio.peakDB.isFinite ? String(format: "%+.1f", audio.peakDB) : "-∞")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(audio.peakDB > -0.5 ? Theme.danger : Theme.accent)
                Text("dB")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(6)
            .frame(width: 70, height: 48)
            .background(Theme.surfaceInset)
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.bezel, lineWidth: 1))
        }
        .padding(12)
        .background(Theme.surface)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

struct HorizontalBarMeter: View {
    let channel: String
    let level: Double
    let peak: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(channel)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(Theme.textTertiary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.surfaceInset)

                    Rectangle()
                        .fill(level > 0.95 ? Theme.danger : Theme.accent)
                        .frame(width: CGFloat(max(0, min(1, level))) * geo.size.width)

                    Rectangle()
                        .fill(Theme.textPrimary)
                        .frame(width: 2)
                        .offset(x: max(0, min(geo.size.width - 2, CGFloat(peak) * geo.size.width)))
                }
            }
            .frame(height: 10)
            .cornerRadius(2)
        }
    }
}

struct MultitrackSectionView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        VStack(spacing: 8) {
            // Multitrack Controls Header
            HStack {
                Text("TRACKS")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                Text(String(format: "%02d clips", audio.tracks.reduce(0) { $0 + $1.clips.count }))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)

                Spacer()

                Button(action: {
                    if audio.isPlaying { audio.stopPlayback() }
                    else { audio.startPlayback() }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: audio.isPlaying ? "stop.fill" : "play.fill")
                        Text(audio.isPlaying ? "STOP" : "PLAY")
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.surfaceRaised)
                    .foregroundColor(Theme.textPrimary)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Button(action: {
                    if audio.isRecording { audio.stopRecording() }
                    else { audio.startRecording() }
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(audio.isRecording ? Theme.danger : Color.red)
                            .frame(width: 6, height: 6)
                        Text(audio.isRecording ? "STOP REC" : "REC ➔ TRK \(String(format: "%02d", audio.selectedTrack + 1))")
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(audio.isRecording ? Theme.danger.opacity(0.2) : Theme.surfaceRaised)
                    .foregroundColor(audio.isRecording ? Theme.danger : Theme.textPrimary)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            // Track Rows
            VStack(spacing: 4) {
                ForEach(0..<Theme.trackCount, id: \.self) { i in
                    TrackRowView(index: i, track: audio.tracks[i], audio: audio)
                }
            }
        }
        .padding(12)
        .background(Theme.surface)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

struct TrackRowView: View {
    let index: Int
    let track: TrackInfo
    @ObservedObject var audio: AudioManager

    var isSelected: Bool { audio.selectedTrack == index }

    var body: some View {
        HStack(spacing: 12) {
            // Track Selector
            Button(action: { audio.selectedTrack = index }) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(isSelected ? Theme.accent : Color.clear)
                        .frame(width: 3, height: 12)
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? Theme.accent : Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)

            Text("—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)

            Spacer()

            // Mute / Solo
            HStack(spacing: 2) {
                Button(action: { audio.toggleMute(index) }) {
                    Text("M")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .frame(width: 16, height: 16)
                        .background(track.muted ? Theme.danger : Theme.surfaceInset)
                        .foregroundColor(track.muted ? Theme.bg : Theme.textTertiary)
                        .cornerRadius(2)
                }
                .buttonStyle(.plain)

                Button(action: { audio.toggleSolo(index) }) {
                    Text("S")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .frame(width: 16, height: 16)
                        .background(track.solo ? Theme.eqColor : Theme.surfaceInset)
                        .foregroundColor(track.solo ? Theme.bg : Theme.textTertiary)
                        .cornerRadius(2)
                }
                .buttonStyle(.plain)
            }

            // Volume Slider
            Slider(value: Binding(
                get: { track.volume },
                set: { audio.setTrackVolume(index, $0) }
            ), in: 0...1)
            .frame(width: 80)
            .accentColor(Theme.trackColor(index))

            Text("\(Int(track.volume * 100))")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 20, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isSelected ? Theme.surfaceInset : Color.clear)
        .cornerRadius(3)
    }
}

struct DrawerEffectsView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 12) {
            // EQ
            VStack(spacing: 6) {
                Toggle("EQ", isOn: $audio.eqEnabled)
                    .onChange(of: audio.eqEnabled) { _ in audio.applyEQ() }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.eqColor)
                HStack(spacing: 4) {
                    MiniKnob(label: "LOW", value: $audio.eqLow, range: -12...12, color: Theme.eqColor)
                        .onChange(of: audio.eqLow) { _ in audio.applyEQ() }
                    MiniKnob(label: "MID", value: $audio.eqMid, range: -12...12, color: Theme.eqColor)
                        .onChange(of: audio.eqMid) { _ in audio.applyEQ() }
                    MiniKnob(label: "HI", value: $audio.eqHigh, range: -12...12, color: Theme.eqColor)
                        .onChange(of: audio.eqHigh) { _ in audio.applyEQ() }
                }
            }
            .padding(8)
            .background(Theme.surface)
            .cornerRadius(4)

            // Reverb
            VStack(spacing: 6) {
                Toggle("REVERB", isOn: $audio.reverbEnabled)
                    .onChange(of: audio.reverbEnabled) { _ in audio.applyReverb() }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.reverbColor)
                MiniKnob(label: "MIX", value: $audio.reverbMix, range: 0...100, color: Theme.reverbColor)
                    .onChange(of: audio.reverbMix) { _ in audio.applyReverb() }
            }
            .padding(8)
            .background(Theme.surface)
            .cornerRadius(4)

            // Delay
            VStack(spacing: 6) {
                Toggle("DELAY", isOn: $audio.delayEnabled)
                    .onChange(of: audio.delayEnabled) { _ in audio.applyDelay() }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.delayColor)
                HStack(spacing: 4) {
                    MiniKnob(label: "TIME", value: $audio.delayTime, range: 0.05...1.0, color: Theme.delayColor)
                        .onChange(of: audio.delayTime) { _ in audio.applyDelay() }
                    MiniKnob(label: "FB", value: $audio.delayFeedback, range: 0...90, color: Theme.delayColor)
                        .onChange(of: audio.delayFeedback) { _ in audio.applyDelay() }
                    MiniKnob(label: "MIX", value: $audio.delayMix, range: 0...100, color: Theme.delayColor)
                        .onChange(of: audio.delayMix) { _ in audio.applyDelay() }
                }
            }
            .padding(8)
            .background(Theme.surface)
            .cornerRadius(4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

struct MiniKnob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Slider(value: $value, in: range)
                .accentColor(color)
                .frame(width: 50)
        }
    }
}

// ── Root View ────────────────────────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var audio = AudioManager()

    var body: some View {
        ZStack {
            Theme.bg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderBar(audio: audio)
                SignalBar(audio: audio)

                if audio.showEffects {
                    DrawerEffectsView(audio: audio)
                }

                WaveformScopeView(audio: audio)
                LevelMeterView(audio: audio)
                MultitrackSectionView(audio: audio)

                // Absorbs leftover space cleanly to keep content pinned top
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            audio.startMonitoring()
        }
    }
}

// ── App Entry Point ──────────────────────────────────────────────────────────

@main
struct MonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 680)
                .background(Theme.bg)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}