// ProjectStore.swift — the one place the project changes.
//
// Views never edit the project directly. They call `perform`, which takes a snapshot for undo,
// applies the change, tells the audio engine, and schedules an autosave.

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

public final class ProjectStore: ObservableObject {
    @Published public private(set) var project: Project
    @Published public private(set) var package: ProjectPackage
    @Published public private(set) var missingAssets: Set<UUID> = []
    @Published public private(set) var isDirty = false
    @Published public private(set) var isExporting = false
    @Published public var selectedTrackID: UUID?
    @Published public var selectedClipID: UUID?
    @Published public var selectedSlotID: UUID?
    @Published public private(set) var armedTrackID: UUID?
    /// Width of the timeline area in points, reported by the view so zoom and follow can use it.
    public var timelineWidth: Double = 800

    public let engine: AudioEngine
    public let peaks = PeakCache()
    public let registry = EffectRegistry.shared

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var coalesceKey: String?
    private var autosave: DispatchWorkItem?
    private var tapTimes: [Date] = []
    private static let lastProjectKey = "lastProjectPath"

    public init() {
        engine = AudioEngine(registry: EffectRegistry.shared)

        // Reopen the last project if it is still there; otherwise start an untitled one.
        var opened: (Project, ProjectPackage)?
        if let path = UserDefaults.standard.string(forKey: Self.lastProjectKey) {
            let candidate = ProjectPackage(url: URL(fileURLWithPath: path))
            if let loaded = try? candidate.load() { opened = (loaded, candidate) }
        }
        if let opened {
            project = opened.0
            package = opened.1
        } else {
            project = Project()
            package = (try? ProjectPackage.makeUntitled())
                ?? ProjectPackage(url: FileManager.default.temporaryDirectory.appendingPathComponent("Untitled.xyproj"))
        }
        selectedTrackID = project.tracks.first?.id

        engine.projectProvider = { [unowned self] in (self.project, self.package) }
        engine.onTake = { [weak self] take in self?.add(take) }
    }

    /// Call once the window exists.
    public func startAudio() {
        missingAssets = package.missingAssets(in: project)
        peaks.load(project: project, package: package)
        engine.start()
    }

    public var timebase: Timebase { project.timebase }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var selectedTrackIndex: Int? { project.trackIndex(selectedTrackID) }

    // MARK: Changing the project

