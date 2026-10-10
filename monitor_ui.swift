// monitor_ui.swift — OP-XY Monitor: USB audio monitoring, effects, multitrack & recording
//
// Build:  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk swiftc -parse-as-library monitor_ui.swift -o monitor_ui
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
    var isPlaying = false
    var loopProgress: Double = 0
    var undoClips: [TrackClip]? = nil
    var layerCount: Int { clips.count }
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

// ── CoreAudio Global Helpers ─────────────────────────────────────────────────

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

    // Looper
    @Published var bpm: Double = 120
    @Published var metronomeEnabled = false
    @Published var quantizeMode: Int = 0  // 0=OFF, 1=1 BAR, 2=1/2 BAR
    static let quantizeLabels = ["OFF", "1 BAR", "½ BAR"]

    // Multitrack
    @Published var recordings: [Recording] = []
    @Published var tracks: [TrackInfo] = (0..<Theme.trackCount).map { TrackInfo(id: $0) }
    @Published var selectedTrack: Int = 0
    @Published var isPlaying = false

    // Audio Engine Internals
    private var engine:       AVAudioEngine?
    private var reverbNode:   AVAudioUnitReverb?
    private var delayNode:    AVAudioUnitDelay?
    private var eqNode:       AVAudioUnitEQ?
    private var outMixer:     AVAudioMixerNode?
    var masterMixer:  AVAudioMixerNode?
    private var audioFile:    AVAudioFile?
    private var previousDefaultInput: AudioDeviceID?
    private var playerNodes:  [AVAudioPlayerNode] = []
    private var trackMixers:  [AVAudioMixerNode] = []

    // Metronome
    private var metronomeNode:  AVAudioPlayerNode?
    private var metronomeTimer: Timer?
    private var clickBuffer:    AVAudioPCMBuffer?

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

    func startMonitoring() {
        if inputDevices.isEmpty { loadDevices() }

        guard let inID = selectedInputID,
              let inDev = inputDevices.first(where: { $0.id == inID }) else {
            status = "No input device selected"
            return
        }

        let currentOutID = getDefaultAudioDevice(input: false)
        if currentOutID == inID {
            status = "Output set to \(inDev.name) — change output in System Settings to avoid loopback"
            return
        }

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

        let metroNode = AVAudioPlayerNode()
        eng.attach(metroNode)
        eng.connect(metroNode, to: master, format: stereoFmt)

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
        playerNodes    = players
        trackMixers    = trkMixers
        metronomeNode  = metroNode
        clickBuffer    = generateClickBuffer(sampleRate: hwFmt.sampleRate)
        isMonitoring   = true

        let outName = nameOfDevice(currentOutID)
        status = "\(inDev.name) → \(outName)"
        sampleRateString = "\(Int(hwFmt.sampleRate / 1000)) kHz · 24-bit · Stereo"
        startDisplayTimer()
        if metronomeEnabled { startMetronome() }
    }

    func stopMonitoring() {
        if isRecording { stopRecording() }
        if isPlaying   { stopPlayback() }
        teardown()
        restoreDefaultInput()
        isMonitoring = false
        displayTimer?.invalidate(); displayTimer = nil
        levelL = 0; levelR = 0; peakL = 0; peakR = 0
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

    private func teardown() {
        stopMetronome()
        outMixer?.removeTap(onBus: 0)
        engine?.stop()
        engine        = nil
        reverbNode    = nil
        delayNode     = nil
        eqNode        = nil
        outMixer      = nil
        masterMixer   = nil
        metronomeNode = nil
        clickBuffer   = nil
        playerNodes   = []
        trackMixers   = []
    }

    private func restoreDefaultInput() {
        if let prev = previousDefaultInput {
            setDefaultAudioDevice(prev, input: true)
            previousDefaultInput = nil
        }
    }

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

                // Update loop progress for each playing track
                for i in 0..<min(self.tracks.count, self.playerNodes.count) {
                    if self.tracks[i].isPlaying,
                       let nodeTime = self.playerNodes[i].lastRenderTime,
                       nodeTime.isSampleTimeValid,
                       let playerTime = self.playerNodes[i].playerTime(forNodeTime: nodeTime),
                       let clip = self.tracks[i].clips.last {
                        let totalFrames = clip.duration * playerTime.sampleRate
                        if totalFrames > 0 {
                            let pos = Double(playerTime.sampleTime).truncatingRemainder(dividingBy: totalFrames)
                            self.tracks[i].loopProgress = max(0, pos / totalFrames)
                        }
                    }
                }
            }
        }
    }

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
    func applyDelay() {
        delayNode?.delayTime = delayTime; delayNode?.feedback = Float(delayFeedback)
        delayNode?.wetDryMix = Float(delayMix); delayNode?.bypass = !delayEnabled
    }
    func applyEQ() {
        eqNode?.bands[0].gain = Float(eqLow); eqNode?.bands[1].gain = Float(eqMid)
        eqNode?.bands[2].gain = Float(eqHigh); eqNode?.bypass = !eqEnabled
    }

    // ── Metronome ───────────────────────────────────────────────────────────

    func toggleMetronome() {
        metronomeEnabled.toggle()
        if metronomeEnabled && isMonitoring {
            startMetronome()
        } else {
            stopMetronome()
        }
    }

    func setBPM(_ newBPM: Double) {
        bpm = max(40, min(300, newBPM))
        if metronomeEnabled && isMonitoring {
            startMetronome()
        }
    }

    private func startMetronome() {
        stopMetronome()
        guard let node = metronomeNode, clickBuffer != nil else { return }
        if !node.isPlaying { node.play() }
        playClick()
        let interval = 60.0 / bpm
        metronomeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.playClick()
        }
    }

    private func stopMetronome() {
        metronomeTimer?.invalidate()
        metronomeTimer = nil
    }

    private func playClick() {
        guard let node = metronomeNode, let buf = clickBuffer else { return }
        node.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
    }

    private func generateClickBuffer(sampleRate: Double) -> AVAudioPCMBuffer? {
        let clickDuration = 0.015
        let frameCount = AVAudioFrameCount(sampleRate * clickDuration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData else { return nil }

        let freq: Float = 880
        for i in 0..<Int(frameCount) {
            let t = Float(i) / Float(sampleRate)
            let envelope = exp(-Float(i) / Float(frameCount) * 4.0)
            let sample = sin(2 * .pi * freq * t) * envelope * 0.5
            data[0][i] = sample
            if buffer.format.channelCount > 1 { data[1][i] = sample }
        }
        return buffer
    }

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

    // ── Looper Methods ──────────────────────────────────────────────────────

    func toggleTrackRecord(_ i: Int) {
        if isRecording && selectedTrack == i {
            stopRecording()
            startTrackLoop(i)
        } else {
            if isRecording {
                let prevTrack = selectedTrack
                stopRecording()
                startTrackLoop(prevTrack)
            }
            selectedTrack = i
            startRecording()
        }
    }

    func toggleTrackPlayback(_ i: Int) {
        if tracks[i].isPlaying {
            stopTrackLoop(i)
        } else {
            startTrackLoop(i)
        }
    }

    func startTrackLoop(_ i: Int) {
        guard i < playerNodes.count, !tracks[i].clips.isEmpty else { return }
        let player = playerNodes[i]
        player.stop()

        if let clip = tracks[i].clips.last,
           let file = try? AVAudioFile(forReading: clip.url) {
            let frameCount = AVAudioFrameCount(file.length)
            if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) {
                try? file.read(into: buffer)
                player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                player.play()
                tracks[i].isPlaying = true
            }
        }
    }

    func stopTrackLoop(_ i: Int) {
        guard i < playerNodes.count else { return }
        playerNodes[i].stop()
        tracks[i].isPlaying = false
        tracks[i].loopProgress = 0
    }

    func clearTrack(_ i: Int) {
        stopTrackLoop(i)
        tracks[i].undoClips = tracks[i].clips.isEmpty ? nil : tracks[i].clips
        tracks[i].clips = []
    }

    func undoTrack(_ i: Int) {
        if let prev = tracks[i].undoClips {
            stopTrackLoop(i)
            tracks[i].clips = prev
            tracks[i].undoClips = nil
        }
    }

    func playAll() {
        for i in 0..<tracks.count where !tracks[i].clips.isEmpty {
            startTrackLoop(i)
        }
        status = "Playing all"
    }

    func stopAll() {
        for i in 0..<tracks.count { stopTrackLoop(i) }
        if isRecording { stopRecording() }
        isPlaying = false
        status = "All stopped"
    }

    func clearAll() {
        stopAll()
        for i in 0..<tracks.count {
            tracks[i].undoClips = tracks[i].clips.isEmpty ? nil : tracks[i].clips
            tracks[i].clips = []
        }
        status = "All cleared"
    }

    func cycleQuantize() {
        quantizeMode = (quantizeMode + 1) % 3
    }

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
        HStack(alignment: .center, spacing: 12) {
            // Logo
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("OP-XY")
                    .font(.system(size: 22, weight: .black, design: .default))
                    .foregroundColor(Theme.textPrimary)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 3, height: 16)
                Text("LOOPER")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .tracking(3)
            }

            Spacer()

            // Tempo control
            TempoControl(audio: audio)

            // Time Signature
            Text("4/4")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Theme.surfaceInset)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))

            // Metronome
            Button { audio.toggleMetronome() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "metronome.fill")
                        .font(.system(size: 10))
                    Text(audio.metronomeEnabled ? "ON" : "OFF")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(audio.metronomeEnabled ? Theme.accent : Theme.surfaceInset)
                .foregroundColor(audio.metronomeEnabled ? .black : Theme.textTertiary)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
            }.buttonStyle(.plain)

            // Quantize
            Button { audio.cycleQuantize() } label: {
                HStack(spacing: 4) {
                    Text("Q")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                    Text(AudioManager.quantizeLabels[audio.quantizeMode])
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(audio.quantizeMode > 0 ? Theme.accent.opacity(0.2) : Theme.surfaceInset)
                .foregroundColor(audio.quantizeMode > 0 ? Theme.accent : Theme.textTertiary)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(audio.quantizeMode > 0 ? Theme.accent.opacity(0.4) : Theme.line))
            }.buttonStyle(.plain)

            // FX toggle
            Button(action: { audio.showEffects.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text("FX")
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(audio.showEffects ? Theme.accent : Theme.surfaceRaised)
                .foregroundColor(audio.showEffects ? .black : Theme.textSecondary)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
            }.buttonStyle(.plain)

            // Status dot + format
            HStack(spacing: 5) {
                Circle()
                    .fill(audio.isMonitoring ? Theme.accent : Theme.textTertiary)
                    .frame(width: 5, height: 5)
                Text(audio.sampleRateString)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(.leading, 78)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(Theme.bg)
    }
}

