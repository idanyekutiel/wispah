import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?
    private var debugPanelWindow: NSPanel?
    private var settingsWindow: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetup),
            name: .showSetup,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleDebugPanel),
            name: .toggleDebugPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()

            if !AXIsProcessTrusted() {
                appState.showAccessibilityAlert()
            }
        }

    }

    @objc func handleShowSetup() {
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        showSetupWindow()
    }

    @objc private func handleToggleDebugPanel() {
        toggleDebugPanelWindow()
    }

    @objc private func handleShowSettings() {
        toggleSettingsWindow()
    }

    private func toggleDebugPanelWindow() {
        if let debugPanelWindow, debugPanelWindow.isVisible {
            debugPanelWindow.orderOut(nil)
            appState.isDebugPanelVisible = false
            return
        }

        if debugPanelWindow == nil {
            presentDebugPanelWindow()
        } else {
            debugPanelWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            appState.isDebugPanelVisible = true
            debugPanelWindow?.orderFrontRegardless()
        }
    }

    private func presentDebugPanelWindow() {
        let debugView = PipelineDebugPanelView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: debugView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pipeline Debug"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()

        debugPanelWindow = panel
        appState.isDebugPanelVisible = true

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.appState.isDebugPanelVisible = false
        }
    }

    private func toggleSettingsWindow() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.orderOut(nil)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow?.orderFrontRegardless()
        }
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()

        settingsWindow = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
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
        appState.startAccessibilityPolling()

        if !AXIsProcessTrusted() {
            appState.showAccessibilityAlert()
        }
    }
}
