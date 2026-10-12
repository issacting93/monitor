// App_iOS.swift — iPad app entry point
//
// Stage A placeholder: proves the shared core links on iOS. The real iPad UI
// lands in Stage D (Views_iOS.swift); this root is replaced then.

#if os(iOS)
import SwiftUI

@main
struct Tape08iOSApp: App {
    @StateObject private var audio = AudioManager()

    var body: some Scene {
        WindowGroup {
            IOSRootView(audio: audio)
                .preferredColorScheme(.dark)
        }
    }
}

struct IOSRootView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        VStack(spacing: 16) {
            Text("TAPE 08")
                .font(.system(size: 34, weight: .black, design: .monospaced))
                .tracking(6)
                .foregroundColor(Theme.accent)
            Text("iPad — core running")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Text(audio.status)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onAppear { audio.startMonitoring() }
    }
}
#endif