struct SignalBar: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack {
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

// ── Compact Meters ──────────────────────────────────────────────────────────

struct CompactMeterBar: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 10) {
            Text("L")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.surfaceInset)
                    Rectangle()
                        .fill(audio.levelL > 0.95 ? Theme.danger : Theme.accent)
                        .frame(width: CGFloat(max(0, min(1, audio.levelL))) * geo.size.width)
                    Rectangle().fill(Theme.textPrimary).frame(width: 1.5)
                        .offset(x: max(0, CGFloat(audio.peakL) * geo.size.width - 1))
                }
            }
            .frame(height: 6).cornerRadius(1)

            Text("R")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.surfaceInset)
                    Rectangle()
                        .fill(audio.levelR > 0.95 ? Theme.danger : Theme.accent)
                        .frame(width: CGFloat(max(0, min(1, audio.levelR))) * geo.size.width)
                    Rectangle().fill(Theme.textPrimary).frame(width: 1.5)
                        .offset(x: max(0, CGFloat(audio.peakR) * geo.size.width - 1))
                }
            }
            .frame(height: 6).cornerRadius(1)

            Text(audio.peakDB.isFinite ? String(format: "%+.1f", audio.peakDB) : "-∞")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(audio.peakDB > -0.5 ? Theme.danger : Theme.textSecondary)
                .frame(width: 50, alignment: .trailing)
            Text("dB")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(Theme.surface)
    }
}

