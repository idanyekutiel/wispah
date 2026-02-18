import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import os.log

extension AppState {
    func startContextCapture() {
        contextCaptureTask?.cancel()
        capturedContext = nil
        lastPostProcessingStatus = ""
        lastContextScreenshotDataURL = nil

        if !screenRecordingEnabled {
            lastContextSummary = "Collecting app context (text only)..."
            lastContextScreenshotStatus = "Screen recording disabled"

            contextCaptureTask = Task { [weak self] in
                guard let self else { return nil }
                let frontmostApp = NSWorkspace.shared.frontmostApplication
                let windowTitle = self.focusedWindowTitle(for: frontmostApp)
                let context = AppContext(
                    appName: frontmostApp?.localizedName,
                    bundleIdentifier: frontmostApp?.bundleIdentifier,
                    windowTitle: windowTitle,
                    selectedText: nil,
                    currentActivity: "Screen recording disabled. Using text-only context: \(frontmostApp?.localizedName ?? "Unknown") — \(windowTitle ?? "Unknown window").",
                    contextPrompt: nil,
                    screenshotDataURL: nil,
                    screenshotMimeType: nil,
                    screenshotError: nil
                )
                await MainActor.run {
                    self.capturedContext = context
                    self.lastContextSummary = context.contextSummary
                    self.lastContextScreenshotStatus = "Screen recording disabled"
                    self.lastPostProcessingStatus = "App context captured (text only)"
                }
                return context
            }
            return
        }

        lastContextSummary = "Collecting app context..."
        lastContextScreenshotStatus = "Collecting screenshot..."

        contextCaptureTask = Task { [weak self] in
            guard let self else { return nil }
            let context = await self.contextService.collectContext()
            await MainActor.run {
                self.capturedContext = context
                self.lastContextSummary = context.contextSummary
                self.lastContextScreenshotDataURL = context.screenshotDataURL
                self.lastContextScreenshotStatus = context.screenshotError
                    ?? "available (\(context.screenshotMimeType ?? "image"))"
                self.lastPostProcessingStatus = "App context captured"
                self.handleScreenshotCaptureIssue(context.screenshotError)
            }
            return context
        }
    }

    func fallbackContextAtStop() -> AppContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let windowTitle = focusedWindowTitle(for: frontmostApp)
        return AppContext(
            appName: frontmostApp?.localizedName,
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: nil,
            currentActivity: "Could not refresh app context at stop time; using text-only post-processing.",
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: "No app context captured before stop"
        )
    }

    func focusedWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return focusedWindowTitle(from: appElement)
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }
        guard let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) else {
            return nil
        }
        return trimmedText(windowTitle)
    }

    func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue
    }

    private func trimmedText(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    func handleScreenshotCaptureIssue(_ message: String?) {
        guard let message, !message.isEmpty else {
            hasShownScreenshotPermissionAlert = false
            return
        }
        os_log(.info, log: recordingLog, "Screenshot capture issue (non-fatal): %{public}@", message)
    }
}
