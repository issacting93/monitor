// TimelineView.swift — ruler, lanes, clips and playhead.
//
// The timeline does its own scrolling: it draws only what is between scrollX and the right edge,
// so a ten-minute song at high zoom costs the same to draw as a ten-second one.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var engine: AudioEngine
    let rowHeight: CGFloat

    private struct PlacedClip: Identifiable {
        let clip: Clip
        let trackIndex: Int
        var id: UUID { clip.id }
    }

    var body: some View {
        GeometryReader { geo in
            let project = store.project
            let lanesHeight = rowHeight * CGFloat(project.tracks.count)
            // One flat list, keyed by clip ID, so a clip keeps its view (and its drag) when it changes track.
            let placed = project.tracks.enumerated().flatMap { index, track in
                track.clips.map { PlacedClip(clip: $0, trackIndex: index) }
            }

            VStack(spacing: 0) {
                RulerView(width: geo.size.width)
                    .frame(height: Theme.rulerHeight)

                ZStack(alignment: .topLeading) {
                    LaneGrid(project: project, rowHeight: rowHeight, selectedIndex: store.selectedTrackIndex)

                    ForEach(placed) { item in
                        ClipView(peaks: store.peaks, clip: item.clip, trackIndex: item.trackIndex,
                                 rowHeight: rowHeight, viewport: Double(geo.size.width))
                    }

                    if let preview = engine.preview, let index = project.trackIndex(preview.trackID) {
                        RecordingClipView(preview: preview, trackIndex: index, rowHeight: rowHeight,
                                          view: project.view, sampleRate: project.sampleRate)
                    }

                    if project.assets.isEmpty, engine.preview == nil {
                        Text("Arm a track with its R button, then press R to record.\nOr drop audio files onto a lane.")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: geo.size.width, height: lanesHeight)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: lanesHeight, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .coordinateSpace(name: "lanes")
                .onTapGesture { location in
                    let index = Int(location.y / rowHeight)
                    if project.tracks.indices.contains(index) { store.select(track: project.tracks[index].id) }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers, location in
                    drop(providers, at: location)
                }

                Spacer(minLength: 0)
            }
            .overlay(alignment: .topLeading) {
                PlayheadView(clock: engine.clock, width: geo.size.width,
                             height: Theme.rulerHeight + lanesHeight)
            }
            .onAppear { store.timelineWidth = Double(geo.size.width) }
            .onChange(of: geo.size.width) { store.timelineWidth = Double($0) }
        }
    }

    private func drop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let view = store.project.view
        let index = min(max(Int(location.y / rowHeight), 0), store.project.tracks.count - 1)
        let start = store.snapped(view.scrollX + Double(location.x) / view.pixelsPerSecond)
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { store.importFiles(urls, trackIndex: index, at: start) }
        }
        return true
    }
}

// MARK: Lanes background

private struct LaneGrid: View {
    let project: Project
    let rowHeight: CGFloat
    let selectedIndex: Int?

    var body: some View {
        Canvas { context, size in
            let view = project.view
            let pps = view.pixelsPerSecond
            let timebase = project.timebase

            if let selectedIndex {
                context.fill(Path(CGRect(x: 0, y: CGFloat(selectedIndex) * rowHeight, width: size.width, height: rowHeight)),
                             with: .color(Theme.lane))
            }

            // Grid lines: the same spacing clips snap to.
            let stepBeats = timebase.gridBeats(pixelsPerSecond: pps)
            let step = stepBeats * timebase.secondsPerBeat
            var n = Int((view.scrollX / step).rounded(.down))
            let lastVisible = view.scrollX + Double(size.width) / pps
            while Double(n) * step <= lastVisible {
                let x = (Double(n) * step - view.scrollX) * pps
                let isBar = (Double(n) * stepBeats).truncatingRemainder(dividingBy: Double(timebase.beatsPerBar)) == 0
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }, with: .color(Theme.line.opacity(isBar ? 0.9 : 0.35)), lineWidth: 0.5)
                n += 1
            }