// ── Loop Grid ───────────────────────────────────────────────────────────────

struct LoopGridView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        VStack(spacing: 2) {
            // Grid header
            HStack {
                Text("LOOP GRID")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .tracking(2)
                Spacer()
                let clipCount = audio.tracks.reduce(0) { $0 + $1.clips.count }
                let activeCount = audio.tracks.filter { $0.isPlaying }.count
                Text("\(clipCount) clips · \(activeCount) active")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 4).padding(.bottom, 4)

            // Track pads
            ForEach(0..<Theme.trackCount, id: \.self) { i in
                LoopPadView(index: i, track: audio.tracks[i], audio: audio)
            }
        }
        .padding(12)
        .background(Theme.surface)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}

struct LoopPadView: View {
    let index: Int
    let track: TrackInfo
    @ObservedObject var audio: AudioManager

    private var color: Color { Theme.trackColor(index) }
    private var isRecordingThis: Bool { audio.isRecording && audio.selectedTrack == index }
    private var hasClip: Bool { !track.clips.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            // Color bar + track number
            Rectangle()
                .fill(track.isPlaying ? color : color.opacity(0.3))
                .frame(width: 4)

            Button(action: { audio.selectedTrack = index }) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(audio.selectedTrack == index ? color : Theme.textSecondary)
                    .frame(width: 30)
            }
            .buttonStyle(.plain)

