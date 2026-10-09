// monitor_ui.swift — OP-XY Monitor: USB audio monitoring, effects & recording
//
// Build:  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
//         swiftc monitor_ui.swift -o monitor_ui
// Run:    ./monitor_ui

import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

// ── Theme ────────────────────────────────────────────────────────────────────

enum Theme {
    static let bg            = Color(red: 0x26/255.0, green: 0x28/255.0, blue: 0x2B/255.0) // #26282B
    static let surface       = Color(red: 0x2F/255.0, green: 0x32/255.0, blue: 0x36/255.0) // #2F3236
    static let line          = Color(red: 0x3A/255.0, green: 0x3D/255.0, blue: 0x42/255.0) // #3A3D42
    static let accent        = Color(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x1F/255.0) // #FF6B1F
    static let textPrimary   = Color(red: 0xEC/255.0, green: 0xEA/255.0, blue: 0xE6/255.0) // #ECEAE6
    static let textSecondary = Color(red: 0x8F/255.0, green: 0x93/255.0, blue: 0x9A/255.0) // #8F939A
    static let textTertiary  = Color(red: 0x5C/255.0, green: 0x60/255.0, blue: 0x66/255.0) // #5C6066
    static let danger        = Color(red: 0xF2/255.0, green: 0x47/255.0, blue: 0x3F/255.0) // #F2473F
    static let eqColor       = Color(red: 0xC9/255.0, green: 0xB4/255.0, blue: 0x5C/255.0) // #C9B45C
    static let reverbColor   = Color(red: 0x7F/255.0, green: 0xCF/255.0, blue: 0xB6/255.0) // #7FCFB6
    static let delayColor    = Color(red: 0x8C/255.0, green: 0x96/255.0, blue: 0xF7/255.0) // #8C96F7
    static let waveGray      = Color(red: 0x7A/255.0, green: 0x7E/255.0, blue: 0x85/255.0) // #7A7E85

    static let waveformCount = 140
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
    var name: String { url.lastPathComponent }
    var durationString: String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}

