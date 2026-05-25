import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var debugLogWindow: NSWindow?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetup),
            name: .showSetup,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowDebugLogs),
            name: .showDebugLogs,
            object: nil
        )

        // Refresh permissions on app activation
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appState.refreshPermissions()
        }

        // Cmd+Comma opens settings (standard macOS convention)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "," {
                guard self?.appState.hasCompletedSetup == true else { return event }
                self?.appState.selectedSettingsTab = .general
                NotificationCenter.default.post(name: .showSettings, object: nil)
                return nil
            }
            return event
        }

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()
            Task { @MainActor in
                UpdateManager.shared.startPeriodicChecks()
            }

            if !AXIsProcessTrusted() {
                appState.showAccessibilityAlert()
            }

            if appState.settingsWindowWasOpen {
                showSettingsWindow()
            }
        }

    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !appState.hasCompletedSetup {
            showSetupWindow()
            return true
        }
        if !flag {
            showSettingsWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Resume media if we had paused it during recording
        appState.handleAudioOnRecordingStop()
    }

    // MARK: - Activation Policy

    /// Show in dock/app switcher when any window is open, hide when all closed
    private func updateActivationPolicy() {
        let hasVisibleWindow = [settingsWindow, debugLogWindow, setupWindow]
            .contains { $0?.isVisible == true }

        NSApp.setActivationPolicy(hasVisibleWindow ? .regular : .accessory)
    }

    // MARK: - Notification Handlers

    @objc func handleShowSetup() {
        appState.hasCompletedSetup = false
        UserDefaults.standard.removeObject(forKey: "setupResumeStep")
        appState.stopAccessibilityPolling()
        showSetupWindow()
    }

    @objc private func handleShowSettings() {
        guard appState.hasCompletedSetup else {
            showSetupWindow()
            return
        }
        showSettingsWindow()
    }

    @objc private func handleShowDebugLogs() {
        guard appState.hasCompletedSetup else {
            showSetupWindow()
            return
        }
        showDebugLogWindow()
    }

    // MARK: - Window Management

    private func showSettingsWindow() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        updateActivationPolicy()
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wispah Flow"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
        appState.settingsWindowWasOpen = true

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
            if self?.isTerminating != true {
                self?.appState.settingsWindowWasOpen = false
            }
            self?.updateActivationPolicy()
        }
    }

    private func showDebugLogWindow() {
        if let debugLogWindow, debugLogWindow.isVisible {
            debugLogWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = DebugLogView()
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wispah Flow — Debug Logs"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 300)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugLogWindow = window
        updateActivationPolicy()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.debugLogWindow = nil
            self?.updateActivationPolicy()
        }
    }

    func showSetupWindow() {
        if let setupWindow, setupWindow.isVisible {
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let setupView = SetupView(onComplete: { [weak self] in
            self?.completeSetup()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Wispah Flow"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: setupView)
        window.minSize = NSSize(width: 520, height: 480)
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
        updateActivationPolicy()
    }

    func completeSetup() {
        appState.hasCompletedSetup = true
        UserDefaults.standard.removeObject(forKey: "setupResumeStep")
        setupWindow?.close()
        setupWindow = nil
        updateActivationPolicy()
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        Task { @MainActor in
            UpdateManager.shared.startPeriodicChecks()
        }

        if !AXIsProcessTrusted() {
            appState.showAccessibilityAlert()
        }
    }
}
