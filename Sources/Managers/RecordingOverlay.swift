import SwiftUI
import AppKit

// MARK: - State

class RecordingOverlayState: ObservableObject {
    @Published var phase: OverlayPhase = .recording
    @Published var audioLevel: Float = 0.0
}

enum OverlayPhase {
    case initializing
    case recording
    case transcribing
    case done
}

class ErrorOverlayState: ObservableObject {
    @Published var message: String = ""
    var onDismiss: (() -> Void)?
}

// MARK: - Panel Helpers

private func makeOverlayPanel(width: CGFloat, height: CGFloat, ignoresMouseEvents: Bool = true) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .screenSaver
    panel.ignoresMouseEvents = ignoresMouseEvents
    panel.collectionBehavior = [.canJoinAllSpaces]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
}

/// Creates a container with a vibrancy blur layer and a SwiftUI overlay for the liquid glass effect.
private func makeGlassContent<V: View>(
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat,
    maskedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner],
    rootView: V
) -> NSView {
    let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0

    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    container.wantsLayer = true
    container.layer?.contentsScale = scaleFactor
    container.layer?.backgroundColor = .clear

    let hosting = NSHostingView(rootView: rootView)
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    hosting.wantsLayer = true
    hosting.layer?.contentsScale = scaleFactor
    hosting.layer?.backgroundColor = .clear
    container.addSubview(hosting)

    return container
}

// MARK: - Manager

class RecordingOverlayManager {
    private var overlayWindow: NSPanel?
    private var transcribingPanel: NSPanel?
    private var errorPanel: NSPanel?
    private var errorDismissWorkItem: DispatchWorkItem?
    private var overlayState = RecordingOverlayState()
    private var errorState = ErrorOverlayState()