private let reverbPresets: [(label: String, preset: AVAudioUnitReverbPreset)] = [
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

private func reverbLabel(_ p: AVAudioUnitReverbPreset) -> String {
    reverbPresets.first { $0.preset.rawValue == p.rawValue }?.label ?? "Unknown"
}

// ── AudioManager ─────────────────────────────────────────────────────────────

class AudioManager: ObservableObject {
    // Published state
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

    // Reverb
    @Published var reverbEnabled = false
    @Published var reverbPreset: AVAudioUnitReverbPreset = .mediumHall
    @Published var reverbMix: Double = 40

    // Delay
    @Published var delayEnabled   = false
    @Published var delayTime:     Double = 0.25
    @Published var delayFeedback: Double = 30
    @Published var delayMix:      Double = 25

    // EQ
    @Published var eqEnabled = false
    @Published var eqLow:  Double = 0
    @Published var eqMid:  Double = 0
    @Published var eqHigh: Double = 0

    @Published var recordings: [Recording] = []

    // Audio engine internals
    private var engine:       AVAudioEngine?
    private var reverbNode:   AVAudioUnitReverb?
    private var delayNode:    AVAudioUnitDelay?
    private var eqNode:       AVAudioUnitEQ?
    private var outMixer:     AVAudioMixerNode?
    private var audioFile:    AVAudioFile?
    private var previousDefaultInput: AudioDeviceID?

    // Metering (written from audio thread, read from display timer — benign race)
    private var rawLevel:  Float = 0
    private var rawPeak:   Float = 0
    private var peakHold:  Int   = 0
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

    init() {
        loadDevices()
        setupHardwareListeners()
    }

    deinit {
        if isMonitoring { teardown() }
        displayTimer?.invalidate()
        recordingTimer?.invalidate()
    }

    // MARK: - Devices

    func loadDevices() {
        let all     = enumerateDevices()
        let inputs  = all.filter { channelCount(id: $0.id, input: true) > 0 }
        let outputs = all.filter { channelCount(id: $0.id, input: false) > 0 }

        let apply = { [weak self] in
            guard let self else { return }
            self.inputDevices  = inputs
            self.outputDevices = outputs

            // Re-validate selected input
            if self.selectedInputID == nil ||
               !inputs.contains(where: { $0.id == self.selectedInputID }) {
                self.selectedInputID =
                    inputs.first(where: { $0.name.localizedCaseInsensitiveContains("XY") })?.id
                    ?? inputs.first(where: { $0.name.localizedCaseInsensitiveContains("OP") })?.id
                    ?? inputs.first?.id
            }
            // Re-validate selected output (exclude the input instrument!)
            let playbackOutputs = outputs.filter { $0.id != self.selectedInputID && !$0.name.localizedCaseInsensitiveContains("XY") }
            let preferredOutput = playbackOutputs.first(where: {
                $0.name.localizedCaseInsensitiveContains("speaker") ||
                $0.name.localizedCaseInsensitiveContains("headphone") ||
                $0.name.localizedCaseInsensitiveContains("macbook")
            })?.id ?? playbackOutputs.first?.id ?? outputs.first?.id

            if self.selectedOutputID == nil ||
               !outputs.contains(where: { $0.id == self.selectedOutputID }) ||
               self.selectedOutputID == self.selectedInputID {
                let sysOut = self.currentSystemOutputID()
                if let s = sysOut, playbackOutputs.contains(where: { $0.id == s }) {
                    self.selectedOutputID = s
                } else {
                    self.selectedOutputID = preferredOutput
                }
            }
            if let inName = inputs.first(where: { $0.id == self.selectedInputID })?.name,
               let outName = outputs.first(where: { $0.id == self.selectedOutputID })?.name {
                print("[Monitor] Active Devices — Input: \(inName) | Output: \(outName)")
            }
        }

        // Run synchronously when already on main thread so that callers
        // (init, startMonitoring, Refresh button) see results immediately.
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }

    private func setupHardwareListeners() {
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devAddr, DispatchQueue.main
        ) { [weak self] _, _ in self?.loadDevices() }

        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outAddr, DispatchQueue.main
        ) { [weak self] _, _ in self?.loadDevices() }
    }

    // MARK: - Monitor

    func startMonitoring() {
        // Refresh devices if list is empty or selected input is stale
        if inputDevices.isEmpty || selectedInputID == nil ||
           !inputDevices.contains(where: { $0.id == selectedInputID }) {
            loadDevices()
        }

        guard let inID = selectedInputID
                ?? inputDevices.first(where: { $0.name.localizedCaseInsensitiveContains("XY") })?.id
                ?? inputDevices.first?.id,
              let inDev = inputDevices.first(where: { $0.id == inID })
        else { status = "No input device — connect OP-XY"; return }

        selectedInputID = inID
        startEngine(inputID: inID, outputID: selectedOutputID, failedOutputIDs: [])

        if isMonitoring {
            let outName = selectedOutputID
                .flatMap { id in outputDevices.first { $0.id == id }?.name }
                ?? "system output"
            status = "\(inDev.name) \u{2192} \(outName)"
            startDisplayTimer()
        }
    }

    func stopMonitoring() {
        if isRecording { stopRecording() }
        teardown()
        isMonitoring = false
        displayTimer?.invalidate(); displayTimer = nil
        level = 0; peak = 0
        levelL = 0; levelR = 0; peakL = 0; peakR = 0
        peakDB = -Double.infinity
        waveformSamples = Array(repeating: 0, count: Theme.waveformCount)
        status = "Stopped"
    }

    func switchOutput(to id: AudioDeviceID) {
        selectedOutputID = id
        guard isMonitoring, let inID = selectedInputID else { return }
        let wasRecording = isRecording
        if wasRecording { stopRecording() }
        teardown()
        startEngine(inputID: inID, outputID: id, failedOutputIDs: [])
        if wasRecording { startRecording() }
        let inName  = inputDevices.first { $0.id == inID }?.name ?? "input"
        let outName = outputDevices.first { $0.id == id }?.name ?? "output"
        if isMonitoring { status = "\(inName) \u{2192} \(outName)" }
    }

    func applyVolume(_ v: Double) {
        volume = v
        outMixer?.outputVolume = Float(v)
    }

    // MARK: - Engine lifecycle

    private func startEngine(inputID: AudioDeviceID, outputID: AudioDeviceID?,
                             failedOutputIDs: Set<AudioDeviceID>) {
        var currentFailed = failedOutputIDs
        if let outID = outputID { currentFailed.insert(outID) }

        let eng = AVAudioEngine()

        // 1. Set the input device as the system default input (restored on stop).
        //    Don't pin via AudioUnitSetProperty — that can silently redirect the
        //    output node onto the same device.
        previousDefaultInput = getDefaultInputID()
        setDefaultInput(inputID)
        print("[Monitor] Set default input: \(deviceName(previousDefaultInput ?? 0)) \u{2192} \(deviceName(inputID))")

        // 2. Check output isn't the input device
        let currentOutput = defaultOutputDeviceID()
        if currentOutput == inputID {
            status = "Output is set to \(deviceName(inputID)) \u{2014} change in Sound settings"
            restoreDefaultInput()
            return
        }

        // 3. Query formats — engine uses system defaults for both sides
        let hwFmt = eng.inputNode.inputFormat(forBus: 0)
        let inFmt = AVAudioFormat(standardFormatWithSampleRate: hwFmt.sampleRate,
                                  channels: hwFmt.channelCount) ?? hwFmt
        guard inFmt.sampleRate > 0 else {
            status = "No usable format \u{2014} check Microphone permission"
            restoreDefaultInput()
            return
        }

        let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: inFmt.sampleRate,
                                      channels: 2) ?? inFmt

        print("[Monitor] Input: \(inFmt.sampleRate) Hz \(inFmt.channelCount)ch")
        print("[Monitor] Output: \(deviceName(currentOutput))")

        // Chain: inputNode → mainMixer → EQ → Reverb → Delay → outMixer → outputNode
        let eq      = buildEQ()
        let reverb  = buildReverb()
        let delay   = buildDelay()
        let mixer   = AVAudioMixerNode()
        eng.attach(eq); eng.attach(reverb); eng.attach(delay); eng.attach(mixer)

        eng.connect(eng.inputNode,     to: eng.mainMixerNode, format: inFmt)
        eng.mainMixerNode.outputVolume = 1.0
        eng.connect(eng.mainMixerNode, to: eq,                format: stereoFmt)
        eng.connect(eq,                to: reverb,            format: stereoFmt)
        eng.connect(reverb,            to: delay,             format: stereoFmt)
        eng.connect(delay,             to: mixer,             format: stereoFmt)

        // Let the engine negotiate the output format
        eng.connect(mixer, to: eng.outputNode, format: nil)

        mixer.outputVolume = Float(volume)

        // Metering & recording tap on the output mixer (post-effects)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.processTap(buf)
        }

        eng.prepare()
        do {
            try eng.start()
            print("[Monitor] Engine running — outputNode in: \(eng.outputNode.inputFormat(forBus: 0).sampleRate) Hz")
        } catch {
            print("[Monitor] Engine start FAILED: \(error)")
            handleOutputFailure(inputID: inputID, failedOutputID: outputID,
                                failedOutputIDs: currentFailed,
                                error: error.localizedDescription)
            return
        }

        engine       = eng
        reverbNode   = reverb
        delayNode    = delay
        eqNode       = eq
        outMixer     = mixer
        isMonitoring = true
    }

    private func handleOutputFailure(inputID: AudioDeviceID, failedOutputID: AudioDeviceID?,
                                     failedOutputIDs: Set<AudioDeviceID>, error: String) {
        if let fallback = fallbackOutput(excluding: failedOutputIDs) {
            let failedName = failedOutputID.flatMap { id in
                outputDevices.first { $0.id == id }?.name
            } ?? "output"
            let fbName = outputDevices.first { $0.id == fallback }?.name ?? "built-in"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selectedOutputID = fallback
                self.status = "\(failedName) unavailable \u{2014} routed to \(fbName)"
                self.startEngine(inputID: inputID, outputID: fallback,
                                 failedOutputIDs: failedOutputIDs)
            }
        } else {
            isMonitoring = false
            status = "Output error: \(error)"
        }
    }

    private func teardown() {
        outMixer?.removeTap(onBus: 0)
        engine?.stop()
        engine     = nil
        reverbNode = nil
        delayNode  = nil
        eqNode     = nil
        outMixer   = nil
        restoreDefaultInput()
    }

    private func restoreDefaultInput() {
        if let prev = previousDefaultInput {
            setDefaultInput(prev)
            print("[Monitor] Restored default input: \(deviceName(prev))")
            previousDefaultInput = nil
        }
    }

    // MARK: - Metering

    private func processTap(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        let channels = Int(buf.format.channelCount)

        // RMS of channel 0 (L)
        var sumL: Float = 0
        for i in 0..<n { sumL += data[0][i] * data[0][i] }
        let rmsL = sqrt(sumL / Float(n))

        // RMS of channel 1 (R) — fallback to L if mono
        let rmsR: Float
        if channels > 1 {
            var sumR: Float = 0
            for i in 0..<n { sumR += data[1][i] * data[1][i] }
            rmsR = sqrt(sumR / Float(n))
        } else {
            rmsR = rmsL
        }

        let rms = max(rmsL, rmsR)

        rawLevel  = rms
        rawLevelL = rmsL
        rawLevelR = rmsR

        if rms >= rawPeak { rawPeak = rms; peakHold = 0 }
        else { peakHold += 1; if peakHold > 43 { rawPeak *= 0.93 } }

        if rmsL >= rawPeakL { rawPeakL = rmsL; peakHoldL = 0 }
        else { peakHoldL += 1; if peakHoldL > 43 { rawPeakL *= 0.93 } }

        if rmsR >= rawPeakR { rawPeakR = rmsR; peakHoldR = 0 }
        else { peakHoldR += 1; if peakHoldR > 43 { rawPeakR *= 0.93 } }

        // Write to recording file
        if let file = audioFile { try? file.write(from: buf) }
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            let scaled     = Double(min(self.rawLevel * 5, 1))
            let scaledPeak = Double(min(self.rawPeak * 5, 1))
            let scaledL     = Double(min(self.rawLevelL * 5, 1))
            let scaledR     = Double(min(self.rawLevelR * 5, 1))
            let scaledPeakL = Double(min(self.rawPeakL * 5, 1))
            let scaledPeakR = Double(min(self.rawPeakR * 5, 1))
            let maxPeak     = Double(max(self.rawPeakL, self.rawPeakR))
            DispatchQueue.main.async {
                self.level = self.level * 0.72 + scaled * 0.28
                self.peak  = scaledPeak
                self.levelL = self.levelL * 0.72 + scaledL * 0.28
                self.levelR = self.levelR * 0.72 + scaledR * 0.28
                self.peakL  = scaledPeakL
                self.peakR  = scaledPeakR
                // Peak dB readout
                if maxPeak > 0 {
                    self.peakDB = 20.0 * log10(maxPeak)
                } else {
                    self.peakDB = -Double.infinity
                }
                // Shift waveform buffer
                var samples = self.waveformSamples
                samples.removeFirst()
                samples.append(self.level)
                self.waveformSamples = samples
            }
        }
    }

    // MARK: - Effects — build

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

    // MARK: - Effects — live update

    func applyReverb() {
        reverbNode?.wetDryMix = Float(reverbMix)
        reverbNode?.bypass    = !reverbEnabled
    }
    func changeReverbPreset(_ p: AVAudioUnitReverbPreset) {
        reverbPreset = p
        reverbNode?.loadFactoryPreset(p)
        reverbNode?.wetDryMix = Float(reverbMix)
    }
    func applyDelay() {
        delayNode?.delayTime = delayTime
        delayNode?.feedback  = Float(delayFeedback)
        delayNode?.wetDryMix = Float(delayMix)
        delayNode?.bypass    = !delayEnabled
    }
    func applyEQ() {
        eqNode?.bands[0].gain = Float(eqLow)
        eqNode?.bands[1].gain = Float(eqMid)
        eqNode?.bands[2].gain = Float(eqHigh)
        eqNode?.bypass        = !eqEnabled
    }

    // MARK: - Recording

    func startRecording() {
        guard isMonitoring, let eng = engine else { return }
        let fmt  = eng.mainMixerNode.outputFormat(forBus: 0)
        let name = "recording_\(Self.timestampFmt.string(from: Date())).wav"
        let url  = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/\(name)")
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            recordingStart    = Date()
            recordingDuration = 0
            isRecording       = true
            status            = "Recording \u{2192} \(name)"
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
                [weak self] _ in
                guard let self, let s = self.recordingStart else { return }
                DispatchQueue.main.async { self.recordingDuration = Date().timeIntervalSince(s) }
            }
        } catch {
            status = "Cannot create file: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate(); recordingTimer = nil
        let saved = audioFile?.url
        let dur   = recordingDuration
        audioFile   = nil
        isRecording = false
        if let u = saved {
            status = "Saved \(u.lastPathComponent)"
            DispatchQueue.main.async { self.recordings.append(Recording(url: u, duration: dur)) }
        }
    }

    func removeRecording(_ rec: Recording) {
        recordings.removeAll { $0.id == rec.id }
    }

    // MARK: - CoreAudio helpers

    private func fallbackOutput(excluding badIDs: Set<AudioDeviceID>) -> AudioDeviceID? {
        let candidates = outputDevices.filter { !badIDs.contains($0.id) }
        for kw in ["built-in", "macbook", "imac", "headphone", "speaker", "display"] {
            if let d = candidates.first(where: { $0.name.localizedCaseInsensitiveContains(kw) }) {
                return d.id
            }
        }
        return candidates.first?.id
    }

    private func enumerateDevices() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &sz) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &sz, &ids) == noErr else { return [] }
        return ids.map { AudioDevice(id: $0, name: deviceName($0)) }
    }

    private func deviceName(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &ref) == noErr,
              let v = ref?.takeRetainedValue() else { return "Unknown" }
        return v as String
    }

    private func channelCount(id: AudioDeviceID, input: Bool) -> Int {
        let scope: AudioObjectPropertyScope = input
            ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(sz), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func currentSystemOutputID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = kAudioDeviceUnknown
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &sz, &id) == noErr,
              id != kAudioDeviceUnknown else { return nil }
        return id
    }

    private func defaultOutputDeviceID() -> AudioDeviceID {
        currentSystemOutputID() ?? AudioDeviceID(kAudioDeviceUnknown)
    }

    private func getDefaultInputID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &sz, &id)
        return id
    }

    private func setDefaultInput(_ id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }
}

