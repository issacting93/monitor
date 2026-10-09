// looper.swift — record, loop, overdub and play back a USB audio input (e.g. OP-XY).
//
// Build:  swiftc -O looper.swift -o looper        (recommended)
// Run:    ./looper                (looks for an input whose name contains "XY")
//         ./looper "OP-1"         (or match a different device name)
//         swift looper.swift      (also works, just slower on long loops)
//
// Keys:   SPACE  record / close the loop / overdub one pass / cancel overdub
//         P      stop or restart loop playback
//         U      undo the last layer
//         C      clear everything
//         S      save the current loop mix to the Desktop as a WAV
//         M      toggle live monitoring of the input
//         Q      quit (Ctrl+C also works; both restore your previous default input)
//
// Signal graph (same shape as monitor_ui.swift, which is known to pass audio):
//
//   input ─> mainMixer ─(tap: meter + capture)─> monitorMixer ─┐
//                                                              ├─> outMixer ─> output
//   loop player ───────────────────────────────────────────────┘
//
// There is one loop player. Every layer has exactly the loop's length, the layers
// are summed into one buffer, and a new mix is swapped in at the loop boundary, so
// layers can never drift against each other.

import AVFoundation
import CoreAudio
import Accelerate
import Darwin

// If overdubs land late against the loop (likely with Bluetooth output), raise this.
// It shifts each new layer earlier by this many milliseconds.
let latencyCompensationMs: Double = 0

// ── CoreAudio helpers ───────────────────────────────────────────────────────

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func name(of id: AudioDeviceID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var cfName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName) == noErr,
          let value = cfName?.takeRetainedValue() else { return "(unknown)" }
    return value as String
}

func inputChannels(of id: AudioDeviceID) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func defaultDevice(input: Bool) -> AudioDeviceID {
    var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
    return id
}

@discardableResult
func setDefaultInput(_ id: AudioDeviceID) -> Bool {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var dev = id
    return AudioObjectSetPropertyData(systemObject, &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
}

func deviceOnUnit(_ unit: AudioUnit?) -> AudioDeviceID {
    guard let unit else { return AudioDeviceID(kAudioObjectUnknown) }
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                         kAudioUnitScope_Global, 0, &id, &size)
    return id
}

// ── Looper ──────────────────────────────────────────────────────────────────

struct LooperError: Error, CustomStringConvertible {
    let description: String
}

final class Looper {
    enum Mode { case empty, recording, playing, overdubbing, stopped }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let monitorMixer = AVAudioMixerNode()
    let outMixer = AVAudioMixerNode()
    let format: AVAudioFormat          // stereo float at the input's sample rate
    let sampleRate: Double

    private let lock = NSLock()        // guards everything below (tap thread vs main thread)
    private var mode: Mode = .empty
    private var captured: [[Float]] = [[], []]     // frames being recorded right now
    private var layers: [[[Float]]] = []           // finished layers, each [channel][frame]
    private var loopLength = 0                     // frames
    private var overdubOffset: Int?                // loop position where the overdub began
    private var overdubClosing = false
    private var peak: Float = 0
    private var monitoring = true
    private var note = "Press SPACE to record your first loop"

