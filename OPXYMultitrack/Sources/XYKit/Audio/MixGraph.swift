// MixGraph.swift — the persistent audio graph for the eight tracks.
//
//   per track:  player ─┐
//                       ├─ pre ─ [effect slots…] ─ fader (volume, pan, mute) ─┐
//   live input ─────────┘  (armed track only)                                  ├─ main ─ limiter ─ out ─ device
//
// Built once per engine. The live engine and the offline exporter both use this class,
// so a bounce goes through exactly the nodes you were listening to.

import AVFoundation

/// A stretch of the project, [a, b), that starts playing at player time t0.
/// Plain playback is one segment. Cycle playback is the first pass plus one segment per repeat.
struct PlaySegment {
    var a: Double
    var b: Double
    var t0: Double
}

final class MixGraph {
    final class Strip {
        let player = AVAudioPlayerNode()
        let pre = AVAudioMixerNode()
        let fader = AVAudioMixerNode()
        var effects: [(slotID: UUID, instance: EffectInstance)] = []
        var shape: [String] = []                     // slot IDs + module IDs, to notice when the chain changed
        var applied: [UUID: [String: Float]] = [:]   // last values sent, so unchanged parameters aren't re-sent
    }

    let engine: AVAudioEngine
    let format: AVAudioFormat
    let strips: [Strip]
    let limiter: AVAudioUnitEffect
    let outMixer = AVAudioMixerNode()
    private var files: [UUID: AVAudioFile] = [:]     // streamed by the players
    private var readers: [UUID: AVAudioFile] = [:]   // second handle per asset for reading fades, so the two never share a read position
    private var sampleRate: Double { format.sampleRate }

