import SwiftUI

// MARK: - Microphone Option Row

struct MicrophoneOptionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hotkey Recorder Button

struct HotkeyRecorderButton: View {
    let label: String
    @Binding var binding: HotkeyBinding
    @EnvironmentObject private var appState: AppState
    @State private var isRecording = false
    @State private var pulseOpacity = false
    @State private var globalKeyMonitor: Any?
    @State private var localKeyMonitor: Any?
    @State private var globalFlagsMonitor: Any?
    @State private var localFlagsMonitor: Any?

    // Chord accumulation state
    @State private var heldModifierFlags: NSEvent.ModifierFlags = []
    @State private var lastModifierKeyCode: UInt16 = 0

    /// Modifiers that can participate in key combos, including Fn.
    private static let comboModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]

    /// Live preview of the chord being built
    private var chordPreview: String {
        var parts: [String] = []
        if heldModifierFlags.contains(.function) { parts.append("Fn ") }
        if heldModifierFlags.contains(.control) { parts.append("⌃") }
        if heldModifierFlags.contains(.option) { parts.append("⌥") }
        if heldModifierFlags.contains(.shift) { parts.append("⇧") }
        if heldModifierFlags.contains(.command) { parts.append("⌘") }
        if parts.isEmpty { return "Press a key..." }
        return parts.joined() + "…"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 100, alignment: .leading)

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack(spacing: 6) {
                    if isRecording {
                        Text(chordPreview)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(.blue)
                            .opacity(pulseOpacity ? 0.5 : 1.0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseOpacity)
                    } else {
                        Text(binding.displayName)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(binding.isDisabled ? .secondary : .primary)
                    }
                }
                .frame(minWidth: 120)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isRecording ? Color.blue.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isRecording ? Color.blue : Color.secondary.opacity(0.3), lineWidth: isRecording ? 2 : 1)
                )
            }
            .buttonStyle(.plain)

            if isRecording {
                Button("Cancel") {
                    stopRecording()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if !binding.isDisabled {
                Button {
                    binding = .disabled
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Clear hotkey")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        isRecording = true
        pulseOpacity = true
        heldModifierFlags = []
        lastModifierKeyCode = 0

        // Pause hotkey monitoring so the recorded key doesn't trigger actions
        appState.hotkeyManager.stop()

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlags(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlags(event)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
            return nil // consume
        }
    }

    private func stopRecording() {
        isRecording = false
        pulseOpacity = false
        heldModifierFlags = []
        lastModifierKeyCode = 0
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }

        appState.restartHotkeyMonitoring()
    }

    // MARK: - Event handling

    private func handleFlags(_ event: NSEvent) {
        guard isRecording else { return }
        let keyCode = event.keyCode
        guard isModifierKeyCode(keyCode) else { return }

        let newMods = event.modifierFlags.intersection(Self.comboModifierMask)
        let addedMods = newMods.subtracting(heldModifierFlags)

        if !addedMods.isEmpty {
            lastModifierKeyCode = keyCode
        }

        if newMods.isEmpty && !heldModifierFlags.isEmpty && lastModifierKeyCode != 0 {
            finalizeModifierOnlyBinding(keyCode: lastModifierKeyCode, modifiers: heldModifierFlags)
            return
        }

        heldModifierFlags = newMods
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isRecording else { return }

        // Escape with no modifiers held → cancel
        if event.keyCode == 53 && heldModifierFlags.isEmpty {
            stopRecording()
            return
        }

        // Regular key pressed → finalize as combo (modifiers + key) or plain key
        let keyCode = event.keyCode
        let modifiers = heldModifierFlags
        let chars = event.charactersIgnoringModifiers
        let name = displayNameForKey(keyCode: keyCode, modifiers: modifiers, characters: chars)

        let newBinding = HotkeyBinding(
            keyCode: keyCode,
            modifierFlags: modifiers.rawValue,
            displayName: name,
            isModifier: false
        )
        binding = newBinding
        stopRecording()
    }

    private func finalizeModifierOnlyBinding(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let ownFlag = modifierFlag(for: keyCode)
        let storedModifiers = ownFlag.map { modifiers.subtracting($0) } ?? modifiers
        let name = displayNameForKey(keyCode: keyCode, modifiers: storedModifiers, characters: nil)
        let newBinding = HotkeyBinding(
            keyCode: keyCode,
            modifierFlags: storedModifiers.rawValue,
            displayName: name,
            isModifier: true
        )
        binding = newBinding
        stopRecording()
    }

    // MARK: - Helpers

    private func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        [55, 54, 56, 60, 58, 61, 59, 62, 63].contains(keyCode)
    }

    private func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 63: return .function
        case 58, 61: return .option
        case 55, 54: return .command
        case 56, 60: return .shift
        case 59, 62: return .control
        default: return nil
        }
    }
}