    /// Whether the main screen has a camera housing (notch).
    private var screenHasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }

    func showInitializing() {
        DispatchQueue.main.async {
            self.overlayState.phase = .initializing
            self.overlayState.audioLevel = 0.0
            self._showOverlayPanel()
        }
    }

    func showRecording() {
        DispatchQueue.main.async {
            self.overlayState.phase = .recording
            self.overlayState.audioLevel = 0.0
            self._showOverlayPanel()
        }
    }

    func transitionToRecording() {
        DispatchQueue.main.async { self.overlayState.phase = .recording }
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async { self.overlayState.audioLevel = level }
    }

    func showTranscribing() {
        DispatchQueue.main.async { self._showTranscribing() }
    }

    func slideUpToNotch(completion: @escaping () -> Void) {
        DispatchQueue.main.async { self._slideUpToNotch(completion: completion) }
    }

    func showDone() {
        DispatchQueue.main.async { self._showDone() }
    }

    func showError(_ message: String) {
        DispatchQueue.main.async { self._showError(message) }
    }

    func dismiss() {
        DispatchQueue.main.async { self._dismiss() }
    }

    private func _showOverlayPanel() {
        let panelWidth: CGFloat = 120
        let panelHeight: CGFloat = 32

        let hasNotch = screenHasNotch
        let notchInset: CGFloat = 4 // tuck flat top behind menu bar (notch screens only)

        if let panel = overlayWindow {
            guard let screen = NSScreen.main else { return }
            let x = panelX(screen, width: panelWidth)
            let y: CGFloat
            if hasNotch {
                y = screen.visibleFrame.maxY - panelHeight + notchInset
            } else {
                y = screen.frame.maxY - panelHeight
            }
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let panel = makeOverlayPanel(width: panelWidth, height: panelHeight)

        let view = RecordingOverlayView(state: overlayState)
        panel.contentView = makeGlassContent(
            width: panelWidth,
            height: panelHeight,
            cornerRadius: 12,
            maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner],
            rootView: view
        )

        if let screen = NSScreen.main {
            let x = panelX(screen, width: panelWidth)
            let hiddenY: CGFloat
            let visibleY: CGFloat
            if hasNotch {
                // Start hidden behind menu bar, pop out from notch
                hiddenY = screen.visibleFrame.maxY
                visibleY = screen.visibleFrame.maxY - panelHeight + notchInset
            } else {
                // Start hidden above screen top, pop in from very top
                hiddenY = screen.frame.maxY
                visibleY = screen.frame.maxY - panelHeight
            }

            panel.setFrame(NSRect(x: x, y: hiddenY, width: panelWidth, height: panelHeight), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()

            // Spring-like drop: overshoots slightly then settles
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
                panel.animator().setFrame(NSRect(x: x, y: visibleY, width: panelWidth, height: panelHeight), display: true)
            }
        }

        self.overlayWindow = panel
    }

    private func _slideUpToNotch(completion: @escaping () -> Void) {
        guard let panel = overlayWindow, let screen = NSScreen.main else {
            completion()
            return
        }

        // Release immediately so a new recording can create a fresh panel
        self.overlayWindow = nil

        let hiddenY = screenHasNotch ? screen.visibleFrame.maxY : screen.frame.maxY
        let frame = panel.frame

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            panel.animator().setFrame(NSRect(x: frame.origin.x, y: hiddenY, width: frame.width, height: frame.height), display: true)
        }, completionHandler: {
            panel.orderOut(nil)
            completion()
        })
    }

    private func _showTranscribing() {
        overlayState.phase = .transcribing

        if let panel = overlayWindow {
            panel.orderOut(nil)
            overlayWindow = nil
        }

        if transcribingPanel != nil { return }

        let panelWidth: CGFloat = 44
        let panelHeight: CGFloat = 22

        let panel = makeOverlayPanel(width: panelWidth, height: panelHeight)

        let view = TranscribingIndicatorView()
        panel.contentView = makeGlassContent(
            width: panelWidth,
            height: panelHeight,
            cornerRadius: 11,
            maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner],
            rootView: view
        )

        if let screen = NSScreen.main {
            let x = panelX(screen, width: panelWidth)
            let y: CGFloat
            if screenHasNotch {
                y = screen.visibleFrame.maxY - panelHeight
            } else {
                y = screen.frame.maxY - panelHeight
            }
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }

        self.transcribingPanel = panel
    }

    private func _showDone() {
        overlayState.phase = .done

        if let panel = transcribingPanel {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                self.transcribingPanel = nil
            })
        }
    }

    private func _showError(_ message: String) {
        // Dismiss any existing overlays
        _dismiss()
        cancelScheduledErrorDismiss()

        errorState.message = message
        errorState.onDismiss = { [weak self] in
            self?._dismissError()
        }

        guard let screen = NSScreen.main else { return }
        let hasNotch = screenHasNotch

        // Step 1: Show the pill dropping from the notch (same as recording start)
        let pillWidth: CGFloat = 120
        let pillHeight: CGFloat = 32
        let notchInset: CGFloat = 4

        let pillPanel = makeOverlayPanel(width: pillWidth, height: pillHeight, ignoresMouseEvents: false)

        let pillView = ErrorPillView()
        pillPanel.contentView = makeGlassContent(
            width: pillWidth,
            height: pillHeight,
            cornerRadius: 12,
            maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner],
            rootView: pillView
        )

        let pillX = panelX(screen, width: pillWidth)
        let hiddenY: CGFloat
        let visibleY: CGFloat
        if hasNotch {
            hiddenY = screen.visibleFrame.maxY
            visibleY = screen.visibleFrame.maxY - pillHeight + notchInset
        } else {
            hiddenY = screen.frame.maxY
            visibleY = screen.frame.maxY - pillHeight
        }

        pillPanel.setFrame(NSRect(x: pillX, y: hiddenY, width: pillWidth, height: pillHeight), display: true)
        pillPanel.alphaValue = 1
        pillPanel.orderFrontRegardless()
        self.overlayWindow = pillPanel

        // Animate pill drop
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            pillPanel.animator().setFrame(NSRect(x: pillX, y: visibleY, width: pillWidth, height: pillHeight), display: true)
        }, completionHandler: {
            // Step 2: Shake the pill + play error sound
            NSSound(named: "Funk")?.play()
            self._shakePanel(pillPanel)

            // Step 3: Error drops out mid-shake — like it was shaken loose
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self._dropErrorLabel(message, screen: screen, pillY: visibleY)
            }
        })

        // Step 4: Auto-dismiss everything after 3s
        scheduleErrorDismiss()
    }

    private func _dropErrorLabel(_ message: String, screen: NSScreen, pillY: CGFloat) {
        errorState.message = message

        let panelWidth: CGFloat = 260
        let panelHeight: CGFloat = 30
        let gap: CGFloat = 6

        let panel = makeOverlayPanel(width: panelWidth, height: panelHeight, ignoresMouseEvents: false)

        let view = ErrorOverlayView(state: errorState)
        panel.contentView = makeGlassContent(
            width: panelWidth,
            height: panelHeight,
            cornerRadius: 8,
            rootView: view
        )

        let x = panelX(screen, width: panelWidth)
        let finalY = pillY - panelHeight - gap
        let startY = finalY + 12 // starts tucked up behind the pill

        panel.setFrame(NSRect(x: x, y: startY, width: panelWidth, height: panelHeight), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.errorPanel = panel

        // Drop down + fade in — shaken loose from the pill
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.64, 1.0)
            panel.animator().setFrame(NSRect(x: x, y: finalY, width: panelWidth, height: panelHeight), display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func _dismissError() {
        cancelScheduledErrorDismiss()

        let errorPanelRef = errorPanel
        let pillPanelRef = overlayWindow

        // Step 1: Error label fades out + slides up (back toward the pill)
        if let errorPanelRef {
            let frame = errorPanelRef.frame
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                errorPanelRef.animator().alphaValue = 0
                errorPanelRef.animator().setFrame(
                    NSRect(x: frame.origin.x, y: frame.origin.y + 10, width: frame.width, height: frame.height),
                    display: true
                )
            }, completionHandler: {
                errorPanelRef.orderOut(nil)
            })
        }
        self.errorPanel = nil

        // Step 2: Pill slides back up into the notch (after a short delay)
        if let pillPanelRef, let screen = NSScreen.main {
            let hiddenY = screenHasNotch ? screen.visibleFrame.maxY : screen.frame.maxY
            let frame = pillPanelRef.frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
                    pillPanelRef.animator().setFrame(
                        NSRect(x: frame.origin.x, y: hiddenY, width: frame.width, height: frame.height),
                        display: true
                    )
                }, completionHandler: {
                    pillPanelRef.orderOut(nil)
                    self?.overlayWindow = nil
                })
            }
        } else {
            self.overlayWindow = nil
        }

        errorState.onDismiss = nil
    }

    private func _shakePanel(_ panel: NSPanel) {
        let frame = panel.frame
        let shakeOffset: CGFloat = 8
        let shakeDuration: TimeInterval = 0.06

        // 4 rapid shakes: right, left, right, left, center
        let offsets: [CGFloat] = [shakeOffset, -shakeOffset, shakeOffset * 0.6, -shakeOffset * 0.6, 0]
        var delay: TimeInterval = 0

        for offset in offsets {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = shakeDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(
                        NSRect(x: frame.origin.x + offset, y: frame.origin.y, width: frame.width, height: frame.height),
                        display: true
                    )
                }
            }
            delay += shakeDuration
        }
    }

    private func _dismiss() {
        cancelScheduledErrorDismiss()

        if let panel = overlayWindow {
            panel.orderOut(nil)
            overlayWindow = nil
        }
        if let panel = transcribingPanel {
            panel.orderOut(nil)
            transcribingPanel = nil
        }
        if let panel = errorPanel {
            panel.orderOut(nil)
            errorPanel = nil
        }

        errorState.onDismiss = nil
    }

    private func scheduleErrorDismiss() {
        let workItem = DispatchWorkItem { [weak self] in
            self?._dismissError()
        }
        errorDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: workItem)
    }

    private func cancelScheduledErrorDismiss() {
        errorDismissWorkItem?.cancel()
        errorDismissWorkItem = nil
    }

    private func panelX(_ screen: NSScreen, width: CGFloat) -> CGFloat {
        screen.frame.midX - width / 2
    }
}