    init() throws {
        let hw = engine.inputNode.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0,
              let inFormat = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate,
                                           channels: hw.channelCount),
              let loopFormat = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate,
                                             channels: 2) else {
            throw LooperError(description:
                "Input has no usable format. Check microphone permission for Terminal in " +
                "System Settings > Privacy & Security > Microphone.")
        }
        format = loopFormat
        sampleRate = loopFormat.sampleRate

        engine.attach(player)
        engine.attach(monitorMixer)
        engine.attach(outMixer)

        let main = engine.mainMixerNode
        engine.connect(engine.inputNode, to: main, format: inFormat)
        main.outputVolume = 1.0
        engine.connect(main, to: monitorMixer, format: loopFormat)
        engine.connect(monitorMixer, to: outMixer, format: loopFormat)
        engine.connect(player, to: outMixer, format: loopFormat)
        engine.connect(outMixer, to: engine.outputNode, format: nil)

        main.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, when in
            self?.handleTap(buffer, when)
        }

        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw LooperError(description: "Could not start audio: \(error.localizedDescription)")
        }
    }

    // MARK: Capture (runs on the tap thread)

    private func handleTap(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        var blockPeak: Float = 0
        vDSP_maxmgv(data[0], 1, &blockPeak, vDSP_Length(frames))

        lock.lock()
        defer { lock.unlock() }
        peak = blockPeak

        guard mode == .recording || mode == .overdubbing else { return }

        if mode == .overdubbing, overdubOffset == nil {
            overdubOffset = loopPosition(at: when)
        }
        for c in 0..<2 {
            let source = data[min(c, channels - 1)]
            captured[c].append(contentsOf: UnsafeBufferPointer(start: source, count: frames))
        }
        if mode == .overdubbing, !overdubClosing, captured[0].count >= loopLength {
            overdubClosing = true
            DispatchQueue.main.async { [weak self] in self?.finishOverdub() }
        }
    }

    /// Where the loop is, in frames from its start, at a given engine time. Call with the lock held.
    private func loopPosition(at time: AVAudioTime?) -> Int {
        guard loopLength > 0 else { return 0 }
        var playerTime: AVAudioTime?
        if let time { playerTime = player.playerTime(forNodeTime: time) }
        if playerTime == nil, let last = player.lastRenderTime {
            playerTime = player.playerTime(forNodeTime: last)
        }
        guard let playerTime else { return 0 }
        let position = Int(playerTime.sampleTime) % loopLength
        return position < 0 ? position + loopLength : position
    }

    // MARK: Transport (main thread)

    func recordKey() {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .empty:
            captured = [[], []]
            mode = .recording
            note = "Recording — press SPACE again to close the loop"
        case .recording:
            closeFirstLoop()
        case .playing:
            captured = [[], []]
            overdubOffset = nil
            overdubClosing = false
            mode = .overdubbing
            note = "Overdubbing one pass — SPACE cancels"
        case .overdubbing:
            captured = [[], []]
            mode = .playing
            note = "Overdub cancelled"
        case .stopped:
            note = "Press P to start the loop, then SPACE to overdub"
        }
    }

    private func closeFirstLoop() {
        let frames = captured[0].count
        guard frames >= Int(sampleRate * 0.25) else {
            captured = [[], []]
            mode = .empty
            note = "Too short — press SPACE to try again"
            return
        }
        var layer = captured
        captured = [[], []]
        fadeEdges(&layer)
        layers = [layer]
        loopLength = frames
        mode = .playing
        player.stop()
        scheduleMix(atLoopBoundary: false)
        player.play()
        note = "Loop closed — SPACE to overdub"
    }

    private func finishOverdub() {
        lock.lock()
        defer { lock.unlock() }
        overdubClosing = false
        guard mode == .overdubbing, loopLength > 0, captured[0].count >= loopLength else { return }

        let length = loopLength
        var take = captured.map { Array($0[0..<length]) }
        captured = [[], []]
        fadeEdges(&take)

        // The take began partway through the loop, so rotate it to line up with the loop start.
        let compensation = Int(sampleRate * latencyCompensationMs / 1000)
        let raw = (overdubOffset ?? 0) - compensation
        let start = ((raw % length) + length) % length
        let split = length - start
        let layer = take.map { Array($0[split..<length]) + Array($0[0..<split]) }

        layers.append(layer)
        overdubOffset = nil
        mode = .playing
        scheduleMix(atLoopBoundary: true)
        note = "Layer \(layers.count) added — U to undo"
    }

    func playKey() {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .playing, .overdubbing:
            player.stop()
            captured = [[], []]
            mode = .stopped
            note = "Stopped — P to play"
        case .stopped:
            scheduleMix(atLoopBoundary: false)
            player.play()
            mode = .playing
            note = "Playing"
        case .empty, .recording:
            note = "Nothing to play yet — SPACE to record"
        }
    }

    func undoKey() {
        lock.lock()
        defer { lock.unlock() }
        guard mode == .playing || mode == .stopped, !layers.isEmpty else {
            note = "Nothing to undo"
            return
        }
        layers.removeLast()
        if layers.isEmpty {
            resetToEmpty()
            note = "Loop removed — SPACE to record"
        } else {
            if mode == .playing { scheduleMix(atLoopBoundary: true) }
            note = "Removed a layer — \(layers.count) left"
        }
    }

    func clearKey() {
        lock.lock()
        defer { lock.unlock() }
        resetToEmpty()
        note = "Cleared — SPACE to record"
    }

    private func resetToEmpty() {
        player.stop()
        layers = []
        captured = [[], []]
        loopLength = 0
        overdubOffset = nil
        mode = .empty
    }

    func monitorKey() {
        lock.lock()
        defer { lock.unlock() }
        monitoring.toggle()
        monitorMixer.outputVolume = monitoring ? 1 : 0
        note = monitoring ? "Monitoring on" : "Monitoring off (loop still plays)"
    }

    func saveKey() {
        lock.lock()
        defer { lock.unlock() }
        guard !layers.isEmpty, let buffer = makeBuffer(from: mixdown()) else {
            note = "Nothing to save"
            return
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "loop_\(stamp.string(from: Date())).wav"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
            note = "Saved ~/Desktop/\(fileName)"
        } catch {
            note = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: Mixing

    /// Sum every layer into one loop. Call with the lock held.
    private func mixdown() -> [[Float]] {
        var out = [[Float]](repeating: [Float](repeating: 0, count: loopLength), count: 2)
        for layer in layers {
            for c in 0..<2 { out[c] = vDSP.add(out[c], layer[c]) }
        }
        for c in 0..<2 { out[c] = vDSP.clip(out[c], to: -1...1) }
        return out
    }

    private func makeBuffer(from samples: [[Float]]) -> AVAudioPCMBuffer? {
        let frames = samples[0].count
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<2 {
            samples[c].withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    memcpy(channels[c], base, frames * MemoryLayout<Float>.size)
                }
            }
        }
        return buffer
    }

    /// Queue the current mix. With atLoopBoundary the swap waits for the running pass to
    /// finish, which keeps the loop phase intact.
    private func scheduleMix(atLoopBoundary: Bool) {
        guard let buffer = makeBuffer(from: mixdown()) else { return }
        let options: AVAudioPlayerNodeBufferOptions = atLoopBoundary ? [.loops, .interruptsAtLoop]
                                                                     : [.loops]
        player.scheduleBuffer(buffer, at: nil, options: options, completionHandler: nil)
    }

    /// 5 ms fade at both ends so the loop seam doesn't click.
    private func fadeEdges(_ samples: inout [[Float]]) {
        let frames = samples[0].count
        let fade = min(Int(sampleRate * 0.005), frames / 2)
        guard fade > 0 else { return }
        for c in 0..<samples.count {
            for i in 0..<fade {
                let gain = Float(i) / Float(fade)
                samples[c][i] *= gain
                samples[c][frames - 1 - i] *= gain
            }
        }
    }

    // MARK: Device changes

    private func handleConfigurationChange() {
        lock.lock()
        defer { lock.unlock() }
        engine.connect(outMixer, to: engine.outputNode, format: nil)
        do {
            try engine.start()
        } catch {
            note = "Audio device changed and the engine could not restart: \(error.localizedDescription)"
            return
        }
        if mode == .playing || mode == .overdubbing {
            captured = [[], []]
            mode = .playing
            player.stop()
            scheduleMix(atLoopBoundary: false)
            player.play()
        } else if mode == .recording {
            captured = [[], []]
            mode = .empty
        }
        note = "Audio device changed — engine restarted"
    }

    // MARK: Display

    func statusLine() -> String {
        lock.lock()
        defer { lock.unlock() }

        let label: String
        switch mode {
        case .empty:       label = "EMPTY  "
        case .recording:   label = "REC  ● "
        case .playing:     label = "PLAY ▶ "
        case .overdubbing: label = "DUB  ● "
        case .stopped:     label = "STOP ■ "
        }

        let db: Float = peak > 0 ? 20 * log10(peak) : -60
        let filled = Int(max(0, min(1, (db + 60) / 60)) * 20)
        let meter = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)

        var details: [String] = []
        if mode == .recording {
            details.append(String(format: "%.1fs", Double(captured[0].count) / sampleRate))
        }
        if loopLength > 0 {
            let length = Double(loopLength) / sampleRate
            if mode == .playing || mode == .overdubbing {
                let position = Double(loopPosition(at: nil)) / sampleRate
                details.append(String(format: "%.1f/%.1fs", position, length))
            } else {
                details.append(String(format: "loop %.1fs", length))
            }
            details.append("\(layers.count) layer\(layers.count == 1 ? "" : "s")")
        }
        if !monitoring { details.append("monitor off") }

        let info = details.isEmpty ? "" : "  " + details.joined(separator: " · ")
        return "  \(label) [\(meter)]\(info)  —  \(note)"
    }

    func stop() {
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }
}

