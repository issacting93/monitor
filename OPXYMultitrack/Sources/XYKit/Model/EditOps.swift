// EditOps.swift — every timeline edit as a pure function on Project.
// The UI calls these inside ProjectStore.perform, which handles undo and tells the engine.

import Foundation

enum EditOps {
    static let minClipLength = 0.02

    static func locate(_ id: UUID, in p: Project) -> (track: Int, clip: Int)? {
        for (t, track) in p.tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) { return (t, c) }
        }
        return nil
    }

    static func clip(_ id: UUID, in p: Project) -> Clip? {
        locate(id, in: p).map { p.tracks[$0.track].clips[$0.clip] }
    }

    static func move(_ id: UUID, toStart: Double, toTrack: Int? = nil, in p: inout Project) {
        guard let loc = locate(id, in: p) else { return }
        var clip = p.tracks[loc.track].clips[loc.clip]
        clip.start = max(0, toStart)
        let dest = min(max(toTrack ?? loc.track, 0), p.tracks.count - 1)
        if dest == loc.track {
            p.tracks[loc.track].clips[loc.clip] = clip
        } else {
            p.tracks[loc.track].clips.remove(at: loc.clip)
            p.tracks[dest].clips.append(clip)
        }
    }

    /// Drag the left edge. The audio stays where it is on the timeline; the clip reveals more or less of it.
    static func trimStart(_ id: UUID, to newStart: Double, in p: inout Project) {
        guard let loc = locate(id, in: p) else { return }
        var c = p.tracks[loc.track].clips[loc.clip]
        let lowest = max(0, c.start - c.offset)               // can't reveal audio before the file begins
        let highest = c.start + c.length - minClipLength
        let s = min(max(newStart, lowest), highest)
        let delta = s - c.start
        c.start = s
        c.offset += delta
        c.length -= delta
        p.tracks[loc.track].clips[loc.clip] = c
    }

    /// Set the length of one repetition, limited by how much audio the asset has.
    static func setLength(_ id: UUID, to newLength: Double, in p: inout Project) {
        guard let loc = locate(id, in: p) else { return }
        var c = p.tracks[loc.track].clips[loc.clip]
        let duration = p.asset(c.assetID)?.duration ?? 0
        let longest = duration > 0 ? max(minClipLength, duration - c.offset) : Double.greatestFiniteMagnitude
        c.length = min(max(newLength, minClipLength), longest)
        p.tracks[loc.track].clips[loc.clip] = c
    }

    static func setLoopCount(_ id: UUID, to count: Int, in p: inout Project) {
        guard let loc = locate(id, in: p) else { return }
        p.tracks[loc.track].clips[loc.clip].loopCount = min(max(count, 1), 256)
    }

    /// Cut a clip at a timeline position. Works inside any repetition of a looped clip:
    /// the repetitions before and after the cut stay looped, the cut repetition becomes two plain clips.
    static func split(_ id: UUID, at t: Double, in p: inout Project) {
        guard let loc = locate(id, in: p) else { return }
        let c = p.tracks[loc.track].clips[loc.clip]
        let n = max(1, c.loopCount)
        guard t > c.start + minClipLength, t < c.end - minClipLength else { return }

        let k = min(n - 1, Int((t - c.start) / c.length))
        let repStart = c.start + Double(k) * c.length
        let u = t - repStart
        var pieces: [Clip] = []

        if k > 0 {                                            // repetitions before the cut keep the original ID
            var before = c
            before.loopCount = k
            pieces.append(before)
        }
        if u > minClipLength / 2 {
            var left = c
            left.id = k > 0 ? UUID() : c.id
            left.start = repStart
            left.length = u
            left.loopCount = 1
            pieces.append(left)
        }
        if c.length - u > minClipLength / 2 {
            var right = c
            right.id = UUID()
            right.start = t
            right.offset = c.offset + u
            right.length = c.length - u
            right.loopCount = 1
            pieces.append(right)
        }
        if k < n - 1 {
            var after = c
            after.id = UUID()
            after.start = repStart + c.length
            after.loopCount = n - 1 - k
            pieces.append(after)
        }
        p.tracks[loc.track].clips.replaceSubrange(loc.clip...loc.clip, with: pieces)
    }

    /// Copy a clip and place the copy directly after it. Returns the new clip's ID.
    @discardableResult
    static func duplicate(_ id: UUID, in p: inout Project) -> UUID? {
        guard let loc = locate(id, in: p) else { return nil }
        var copy = p.tracks[loc.track].clips[loc.clip]
        copy.id = UUID()
        copy.start = copy.end
        p.tracks[loc.track].clips.append(copy)
        return copy.id
    }

    static func delete(_ id: UUID, in p: inout Project) {
        guard let loc = locate(id, in: p) else { return }
        p.tracks[loc.track].clips.remove(at: loc.clip)
    }

    /// Remove everything on one track between a and b, cutting clips that straddle the edges.
    /// A new take uses this so it replaces what was underneath, the way tape does.
    static func clearRange(track: Int, from a: Double, to b: Double, in p: inout Project) {
        guard p.tracks.indices.contains(track), b > a else { return }
        for id in p.tracks[track].clips.map(\.id) { split(id, at: a, in: &p) }
        for id in p.tracks[track].clips.map(\.id) { split(id, at: b, in: &p) }
        p.tracks[track].clips.removeAll { $0.start >= a - 1e-6 && $0.end <= b + 1e-6 }
    }
}