    init(engine: AVAudioEngine, format: AVAudioFormat, trackCount: Int) {
        self.engine = engine
        self.format = format
        self.strips = (0..<trackCount).map { _ in Strip() }
        self.limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))

        let main = engine.mainMixerNode
        engine.attach(limiter)
        engine.attach(outMixer)
        for strip in strips {
            engine.attach(strip.player)
            engine.attach(strip.pre)
            engine.attach(strip.fader)
            engine.connect(strip.player, to: strip.pre, fromBus: 0, toBus: 0, format: format)
            engine.connect(strip.pre, to: strip.fader, fromBus: 0, toBus: 0, format: format)
            engine.connect(strip.fader, to: main, format: format)
        }
        engine.connect(main, to: limiter, format: format)
        engine.connect(limiter, to: outMixer, format: format)
        engine.connect(outMixer, to: engine.outputNode, format: nil)   // the engine converts to the device's rate here
    }

    // MARK: Keeping the graph in step with the project

    func sync(project: Project, registry: EffectRegistry) {
        let anySolo = project.tracks.contains { $0.solo }
        for (index, track) in project.tracks.enumerated() where index < strips.count {
            let strip = strips[index]
            let shape = track.fx.map { "\($0.id.uuidString)|\($0.moduleID)" }
            if strip.shape != shape {
                rebuildChain(strip, slots: track.fx, registry: registry)
                strip.shape = shape
            }
            for slot in track.fx {
                guard let instance = strip.effects.first(where: { $0.slotID == slot.id })?.instance,
                      let descriptor = registry.descriptor(slot.moduleID) else { continue }
                var applied = strip.applied[slot.id] ?? [:]
                let bypass: Float = slot.bypass ? 1 : 0
                if applied["__bypass"] != bypass {
                    instance.setBypass(slot.bypass)
                    applied["__bypass"] = bypass
                }
                for parameter in descriptor.parameters {
                    let value = slot.value(for: parameter)
                    if applied[parameter.id] != value {
                        instance.setParameter(parameter.id, value: value)
                        applied[parameter.id] = value
                    }
                }
                strip.applied[slot.id] = applied
            }
            let silenced = track.mute || (anySolo && !track.solo)
            strip.fader.outputVolume = silenced ? 0 : Float(track.volume)
            strip.fader.pan = Float(track.pan)
        }
        engine.mainMixerNode.outputVolume = Float(project.masterVolume)
    }

    /// Replace a track's effect chain. Called when a slot is added, removed or reordered:
    /// the whole chain for that one track is rebuilt, which is simple and correct, and costs
    /// a brief dropout on that track if audio is playing.
    private func rebuildChain(_ strip: Strip, slots: [EffectSlot], registry: EffectRegistry) {
        for effect in strip.effects { engine.detach(effect.instance.node) }
        strip.effects = []
        strip.applied = [:]

        var previous: AVAudioNode = strip.pre
        for slot in slots {
            // A slot whose module isn't installed is skipped here; the audio passes straight through.
            guard let instance = registry.descriptor(slot.moduleID)?.make(format) else { continue }
            engine.attach(instance.node)
            engine.connect(previous, to: instance.node, fromBus: 0, toBus: 0, format: format)
            strip.effects.append((slot.id, instance))
            previous = instance.node
        }
        engine.connect(previous, to: strip.fader, fromBus: 0, toBus: 0, format: format)
    }

    // MARK: Files

    /// Open every asset the project uses. Assets that are missing or in the wrong format are left out
    /// and their clips stay silent.
    func loadFiles(project: Project, package: ProjectPackage) {
        for asset in project.assets where files[asset.id] == nil {
            guard let file = try? AVAudioFile(forReading: package.audioURL(asset)) else { continue }
            let f = file.processingFormat
            guard f.channelCount == format.channelCount, f.sampleRate == format.sampleRate else {
                print("[Graph] \(asset.fileName) is \(f.sampleRate) Hz / \(f.channelCount) ch; expected the project format")
                continue
            }
            files[asset.id] = file
            readers[asset.id] = try? AVAudioFile(forReading: package.audioURL(asset))
        }
    }

    // MARK: Scheduling

    func schedule(project: Project, segments: [PlaySegment]) {
        for (index, track) in project.tracks.enumerated() where index < strips.count {
            for clip in track.clips {
                guard let file = files[clip.assetID] else { continue }
                for segment in segments {
                    schedule(clip, file: file, reader: readers[clip.assetID] ?? file,
                             on: strips[index].player, segment: segment)
                }
            }
        }
    }

    private func frames(_ seconds: Double) -> AVAudioFramePosition {
        AVAudioFramePosition((seconds * sampleRate).rounded())
    }

    private func schedule(_ clip: Clip, file: AVAudioFile, reader: AVAudioFile,
                          on player: AVAudioPlayerNode, segment: PlaySegment) {
        let lengthF = frames(clip.length)
        guard lengthF > 0 else { return }
        let offsetF = frames(clip.offset)
        let segmentStartF = frames(segment.a)
        let segmentEndF = segment.b.isFinite ? frames(segment.b) : AVAudioFramePosition.max
        let playerBaseF = frames(segment.t0)
        let fadeInF = min(frames(clip.fadeIn), lengthF / 2)
        let fadeOutF = min(frames(clip.fadeOut), lengthF / 2)
        let unityGain = abs(clip.gain - 1) < 0.0001

        for repetition in 0..<max(1, clip.loopCount) {
            let repStartF = frames(clip.start) + AVAudioFramePosition(repetition) * lengthF
            // The part of this repetition that falls inside the segment, as frames local to the repetition.
            let u0 = max(0, segmentStartF - repStartF)
            var u1 = min(lengthF, segmentEndF - repStartF)
            u1 = min(u1, file.length - offsetF)                       // never read past the end of the file
            guard u1 > u0 else { continue }

            func playerTime(_ u: AVAudioFramePosition) -> AVAudioTime {
                AVAudioTime(sampleTime: playerBaseF + repStartF + u - segmentStartF, atRate: sampleRate)
            }
            func plain(_ from: AVAudioFramePosition, _ to: AVAudioFramePosition) {
                guard to > from else { return }
                player.scheduleSegment(file, startingFrame: offsetF + from,
                                       frameCount: AVAudioFrameCount(to - from), at: playerTime(from))
            }
            func processed(_ from: AVAudioFramePosition, _ to: AVAudioFramePosition) {
                guard to > from,
                      let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(to - from)) else { return }
                reader.framePosition = offsetF + from
                guard (try? reader.read(into: buffer, frameCount: AVAudioFrameCount(to - from))) != nil,
                      buffer.frameLength > 0, let data = buffer.floatChannelData else { return }
                for i in 0..<Int(buffer.frameLength) {
                    let u = from + AVAudioFramePosition(i)
                    var gain = Float(clip.gain)
                    if fadeInF > 0, u < fadeInF { gain *= Float(u) / Float(fadeInF) }
                    if fadeOutF > 0, u >= lengthF - fadeOutF { gain *= Float(lengthF - u) / Float(fadeOutF) }
                    for c in 0..<Int(buffer.format.channelCount) { data[c][i] *= gain }
                }
                player.scheduleBuffer(buffer, at: playerTime(from), options: [])
            }

            if unityGain {
                // Only the fades need touching: read those into memory and stream the middle from disk.
                let headEnd = min(u1, max(u0, fadeInF))
                let tailStart = max(headEnd, min(u1, lengthF - fadeOutF))
                processed(u0, headEnd)
                plain(headEnd, tailStart)
                processed(tailStart, u1)
            } else {
                processed(u0, u1)
            }
        }
    }

    func startPlayers(at time: AVAudioTime?) {
        for strip in strips { strip.player.play(at: time) }
    }

    func stopPlayers() {
        for strip in strips { strip.player.stop() }
    }
}
