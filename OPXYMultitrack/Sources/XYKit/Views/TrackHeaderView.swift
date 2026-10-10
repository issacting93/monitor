// TrackHeaderView.swift — one row of the left column: colour, name, arm, mute, solo, volume, pan, meter.

import AppKit
import SwiftUI

struct TrackHeaderView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var engine: AudioEngine
    let index: Int
    let height: CGFloat

    var body: some View {
        let track = store.project.tracks[index]
        let color = Theme.track(track.colorIndex)
        let selected = store.selectedTrackID == track.id
        let armed = store.armedTrackID == track.id

        HStack(spacing: 8) {
            Rectangle().fill(color).frame(width: 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    TextField("Track", text: Binding(
                        get: { track.name },
                        set: { name in store.perform("name-\(track.id)", reschedule: false) { $0.tracks[index].name = name } }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
                    Chip(text: "R", isOn: armed, color: Theme.danger) { store.toggleArm(track.id) }
                        .help("Arm for recording")
                    Chip(text: "M", isOn: track.mute, color: Theme.textSecondary) {
                        store.perform { $0.tracks[index].mute.toggle() }
                    }
                    Chip(text: "S", isOn: track.solo, color: Theme.cycle) {
                        store.perform { $0.tracks[index].solo.toggle() }
                    }
                }
                if height >= 44 {
                    HStack(spacing: 8) {
                        DragBar(value: track.volume, range: 0...1.2, color: color,
                                onChange: { v in store.perform("vol-\(track.id)", reschedule: false) { $0.tracks[index].volume = v } },
                                onEnd: { store.endGesture() })
                            .help("Volume")
                        DragBar(value: track.pan, range: -1...1, color: Theme.textSecondary, centred: true,
                                onChange: { v in
                                    let pan = abs(v) < 0.06 ? 0 : v          // easy to find the centre
                                    store.perform("pan-\(track.id)", reschedule: false) { $0.tracks[index].pan = pan }
                                },
                                onEnd: { store.endGesture() })
                            .frame(width: 44)
                            .help("Pan")
                    }
                }
            }
            .padding(.vertical, 4)

            MeterBar(hub: engine.meters, index: index, color: color, vertical: true)
                .frame(width: 4)
                .padding(.vertical, 5)
                .padding(.trailing, 6)
        }
        .frame(height: height)
        .background(selected ? Theme.surface : Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture { store.select(track: track.id) }
    }
}