            for row in 1...max(project.tracks.count, 1) {
                let y = CGFloat(row) * rowHeight
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }, with: .color(Theme.line), lineWidth: 0.5)
            }

            if project.cycle.enabled {
                let x0 = (project.cycle.start - view.scrollX) * pps
                let x1 = (project.cycle.end - view.scrollX) * pps
                context.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 0), height: size.height)),
                             with: .color(Theme.cycle.opacity(0.06)))
            }
        }
    }
}

// MARK: Ruler

/// Bar numbers along the top. Click or drag to move the playhead; Option-drag to set the cycle range.
private struct RulerView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var engine: AudioEngine
    let width: CGFloat
    @State private var cycleAnchor: Double?
    @State private var pendingSeek: Double?

    var body: some View {
        let project = store.project
        Canvas { context, size in
            let view = project.view
            let pps = view.pixelsPerSecond
            let bar = project.timebase.secondsPerBar

            let cycleX0 = (project.cycle.start - view.scrollX) * pps
            let cycleX1 = (project.cycle.end - view.scrollX) * pps
            context.fill(Path(CGRect(x: cycleX0, y: 0, width: max(cycleX1 - cycleX0, 0), height: 5)),
                         with: .color(Theme.cycle.opacity(project.cycle.enabled ? 0.9 : 0.25)))

            // Label every bar when there is room, otherwise every 2nd, 4th, 8th…
            var every = 1
            while Double(every) * bar * pps < 34 { every *= 2 }
            var n = Int((view.scrollX / bar).rounded(.down))
            n -= ((n % every) + every) % every
            while Double(n) * bar <= view.scrollX + Double(size.width) / pps {
                let x = (Double(n) * bar - view.scrollX) * pps
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: size.height - 8))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }, with: .color(Theme.textTertiary), lineWidth: 0.5)
                context.draw(Text("\(n + 1)").font(Theme.mono).foregroundColor(Theme.textSecondary),
                             at: CGPoint(x: x + 4, y: size.height - 9), anchor: .leading)
                n += every
            }
        }
        .background(Theme.bg)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let view = store.project.view
                    let time = max(0, view.scrollX + Double(gesture.location.x) / view.pixelsPerSecond)
                    if NSEvent.modifierFlags.contains(.option) {
                        let anchor = cycleAnchor
                            ?? store.snapped(view.scrollX + Double(gesture.startLocation.x) / view.pixelsPerSecond)
                        cycleAnchor = anchor
                        let other = store.snapped(time)
                        store.perform("cycle", reschedule: false) {
                            $0.cycle.start = min(anchor, other)
                            $0.cycle.end = max(anchor, other)
                            if $0.cycle.end - $0.cycle.start > 0.05 { $0.cycle.enabled = true }
                        }
                    } else if engine.isPlaying {
                        pendingSeek = store.snapped(time)     // while playing, jump once on release
                    } else {
                        engine.seek(to: store.snapped(time))
                    }
                }
                .onEnded { _ in
                    if cycleAnchor != nil {
                        cycleAnchor = nil
                        store.endGesture()
                    }
                    if let target = pendingSeek {
                        pendingSeek = nil
                        engine.seek(to: target)
                    }
                }
        )
    }
}

// MARK: Playhead

private struct PlayheadView: View {
    @ObservedObject var clock: TransportClock
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var engine: AudioEngine
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let view = store.project.view
        let x = (clock.position - view.scrollX) * view.pixelsPerSecond
        Rectangle()
            .fill(engine.isRecording ? Theme.danger : Color.white.opacity(0.9))
            .frame(width: 1, height: height)
            .offset(x: x)
            .opacity(x >= 0 && x <= Double(width) ? 1 : 0)
            .allowsHitTesting(false)
            .onChange(of: clock.position) { position in
                // Follow the playhead a page at a time while playing.
                guard engine.isPlaying else { return }
                let view = store.project.view
                let px = (position - view.scrollX) * view.pixelsPerSecond
                if px > Double(width) - 24 || px < 0 {
                    store.setView { $0.scrollX = max(0, position - 40 / $0.pixelsPerSecond) }
                }
            }
    }
}

