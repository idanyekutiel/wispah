import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
        }
    }

    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupView(onComplete: { [weak self] in
            self?.completeSetup()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice to Text"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: setupView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        NSApp.setActivationPolicy(.accessory)
        appState.startHotkeyMonitoring()
    }
}
