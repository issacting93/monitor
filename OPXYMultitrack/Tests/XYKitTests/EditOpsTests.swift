import XCTest
@testable import XYKit

final class EditOpsTests: XCTestCase {
    private func makeProject(clipStart: Double = 2, length: Double = 4, loops: Int = 1) -> (Project, UUID) {
        var p = Project()
        let asset = Asset(fileName: "a.wav", name: "a", duration: 10)
        p.assets = [asset]
        let clip = Clip(assetID: asset.id, name: "a", start: clipStart, offset: 1, length: length, loopCount: loops)
        p.tracks[0].clips = [clip]
        return (p, clip.id)
    }

    func testMoveClampsToZeroAndChangesTrack() {
        var (p, id) = makeProject()
        EditOps.move(id, toStart: -3, toTrack: 2, in: &p)
        XCTAssertTrue(p.tracks[0].clips.isEmpty)
        XCTAssertEqual(p.tracks[2].clips.first?.start, 0)
    }

    func testTrimStartKeepsAudioInPlace() {
        var (p, id) = makeProject()
        EditOps.trimStart(id, to: 3, in: &p)
        let c = EditOps.clip(id, in: p)!
        XCTAssertEqual(c.start, 3, accuracy: 1e-9)
        XCTAssertEqual(c.offset, 2, accuracy: 1e-9)
        XCTAssertEqual(c.length, 3, accuracy: 1e-9)
        XCTAssertEqual(c.end, 6, accuracy: 1e-9)
    }

    func testTrimStartCannotGoBeforeFileStart() {
        var (p, id) = makeProject()
        EditOps.trimStart(id, to: -5, in: &p)
        let c = EditOps.clip(id, in: p)!
        XCTAssertEqual(c.offset, 0, accuracy: 1e-9)
        XCTAssertEqual(c.start, 1, accuracy: 1e-9)
    }

    func testLengthLimitedByAsset() {
        var (p, id) = makeProject()
        EditOps.setLength(id, to: 100, in: &p)
        XCTAssertEqual(EditOps.clip(id, in: p)!.length, 9, accuracy: 1e-9)   // 10 s asset, 1 s offset
    }

    func testSplitPlainClip() {
        var (p, id) = makeProject()
        EditOps.split(id, at: 3.5, in: &p)
        let clips = p.tracks[0].clips
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].id, id)
        XCTAssertEqual(clips[0].length, 1.5, accuracy: 1e-9)
        XCTAssertEqual(clips[1].start, 3.5, accuracy: 1e-9)
        XCTAssertEqual(clips[1].offset, 2.5, accuracy: 1e-9)
        XCTAssertEqual(clips[1].end, 6, accuracy: 1e-9)
    }

    func testSplitInsideSecondRepetitionOfLoopedClip() {
        var (p, id) = makeProject(clipStart: 0, length: 2, loops: 4)       // covers 0...8
        EditOps.split(id, at: 3, in: &p)
        let clips = p.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(clips.map(\.start), [0, 2, 3, 4])
        XCTAssertEqual(clips.map(\.loopCount), [1, 1, 1, 2])
        XCTAssertEqual(clips.map(\.totalLength).reduce(0, +), 8, accuracy: 1e-9)
        XCTAssertEqual(Set(clips.map(\.id)).count, 4)
    }

    func testClearRangeCutsStraddlingClip() {
        var (p, _) = makeProject(clipStart: 0, length: 8)
        EditOps.clearRange(track: 0, from: 2, to: 5, in: &p)
        let clips = p.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].end, 2, accuracy: 1e-9)
        XCTAssertEqual(clips[1].start, 5, accuracy: 1e-9)
    }

    func testSnapUsesVisibleGrid() {
        let tb = Timebase(bpm: 120, beatsPerBar: 4)                         // one beat = 0.5 s
        XCTAssertEqual(tb.snap(1.1, pixelsPerSecond: 60), 1.0, accuracy: 1e-9)
        XCTAssertEqual(tb.barBeat(0), "1.1")
        XCTAssertEqual(tb.barBeat(2.5), "2.2")
    }

    func testProjectRoundTripsThroughJSON() throws {
        let (p, _) = makeProject()
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), p)
    }
}
