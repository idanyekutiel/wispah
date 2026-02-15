import SwiftUI

@main
struct VoiceToTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Voice to Text", systemImage: "mic.fill") {
            MenuBarView()
                .environmentObject(appDelegate.appState)
        }
    }
}