// ── WaveformView ─────────────────────────────────────────────────────────────

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

            // Center line at 50%
            context.stroke(
                Path { p in
                    p.move(to: CGPoint(x: 0, y: midY))
                    p.addLine(to: CGPoint(x: size.width, y: midY))
                },
                with: .color(Theme.line.opacity(0.6)),
                lineWidth: 0.5)

            // Draw bars
            for (i, sample) in samples.enumerated() {
                let h = midY * CGFloat(sample)
                guard h > 0.5 else { continue }
                let x = CGFloat(i) * barW
                let w = max(barW - gap, 1)

                // Recent bars (last 20%) use accent color, older bars use gray with fading opacity
                let recentThreshold = Int(Double(samples.count) * 0.8)
                let color: Color
                let opacity: Double
                if i >= recentThreshold {
                    color = Theme.accent
                    opacity = 0.5 + sample * 0.5
                } else {
                    color = Theme.waveGray
                    let fadePos = Double(i) / Double(recentThreshold)
                    opacity = (0.15 + fadePos * 0.45) * (0.3 + sample * 0.7)
                }

                // Upper half
                context.fill(Path(CGRect(x: x, y: midY - h, width: w, height: h)),
                             with: .color(color.opacity(opacity)))
                // Lower half (mirror)
                context.fill(Path(CGRect(x: x, y: midY, width: w, height: h)),
                             with: .color(color.opacity(opacity)))
            }

            // Playhead line at right edge
            if isActive {
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: size.width - 1, y: 0))
                        p.addLine(to: CGPoint(x: size.width - 1, y: size.height))
                    },
                    with: .color(.white.opacity(0.8)),
                    lineWidth: 1)
            }

            // REC IN marker when recording
            if isRecording {
                let markerX = size.width - 60
                context.fill(
                    Path(CGRect(x: markerX, y: 4, width: 52, height: 16)),
                    with: .color(Theme.danger.opacity(0.85)))
                context.draw(
                    Text("REC IN")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white),
                    at: CGPoint(x: markerX + 26, y: 12))
            }
        }
        .background(Theme.bg)

        // Time labels below
        HStack {
            Text("\u{2212}40s")
            Spacer()
            Text("\u{2212}30s")
            Spacer()
            Text("\u{2212}20s")
            Spacer()
            Text("\u{2212}10s")
            Spacer()
            Text("now")
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
                    // Track background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.surface)

                    // Fill bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isActive ? Theme.accent : Theme.waveGray.opacity(0.4))
                        .frame(width: g.size.width * max(level, 0))
                        .animation(.linear(duration: 0.03), value: level)

                    // Peak indicator
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
    let value: Double       // 0...1 normalized
    let bipolar: Bool       // if true, center is zero (e.g. EQ)
    let color: Color
    let label: String
    let displayValue: String

    private let startAngle: Double = 135  // degrees
    private let sweepAngle: Double = 270  // degrees
    private let size: CGFloat = 64

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Gray track arc
                arcPath(from: 0, to: 1)
                    .stroke(Theme.line, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                // Colored value arc
                if bipolar {
                    arcPath(from: 0.5, to: value)
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                } else {
                    arcPath(from: 0, to: value)
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }

                // Center circle
                Circle()
                    .fill(Theme.surface)
                    .frame(width: size * 0.4, height: size * 0.4)

                // White indicator line
                indicatorLine()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .frame(width: size, height: size)

            Text(displayValue)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)

            Text(label)
                .font(.system(size: 9, design: .default))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func angleForValue(_ v: Double) -> Double {
        let clamped = min(max(v, 0), 1)
        return (startAngle + sweepAngle * clamped) * .pi / 180
    }

    private func arcPath(from: Double, to: Double) -> Path {
        let radius = size / 2 - 4
        let center = CGPoint(x: size / 2, y: size / 2)
        let s = min(from, to)
        let e = max(from, to)
        let sAngle = Angle(degrees: startAngle + sweepAngle * s)
        let eAngle = Angle(degrees: startAngle + sweepAngle * e)
        return Path { p in
            p.addArc(center: center, radius: radius,
                     startAngle: sAngle, endAngle: eAngle, clockwise: false)
        }
    }

    private func indicatorLine() -> Path {
        let angle = angleForValue(value)
        let center = CGPoint(x: size / 2, y: size / 2)
        let innerR = size * 0.2
        let outerR = size / 2 - 4
        return Path { p in
            p.move(to: CGPoint(x: center.x + innerR * cos(angle),
                               y: center.y + innerR * sin(angle)))
            p.addLine(to: CGPoint(x: center.x + outerR * cos(angle),
                                  y: center.y + outerR * sin(angle)))
        }
    }
}

