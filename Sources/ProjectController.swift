// ProjectController.swift — .xyproj package save/load
//
// Owns project serialization: writing the project.json manifest + copied audio
// into the package directory, decoding it back, and applying the restored session
// state to the running app. The published project state (projectURL, projectName,
// projectDirty) stays on AudioManager and is written through the `manager` reference.

import Foundation
#if os(macOS)
import AppKit
#endif
import AVFoundation
import UniformTypeIdentifiers

final class ProjectController {
    private unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    // MARK: - Save

    func save(completion: ((Bool) -> Void)? = nil) {
        if let url = manager.projectURL {
            performSave(to: url, completion: completion)
        } else {
            saveAs(completion: completion)
        }
    }

    func saveAs(completion: ((Bool) -> Void)? = nil) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.nameFieldStringValue = manager.projectName
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destURL = panel.url else {
                completion?(false)          // cancelled — save did not happen
                return
            }
            DispatchQueue.main.async {
                var url = destURL
                if url.pathExtension != "xyproj" {
                    url = url.appendingPathExtension("xyproj")
                }
                self?.performSave(to: url, completion: completion)
            }
        }
        #else
        manager.status = "Project save is not available on iPad yet"
        completion?(false)
        #endif
    }

    private func performSave(to packageURL: URL, completion: ((Bool) -> Void)? = nil) {
        let m = manager

        // Serialize on the main thread — it reads the live session — then hand the
        // manifest and the list of files to copy to the background. Copying every clip
        // is what makes a save slow, and a project can hold a lot of audio.
        let data = buildProjectData()
        let copies: [(src: URL, dest: URL)] = m.tracks.flatMap { t in
            t.clips.map { clip in
                (clip.url,
                 packageURL.appendingPathComponent("Audio/Track \(t.id + 1)/\(clip.url.lastPathComponent)"))
            }
        }

        m.status = "Saving \(packageURL.lastPathComponent)…"
        m.runOffMain(busy: "Saving project…") { () -> String? in
            let fm = FileManager.default

            // Create package directory
            try? fm.createDirectory(at: packageURL, withIntermediateDirectories: true)

            // Copy audio files into Audio/ subdirectory. The copies stay best-effort, as
            // before: a clip that cannot be copied leaves the manifest describing it,
            // which the load path already reports as a missing file.
            for copy in copies {
                try? fm.createDirectory(at: copy.dest.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                if !fm.fileExists(atPath: copy.dest.path) {
                    try? fm.copyItem(at: copy.src, to: copy.dest)
                }
            }

            // Serialize project data
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let jsonData = try encoder.encode(data)
                try jsonData.write(to: packageURL.appendingPathComponent("project.json"))
                return nil
            } catch {
                return error.localizedDescription
            }
        } apply: { [weak self] error in
            guard let self else { return }
            if let error {
                self.manager.status = "Save error: \(error)"
                completion?(false)
                return
            }
            self.manager.projectURL = packageURL
            self.manager.projectName = packageURL.deletingPathExtension().lastPathComponent
            self.manager.projectDirty = false
            self.manager.status = "Saved \(self.manager.projectName)"
            // Only here, in the branch that actually wrote the file: the failure path
            // above returns before this, so a cancelled panel or a write error cannot
            // put a URL in Open Recent that nothing was ever saved to.
            self.manager.noteRecentProject(packageURL)
            completion?(true)
        }
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
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // The exported identifier first — it is the type the bundle declares, and the
        // one `UTExportedTypeDeclarations` names (`com.tape08.xyproj`) — then the
        // extension, so a build without the declaration still lets a project be picked.
        // `UTType(_:)` here is the failable `init?(identifier:)`; `UTType(exportedAs:)`
        // is the one that traps when the type is undeclared, which is exactly the case
        // this chain exists to survive.
        panel.allowedContentTypes = [UTType("com.tape08.xyproj")
                                     ?? UTType(filenameExtension: "xyproj")
                                     ?? .folder]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.performLoad(from: url)
            }
        }
        #else
        manager.status = "Project load is not available on iPad yet"
        #endif
    }

    /// Loads a project the app was handed rather than asked for: the URL from a Finder
    /// double-click on a `.xyproj`, or one chosen from File ▸ Open Recent.
    ///
    /// Deliberately the *same* `performLoad` the panel uses. These URLs are not more
    /// trusted than a panel's — a recent-document entry is a path out of `UserDefaults`
    /// that may now be anything — so a second entry point that skipped validation would
    /// be a way around the manifest checks `resolveInPackage` performs. It defers to the
    /// next main-queue turn for the same reason the panel does: `performLoad` tears the
    /// session down and rebuilds it, which must not happen inside a menu or event dispatch.
    func open(at url: URL) {
        #if os(macOS)
        DispatchQueue.main.async { [weak self] in
            self?.performLoad(from: url)
        }
        #else
        manager.status = "Project load is not available on iPad yet"
        #endif
    }

    private func performLoad(from packageURL: URL) {
        let m = manager
        let jsonURL = packageURL.appendingPathComponent("project.json")
        let fm = FileManager.default

        // Checked before the manifest, because Open Recent makes a *deleted* project
        // reachable: its entry stays in the list, and reporting "missing project.json"
        // for a folder that is not there at all describes the wrong problem.
        guard fm.fileExists(atPath: packageURL.path) else {
            m.status = "Project not found: \(packageURL.lastPathComponent)"
            return
        }

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
        var escapedFiles: [String] = []
        for td in proj.tracks where td.index < Theme.trackCount {
            for cd in td.clips {
                guard let fileURL = resolveInPackage(cd.relativePath, packageURL: packageURL) else {
                    escapedFiles.append(cd.relativePath)
                    continue
                }
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
                self?.applyLoaded(proj, packageURL: packageURL, builtClips: built,
                                  missingFiles: missingFiles, escapedFiles: escapedFiles)
            }
        }
    }

    /// Resolves a manifest path against the package root, or nil when it escapes it.
    ///
    /// `relativePath` comes straight out of `project.json` — a file on disk anyone can
    /// edit — and whatever it names is read and decoded into a clip, so a path like
    /// `../../Documents/notes.wav` has to be refused rather than followed. An absolute
    /// path and the `.`/`..` traversal components are rejected outright; the containment
    /// check afterwards catches what those miss, which is a symlink inside the package
    /// pointing out of it — that is why the comparison is on the *resolved* path.
    private func resolveInPackage(_ relativePath: String, packageURL: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }

        // Both sides are resolved before comparing: the package itself can be reached
        // through a symlink (/tmp is one on macOS), and an unresolved root would then
        // fail to match its own children.
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let resolved = root.appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPath) else { return nil }
        return resolved
    }

    // Applies a decoded project on the main thread, after the off-main clip peak
    // decode in `performLoad`.
    private func applyLoaded(_ proj: ProjectData, packageURL: URL,
                             builtClips: [(trackIndex: Int, clip: TrackClip)],
                             missingFiles: [String], escapedFiles: [String]) {
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
        // The loaded project's clips are all new identities, so the previous selection
        // cannot resolve and is dropped rather than left to fall back silently.
        m.selectedClipID = nil
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
        // Recorded at the end of a load that got this far, so an unreadable or
        // malformed package is never added by the act of failing to open it. This is
        // what makes a Finder double-click show up in Open Recent next launch.
        m.noteRecentProject(packageURL)

        // Report both kinds of dropped clip rather than loading quietly short: a missing
        // file is a moved project, a path outside the package is a manifest that was
        // hand-edited, and the user should be able to tell which they are looking at.
        var notes: [String] = []
        if !missingFiles.isEmpty {
            notes.append("\(missingFiles.count) missing file\(missingFiles.count == 1 ? "" : "s")")
        }
        if !escapedFiles.isEmpty {
            notes.append("\(escapedFiles.count) path\(escapedFiles.count == 1 ? "" : "s") outside the project")
        }
        m.status = notes.isEmpty
            ? "Loaded \(m.projectName)"
            : "Loaded \(m.projectName) (\(notes.joined(separator: ", ")))"
    }
}