// MARK: - Liquid Glass Overlay

/// Decorative layers on top of the NSVisualEffectView blur to create a liquid glass appearance:
/// a specular highlight gradient and a gradient border that's brighter where light hits.
private struct LiquidGlassOverlay<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        ZStack {
            // Dark tint over the blur for a deeper glass look
            shape
                .fill(.black.opacity(0.45))

            // Specular highlight — subtle light refraction at the top
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.12), location: 0),
                            .init(color: .white.opacity(0.03), location: 0.35),
                            .init(color: .clear, location: 0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Glass edge — gradient border, brighter at top
            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.35), location: 0),
                            .init(color: .white.opacity(0.1), location: 0.5),
                            .init(color: .white.opacity(0.04), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
    }
}

// MARK: - Waveform Views

struct WaveformBar: View {
    let amplitude: CGFloat

    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 20

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.white, .white.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3, height: minHeight + (maxHeight - minHeight) * amplitude)
    }
}

struct WaveformView: View {
    let audioLevel: Float

    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                WaveformBar(amplitude: barAmplitude(for: index))
                    .animation(
                        .interpolatingSpring(stiffness: 600, damping: 28),
                        value: audioLevel
                    )
            }
        }
        .frame(height: 20)
    }

    private func barAmplitude(for index: Int) -> CGFloat {
        let level = CGFloat(audioLevel)
        // Power curve to boost quieter levels visually
        let boosted = sqrt(level)
        return min(boosted * Self.multipliers[index], 1.0)
    }
}

