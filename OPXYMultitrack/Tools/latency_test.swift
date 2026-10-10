// latency_test.swift — measure round-trip latency before trusting overdubs.
//
// Setup:  route the Mac's output back into the input you record from. With the OP-XY, send the Mac's
//         audio to it over USB and make sure it passes that audio back; or use a short cable from
//         headphone out to an interface input. Keep the volume low.
// Run:    swift Tools/latency_test.swift
// Read:   run it three or four times. A steady number is what goes into the project's latencyOffsetMs
//         (minus the "reported latency" the app shows in its status bar, which is already applied).
//         A number that jumps between runs means the two devices drift, and the fix is an aggregate
//         device, not an offset.

import AVFoundation

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let inputFormat = engine.inputNode.outputFormat(forBus: 0)
guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
    print("No usable input. Check the default input device and Microphone permission for Terminal.")
    exit(1)
}
let format = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 2)!
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)

// One loud click: a single full-scale sample followed by silence.
let impulse = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
impulse.frameLength = 4800
for c in 0..<2 { impulse.floatChannelData![c][0] = 1.0 }

let threshold: Float = 0.1
var sentHost: UInt64 = 0
var heardHost: UInt64?
let lock = NSLock()

engine.inputNode.installTap(onBus: 0, bufferSize: 256, format: inputFormat) { buffer, when in
    guard let data = buffer.floatChannelData, when.isHostTimeValid else { return }
    lock.lock()
    defer { lock.unlock() }
    guard heardHost == nil, sentHost != 0 else { return }
    for i in 0..<Int(buffer.frameLength) {
        var level: Float = 0
        for c in 0..<Int(buffer.format.channelCount) { level = max(level, abs(data[c][i])) }
        if level > threshold {
            let offset = AVAudioTime.hostTime(forSeconds: Double(i) / buffer.format.sampleRate)
            let host = when.hostTime + offset
            if host > sentHost { heardHost = host }
            return
        }
    }
}

do { try engine.start() } catch {
    print("Could not start audio: \(error.localizedDescription)")
    exit(1)
}

let start = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.5)
lock.lock()
sentHost = start
lock.unlock()
player.scheduleBuffer(impulse, at: nil, options: [])
player.play(at: AVAudioTime(hostTime: start))

Thread.sleep(forTimeInterval: 2.0)
engine.stop()

lock.lock()
let heard = heardHost
lock.unlock()
if let heard {
    let seconds = AVAudioTime.seconds(forHostTime: heard - start)
    print(String(format: "Round-trip latency: %.2f ms (%d samples at %.0f Hz)",
                 seconds * 1000, Int((seconds * inputFormat.sampleRate).rounded()), inputFormat.sampleRate))
} else {
    print("No click came back. Check the loopback routing and the output volume, then run it again.")
}