// ── Pick the input device ───────────────────────────────────────────────────

let query = CommandLine.arguments.dropFirst().first ?? "XY"
let inputs = allDevices().filter { inputChannels(of: $0) > 0 }

guard let device = inputs.first(where: { name(of: $0).localizedCaseInsensitiveContains(query) }) else {
    print("No audio input matching \"\(query)\". Inputs found:")
    inputs.forEach { print("  - \(name(of: $0))") }
    exit(1)
}

let outputDevice = defaultDevice(input: false)
if outputDevice == device {
    print("The Mac's sound output is set to \(name(of: device)), the same device you're recording,")
    print("so you would hear nothing. Choose speakers or headphones in")
    print("System Settings > Sound > Output, then run this again.")
    exit(1)
}

// ── Make it the default input while running (restored on exit) ──────────────

let previousInput = defaultDevice(input: true)

func restoreInput() {
    if previousInput != device, previousInput != AudioDeviceID(kAudioObjectUnknown) {
        setDefaultInput(previousInput)
    }
}

if previousInput != device {
    guard setDefaultInput(device) else {
        print("Could not make \(name(of: device)) the default input.")
        print("Select it in System Settings > Sound > Input, then run this again.")
        exit(1)
    }
    Thread.sleep(forTimeInterval: 0.5)   // let CoreAudio apply the change before the engine reads it
}

