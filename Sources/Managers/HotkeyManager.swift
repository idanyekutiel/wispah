import Cocoa
import Carbon

// MARK: - HotkeyBinding

struct HotkeyBinding: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let modifierFlags: UInt    // NSEvent.ModifierFlags.rawValue, masked to device-independent
    let displayName: String
    let isModifier: Bool       // true for standalone modifier keys (Fn, Option, etc.)

    static let disabled = HotkeyBinding(keyCode: 0, modifierFlags: 0, displayName: "Disabled", isModifier: false)
    static let fnKey = HotkeyBinding(keyCode: 63, modifierFlags: 0, displayName: "Fn (Globe)", isModifier: true)

    var isDisabled: Bool { self == .disabled }

    /// Migrate old HotkeyOption rawValue strings to HotkeyBinding
    static func fromLegacy(_ rawValue: String) -> HotkeyBinding? {
        switch rawValue {
        case "disabled": return .disabled
        case "fn": return .fnKey
        case "rightOption": return HotkeyBinding(keyCode: 61, modifierFlags: 0, displayName: "Right Option", isModifier: true)
        case "f5": return HotkeyBinding(keyCode: 96, modifierFlags: 0, displayName: "F5", isModifier: false)
        default: return nil
        }
    }

    /// The modifier flag to check for this key when it's a modifier key
    var modifierFlag: NSEvent.ModifierFlags? {
        guard isModifier else { return nil }
        switch keyCode {
        case 63: return .function                    // Fn/Globe
        case 58, 61: return .option                  // Left/Right Option
        case 55, 54: return .command                 // Left/Right Command
        case 56, 60: return .shift                   // Left/Right Shift
        case 59, 62: return .control                 // Left/Right Control
        default: return nil
        }
    }
}

// MARK: - Display Name Generation

func displayNameForKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String? = nil) -> String {
    // Build modifier prefix
    var prefix = ""
    let deviceIndependent = modifiers.intersection(.deviceIndependentFlagsMask)
    // Only add modifier symbols if they're combined with a non-modifier key
    if !isModifierKeyCode(keyCode) {
        if deviceIndependent.contains(.control) { prefix += "⌃" }
        if deviceIndependent.contains(.option) { prefix += "⌥" }
        if deviceIndependent.contains(.shift) { prefix += "⇧" }
        if deviceIndependent.contains(.command) { prefix += "⌘" }
    }

    // Known modifier keyCodes (standalone)
    switch keyCode {
    case 63: return "Fn (Globe)"
    case 58: return "Left Option"
    case 61: return "Right Option"
    case 55: return "Left Command"
    case 54: return "Right Command"
    case 56: return "Left Shift"
    case 60: return "Right Shift"
    case 59: return "Left Control"
    case 62: return "Right Control"
    default: break
    }

    // F-keys
    let fKeyMap: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    if let fKey = fKeyMap[keyCode] {
        return prefix + fKey
    }

    // Special keys
    let specialKeyMap: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
        53: "Escape", 76: "Enter", 115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down", 123: "Left Arrow",
        124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
        71: "Clear", 117: "Forward Delete",
    ]
    if let special = specialKeyMap[keyCode] {
        return prefix + special
    }

    // Regular keys — use characters
    if let chars = characters?.uppercased(), !chars.isEmpty {
        return prefix + chars
    }

    return prefix + "Key \(keyCode)"
}

private func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
    [55, 54, 56, 60, 58, 61, 59, 62, 63].contains(keyCode)
}

// MARK: - HotkeyManager

class HotkeyManager {
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var keyDownStates: [UInt16: Bool] = [:]
    private var monitoredBindings: [HotkeyBinding] = []

    var onKeyDown: ((HotkeyBinding) -> Void)?
    var onKeyUp: ((HotkeyBinding) -> Void)?

    func start(bindings: [HotkeyBinding]) {
        stop()
        monitoredBindings = bindings.filter { !$0.isDisabled }
        for binding in monitoredBindings {
            keyDownStates[binding.keyCode] = false
        }

        let hasModifier = monitoredBindings.contains(where: { $0.isModifier })
        let hasRegularKey = monitoredBindings.contains(where: { !$0.isModifier })

        if hasModifier {
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event: event)
            }
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event: event)
                return event
            }
        }

        if hasRegularKey {
            globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event: event)
            }
            globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
                self?.handleKeyUp(event: event)
            }
            localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event: event)
                return event
            }
            localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                self?.handleKeyUp(event: event)
                return event
            }
        }
    }

    /// Modifiers we compare when matching combo bindings (⌃⌥⇧⌘)
    private static let relevantModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// Match a non-modifier binding by keyCode + modifier flags
    private func matchingBinding(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags? = nil) -> HotkeyBinding? {
        monitoredBindings.first(where: { binding in
            guard binding.keyCode == keyCode else { return false }
            if binding.isModifier { return true }
            // For non-modifier bindings, also check that combo modifiers match
            guard let mods = modifiers else { return true }
            let eventMods = mods.intersection(Self.relevantModifierMask)
            let bindingMods = NSEvent.ModifierFlags(rawValue: binding.modifierFlags)
                .intersection(Self.relevantModifierMask)
            return eventMods == bindingMods
        })
    }

    private func handleFlagsChanged(event: NSEvent) {
        for binding in monitoredBindings where binding.isModifier && binding.keyCode == event.keyCode {
            guard let flag = binding.modifierFlag else { continue }
            let flagIsSet = event.modifierFlags.contains(flag)

            let wasDown = keyDownStates[binding.keyCode] ?? false
            if flagIsSet && !wasDown {
                keyDownStates[binding.keyCode] = true
                onKeyDown?(binding)
            } else if !flagIsSet && wasDown {
                keyDownStates[binding.keyCode] = false
                onKeyUp?(binding)
            }
        }
    }

    private func handleKeyDown(event: NSEvent) {
        // Match by keyCode AND modifier flags (so ⌘K won't fire on bare K)
        guard let binding = matchingBinding(for: event.keyCode, modifiers: event.modifierFlags),
              !binding.isModifier else { return }
        guard !event.isARepeat else { return }
        let wasDown = keyDownStates[binding.keyCode] ?? false
        if !wasDown {
            keyDownStates[binding.keyCode] = true
            onKeyDown?(binding)
        }
    }

    private func handleKeyUp(event: NSEvent) {
        // On key up, match by keyCode only — modifiers may already be released
        guard let binding = matchingBinding(for: event.keyCode), !binding.isModifier else { return }
        let wasDown = keyDownStates[binding.keyCode] ?? false
        if wasDown {
            keyDownStates[binding.keyCode] = false
            onKeyUp?(binding)
        }
    }

    func stop() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyUpMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyUpMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyDownMonitor = nil
        globalKeyUpMonitor = nil
        localKeyDownMonitor = nil
        localKeyUpMonitor = nil
        keyDownStates.removeAll()
        monitoredBindings.removeAll()
    }

    deinit {
        stop()
    }
}
