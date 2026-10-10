// InspectorView.swift — the bottom panel. Shows the selected clip's settings, or the selected track's effect chain.
// Effect knobs are generated from each module's parameter list, so a downloaded add-on gets a panel with no UI code.

import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let id = store.selectedClipID, let clip = EditOps.clip(id, in: store.project) {
                ClipInspector(clip: clip)
            } else if let index = store.selectedTrackIndex {
                ChainInspector(trackIndex: index)
            } else {
                Text("Select a track or a clip")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 128)
        .background(Theme.bg)
    }
}

private func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased())
        .font(Theme.label)
        .tracking(1.2)
        .foregroundStyle(Theme.textTertiary)
}

// MARK: Clip

private struct ClipInspector: View {
    @EnvironmentObject var store: ProjectStore
    let clip: Clip

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Clip")
                Text(clip.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(store.timebase.barBeat(clip.start))  ·  \(Timebase.clock(clip.totalLength))")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 4) {
                    Chip(text: "SPLIT", isOn: false, width: nil) { store.splitAtPlayhead() }
                    Chip(text: "DUPLICATE", isOn: false, width: nil) { store.duplicateSelected() }
                    Chip(text: "DELETE", isOn: false, width: nil) { store.deleteSelected() }
                }
            }
            .frame(width: 230, alignment: .leading)

            Rectangle().fill(Theme.line).frame(width: 0.5)

            HStack(spacing: 14) {
                Knob(label: "Gain", value: clip.gain, range: 0...2, defaultValue: 1,
                     display: clip.gain > 0.001 ? String(format: "%+.1f dB", 20 * log10(clip.gain)) : "-∞ dB",
                     onChange: { v in edit("gain") { $0.gain = v } }, onEnd: store.endGesture)
                Knob(label: "Fade In", value: clip.fadeIn, range: 0...2, defaultValue: 0.005,
                     display: "\(Int(clip.fadeIn * 1000)) ms",
                     onChange: { v in edit("fadeIn") { $0.fadeIn = v } }, onEnd: store.endGesture)
                Knob(label: "Fade Out", value: clip.fadeOut, range: 0...2, defaultValue: 0.005,
                     display: "\(Int(clip.fadeOut * 1000)) ms",
                     onChange: { v in edit("fadeOut") { $0.fadeOut = v } }, onEnd: store.endGesture)
                Knob(label: "Repeats", value: Double(clip.loopCount), range: 1...16, defaultValue: 1,
                     display: "×\(clip.loopCount)",
                     onChange: { v in edit("loops") { $0.loopCount = Int(v.rounded()) } }, onEnd: store.endGesture)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func edit(_ name: String, _ change: @escaping (inout Clip) -> Void) {
        let id = clip.id
        store.perform("clip-\(name)-\(id)", reschedule: false) { p in
            guard let location = EditOps.locate(id, in: p) else { return }
            change(&p.tracks[location.track].clips[location.clip])
        }
    }
}

// MARK: Effect chain

private struct ChainInspector: View {
    @EnvironmentObject var store: ProjectStore
    let trackIndex: Int

    private func color(for category: String?) -> Color {
        switch category {
        case "Character": return Theme.accent
        case "Utility": return Theme.cycle
        case nil: return Theme.textTertiary
        default: return Theme.track(2)
        }
    }

    var body: some View {
        let track = store.project.tracks[trackIndex]
        let selectedSlot = track.fx.first { $0.id == store.selectedSlotID }

        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("\(track.name) · effects")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Text("IN").font(Theme.label).foregroundStyle(Theme.textTertiary)
                        ForEach(track.fx) { slot in
                            Text("›").foregroundStyle(Theme.textTertiary)
                            slotChip(slot)
                        }
                        Text("›").foregroundStyle(Theme.textTertiary)
                        addMenu
                    }
                }
                if let slot = selectedSlot {
                    HStack(spacing: 4) {
                        Chip(text: "◀", isOn: false) { store.moveSlot(slot.id, by: -1) }
                        Chip(text: "▶", isOn: false) { store.moveSlot(slot.id, by: 1) }
                        Chip(text: slot.bypass ? "BYPASSED" : "ON", isOn: !slot.bypass, width: nil) {
                            store.updateSlot(slot.id) { $0.bypass.toggle() }
                        }
                        Chip(text: "REMOVE", isOn: false, width: nil) { store.removeSlot(slot.id) }
                    }
                }
            }
            .padding(12)
            .frame(width: 380, alignment: .leading)

            Rectangle().fill(Theme.line).frame(width: 0.5)

            Group {
                if let slot = selectedSlot {
                    if let descriptor = store.registry.descriptor(slot.moduleID) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(descriptor.parameters) { parameter in
                                    knob(parameter, slot: slot, color: color(for: descriptor.category))
                                }
                            }
                            .padding(12)
                        }
                        .opacity(slot.bypass ? 0.4 : 1)
                    } else {
                        message("\"\(slot.moduleID)\" isn't installed.\nThe slot is kept and its audio passes straight through.")
                    }
                } else {
                    message(track.fx.isEmpty ? "No effects on this track yet. Add one with +." : "Select an effect to see its controls.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .padding(12)
    }

    private func slotChip(_ slot: EffectSlot) -> some View {
        let descriptor = store.registry.descriptor(slot.moduleID)
        let tint = color(for: descriptor?.category)
        let selected = store.selectedSlotID == slot.id
        return Button {
            store.selectedClipID = nil
            store.selectedSlotID = slot.id
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(slot.bypass ? Color.clear : tint)
                    .overlay(Circle().stroke(tint, lineWidth: 1))
                    .frame(width: 7, height: 7)
                Text(descriptor?.name ?? "Missing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(selected ? Theme.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? tint.opacity(0.6) : Theme.line, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    private var addMenu: some View {
        Menu {
            ForEach(store.registry.categories, id: \.self) { category in
                Section(category) {
                    ForEach(store.registry.descriptors.filter { $0.category == category }) { descriptor in
                        Button(descriptor.name) { store.addEffect(descriptor.id) }
                    }
                }
            }
        } label: {
            Text("+")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func knob(_ parameter: EffectParameter, slot: EffectSlot, color: Color) -> some View {
        let value = slot.value(for: parameter)
        let display: String
        if let choices = parameter.choices {
            let index = min(max(Int((value - parameter.min).rounded()), 0), choices.count - 1)
            display = choices.isEmpty ? "" : choices[index]
        } else {
            display = formatValue(Double(value), unit: parameter.unit, span: Double(parameter.max - parameter.min))
        }
        return Knob(label: parameter.name, value: Double(value),
                    range: Double(parameter.min)...Double(parameter.max),
                    defaultValue: Double(parameter.defaultValue), color: color, display: display,
                    onChange: { v in
                        let next = parameter.choices == nil ? Float(v) : Float(v.rounded())
                        store.updateSlot(slot.id, key: "fx-\(slot.id)-\(parameter.id)") { $0.values[parameter.id] = next }
                    },
                    onEnd: store.endGesture)
    }
}