// MARK: Clips

struct ClipView: View {
    @EnvironmentObject var store: ProjectStore
    @ObservedObject var peaks: PeakCache
    let clip: Clip
    let trackIndex: Int
    let rowHeight: CGFloat
    let viewport: Double

    @State private var origin: Clip?
    @State private var originTrack = 0

    var body: some View {
        let view = store.project.view
        let pps = view.pixelsPerSecond
        let x0 = (clip.start - view.scrollX) * pps
        let x1 = x0 + clip.totalLength * pps
        // Only the part inside the window is laid out and drawn.
        let left = max(x0, -12.0)
        let right = min(x1, viewport + 12.0)

        if right > left {
            let color = Theme.track(store.project.tracks[trackIndex].colorIndex)
            let selected = store.selectedClipID == clip.id
            let missing = store.missingAssets.contains(clip.assetID)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(color.opacity(missing ? 0.1 : 0.26))
                waveform(color: color, left: left, x0: x0, pps: pps)
                Text(missing ? "\(clip.name) (file missing)" : clip.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.top, 2)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.white : color.opacity(0.8), lineWidth: selected ? 1.5 : 0.75)
            }
            .contentShape(Rectangle())
            .gesture(moveGesture(pps: pps))
            .simultaneousGesture(TapGesture().onEnded { store.select(clip: clip.id) })
            .overlay(alignment: .leading) {
                if x0 >= left { edgeHandle.gesture(trimStartGesture(pps: pps)) }
            }
            .overlay(alignment: .trailing) {
                if x1 <= right {
                    VStack(spacing: 0) {
                        // Top corner: drag to repeat the clip. Rest of the edge: drag to change its length.
                        Image(systemName: "repeat")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.textPrimary.opacity(right - left > 36 ? 0.8 : 0))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                            .gesture(loopGesture(pps: pps))
                            .help("Drag to repeat")
                        edgeHandle.gesture(trimEndGesture(pps: pps))
                    }
                }
            }
            .frame(width: right - left, height: rowHeight - 3)
            .offset(x: left, y: CGFloat(trackIndex) * rowHeight + 1.5)
        }
    }

    private var edgeHandle: some View {
        Color.clear
            .frame(width: 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func waveform(color: Color, left: Double, x0: Double, pps: Double) -> some View {
        let data = peaks.peaks(clip.assetID) ?? []
        let bucketsPerSecond = store.project.sampleRate / Double(PeakCache.framesPerBucket)
        return Canvas { context, size in
            guard !data.isEmpty, clip.length > 0 else { return }
            let width = Double(size.width)
            let height = Double(size.height)
            let mid = height / 2 + 5
            let amplitude = max(2, (height - 16) / 2)
            var path = Path()
            var x = 0.0
            while x < width {
                let local = (left + x - x0) / pps                      // seconds from the clip's start
                if local >= 0, local < clip.totalLength {
                    let inRepetition = local.truncatingRemainder(dividingBy: clip.length)
                    let t0 = clip.offset + inRepetition
                    let first = max(0, Int(t0 * bucketsPerSecond))
                    let last = min(data.count - 1, max(first, Int((t0 + 1 / pps) * bucketsPerSecond)))
                    if first <= last {
                        var peak: Float = 0
                        for i in first...last { peak = max(peak, data[i]) }
                        let h = min(amplitude, max(0.5, Double(peak) * clip.gain * amplitude))
                        path.addRect(CGRect(x: x, y: mid - h, width: 1, height: h * 2))
                    }
                }
                x += 1
            }
            context.fill(path, with: .color(color))

            if clip.loopCount > 1 {
                for k in 1..<clip.loopCount {
                    let lx = x0 + Double(k) * clip.length * pps - left
                    guard lx > 0, lx < width else { continue }
                    context.stroke(Path { p in
                        p.move(to: CGPoint(x: lx, y: 0))
                        p.addLine(to: CGPoint(x: lx, y: height))
                    }, with: .color(Color.white.opacity(0.5)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // Each drag remembers the clip as it was when the drag began, and passes one key to the store
    // so the whole drag becomes a single undo step.

    private func begin() -> Clip {
        if let origin { return origin }
        origin = clip
        originTrack = trackIndex
        store.select(clip: clip.id)
        return clip
    }

    private func finish() {
        origin = nil
        store.endGesture()
    }

    private func moveGesture(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("lanes"))
            .onChanged { gesture in
                let o = begin()
                let start = store.snapped(o.start + Double(gesture.translation.width) / pps)
                let track = originTrack + Int((gesture.translation.height / rowHeight).rounded())
                store.perform("move-\(clip.id)", reschedule: false) {
                    EditOps.move(clip.id, toStart: start, toTrack: track, in: &$0)
                }
            }
            .onEnded { _ in finish() }
    }

    private func trimStartGesture(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("lanes"))
            .onChanged { gesture in
                let o = begin()
                let target = store.snapped(o.start + Double(gesture.translation.width) / pps)
                // Always trim from the original, so the edge follows the mouse rather than accumulating.
                store.perform("trimStart-\(clip.id)", reschedule: false) { p in
                    guard let location = EditOps.locate(clip.id, in: p) else { return }
                    p.tracks[location.track].clips[location.clip] = o
                    EditOps.trimStart(clip.id, to: target, in: &p)
                }
            }
            .onEnded { _ in finish() }
    }

    private func trimEndGesture(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("lanes"))
            .onChanged { gesture in
                let o = begin()
                let count = Double(max(1, o.loopCount))
                let delta = Double(gesture.translation.width) / pps
                let length = count == 1 ? store.snapped(o.end + delta) - o.start : o.length + delta / count
                store.perform("trimEnd-\(clip.id)", reschedule: false) {
                    EditOps.setLength(clip.id, to: length, in: &$0)
                }
            }
            .onEnded { _ in finish() }
    }

    private func loopGesture(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("lanes"))
            .onChanged { gesture in
                let o = begin()
                let total = o.totalLength + Double(gesture.translation.width) / pps
                let count = Int((total / o.length).rounded())
                store.perform("loop-\(clip.id)", reschedule: false) {
                    EditOps.setLoopCount(clip.id, to: count, in: &$0)
                }
            }
            .onEnded { _ in finish() }
    }
}

/// The take in progress: a red clip that grows as audio arrives.
private struct RecordingClipView: View {
    let preview: RecordingPreview
    let trackIndex: Int
    let rowHeight: CGFloat
    let view: ViewState
    let sampleRate: Double

    var body: some View {
        let pps = view.pixelsPerSecond
        let x0 = (preview.start - view.scrollX) * pps
        let width = max(2, preview.duration * pps)
        let secondsPerBucket = Double(PeakCache.framesPerBucket) / sampleRate
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                         with: .color(Theme.danger.opacity(0.25)))
            var path = Path()
            let mid = Double(size.height) / 2
            for (i, peak) in preview.peaks.enumerated() {
                let x = Double(i) * secondsPerBucket * pps
                let h = max(0.5, min(1, Double(peak)) * (mid - 3))
                path.addRect(CGRect(x: x, y: mid - h, width: max(1, secondsPerBucket * pps), height: h * 2))
            }
            context.fill(path, with: .color(Theme.danger))
        }
        .frame(width: width, height: rowHeight - 3)
        .offset(x: x0, y: CGFloat(trackIndex) * rowHeight + 1.5)
        .allowsHitTesting(false)
    }
}
