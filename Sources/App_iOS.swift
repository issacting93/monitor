// App_iOS.swift — iPad app entry point

#if os(iOS)
import SwiftUI

@main
struct Tape08iOSApp: App {
    @StateObject private var audio = AudioManager()

    var body: some Scene {
        WindowGroup {
            IOSRootView(audio: audio)
        }
    }
}
#endif