            // Waveform / Loop visualization
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.surfaceInset)

                    if hasClip, let clip = track.clips.last, !clip.peaks.isEmpty {
                        // Waveform peaks
                        HStack(spacing: 1) {
                            ForEach(0..<clip.peaks.count, id: \.self) { j in
                                let peak = clip.peaks[j]
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(color.opacity(0.6))
                                    .frame(width: max(1, (geo.size.width - CGFloat(clip.peaks.count)) / CGFloat(clip.peaks.count)),
                                           height: max(2, CGFloat(peak) * (geo.size.height - 6)))
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, 2)

                        // Loop progress playhead
                        if track.isPlaying {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 1.5)
                                .offset(x: CGFloat(track.loopProgress) * geo.size.width)
                        }

                        // Layer count badge
                        if track.layerCount > 1 {
                            Text("×\(track.layerCount)")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundColor(color)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Theme.bg.opacity(0.8))
                                .cornerRadius(2)
                                .padding(3)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        }
                    } else {
                        // Empty state
                        Text("EMPTY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.textTertiary.opacity(0.4))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Recording flash overlay
                    if isRecordingThis {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.danger.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Theme.danger.opacity(0.4), lineWidth: 1)
                            )
                    }
                }
            }
            .frame(height: 44)
            .padding(.vertical, 4)

            // Track action buttons
            HStack(spacing: 4) {
                // REC per track
                Button { audio.toggleTrackRecord(index) } label: {
                    Circle()
                        .fill(isRecordingThis ? Theme.danger : Theme.textTertiary.opacity(0.3))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().fill(isRecordingThis ? Theme.danger : Color.red.opacity(0.7))
                                .frame(width: 10, height: 10)
                        )
                }.buttonStyle(.plain)

                // PLAY/STOP per track
                Button { audio.toggleTrackPlayback(index) } label: {
                    Image(systemName: track.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(track.isPlaying ? color.opacity(0.2) : Theme.surfaceInset)
                        .foregroundColor(track.isPlaying ? color : Theme.textTertiary)
                        .cornerRadius(3)
                }.buttonStyle(.plain)

                // CLEAR
                Button { audio.clearTrack(index) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Theme.surfaceInset)
                        .foregroundColor(hasClip ? Theme.textSecondary : Theme.textTertiary.opacity(0.3))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .disabled(!hasClip)
            }
            .padding(.horizontal, 6)

            // M / S
            HStack(spacing: 2) {
                Button { audio.toggleMute(index) } label: {
                    Text("M")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .frame(width: 18, height: 18)
                        .background(track.muted ? Theme.danger : Theme.surfaceInset)
                        .foregroundColor(track.muted ? Theme.bg : Theme.textTertiary)
                        .cornerRadius(2)
                }.buttonStyle(.plain)

                Button { audio.toggleSolo(index) } label: {
                    Text("S")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .frame(width: 18, height: 18)
                        .background(track.solo ? Theme.eqColor : Theme.surfaceInset)
                        .foregroundColor(track.solo ? Theme.bg : Theme.textTertiary)
                        .cornerRadius(2)
                }.buttonStyle(.plain)
            }

            // Volume fader
            TrackFader(
                value: Binding(
                    get: { track.volume },
                    set: { audio.setTrackVolume(index, $0) }
                ),
                color: color
            )
            .frame(width: 80)
            .padding(.horizontal, 6)

            Text("\(Int(track.volume * 100))")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(audio.selectedTrack == index ? Theme.surfaceInset.opacity(0.5) : Color.clear)
        )
    }
}

struct TrackFader: View {
    @Binding var value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.surfaceInset)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.5))
                    .frame(width: CGFloat(value) * geo.size.width)
                // Thumb
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 4, height: geo.size.height)
                    .offset(x: max(0, CGFloat(value) * geo.size.width - 2))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        value = min(max(Double(g.location.x / geo.size.width), 0), 1)
                    }
            )
        }
        .frame(height: 12)
        .cornerRadius(2)
    }
}

