import Foundation
import ApplicationServices
import AppKit

struct AppContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let currentActivity: String
    let screenshotDataURL: String?
    let screenshotMimeType: String?
    let screenshotError: String?

    var contextSummary: String {
        var lines: [String] = ["Current activity: \(currentActivity)"]

        lines.append("Current app: \(appName ?? "Unknown")")

        if let bundleIdentifier {
            lines.append("Bundle ID: \(bundleIdentifier)")
        }
        if let windowTitle, !windowTitle.isEmpty {
            lines.append("Window: \(windowTitle)")
        }
        if let selectedText, !selectedText.isEmpty {
            lines.append("Visible selected text:\n\(selectedText)")
        }
        if let screenshotError {
            lines.append("Screenshot status: \(screenshotError)")
        } else {
            let mimeType = screenshotMimeType ?? "image"
            lines.append("Screenshot status: available (\(mimeType))")
        }

        return lines.joined(separator: "\n")
    }
}

final class AppContextService {
    private let apiKey: String
    private let baseURL = "https://api.groq.com/openai/v1"
    private let fallbackTextModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private let visionModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private let maxScreenshotDataURILength = 3_900_000

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func collectContext() async -> AppContext {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return AppContext(
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                currentActivity: "You are dictating in an unrecognized context.",
                screenshotDataURL: nil,
                screenshotMimeType: nil,
                screenshotError: "No frontmost application"
            )
        }

