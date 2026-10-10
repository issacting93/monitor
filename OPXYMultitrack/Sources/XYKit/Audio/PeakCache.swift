// PeakCache.swift — waveform overviews. One peak value per 512 frames, computed once per asset
// and cached in the package's Peaks folder, so drawing never reads audio.

import AVFoundation
import Foundation

public final class PeakCache: ObservableObject {
    public static let framesPerBucket = 512

    /// Bumped whenever new peaks arrive so clip views redraw.
    @Published public private(set) var revision = 0
    private var store: [UUID: [Float]] = [:]
    private let queue = DispatchQueue(label: "opxy.peaks", qos: .utility)

    public func peaks(_ assetID: UUID) -> [Float]? { store[assetID] }

    public func set(_ assetID: UUID, peaks: [Float], package: ProjectPackage? = nil) {
        store[assetID] = peaks
        revision += 1
        if let package {
            queue.async { Self.write(peaks, to: package.peaksURL(assetID)) }
        }
    }

    public func removeAll() {
        store.removeAll()
        revision += 1
    }

    /// Load cached peaks for every asset, computing any that are missing. Runs off the main thread.
    public func load(project: Project, package: ProjectPackage) {
        for asset in project.assets where store[asset.id] == nil {
            let cacheURL = package.peaksURL(asset.id)
            let audioURL = package.audioURL(asset)
            queue.async { [weak self] in
                var peaks = Self.read(cacheURL)
                if peaks == nil, let computed = try? Self.compute(audioURL) {
                    Self.write(computed, to: cacheURL)
                    peaks = computed
                }
                guard let peaks else { return }
                DispatchQueue.main.async {
                    self?.store[asset.id] = peaks
                    self?.revision += 1
                }
            }
        }
    }

    public static func compute(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
        var accumulator = PeakAccumulator()
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            accumulator.append(buffer, from: 0)
        }
        return accumulator.finish()
    }

    private static func read(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func write(_ peaks: [Float], to url: URL) {
        let data = peaks.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url, options: .atomic)
    }
}

/// Folds audio into one absolute peak per bucket. Shared by the offline pass above and the live recording tap.
struct PeakAccumulator {
    private(set) var peaks: [Float] = []
    private var current: Float = 0
    private var fill = 0

    mutating func append(_ buffer: AVAudioPCMBuffer, from start: Int) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard start < frames else { return }
        for i in start..<frames {
            var v: Float = 0
            for c in 0..<channels { v = max(v, abs(data[c][i])) }
            current = max(current, v)
            fill += 1
            if fill == PeakCache.framesPerBucket {
                peaks.append(current)
                current = 0
                fill = 0
            }
        }
    }

    func finish() -> [Float] {
        fill > 0 ? peaks + [current] : peaks
    }
}