// ── ContentView ──────────────────────────────────────────────────────────────

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
                    Text("Monitor")
                        .font(.system(size: 13, design: .default))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Text("48 kHz / 24-bit / 2 ch")
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
                // Live/Rec status
                HStack(spacing: 6) {
                    Circle()
                        .fill(audio.isRecording ? Theme.danger :
                              (audio.isMonitoring ? Theme.accent : Theme.textTertiary))
                        .frame(width: 6, height: 6)

                    HStack(spacing: 2) {
                        Text("Live")
                            .foregroundStyle(audio.isMonitoring && !audio.isRecording
                                             ? Theme.textPrimary : Theme.textTertiary)
                        Text("/")
                            .foregroundStyle(Theme.textTertiary)
                        Text("Rec")
                            .foregroundStyle(audio.isRecording
                                             ? Theme.danger : Theme.textTertiary)
                    }
                    .font(.system(size: 11, weight: .medium, design: .default))
                }

                Text("  \u{2192}  ")
                    .foregroundStyle(Theme.textTertiary)
                    .font(.system(size: 11, design: .default))

                // Input device (clickable)
                Menu {
                    ForEach(audio.inputDevices) { d in
                        Button(d.name) { audio.selectedInputID = d.id }
                    }
                } label: {
                    Text(inputName)
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(audio.isMonitoring)
                .opacity(audio.isMonitoring ? 0.7 : 1)

                Text("  \u{203A}  ")
                    .foregroundStyle(Theme.textTertiary)
                    .font(.system(size: 11, design: .default))

                // Output device (clickable)
                Menu {
                    ForEach(audio.outputDevices) { d in
                        Button(d.name) { if audio.isMonitoring { audio.switchOutput(to: d.id) } else { audio.selectedOutputID = d.id } }
                    }
                } label: {
                    Text(outputName)
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize()

                Spacer()

                // Signal chain
                HStack(spacing: 4) {
                    Text("In")
                        .foregroundStyle(Theme.textTertiary)
                    effectDot(enabled: audio.eqEnabled, color: Theme.eqColor)
                    Text("EQ")
                        .foregroundStyle(Theme.textTertiary)
                    effectDot(enabled: audio.reverbEnabled, color: Theme.reverbColor)
                    Text("Rev")
                        .foregroundStyle(Theme.textTertiary)
                    effectDot(enabled: audio.delayEnabled, color: Theme.delayColor)
                    Text("Dly")
                        .foregroundStyle(Theme.textTertiary)
                    Text("\u{2192}")
                        .foregroundStyle(Theme.textTertiary)
                    Text("Out")
                        .foregroundStyle(Theme.textTertiary)
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 24).padding(.vertical, 6)
            .background(Theme.surface.opacity(0.3))

            // ── Waveform ────────────────────────────────────────
            VStack(spacing: 2) {
                WaveformView(samples: audio.waveformSamples,
                             isActive: audio.isMonitoring,
                             isRecording: audio.isRecording)
                    .frame(height: 120)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 4)

            // ── Meters ──────────────────────────────────────────
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    HorizontalMeter(label: "L", level: audio.levelL, peak: audio.peakL,
                                    isActive: audio.isMonitoring)
                    HorizontalMeter(label: "R", level: audio.levelR, peak: audio.peakR,
                                    isActive: audio.isMonitoring)

                    // dB scale
                    HStack(spacing: 0) {
                        Text(" ")
                            .frame(width: 20) // align with label
                        HStack {
                            Text("-60")
                            Spacer()
                            Text("-36")
                            Spacer()
                            Text("-24")
                            Spacer()
                            Text("-12")
                            Spacer()
                            Text("-6")
                            Spacer()
                            Text("0 dB")
                        }
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    }
                }

                // Peak readout
                VStack(spacing: 2) {
                    Text("PEAK")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    Text(audio.peakDB > -100
                         ? String(format: "%.1f", audio.peakDB)
                         : "-\u{221E}")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(audio.peakDB > -6 ? Theme.danger : Theme.textPrimary)
                    Text("dB")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(width: 70)
            }
            .padding(.horizontal, 24).padding(.vertical, 6)

            // ── Controls Section ────────────────────────────────
            thinDivider()

            HStack(alignment: .top, spacing: 0) {
                // Left column: Routing
                VStack(alignment: .leading, spacing: 10) {
                    routingRow(label: "Input") {
                        Menu {
                            ForEach(audio.inputDevices) { d in
                                Button(d.name) { audio.selectedInputID = d.id }
                            }
                        } label: {
                            Text(inputName)
                                .font(.system(size: 11, design: .default))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(audio.isMonitoring)
                    }

                    routingRow(label: "Output") {
                        Menu {
                            ForEach(audio.outputDevices) { d in
                                Button(d.name) { if audio.isMonitoring { audio.switchOutput(to: d.id) } else { audio.selectedOutputID = d.id } }
                            }
                        } label: {
                            Text(outputName)
                                .font(.system(size: 11, design: .default))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }

                    routingRow(label: "Volume") {
                        HStack(spacing: 4) {
                            Button { audio.applyVolume(max(audio.volume - 0.05, 0)) } label: {
                                Text("\u{2212}")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 22, height: 22)
                                    .background(Theme.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)

                            // Small volume bar
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Theme.surface)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Theme.accent)
                                        .frame(width: g.size.width * audio.volume)
                                }
                            }
                            .frame(width: 60, height: 6)

                            Button { audio.applyVolume(min(audio.volume + 0.05, 1)) } label: {
                                Text("+")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 22, height: 22)
                                    .background(Theme.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)

                            Text("\(Int(audio.volume * 100))%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    routingRow(label: "Save to") {
                        Text("~/Desktop")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

                // Vertical divider
                Rectangle().fill(Theme.line).frame(width: 0.5)

                // Middle column: Effects list
                VStack(alignment: .leading, spacing: 8) {
                    Text("EFFECTS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .tracking(1.5)

                    effectButton(name: "EQ", color: Theme.eqColor,
                                 enabled: audio.eqEnabled, key: "eq")
                    effectButton(name: "Reverb", color: Theme.reverbColor,
                                 enabled: audio.reverbEnabled, key: "reverb")
                    effectButton(name: "Delay", color: Theme.delayColor,
                                 enabled: audio.delayEnabled, key: "delay")
                }
                .frame(width: 140)
                .padding(16)

                // Vertical divider
                Rectangle().fill(Theme.line).frame(width: 0.5)

                // Right column: Effect params
                VStack(alignment: .leading, spacing: 12) {
                    if selectedEffect == "eq" {
                        eqParamsView()
                    } else if selectedEffect == "reverb" {
                        reverbParamsView()
                    } else {
                        delayParamsView()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            }
            .fixedSize(horizontal: false, vertical: true)

            thinDivider()

            // ── Transport + Recordings ──────────────────────────
            HStack(alignment: .top, spacing: 0) {
                // Left: Timer and controls
                VStack(alignment: .leading, spacing: 8) {
                    // Timer
                    Text(formatTimerDuration(audio.recordingDuration))
                        .font(.system(size: 44, weight: .light, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)

                    // Status label
                    HStack(spacing: 5) {
                        if audio.isRecording {
                            Circle().fill(Theme.danger)
                                .frame(width: 6, height: 6)
                                .opacity(recBlink ? 1 : 0.3)
                            Text("REC")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.danger)
                        } else if audio.isMonitoring {
                            Text("READY")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                        } else {
                            Text("IDLE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    Spacer().frame(height: 4)

                    // Transport buttons
                    HStack(spacing: 8) {
                        Button {
                            audio.isMonitoring
                                ? audio.stopMonitoring()
                                : audio.startMonitoring()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: audio.isMonitoring
                                      ? "stop.fill" : "waveform")
                                    .font(.system(size: 11))
                                Text(audio.isMonitoring ? "Stop" : "Monitor")
                                    .font(.system(size: 12, weight: .semibold, design: .default))
                            }
                            .frame(width: 120)
                            .padding(.vertical, 8)
                            .background(audio.isMonitoring ? Theme.surface : Theme.accent)
                            .foregroundStyle(audio.isMonitoring ? Theme.textPrimary : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)

                        Button {
                            audio.isRecording
                                ? audio.stopRecording()
                                : audio.startRecording()
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(audio.isRecording ? Theme.danger : Theme.danger.opacity(0.6))
                                    .frame(width: 8, height: 8)
                                Text(audio.isRecording ? "Stop Rec" : "Record")
                                    .font(.system(size: 12, weight: .semibold, design: .default))
                            }
                            .frame(width: 120)
                            .padding(.vertical, 8)
                            .background(audio.isRecording ? Theme.danger.opacity(0.2) : .clear)
                            .foregroundStyle(audio.isMonitoring
                                             ? (audio.isRecording ? Theme.danger : Theme.textPrimary)
                                             : Theme.textTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(audio.isRecording ? Theme.danger : Theme.line))
                        }
                        .buttonStyle(.plain)
                        .disabled(!audio.isMonitoring)
                        .opacity(audio.isMonitoring ? 1 : 0.5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

                // Vertical divider
                Rectangle().fill(Theme.line).frame(width: 0.5)

                // Right: Recordings list
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("RECORDINGS / \(String(format: "%02d", audio.recordings.count))")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .tracking(1.5)
                        Spacer()
                        Text("WAV \u{00B7} 48 kHz")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    if audio.recordings.isEmpty {
                        Text("No recordings yet")
                            .font(.system(size: 11, design: .default))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 8)
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(audio.recordings) { rec in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Theme.accent)
                                            .frame(width: 5, height: 5)
                                        Text(rec.name)
                                            .font(.system(size: 11, design: .default))
                                            .foregroundStyle(Theme.textPrimary)
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(rec.durationString)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Theme.textSecondary)
                                        Button {
                                            NSWorkspace.shared.selectFile(
                                                rec.url.path,
                                                inFileViewerRootedAtPath: "")
                                        } label: {
                                            Image(systemName: "folder")
                                                .font(.system(size: 10))
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                        .buttonStyle(.plain)
                                        Button { audio.removeRecording(rec) } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(Theme.surface.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .stroke(Theme.line.opacity(0.5)))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .fixedSize(horizontal: false, vertical: true)

            // ── Status Footer ───────────────────────────────────
            thinDivider()
            HStack(spacing: 6) {
                Circle()
                    .fill(audio.isRecording ? Theme.danger :
                          (audio.isMonitoring ? Theme.accent : Theme.textTertiary.opacity(0.4)))
                    .frame(width: 6, height: 6)
                Text(audio.status)
                    .font(.system(size: 10, design: .default))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("In \u{2192} EQ \u{2192} Reverb \u{2192} Delay \u{2192} Out")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
        }
        .background(Theme.bg)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                recBlink = true
            }
        }
    }

    // MARK: - Helper Views

    private func thinDivider() -> some View {
        Rectangle().fill(Theme.line).frame(height: 0.5)
    }

    private func effectDot(enabled: Bool, color: Color) -> some View {
        ZStack {
            if enabled {
                Circle().fill(color).frame(width: 6, height: 6)
            } else {
                Circle().stroke(color.opacity(0.5), lineWidth: 1).frame(width: 6, height: 6)
            }
        }
    }

    private func routingRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 50, alignment: .trailing)
            content()
        }
    }

    private func effectButton(name: String, color: Color, enabled: Bool, key: String) -> some View {
        Button {
            selectedEffect = key
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if enabled {
                        Circle().fill(color).frame(width: 8, height: 8)
                    } else {
                        Circle().stroke(color.opacity(0.5), lineWidth: 1).frame(width: 8, height: 8)
                    }
                }
                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(selectedEffect == key ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selectedEffect == key ? Theme.surface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Effect Parameter Views

    @ViewBuilder
    private func eqParamsView() -> some View {
        HStack(spacing: 20) {
            knobWithDrag(label: "Low", value: audio.eqLow, range: -12...12,
                         bipolar: true, color: Theme.eqColor,
                         display: { ($0 >= 0 ? "+" : "") + "\(Int($0)) dB" },
                         setter: { audio.eqLow = $0; audio.applyEQ() })

            knobWithDrag(label: "Mid", value: audio.eqMid, range: -12...12,
                         bipolar: true, color: Theme.eqColor,
                         display: { ($0 >= 0 ? "+" : "") + "\(Int($0)) dB" },
                         setter: { audio.eqMid = $0; audio.applyEQ() })

            knobWithDrag(label: "High", value: audio.eqHigh, range: -12...12,
                         bipolar: true, color: Theme.eqColor,
                         display: { ($0 >= 0 ? "+" : "") + "\(Int($0)) dB" },
                         setter: { audio.eqHigh = $0; audio.applyEQ() })
        }
        .opacity(audio.eqEnabled ? 1 : 0.35)
        .frame(maxWidth: .infinity)

        effectToggle(name: "EQ", subtitle: "200 Hz \u{00B7} 1 kHz \u{00B7} 8 kHz",
                     color: Theme.eqColor,
                     enabled: Binding(get: { audio.eqEnabled },
                                      set: { audio.eqEnabled = $0; audio.applyEQ() }))
    }

    @ViewBuilder
    private func reverbParamsView() -> some View {
        HStack(spacing: 16) {
            // Preset selector
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        let idx = reverbPresets.firstIndex(where: { $0.preset.rawValue == audio.reverbPreset.rawValue }) ?? 0
                        let prev = (idx - 1 + reverbPresets.count) % reverbPresets.count
                        audio.changeReverbPreset(reverbPresets[prev].preset)
                    } label: {
                        Text("\u{2039}")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Text(reverbLabel(audio.reverbPreset))
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 90)

                    Button {
                        let idx = reverbPresets.firstIndex(where: { $0.preset.rawValue == audio.reverbPreset.rawValue }) ?? 0
                        let next = (idx + 1) % reverbPresets.count
                        audio.changeReverbPreset(reverbPresets[next].preset)
                    } label: {
                        Text("\u{203A}")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                Text("Preset")
                    .font(.system(size: 9, design: .default))
                    .foregroundStyle(Theme.textTertiary)
            }

            knobWithDrag(label: "Wet", value: audio.reverbMix, range: 0...100,
                         bipolar: false, color: Theme.reverbColor,
                         display: { "\(Int($0))%" },
                         setter: { audio.reverbMix = $0; audio.applyReverb() })
        }
        .opacity(audio.reverbEnabled ? 1 : 0.35)
        .frame(maxWidth: .infinity)

        effectToggle(name: "Reverb", subtitle: reverbLabel(audio.reverbPreset),
                     color: Theme.reverbColor,
                     enabled: Binding(get: { audio.reverbEnabled },
                                      set: { audio.reverbEnabled = $0; audio.applyReverb() }))
    }

    @ViewBuilder
    private func delayParamsView() -> some View {
        HStack(spacing: 20) {
            knobWithDrag(label: "Time", value: audio.delayTime, range: 0...1,
                         bipolar: false, color: Theme.delayColor,
                         display: { "\(Int($0 * 1000)) ms" },
                         setter: { audio.delayTime = $0; audio.applyDelay() })

            knobWithDrag(label: "Feedback", value: audio.delayFeedback, range: 0...80,
                         bipolar: false, color: Theme.delayColor,
                         display: { "\(Int($0))%" },
                         setter: { audio.delayFeedback = $0; audio.applyDelay() })

            knobWithDrag(label: "Mix", value: audio.delayMix, range: 0...100,
                         bipolar: false, color: Theme.delayColor,
                         display: { "\(Int($0))%" },
                         setter: { audio.delayMix = $0; audio.applyDelay() })
        }
        .opacity(audio.delayEnabled ? 1 : 0.35)
        .frame(maxWidth: .infinity)

        effectToggle(name: "Delay", subtitle: "\(Int(audio.delayTime * 1000)) ms \u{00B7} \(Int(audio.delayFeedback))% fb",
                     color: Theme.delayColor,
                     enabled: Binding(get: { audio.delayEnabled },
                                      set: { audio.delayEnabled = $0; audio.applyDelay() }))
    }

    private func effectToggle(name: String, subtitle: String, color: Color, enabled: Binding<Bool>) -> some View {
        Button { enabled.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    if enabled.wrappedValue {
                        Circle().fill(color).frame(width: 8, height: 8)
                    } else {
                        Circle().stroke(color.opacity(0.5), lineWidth: 1).frame(width: 8, height: 8)
                    }
                }
                Text(enabled.wrappedValue ? "On" : "Off")
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(enabled.wrappedValue ? Theme.textPrimary : Theme.textTertiary)
                Text("\u{00B7}")
                    .foregroundStyle(Theme.textTertiary)
                Text(name)
                    .font(.system(size: 11, design: .default))
                    .foregroundStyle(Theme.textSecondary)
                Text(subtitle)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(enabled.wrappedValue ? color.opacity(0.1) : Theme.surface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                enabled.wrappedValue ? color.opacity(0.3) : Theme.line))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Draggable Knob Wrapper

    private func knobWithDrag(label: String, value: Double, range: ClosedRange<Double>,
                              bipolar: Bool, color: Color,
                              display: (Double) -> String,
                              setter: @escaping (Double) -> Void) -> some View {
        let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)

        return KnobView(value: normalized, bipolar: bipolar, color: color,
                        label: label, displayValue: display(value))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        let delta = -gesture.translation.height / 150
                        let newNorm = min(max(normalized + delta, 0), 1)
                        let newVal = range.lowerBound + newNorm * (range.upperBound - range.lowerBound)
                        setter(newVal)
                    }
            )
    }

    // MARK: - Formatting

    private func formatTimerDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        let tenths = Int((t - Double(Int(t))) * 10)
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }
}

// ── Entry Point ──────────────────────────────────────────────────────────────

AVCaptureDevice.requestAccess(for: .audio) { granted in
    print("[Monitor] Mic access: \(granted)")
}

let audioManager = AudioManager()
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let rootView = ContentView().environmentObject(audioManager)
let controller = NSHostingController(rootView: rootView)
let window = NSWindow(contentViewController: controller)
window.title = "OP-XY Monitor"
window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
window.setContentSize(NSSize(width: 1200, height: 720))
window.minSize = NSSize(width: 800, height: 500)
window.center()
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.backgroundColor = NSColor(red: 0x26/255.0, green: 0x28/255.0, blue: 0x2B/255.0, alpha: 1)
window.appearance = NSAppearance(named: .darkAqua)
window.isMovableByWindowBackground = true
window.makeKeyAndOrderFront(nil)

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.activate(ignoringOtherApps: true)
app.run()
