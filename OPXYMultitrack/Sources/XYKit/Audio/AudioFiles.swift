// AudioFiles.swift — file formats, import conversion and the offline bounce.

import AVFoundation

enum AudioFiles {
    /// What recordings and imports are stored as: 32-bit float WAV at the project rate, stereo.
    static func wavFloatSettings(sampleRate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
         AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }

    /// A copy of a buffer without its first `start` frames.
    static func slice(_ buffer: AVAudioPCMBuffer, from start: Int) -> AVAudioPCMBuffer? {
        let count = Int(buffer.frameLength) - start
        guard count > 0, let source = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let destination = out.floatChannelData else { return nil }
        for c in 0..<Int(buffer.format.channelCount) {
            memcpy(destination[c], source[c] + start, count * MemoryLayout<Float>.size)
        }
        out.frameLength = AVAudioFrameCount(count)
        return out
    }

    /// Bring any audio file into the package, converted to the project's rate and to stereo.
    /// Returns the duration in seconds.
    static func importFile(_ source: URL, to destination: URL, sampleRate: Double) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw AudioFileError.unsupported
        }
        let output = try AVAudioFile(forWriting: destination, settings: wavFloatSettings(sampleRate: sampleRate),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames: AVAudioFramePosition = 0
        var finished = false
        while !finished {
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if input.framePosition >= input.length {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do { try input.read(into: inBuffer) } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError { throw conversionError }
            if outBuffer.frameLength > 0 {
                try output.write(from: outBuffer)
                frames += AVAudioFramePosition(outBuffer.frameLength)
            }
            if status == .endOfStream || status == .error || outBuffer.frameLength == 0 { finished = true }
        }
        return Double(frames) / sampleRate
    }
}

enum AudioFileError: LocalizedError {
    case unsupported
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: return "That audio format can't be read."
        case .renderFailed: return "The export could not be rendered."
        }
    }
}

public enum ExportFormat {
    case wav, m4a

    public var fileExtension: String { self == .wav ? "wav" : "m4a" }

    func settings(sampleRate: Double) -> [String: Any] {
        switch self {
        case .wav:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        case .m4a:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        }
    }
}

enum Exporter {
    /// Bounce a stretch of the project to a file, faster than real time. Builds its own engine in
    /// offline mode with the same MixGraph the live engine uses: same effects, same mix, same limiter.
    static func export(project: Project, package: ProjectPackage, from start: Double, to end: Double,
                       tail: Double = 2, url: URL, format exportFormat: ExportFormat,
                       registry: EffectRegistry) throws {
        guard end > start,
              let format = AVAudioFormat(standardFormatWithSampleRate: project.sampleRate, channels: 2) else {
            throw AudioFileError.renderFailed
        }
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let graph = MixGraph(engine: engine, format: format, trackCount: Project.trackCount)
        graph.sync(project: project, registry: registry)
        graph.loadFiles(project: project, package: package)
        try engine.start()
        defer { engine.stop() }

        graph.schedule(project: project, segments: [PlaySegment(a: start, b: end, t0: 0)])
        graph.startPlayers(at: nil)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw AudioFileError.renderFailed
        }
        let output = try AVAudioFile(forWriting: url, settings: exportFormat.settings(sampleRate: project.sampleRate),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = AVAudioFramePosition(((end - start + tail) * project.sampleRate).rounded())
        while engine.manualRenderingSampleTime < total {
            let remaining = total - engine.manualRenderingSampleTime
            let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
            switch try engine.renderOffline(count, to: buffer) {
            case .success:
                try output.write(from: buffer)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw AudioFileError.renderFailed
            @unknown default:
                throw AudioFileError.renderFailed
            }
        }
        graph.stopPlayers()
    }
}