// MARK: - Recording Overlay View

struct InitializingDotsView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(activeDot == index ? 0.9 : 0.25))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: activeDot)
            }
        }
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                DispatchQueue.main.async { activeDot = (activeDot + 1) % 3 }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState

    var body: some View {
        Group {
            if state.phase == .initializing {
                InitializingDotsView()
                    .frame(width: 100, height: 20)
                    .transition(.opacity)
            } else {
                WaveformView(audioLevel: state.audioLevel)
                    .frame(width: 100, height: 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.phase == .initializing)
        .frame(width: 120, height: 32)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                .fill(Color(white: 0.08))
        )
    }
}

// MARK: - Transcribing Indicator

struct TranscribingIndicatorView: View {
    @State private var animatingDot = 0
    @State private var dotAnimationTimer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(animatingDot == index ? 0.9 : 0.25))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: animatingDot)
            }
        }
        .frame(width: 44, height: 22)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11)
                .fill(Color(white: 0.08))
        )
        .onAppear { startDotAnimation() }
        .onDisappear { stopDotAnimation() }
    }

    private func startDotAnimation() {
        dotAnimationTimer?.invalidate()
        dotAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                animatingDot = (animatingDot + 1) % 3
            }
        }
    }

    private func stopDotAnimation() {
        dotAnimationTimer?.invalidate()
        dotAnimationTimer = nil
    }
}

// MARK: - Error Overlay Views

struct ErrorPillView: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.red.opacity(0.7))
            .frame(width: 120, height: 32)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                    .fill(Color(white: 0.08))
            )
    }
}

struct ErrorOverlayView: View {
    @ObservedObject var state: ErrorOverlayState

    var body: some View {
        HStack(spacing: 8) {
            Text(state.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { state.onDismiss?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(width: 260, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.75)
        )
    }
}
