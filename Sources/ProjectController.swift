// ProjectController.swift — .xyproj package save/load
//
// Owns project serialization: writing the project.json manifest + copied audio
// into the package directory, decoding it back, and applying the restored session
// state to the running app. The published project state (projectURL, projectName,
// projectDirty) stays on AudioManager and is written through the `manager` reference.

import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class ProjectController {
    private unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    // MARK: - Save

    func save() {
        if let url = manager.projectURL {
            performSave(to: url)
        } else {
            saveAs()
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.nameFieldStringValue = manager.projectName
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destURL = panel.url else { return }
            DispatchQueue.main.async {
                var url = destURL
                if url.pathExtension != "xyproj" {
                    url = url.appendingPathExtension("xyproj")
                }
                self?.performSave(to: url)
            }
        }
    }

    private func performSave(to packageURL: URL) {
        let m = manager
        let fm = FileManager.default

        // Create package directory
        try? fm.createDirectory(at: packageURL, withIntermediateDirectories: true)

        // Copy audio files into Audio/ subdirectory
        for t in m.tracks {
            guard !t.clips.isEmpty else { continue }
            let trackAudioDir = packageURL.appendingPathComponent("Audio/Track \(t.id + 1)")
            try? fm.createDirectory(at: trackAudioDir, withIntermediateDirectories: true)
            for clip in t.clips {
                let destFile = trackAudioDir.appendingPathComponent(clip.url.lastPathComponent)
                if !fm.fileExists(atPath: destFile.path) {
                    try? fm.copyItem(at: clip.url, to: destFile)
                }
            }
        }

        // Serialize project data
        let data = buildProjectData()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let jsonData = try encoder.encode(data)
            let jsonURL = packageURL.appendingPathComponent("project.json")
            try jsonData.write(to: jsonURL)
        } catch {
            m.status = "Save error: \(error.localizedDescription)"
            return
        }

        m.projectURL = packageURL
        m.projectName = packageURL.deletingPathExtension().lastPathComponent
        m.projectDirty = false
        m.status = "Saved \(m.projectName)"
    }

    private func buildProjectData() -> ProjectData {
        let m = manager
        var trackDataList: [ProjectTrackData] = []
        for t in m.tracks {
            let clipDataList = t.clips.map { clip -> ProjectClipData in
                let fileName = clip.url.lastPathComponent
                return ProjectClipData(relativePath: "Audio/Track \(t.id + 1)/\(fileName)",
                                       duration: clip.duration)
            }
            trackDataList.append(ProjectTrackData(
                index: t.id,
                clips: clipDataList,
                volume: t.volume,
                pan: t.pan,
                muted: t.muted,
                solo: t.solo
            ))
        }

        let chainData = m.liveChain.map { slot in
            ProjectChainSlotData(moduleID: slot.moduleID, enabled: slot.enabled, parameters: slot.parameters)
        }

        return ProjectData(
            bpm: m.metronomeBPM,
            metronomeEnabled: m.metronomeEnabled,
            metronomeVolume: m.metronomeVolume,
            quantizeMode: m.quantizeMode,
            countInBars: m.countInBars,
            loopEnabled: m.loopEnabled,
            masterVolume: m.volume,
            inputVolume: m.inputVolume,
            selectedTrack: m.selectedTrack,
            tracks: trackDataList,
            effectChain: chainData,
            masterLimiterEnabled: m.masterLimiterEnabled
        )
    }

    // MARK: - Load

    func open() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "xyproj") ?? .folder]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.performLoad(from: url)
            }
        }
    }

    private func performLoad(from packageURL: URL) {
        let m = manager
        let jsonURL = packageURL.appendingPathComponent("project.json")
        let fm = FileManager.default

        guard fm.fileExists(atPath: jsonURL.path) else {
            m.status = "Not a valid project: missing project.json"
            return
        }

        let decoder = JSONDecoder()
        let proj: ProjectData
        do {
            let jsonData = try Data(contentsOf: jsonURL)
            proj = try decoder.decode(ProjectData.self, from: jsonData)
        } catch {
            m.status = "Load error: \(error.localizedDescription)"
            return
        }

        // Stop current playback
        m.stopAll()

        // Restore session state
        m.metronomeBPM = proj.bpm
        m.metronomeEnabled = proj.metronomeEnabled
        m.metronomeVolume = proj.metronomeVolume ?? 0.45
        m.quantizeMode = proj.quantizeMode
        m.countInBars = proj.countInBars
        m.loopEnabled = proj.loopEnabled
        m.applyVolume(proj.masterVolume)
        m.applyInputVolume(proj.inputVolume)
        m.masterLimiterEnabled = proj.masterLimiterEnabled ?? true
        m.selectedTrack = min(proj.selectedTrack, Theme.trackCount - 1)

        // Resolve which clip files exist and collect the peak-decode work. Peak
        // buckets are computed off the main thread below (a project can hold many
        // long clips; reading them on the main thread stalls the UI on open).
        var plan: [(trackIndex: Int, duration: Double, url: URL)] = []
        var missingFiles: [String] = []
        for td in proj.tracks where td.index < Theme.trackCount {
            for cd in td.clips {
                let fileURL = packageURL.appendingPathComponent(cd.relativePath)
                if fm.fileExists(atPath: fileURL.path) {
                    plan.append((td.index, cd.duration, fileURL))
                } else {
                    missingFiles.append(cd.relativePath)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let built: [(trackIndex: Int, clip: TrackClip)] = plan.map { p in
                let peaks = computePeaks(url: p.url, count: Theme.clipPeaks)
                return (p.trackIndex, TrackClip(url: p.url, duration: p.duration, peaks: peaks))
            }
            DispatchQueue.main.async {
                self?.applyLoaded(proj, packageURL: packageURL,
                                  builtClips: built, missingFiles: missingFiles)
            }
        }
    }

    // Applies a decoded project on the main thread, after the off-main clip peak
    // decode in `performLoad`.
    private func applyLoaded(_ proj: ProjectData, packageURL: URL,
                             builtClips: [(trackIndex: Int, clip: TrackClip)],
                             missingFiles: [String]) {
        let m = manager
        var newTracks = (0..<Theme.trackCount).map { TrackInfo(id: $0) }
        for td in proj.tracks where td.index < Theme.trackCount {
            newTracks[td.index].volume = td.volume
            newTracks[td.index].pan = td.pan
            newTracks[td.index].muted = td.muted
            newTracks[td.index].solo = td.solo
        }
        for item in builtClips {
            newTracks[item.trackIndex].clips.append(item.clip)
        }
        m.tracks = newTracks
        m.transport.resetTrackBuffers()

        // Load track buffers for tracks that have clips
        for i in 0..<m.tracks.count where !m.tracks[i].clips.isEmpty {
            m.transport.loadTrackBuffer(i)
        }

        // Restore effect chain
        var newChain: [ChainSlot] = []
        for slotData in proj.effectChain {
            var slot = ChainSlot(moduleID: slotData.moduleID, enabled: slotData.enabled)
            for (key, value) in slotData.parameters { slot.parameters[key] = value }
            newChain.append(slot)
        }
        m.liveChain = newChain

        // Rebuild engine to apply the restored effect chain
        if m.isMonitoring {
            m.stopMonitoring()
            m.startMonitoring()
        }
        m.transport.refreshTrackMixers()

        m.projectURL = packageURL
        m.projectName = packageURL.deletingPathExtension().lastPathComponent
        m.projectDirty = false

        if missingFiles.isEmpty {
            m.status = "Loaded \(m.projectName)"
        } else {
            m.status = "Loaded \(m.projectName) (\(missingFiles.count) missing file\(missingFiles.count == 1 ? "" : "s"))"
        }
    }
}