        let appName = frontmostApp.localizedName
        let bundleIdentifier = frontmostApp.bundleIdentifier
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        let windowTitle = focusedWindowTitle(from: appElement) ?? appName
        let selectedText = selectedText(from: appElement)
        let screenshot = captureActiveWindowScreenshot(
            processIdentifier: frontmostApp.processIdentifier,
            appElement: appElement,
            focusedWindowTitle: windowTitle
        )
        let currentActivity: String
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentActivity = await inferActivityWithLLM(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotDataURL: screenshot.dataURL
            ) ?? fallbackCurrentActivity(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                selectedText: selectedText,
                windowTitle: windowTitle,
                screenshotAvailable: screenshot.dataURL != nil
            )
        } else {
            currentActivity = fallbackCurrentActivity(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                selectedText: selectedText,
                windowTitle: windowTitle,
                screenshotAvailable: screenshot.dataURL != nil
            )
        }

        return AppContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: selectedText,
            currentActivity: currentActivity,
            screenshotDataURL: screenshot.dataURL,
            screenshotMimeType: screenshot.mimeType,
            screenshotError: screenshot.error
        )
    }

    private func inferActivityWithLLM(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        selectedText: String?,
        screenshotDataURL: String?
    ) async -> String? {
        let modelsToTry = [
            screenshotDataURL != nil ? visionModel : fallbackTextModel,
            fallbackTextModel
        ]

        for model in modelsToTry {
            let screenshotPayload = model == visionModel ? screenshotDataURL : nil
            if let inferred = await inferActivityWithLLM(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotDataURL: screenshotPayload,
                model: model
            ) {
                return inferred
            }
        }

        return nil
    }

    private func inferActivityWithLLM(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        selectedText: String?,
        screenshotDataURL: String?,
        model: String
    ) async -> String? {
        do {
            var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let metadata = """
App: \(appName ?? "Unknown")
Bundle ID: \(bundleIdentifier ?? "Unknown")
Window: \(windowTitle ?? "Unknown")
Selected text: \(selectedText ?? "None")
"""

            let systemPrompt = """
You are a context synthesis assistant for a speech-to-text pipeline.
Given app/window metadata and an optional screenshot, output exactly two sentences that describe what the user is doing right now and the likely writing intent in the current window.
Prioritize concrete details only from the context: for email, identify recipients, subject or thread cues, and whether the user is replying or composing; for terminal/code/text work, identify the active command, file, document title, or topic.
If details are missing, state uncertainty instead of inventing facts.
Return only two sentences, no labels, no markdown, no extra commentary.
"""

            let textOnlyPrompt = "Analyze the context and infer the user's current activity in exactly two sentences.\n\n\(metadata)"
            var userMessage: Any = textOnlyPrompt

            if let screenshotDataURL {
                userMessage = [
                    [
                        "type": "text",
                        "text": "Analyze the screenshot plus metadata to infer current activity."
                    ],
                    [
                        "type": "text",
                        "text": metadata
                    ],
                    [
                        "type": "image_url",
                        "image_url": ["url": screenshotDataURL]
                    ]
                ]
            }

            let payload: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userMessage]
                ]
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }

            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : normalizedActivitySummary(cleaned)
        } catch {
            return nil
        }
    }

    private func normalizedActivitySummary(_ value: String) -> String {
        let sentences = value
            .split(whereSeparator: { $0 == "." || $0 == "。" || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.count <= 2 {
            return value
        }

        let firstTwo = sentences.prefix(2)
        return firstTwo.joined(separator: ". ") + "."
    }

    private func fallbackCurrentActivity(
        appName: String?,
        bundleIdentifier: String?,
        selectedText: String?,
        windowTitle: String?,
        screenshotAvailable: Bool
    ) -> String {
        let activeApp = appName ?? "the active application"
        if screenshotAvailable {
            return "Could not reliably infer a two-sentence summary for \(activeApp) from the screenshot and metadata."
        }
        return "Could not reliably infer a two-sentence summary for \(activeApp) from the visible metadata."
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        if let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) {
            return trimmedText(windowTitle)
        }

        return nil
    }

    private func selectedText(from appElement: AXUIElement) -> String? {
        if let focusedElement = accessibilityElement(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let selectedText = accessibilityString(from: focusedElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        if let selectedText = accessibilityString(from: appElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        return nil
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return trimmedText(stringValue)
    }

    private func accessibilityPoint(from element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func accessibilitySize(from element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func captureActiveWindowScreenshot(
        processIdentifier: pid_t,
        appElement: AXUIElement,
        focusedWindowTitle: String?
    ) -> (dataURL: String?, mimeType: String?, error: String?) {
        if !CGPreflightScreenCaptureAccess() {
            return (
                nil,
                nil,
                "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording."
            )
        }

        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]

        guard let windows else {
            return (nil, nil, "Unable to read window list")
        }

        let ownerPIDKey = kCGWindowOwnerPID as String
        let layerKey = kCGWindowLayer as String
        let onScreenKey = kCGWindowIsOnscreen as String
        let windowIDKey = kCGWindowNumber as String
        let boundsKey = kCGWindowBounds as String
        let nameKey = kCGWindowName as String

        struct CandidateWindow {
            let id: CGWindowID
            let layer: Int
            let area: Int
            let bounds: CGRect?
            let name: String?
        }

        let candidateWindows = windows.compactMap { windowInfo -> CandidateWindow? in
            guard let ownerPID = windowInfo[ownerPIDKey] as? Int,
                  ownerPID == processIdentifier else {
                return nil
            }
            guard let isOnScreen = windowInfo[onScreenKey] as? Bool, isOnScreen else { return nil }
            guard let windowIDValue = windowInfo[windowIDKey] as? Int else { return nil }
            let layer = (windowInfo[layerKey] as? Int) ?? 0
            let bounds = boundsRect(windowInfo[boundsKey])
            let width = bounds?.width ?? 1
            let height = bounds?.height ?? 1
            let area = Int(width * height)
            let name = trimmedText(windowInfo[nameKey] as? String)

            return CandidateWindow(
                id: CGWindowID(windowIDValue),
                layer: layer,
                area: area,
                bounds: bounds,
                name: name
            )
        }

        if let focusedWindowBounds = focusedWindowBounds(from: appElement), !focusedWindowBounds.isNull {
            if let activeWindow = candidateWindows
                .compactMap({ candidate -> (CandidateWindow, CGFloat)? in
                    guard let candidateBounds = candidate.bounds else { return nil }
                    let intersection = candidateBounds.intersection(focusedWindowBounds)
                    guard !intersection.isNull else { return nil }
                    let overlap = intersection.width * intersection.height
                    return (candidate, overlap)
                })
                .sorted(by: { lhs, rhs in
                    if lhs.0.layer == rhs.0.layer {
                        return lhs.1 > rhs.1
                    }
                    return lhs.0.layer < rhs.0.layer
                })
                .first?.0 {
                if let dataURL = captureWindowImage(
                    windowID: activeWindow.id,
                    fileType: .jpeg,
                    mimeType: "image/jpeg",
                    compression: 0.5
                ) {
                    return (dataURL, "image/jpeg", nil)
                }
            }

            if let focusedWindowTitle,
               let activeWindow = candidateWindows
                   .filter({ candidate in
                       let normalizedName = candidate.name?
                           .lowercased()
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                       let normalizedTarget = focusedWindowTitle
                           .lowercased()
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                       guard let normalizedName, !normalizedName.isEmpty,
                             !normalizedTarget.isEmpty else {
                           return false
                       }

                       return normalizedName == normalizedTarget || normalizedName.contains(normalizedTarget)
                   })
                   .sorted(by: { lhs, rhs in
                       if lhs.layer == rhs.layer {
                           return lhs.area > rhs.area
                       }
                       return lhs.layer < rhs.layer
                   })
                   .first {
                if let dataURL = captureWindowImage(
                    windowID: activeWindow.id,
                    fileType: .jpeg,
                    mimeType: "image/jpeg",
                    compression: 0.5
                ) {
                    return (dataURL, "image/jpeg", nil)
                }
            }
        }

        guard let fullScreenImage = CGWindowListCreateImage(
            CGRect.infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return (nil, nil, "Could not capture screenshot (screen recording permission or window access issue)")
        }

        if let dataURL = convertImageToDataURL(
            fullScreenImage,
            mimeType: "image/jpeg",
            fileType: .jpeg,
            compression: 0.6,
            maxDimension: nil
        ) {
            return (dataURL, "image/jpeg", nil)
        }

        for targetSize in [2048.0, 1600.0, 1280.0, 1024.0, 768.0, 640.0, 480.0, 360.0, 320.0] {
            let compression = targetSize >= 1024.0 ? 0.6 : 0.45
            if let dataURL = convertImageToDataURL(
                fullScreenImage,
                mimeType: "image/jpeg",
                fileType: .jpeg,
                compression: compression,
                maxDimension: targetSize
            ) {
                return (dataURL, "image/jpeg", nil)
            }
        }

        for targetSize in [320.0, 240.0, 180.0] {
            if let dataURL = convertImageToDataURL(
                fullScreenImage,
                mimeType: "image/jpeg",
                fileType: .jpeg,
                compression: 0.35,
                maxDimension: targetSize
            ) {
                return (dataURL, "image/jpeg", nil)
            }
        }

        for targetSize in [240.0, 160.0, 120.0] {
            if let dataURL = convertImageToDataURL(
                fullScreenImage,
                mimeType: "image/jpeg",
                fileType: .jpeg,
                compression: 0.3,
                maxDimension: targetSize
            ) {
                return (dataURL, "image/jpeg", nil)
            }
        }

        return (nil, nil, "Could not capture screenshot within size limits")
    }

    private func captureWindowImage(
        windowID: CGWindowID,
        fileType: NSBitmapImageRep.FileType,
        mimeType: String,
        compression: Double? = nil,
        maxDimension: CGFloat? = nil
    ) -> String? {
        guard let image = CGWindowListCreateImage(
            .zero,
            .optionIncludingWindow,
            windowID,
            [.bestResolution]
        ) else {
            return nil
        }

        if let dataURL = convertImageToDataURL(
            image,
            mimeType: mimeType,
            fileType: fileType,
            compression: compression,
            maxDimension: maxDimension
        ) {
            return dataURL
        }

        return nil
    }

    private func boundsValue(_ value: Any?) -> CGSize? {
        guard let bounds = value as? [String: Any],
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private func boundsRect(_ value: Any?) -> CGRect? {
        guard let bounds = value as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func focusedWindowBounds(from appElement: AXUIElement) -> CGRect? {
        guard let focusedWindow = accessibilityElement(
            from: appElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ),
              let point = accessibilityPoint(from: focusedWindow, attribute: kAXPositionAttribute as CFString),
              let size = accessibilitySize(from: focusedWindow, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    private func convertImageToDataURL(
        _ image: CGImage,
        mimeType: String,
        fileType: NSBitmapImageRep.FileType,
        compression: Double?,
        maxDimension: CGFloat?
    ) -> String? {
        let imageToEncode = maxDimension.flatMap { resizedImage(for: image, maxDimension: $0) } ?? image
        let imageRepresentation = NSBitmapImageRep(cgImage: imageToEncode)

        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if let compression {
            properties[.compressionFactor] = compression
        }

        guard let imageData = imageRepresentation.representation(using: fileType, properties: properties) else {
            return nil
        }

        let base64 = imageData.base64EncodedString()
        guard base64.count <= maxScreenshotDataURILength else { return nil }
        return "data:\(mimeType);base64,\(base64)"
    }

    private func resizedImage(for image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        guard width > maxDimension || height > maxDimension else {
            return image
        }

        let scale = min(maxDimension / width, maxDimension / height, 1.0)
        let targetSize = CGSize(width: width * scale, height: height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return context.makeImage()
    }

    private func trimmedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }
}