// ── Mini Scope ──────────────────────────────────────────────────────────────

struct MiniScopeView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    let midY = geo.size.height / 2
                    let stepX = geo.size.width / CGFloat(audio.waveformSamples.count - 1)
                    for (i, val) in audio.waveformSamples.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = midY - CGFloat(val) * (geo.size.height / 2.2)
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
            }
        }
        .frame(height: 32)
        .background(Theme.surfaceInset)
        .cornerRadius(3)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

struct TempoControl: View {
    @ObservedObject var audio: AudioManager
    @State private var dragStartBPM: Double? = nil

    var body: some View {
        HStack(spacing: 4) {
            Button { audio.setBPM(audio.bpm - 10) } label: {
                Text("−10")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .frame(width: 26, height: 26)
                    .background(Theme.surfaceRaised)
                    .foregroundColor(Theme.textSecondary)
                    .cornerRadius(3)
            }.buttonStyle(.plain)

            Button { audio.setBPM(audio.bpm - 1) } label: {
                Text("−")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 22, height: 26)
                    .background(Theme.surfaceRaised)
                    .foregroundColor(Theme.textSecondary)
                    .cornerRadius(3)
            }.buttonStyle(.plain)

            // BPM display — drag vertically to scrub
            VStack(spacing: 0) {
                Text("BPM")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                Text(String(format: "%.0f", audio.bpm))
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundColor(Theme.accent)
            }
            .frame(width: 48)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragStartBPM == nil { dragStartBPM = audio.bpm }
                        let delta = -g.translation.height / 3
                        audio.setBPM((dragStartBPM ?? audio.bpm) + delta)
                    }
                    .onEnded { _ in dragStartBPM = nil }
            )

            Button { audio.setBPM(audio.bpm + 1) } label: {
                Text("+")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 22, height: 26)
                    .background(Theme.surfaceRaised)
                    .foregroundColor(Theme.textSecondary)
                    .cornerRadius(3)
            }.buttonStyle(.plain)

            Button { audio.setBPM(audio.bpm + 10) } label: {
                Text("+10")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .frame(width: 26, height: 26)
                    .background(Theme.surfaceRaised)
                    .foregroundColor(Theme.textSecondary)
                    .cornerRadius(3)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Theme.surfaceInset)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
    }
}

