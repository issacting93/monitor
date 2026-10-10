// RootView.swift — the single screen: transport on top, track headers and timeline in the middle,
// inspector underneath, status along the bottom.

import SwiftUI

public struct RootView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var engine: AudioEngine
    @State private var headerDragStart: Double?

    public init() {}

    public var body: some View {
        let view = store.project.view
        VStack(spacing: 0) {
            TransportBar()
            divider

            GeometryReader { geo in
                // Eight rows always fit: they share whatever height the window gives them.
                let rowHeight = max(30, min(76, (geo.size.height - Theme.rulerHeight) / CGFloat(Project.trackCount)))
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("TRACKS").font(Theme.label).tracking(1.2).foregroundStyle(Theme.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .frame(height: Theme.rulerHeight)
                        ForEach(0..<Project.trackCount, id: \.self) { index in
                            TrackHeaderView(index: index, height: rowHeight)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: view.headerWidth)

                    Rectangle().fill(Theme.line).frame(width: 1)
                        .overlay(Color.clear.frame(width: 7).contentShape(Rectangle()).gesture(headerResize))

                    TimelineView(rowHeight: rowHeight)
                }
            }
            .frame(minHeight: 30 * CGFloat(Project.trackCount) + Theme.rulerHeight)

            if view.inspectorOpen {
                divider
                InspectorView()
            }
            divider
            footer
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(height: 0.5) }

    private var headerResize: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { gesture in
                let start = headerDragStart ?? store.project.view.headerWidth
                headerDragStart = start
                store.setView { $0.headerWidth = min(max(start + Double(gesture.translation.width), 170), 360) }
            }
            .onEnded { _ in headerDragStart = nil }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(engine.isRecording ? Theme.danger : (engine.isRunning ? Theme.accent : Theme.textTertiary))
                .frame(width: 6, height: 6)
            Text(engine.status)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Chip(text: "−", isOn: false) { store.zoom(by: 0.8) }
            Chip(text: "+", isOn: false) { store.zoom(by: 1.25) }
            Chip(text: "INSPECTOR", isOn: store.project.view.inspectorOpen, width: nil) {
                store.setView { $0.inspectorOpen.toggle() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
