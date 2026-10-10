// Controls.swift — the small reusable pieces: knob, meter, toggle chip, icon button.

import SwiftUI

/// The arc knob from OP-XY Monitor. Drag up and down to turn; double-click to reset.
struct Knob: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var color: Color = Theme.accent
    var size: CGFloat = 46
    let display: String
    let onChange: (Double) -> Void
    var onEnd: () -> Void = {}

    @State private var dragStart: Double?
    private let startAngle = 135.0
    private let sweep = 270.0

    private var normalized: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }
    private var bipolar: Bool { range.lowerBound < 0 && range.upperBound > 0 }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                arc(0, 1).stroke(Theme.line, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                arc(bipolar ? 0.5 : 0, normalized).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Circle().fill(Theme.surface).frame(width: size * 0.4, height: size * 0.4)
                indicator.stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        let start = dragStart ?? normalized
                        dragStart = start
                        let next = min(max(start - Double(gesture.translation.height) / 150, 0), 1)
                        onChange(range.lowerBound + next * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onEnd()
                    }
            )
            .onTapGesture(count: 2) {
                if let defaultValue {
                    onChange(defaultValue)
                    onEnd()
                }
            }
            Text(display)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(minWidth: size + 18)
    }

    private func arc(_ from: Double, _ to: Double) -> Path {
        let radius = size / 2 - 4
        return Path { p in
            p.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: radius,
                     startAngle: .degrees(startAngle + sweep * min(from, to)),
                     endAngle: .degrees(startAngle + sweep * max(from, to)), clockwise: false)
        }
    }

    private var indicator: Path {
        let angle = (startAngle + sweep * normalized) * Double.pi / 180
        let centre = Double(size) / 2
        let inner = Double(size) * 0.2
        let outer = Double(size) / 2 - 4
        return Path { p in
            p.move(to: CGPoint(x: centre + inner * cos(angle), y: centre + inner * sin(angle)))
            p.addLine(to: CGPoint(x: centre + outer * cos(angle), y: centre + outer * sin(angle)))
        }
    }
}

/// A thin horizontal bar you drag to set a value. Used for track volume and pan.
struct DragBar: View {
    let value: Double
    let range: ClosedRange<Double>
    var color: Color = Theme.textSecondary
    var centred = false
    let onChange: (Double) -> Void
    var onEnd: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            let width = Double(geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                if centred {
                    let mid = width / 2
                    let x = width * fraction
                    Capsule().fill(color)
                        .frame(width: CGFloat(max(abs(x - mid), 2)))
                        .offset(x: CGFloat(min(x, mid)))
                } else {
                    Capsule().fill(color).frame(width: CGFloat(width * fraction))
                }
            }
            .contentShape(Rectangle().inset(by: -5))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let f = min(max(Double(gesture.location.x) / max(width, 1), 0), 1)
                        onChange(range.lowerBound + f * span)
                    }
                    .onEnded { _ in onEnd() }
            )
        }
        .frame(height: 5)
    }
}

/// One level meter. Watches the hub directly so only meters redraw at meter rate.
struct MeterBar: View {
    @ObservedObject var hub: MeterHub
    let index: Int
    var color: Color = Theme.accent
    var vertical = false

    var body: some View {
        let level = MeterHub.display(hub.levels[index])
        GeometryReader { geo in
            ZStack(alignment: vertical ? .bottom : .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.surface)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level > 0.97 ? Theme.danger : color)
                    .frame(width: vertical ? nil : CGFloat(Double(geo.size.width) * level),
                           height: vertical ? CGFloat(Double(geo.size.height) * level) : nil)
            }
        }
    }
}

struct Chip: View {
    let text: String
    let isOn: Bool
    var color: Color = Theme.accent
    var width: CGFloat? = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Theme.textSecondary)
                .frame(width: width, height: 20)
                .padding(.horizontal, width == nil ? 8 : 0)
                .background(isOn ? color : Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let symbol: String
    var tint: Color = Theme.textPrimary
    var filled = false
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint)
                .frame(width: 30, height: 26)
                .background(filled ? tint : Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Format a parameter value with its unit: whole numbers for wide ranges, one decimal for narrow ones.
func formatValue(_ value: Double, unit: String, span: Double) -> String {
    let number = span >= 20 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    return unit.isEmpty ? number : "\(number) \(unit)"
}