    /// Apply a change. Pass the same `key` for every step of one drag so the whole drag is a single undo.
    /// Pass `reschedule: false` during a drag and call `endGesture()` when it finishes.
    public func perform(_ key: String? = nil, reschedule: Bool = true, _ change: (inout Project) -> Void) {
        var next = project
        change(&next)
        guard next != project else { return }
        if key == nil || key != coalesceKey {
            undoStack.append(project)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        coalesceKey = key
        commit(next, reschedule: reschedule)
    }

    public func endGesture() {
        coalesceKey = nil
        engine.rescheduleIfPlaying()
    }

    private func commit(_ next: Project, reschedule: Bool) {
        let old = project
        project = next
        engine.sync(project: next, old: old, reschedule: reschedule)
        validateSelection()
        markDirty()
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        restore(previous)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        restore(next)
    }

    private func restore(_ snapshot: Project) {
        var snapshot = snapshot
        snapshot.view = project.view                      // undo changes the song, not where you're looking
        coalesceKey = nil
        commit(snapshot, reschedule: true)
    }

    private func validateSelection() {
        if let id = selectedClipID, EditOps.locate(id, in: project) == nil { selectedClipID = nil }
        if let id = selectedSlotID, !project.tracks.contains(where: { $0.fx.contains { $0.id == id } }) {
            selectedSlotID = nil
        }
    }

    /// Zoom and scroll: saved with the project, but not undoable and of no interest to the engine.
    public func setView(_ change: (inout ViewState) -> Void) {
        var view = project.view
        change(&view)
        view.pixelsPerSecond = min(max(view.pixelsPerSecond, 4), 800)
        view.scrollX = max(0, view.scrollX)
        guard view != project.view else { return }
        project.view = view
        markDirty()
    }

    public func zoom(by factor: Double) {
        let centre = project.view.scrollX + timelineWidth / 2 / project.view.pixelsPerSecond
        setView {
            $0.pixelsPerSecond = min(max($0.pixelsPerSecond * factor, 4), 800)
            $0.scrollX = centre - timelineWidth / 2 / $0.pixelsPerSecond
        }
    }

    public func scroll(byPoints points: Double) {
        setView { $0.scrollX += points / $0.pixelsPerSecond }
    }

    public func snapped(_ seconds: Double) -> Double {
        let bypass = NSEvent.modifierFlags.contains(.command)        // hold ⌘ while dragging to ignore the grid
        guard project.snap, !bypass else { return max(0, seconds) }
        return timebase.snap(seconds, pixelsPerSecond: project.view.pixelsPerSecond)
    }

    // MARK: Selection and arming

    public func select(track id: UUID) {
        if selectedTrackID != id { selectedSlotID = nil }
        selectedTrackID = id
        selectedClipID = nil
    }

    public func select(clip id: UUID) {
        selectedClipID = id
        if let location = EditOps.locate(id, in: project) {
            let trackID = project.tracks[location.track].id
            if selectedTrackID != trackID { selectedSlotID = nil }
            selectedTrackID = trackID
        }
    }

    /// Only one track is armed at a time: every track is an overdub of the same instrument.
    public func toggleArm(_ id: UUID) {
        guard !engine.isRecording else { return }
        armedTrackID = armedTrackID == id ? nil : id
        engine.setArmed(index: project.trackIndex(armedTrackID))
        if armedTrackID != nil { select(track: id) }
    }

    // MARK: Transport

    public func togglePlay() {
        if engine.isPlaying { engine.stop() } else { engine.play(from: engine.clock.position) }
    }

    public func returnToStart() {
        engine.seek(to: project.cycle.enabled ? project.cycle.start : 0)
    }

    public func toggleRecord() {
        if engine.isRecording {
            engine.stopRecording()
            return
        }
        // Invisible capture: with nothing armed, R arms the selected track and goes.
        if armedTrackID == nil, let selected = selectedTrackID { toggleArm(selected) }
        guard let armed = armedTrackID else { return }
        engine.record(trackID: armed)
    }

    private func add(_ take: Take) {
        peaks.set(take.asset.id, peaks: take.peaks, package: package)
        perform { p in
            guard let index = p.trackIndex(take.trackID) else { return }
            p.assets.append(take.asset)
            // The new take replaces what was under it on this track, like tape.
            EditOps.clearRange(track: index, from: take.start, to: take.start + take.asset.duration, in: &p)
            p.tracks[index].clips.append(Clip(assetID: take.asset.id, name: take.asset.name,
                                              start: take.start, length: take.asset.duration))
        }
    }

    public func tapTempo() {
        let now = Date()
        if let last = tapTimes.last, now.timeIntervalSince(last) > 2 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 6 { tapTimes.removeFirst() }
        guard tapTimes.count >= 3, let first = tapTimes.first else { return }
        let interval = now.timeIntervalSince(first) / Double(tapTimes.count - 1)
        let bpm = (60 / interval).rounded()
        perform("tap") { $0.bpm = min(max(bpm, 40), 240) }
    }

    // MARK: Clip commands

    public func splitAtPlayhead() {
        let t = engine.currentPosition()
        perform { p in
            if let id = self.selectedClipID {
                EditOps.split(id, at: t, in: &p)
            } else if let index = self.selectedTrackIndex {
                for id in p.tracks[index].clips.map(\.id) { EditOps.split(id, at: t, in: &p) }
            }
        }
    }

    public func duplicateSelected() {
        guard let id = selectedClipID else { return }
        var created: UUID?
        perform { created = EditOps.duplicate(id, in: &$0) }
        if let created { selectedClipID = created }
    }

    public func deleteSelected() {
        if let id = selectedClipID {
            perform { EditOps.delete(id, in: &$0) }
        } else if let slot = selectedSlotID {
            removeSlot(slot)
        }
    }

    // MARK: Effect chain

    public func addEffect(_ moduleID: String) {
        guard let index = selectedTrackIndex else { return }
        let slot = EffectSlot(moduleID: moduleID)
        perform { $0.tracks[index].fx.append(slot) }
        selectedSlotID = slot.id
        selectedClipID = nil
    }

    public func removeSlot(_ id: UUID) {
        perform { p in
            for t in p.tracks.indices { p.tracks[t].fx.removeAll { $0.id == id } }
        }
    }

    public func moveSlot(_ id: UUID, by delta: Int) {
        perform { p in
            for t in p.tracks.indices {
                guard let from = p.tracks[t].fx.firstIndex(where: { $0.id == id }) else { continue }
                let to = min(max(from + delta, 0), p.tracks[t].fx.count - 1)
                if to != from { p.tracks[t].fx.swapAt(from, to) }
            }
        }
    }

    public func updateSlot(_ id: UUID, key: String? = nil, _ change: (inout EffectSlot) -> Void) {
        perform(key, reschedule: false) { p in
            for t in p.tracks.indices {
                if let i = p.tracks[t].fx.firstIndex(where: { $0.id == id }) { change(&p.tracks[t].fx[i]) }
            }
        }
    }

    // MARK: Files

    private func markDirty() {
        isDirty = true
        autosave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeToDisk() }
        autosave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func writeToDisk() {
        autosave?.cancel()
        do {
            try package.save(project)
            isDirty = false
        } catch {
            engine.status = "Could not save: \(error.localizedDescription)"
        }
    }

    private func adopt(_ newProject: Project, _ newPackage: ProjectPackage) {
        engine.stop()
        project = newProject
        package = newPackage
        undoStack.removeAll()
        redoStack.removeAll()
        selectedClipID = nil
        selectedSlotID = nil
        selectedTrackID = newProject.tracks.first?.id
        armedTrackID = nil
        engine.setArmed(index: nil)
        isDirty = false
        peaks.removeAll()
        peaks.load(project: newProject, package: newPackage)
        missingAssets = newPackage.missingAssets(in: newProject)
        if !newPackage.isUntitled { UserDefaults.standard.set(newPackage.url.path, forKey: Self.lastProjectKey) }
        engine.clock.position = 0
        engine.reload()
        if !missingAssets.isEmpty {
            engine.status = "\(missingAssets.count) audio file(s) are missing from this project. Their clips are silent."
        }
    }

    public func newProject() {
        writeToDisk()
        guard let fresh = try? ProjectPackage.makeUntitled() else { return }
        UserDefaults.standard.removeObject(forKey: Self.lastProjectKey)
        adopt(Project(sampleRate: project.sampleRate), fresh)
    }

    public func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true        // a .xyproj is a folder; without an app bundle Finder shows it as one
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .xyproj project"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.lastPathComponent == "project.json" { url.deleteLastPathComponent() }
        writeToDisk()
        do {
            let candidate = ProjectPackage(url: url)
            adopt(try candidate.load(), candidate)
        } catch {
            engine.status = "Could not open: \(error.localizedDescription)"
        }
    }