struct DrawerEffectsView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // EQ
            VStack(spacing: 8) {
                fxToggle(label: "EQ", color: Theme.eqColor, enabled: $audio.eqEnabled, action: audio.applyEQ)
                HStack(spacing: 12) {
                    ArcKnob(label: "LOW", value: $audio.eqLow, range: -12...12, color: Theme.eqColor, bipolar: true)
                        .onChange(of: audio.eqLow) { audio.applyEQ() }
                    ArcKnob(label: "MID", value: $audio.eqMid, range: -12...12, color: Theme.eqColor, bipolar: true)
                        .onChange(of: audio.eqMid) { audio.applyEQ() }
                    ArcKnob(label: "HI", value: $audio.eqHigh, range: -12...12, color: Theme.eqColor, bipolar: true)
                        .onChange(of: audio.eqHigh) { audio.applyEQ() }
                }
                .opacity(audio.eqEnabled ? 1 : 0.3)
            }
            .frame(maxWidth: .infinity)
            .padding(12)

            Rectangle().fill(Theme.line).frame(width: 0.5)

            // Reverb
            VStack(spacing: 8) {
                fxToggle(label: "REVERB", color: Theme.reverbColor, enabled: $audio.reverbEnabled, action: audio.applyReverb)
                ArcKnob(label: "MIX", value: $audio.reverbMix, range: 0...100, color: Theme.reverbColor)
                    .onChange(of: audio.reverbMix) { audio.applyReverb() }
                    .opacity(audio.reverbEnabled ? 1 : 0.3)
            }
            .frame(maxWidth: .infinity)
            .padding(12)

            Rectangle().fill(Theme.line).frame(width: 0.5)

            // Delay
            VStack(spacing: 8) {
                fxToggle(label: "DELAY", color: Theme.delayColor, enabled: $audio.delayEnabled, action: audio.applyDelay)
                HStack(spacing: 12) {
                    ArcKnob(label: "TIME", value: $audio.delayTime, range: 0.05...1.0, color: Theme.delayColor)
                        .onChange(of: audio.delayTime) { audio.applyDelay() }
                    ArcKnob(label: "FB", value: $audio.delayFeedback, range: 0...90, color: Theme.delayColor)
                        .onChange(of: audio.delayFeedback) { audio.applyDelay() }
                    ArcKnob(label: "MIX", value: $audio.delayMix, range: 0...100, color: Theme.delayColor)
                        .onChange(of: audio.delayMix) { audio.applyDelay() }
                }
                .opacity(audio.delayEnabled ? 1 : 0.3)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
        }
        .background(Theme.surface)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func fxToggle(label: String, color: Color, enabled: Binding<Bool>, action: @escaping () -> Void) -> some View {
        Button { enabled.wrappedValue.toggle(); action() } label: {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(enabled.wrappedValue ? color : Theme.textTertiary)
                    .frame(width: 3, height: 14)
                    .cornerRadius(1)
                Text(label)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(enabled.wrappedValue ? color : Theme.textTertiary)
                    .tracking(1)
                Spacer()
                Text(enabled.wrappedValue ? "ON" : "OFF")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(enabled.wrappedValue ? color : Theme.textTertiary)
                    .tracking(1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ArcKnob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color
    var bipolar: Bool = false

    private let startAngle: Double = 135
    private let sweepAngle: Double = 270
    private let size: CGFloat = 48

    private var normalized: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                arcPath(from: 0, to: 1)
                    .stroke(Theme.line, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                if bipolar {
                    arcPath(from: 0.5, to: normalized)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                } else {
                    arcPath(from: 0, to: normalized)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                Circle().fill(Theme.surface).frame(width: size * 0.38, height: size * 0.38)
                indicatorLine()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .frame(width: size, height: size)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        let delta = -gesture.translation.height / 150
                        let newNorm = min(max(normalized + delta, 0), 1)
                        value = range.lowerBound + newNorm * (range.upperBound - range.lowerBound)
                    }
            )

            Text(displayValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
    }

    private var displayValue: String {
        if bipolar {
            let v = Int(value)
            return (v >= 0 ? "+" : "") + "\(v)"
        } else if range.upperBound > 10 {
            return "\(Int(value))"
        } else {
            return "\(Int(value * 1000))ms"
        }
    }

    private func angleForValue(_ v: Double) -> Double {
        (startAngle + sweepAngle * min(max(v, 0), 1)) * .pi / 180
    }

    private func arcPath(from: Double, to: Double) -> Path {
        let r = size / 2 - 3, c = CGPoint(x: size / 2, y: size / 2)
        let s = min(from, to), e = max(from, to)
        return Path { p in
            p.addArc(center: c, radius: r,
                     startAngle: Angle(degrees: startAngle + sweepAngle * s),
                     endAngle: Angle(degrees: startAngle + sweepAngle * e),
                     clockwise: false)
        }
    }

    private func indicatorLine() -> Path {
        let a = angleForValue(normalized)
        let c = CGPoint(x: size / 2, y: size / 2)
        let innerR = size * 0.19, outerR = size / 2 - 3
        return Path { p in
            p.move(to: CGPoint(x: c.x + innerR * cos(a), y: c.y + innerR * sin(a)))
            p.addLine(to: CGPoint(x: c.x + outerR * cos(a), y: c.y + outerR * sin(a)))
        }
    }
}

struct TransportBar: View {
    @ObservedObject var audio: AudioManager

    private var timerText: String {
        let t = audio.recordingDuration
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let tenths = Int((t - floor(t)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Timer + status (left)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(audio.isRecording ? Theme.danger : (audio.isMonitoring ? Theme.accent : Theme.textTertiary))
                        .frame(width: 6, height: 6)
                    Text(audio.isRecording ? "REC · TRK \(String(format: "%02d", audio.selectedTrack + 1))"
                         : (audio.isMonitoring ? "LIVE" : "IDLE"))
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundColor(audio.isRecording ? Theme.danger : (audio.isMonitoring ? Theme.accent : Theme.textTertiary))
                        .tracking(2)
                }
                Text(timerText)
                    .font(.system(size: 42, weight: .black, design: .monospaced))
                    .foregroundColor(audio.isRecording ? Theme.danger : Theme.textPrimary)
                    .monospacedDigit()
            }
            .frame(width: 200, alignment: .leading)

            Spacer()

            // Central transport buttons
            HStack(spacing: 8) {
                // UNDO
                Button {
                    audio.undoTrack(audio.selectedTrack)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .bold))
                        Text("UNDO")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                    }
                    .frame(width: 52, height: 52)
                    .background(Theme.surfaceRaised)
                    .foregroundColor(Theme.textSecondary)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                }.buttonStyle(.plain)

                // PLAY ALL
                Button { audio.playAll() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text("PLAY ALL")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                    }
                    .frame(width: 64, height: 52)
                    .background(Theme.surfaceRaised)
                    .foregroundColor(Theme.accent)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                }.buttonStyle(.plain)

                // RECORD (big)
                Button {
                    if audio.isRecording { audio.stopRecording(); audio.startTrackLoop(audio.selectedTrack) }
                    else { audio.startRecording() }
                } label: {
                    VStack(spacing: 4) {
                        Circle()
                            .fill(audio.isRecording ? Theme.danger : Color.red.opacity(0.8))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().stroke(audio.isRecording ? Theme.danger.opacity(0.4) : Color.clear, lineWidth: 4)
                            )
                        Text(audio.isRecording ? "STOP" : "REC")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1)
                    }
                    .frame(width: 80, height: 60)
                    .background(audio.isRecording ? Theme.danger.opacity(0.15) : Theme.surfaceRaised)
                    .foregroundColor(audio.isRecording ? Theme.danger : Theme.textPrimary)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(audio.isRecording ? Theme.danger : Theme.line))
                }.buttonStyle(.plain)

                // STOP ALL (panic)
                Button { audio.stopAll() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 18, weight: .bold))
                        Text("STOP ALL")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                    }
                    .frame(width: 72, height: 60)
                    .background(Theme.surfaceRaised)
                    .foregroundColor(Theme.danger)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.3)))
                }.buttonStyle(.plain)

                // CLEAR ALL
                Button { audio.clearAll() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .bold))
                        Text("CLEAR")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                    }
                    .frame(width: 52, height: 52)
                    .background(Theme.surfaceRaised)
                    .foregroundColor(Theme.textSecondary)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                }.buttonStyle(.plain)
            }

            Spacer()

            // Right: Volume + Monitor toggle
            HStack(spacing: 12) {
                ArcKnob(label: "VOL", value: Binding(
                    get: { audio.volume * 100 },
                    set: { audio.volume = $0 / 100; audio.masterMixer?.outputVolume = Float(audio.volume) }
                ), range: 0...100, color: Theme.accent)

                // MONITOR toggle
                Button {
                    if audio.isMonitoring { audio.stopMonitoring() }
                    else { audio.startMonitoring() }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: audio.isMonitoring ? "headphones" : "headphones")
                            .font(.system(size: 16, weight: .bold))
                        Text(audio.isMonitoring ? "ON" : "OFF")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(1)
                    }
                    .frame(width: 56, height: 56)
                    .background(audio.isMonitoring ? Theme.accent : Theme.surfaceRaised)
                    .foregroundColor(audio.isMonitoring ? .black : Theme.textSecondary)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(audio.isMonitoring ? Theme.accent : Theme.line))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Rectangle().fill(Theme.line).frame(height: 0.5), alignment: .top)
    }
}