// ── Start the looper ────────────────────────────────────────────────────────

let looper: Looper
do {
    looper = try Looper()
} catch {
    print("\(error)")
    restoreInput()
    exit(1)
}

print("Input:   \(name(of: device)) (\(Int(looper.sampleRate)) Hz)")
print("Output:  \(name(of: outputDevice))")
print("Engine:  input on \"\(name(of: deviceOnUnit(looper.engine.inputNode.audioUnit)))\", " +
      "output on \"\(name(of: deviceOnUnit(looper.engine.outputNode.audioUnit)))\"")
print("")
print("SPACE record/overdub   P play/stop   U undo   C clear   S save   M monitor   Q quit")
print("")

// ── Terminal: read single keys without Enter ────────────────────────────────

var savedTerminal = termios()
let terminalIsInteractive = isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &savedTerminal) == 0
if terminalIsInteractive {
    var raw = savedTerminal
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}

func shutdown() -> Never {
    if terminalIsInteractive { tcsetattr(STDIN_FILENO, TCSANOW, &savedTerminal) }
    looper.stop()
    restoreInput()
    print("\nStopped. Default input restored to \(name(of: defaultDevice(input: true))).")
    exit(0)
}

let keySource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
keySource.setEventHandler {
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { return }
    switch Character(UnicodeScalar(byte)) {
    case " ", "r", "R": looper.recordKey()
    case "p", "P":      looper.playKey()
    case "u", "U":      looper.undoKey()
    case "c", "C":      looper.clearKey()
    case "s", "S":      looper.saveKey()
    case "m", "M":      looper.monitorKey()
    case "q", "Q":      shutdown()
    default:            break
    }
}
keySource.resume()

// ── Quit cleanly on Ctrl+C, kill, or a closed Terminal window ───────────────

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { shutdown() }
    source.resume()
    signalSources.append(source)
}

// ── Status line ─────────────────────────────────────────────────────────────

let statusTimer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { _ in
    print("\r\u{1B}[K\(looper.statusLine())", terminator: "")
    fflush(stdout)
}
RunLoop.main.add(statusTimer, forMode: .common)

RunLoop.main.run()