    public func save() {
        if package.isUntitled { saveAs() } else { writeToDisk() }
    }

    public func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).\(ProjectPackage.fileExtension)"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != ProjectPackage.fileExtension { url.appendPathExtension(ProjectPackage.fileExtension) }
        do {
            project.name = url.deletingPathExtension().lastPathComponent
            try package.save(project)
            package = try package.copy(to: url)
            UserDefaults.standard.set(url.path, forKey: Self.lastProjectKey)
            isDirty = false
            engine.status = "Saved \(url.lastPathComponent)"
        } catch {
            engine.status = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Bring audio files in as clips on a track, starting at a timeline position.
    public func importFiles(_ urls: [URL], trackIndex: Int, at start: Double) {
        let package = self.package
        let sampleRate = project.sampleRate
        DispatchQueue.global(qos: .userInitiated).async {
            var imported: [(Asset, [Float])] = []
            for url in urls {
                let fileName = "\(UUID().uuidString).wav"
                let destination = package.audioDir.appendingPathComponent(fileName)
                guard let duration = try? AudioFiles.importFile(url, to: destination, sampleRate: sampleRate),
                      duration > 0 else { continue }
                let asset = Asset(fileName: fileName, name: url.deletingPathExtension().lastPathComponent,
                                  duration: duration)
                imported.append((asset, (try? PeakCache.compute(destination)) ?? []))
            }
            DispatchQueue.main.async {
                guard !imported.isEmpty else {
                    self.engine.status = "Nothing could be imported."
                    return
                }
                var cursor = start
                for (asset, peaks) in imported { self.peaks.set(asset.id, peaks: peaks, package: package) }
                self.perform { p in
                    guard p.tracks.indices.contains(trackIndex) else { return }
                    for (asset, _) in imported {
                        p.assets.append(asset)
                        p.tracks[trackIndex].clips.append(Clip(assetID: asset.id, name: asset.name,
                                                               start: cursor, length: asset.duration))
                        cursor += asset.duration
                    }
                }
            }
        }
    }

    public func export(_ format: ExportFormat, cycleOnly: Bool) {
        let range: (Double, Double) = cycleOnly ? (project.cycle.start, project.cycle.end) : (0, project.endTime)
        guard range.1 > range.0 else {
            engine.status = "Nothing to export yet."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).\(format.fileExtension)"
        panel.allowedContentTypes = [format == .wav ? UTType.wav : UTType.mpeg4Audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = project
        let package = self.package
        let registry = self.registry
        isExporting = true
        engine.status = "Exporting…"
        DispatchQueue.global(qos: .userInitiated).async {
            var message = "Exported \(url.lastPathComponent)"
            do {
                try? FileManager.default.removeItem(at: url)
                try Exporter.export(project: snapshot, package: package, from: range.0, to: range.1,
                                    tail: cycleOnly ? 0 : 2, url: url, format: format, registry: registry)
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.isExporting = false
                self.engine.status = message
            }
        }
    }

    /// Call when the app is quitting.
    public func shutdown() {
        writeToDisk()
        engine.shutdown()
    }
}