struct StatusFooter: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 8) {
            Text(audio.status)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
            Spacer()
            Text("OP-XY MONITOR v1.0")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.line).frame(height: 0.5), alignment: .top)
    }
}

// ── Window Accessor ──────────────────────────────────────────────────────────

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
                window.backgroundColor = NSColor(red: 0x14/255, green: 0x15/255, blue: 0x17/255, alpha: 1)
                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    contentView.superview?.wantsLayer = true
                }
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// ── Root View ────────────────────────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var audio = AudioManager()

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(audio: audio)
            SignalBar(audio: audio)
            CompactMeterBar(audio: audio)

            if audio.showEffects {
                DrawerEffectsView(audio: audio)
            }

            // Loop Grid — the heart of the UI
            ScrollView(.vertical, showsIndicators: false) {
                LoopGridView(audio: audio)
            }

            // Mini waveform scope strip
            MiniScopeView(audio: audio)

            TransportBar(audio: audio)
            StatusFooter(audio: audio)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .background(WindowAccessor { _ in })
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
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
                window.backgroundColor = NSColor(red: 0x14/255, green: 0x15/255, blue: 0x17/255, alpha: 1)
                window.appearance = NSAppearance(named: .darkAqua)
                window.styleMask.insert(.fullSizeContentView)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}