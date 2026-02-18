import Cocoa
import Carbon

enum HotkeyOption: String, CaseIterable, Identifiable {
    case fnKey = "fn"
    case rightOption = "rightOption"
    case f5 = "f5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fnKey: return "Fn (Globe) Key"
        case .rightOption: return "Right Option Key"
        case .f5: return "F5 Key"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .fnKey: return 63       // Fn/Globe key
        case .rightOption: return 61 // Right Option
        case .f5: return 96          // F5
        }
    }

    var isModifier: Bool {
        switch self {
        case .fnKey, .rightOption: return true
        case .f5: return false
        }
    }
}

class HotkeyManager {
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var keyDownStates: [HotkeyOption: Bool] = [:]
    private var monitoredOptions: [HotkeyOption] = []

    var onKeyDown: ((HotkeyOption) -> Void)?
    var onKeyUp: ((HotkeyOption) -> Void)?


    func start(option: HotkeyOption) {
        start(options: [option])
    }

    func start(options: [HotkeyOption]) {
        stop()
        monitoredOptions = options
        for opt in options {
            keyDownStates[opt] = false
        }

        let hasModifier = options.contains(where: { $0.isModifier })
        let hasRegularKey = options.contains(where: { !$0.isModifier })

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

    private func matchingOption(for keyCode: UInt16) -> HotkeyOption? {
        monitoredOptions.first(where: { $0.keyCode == keyCode })
    }

    private func handleFlagsChanged(event: NSEvent) {
        for option in monitoredOptions where option.isModifier && event.keyCode == option.keyCode {
            let flagIsSet: Bool
            switch option {
            case .fnKey:
                flagIsSet = event.modifierFlags.contains(.function)
            case .rightOption:
                flagIsSet = event.modifierFlags.contains(.option)
            default:
                continue
            }

            let wasDown = keyDownStates[option] ?? false
            if flagIsSet && !wasDown {
                keyDownStates[option] = true
                onKeyDown?(option)
            } else if !flagIsSet && wasDown {
                keyDownStates[option] = false
                onKeyUp?(option)
            }
        }
    }

    private func handleKeyDown(event: NSEvent) {
        guard let option = matchingOption(for: event.keyCode), !option.isModifier else { return }
        guard !event.isARepeat else { return }
        let wasDown = keyDownStates[option] ?? false
        if !wasDown {
            keyDownStates[option] = true
            onKeyDown?(option)
        }
    }

    private func handleKeyUp(event: NSEvent) {
        guard let option = matchingOption(for: event.keyCode), !option.isModifier else { return }
        let wasDown = keyDownStates[option] ?? false
        if wasDown {
            keyDownStates[option] = false
            onKeyUp?(option)
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
        monitoredOptions.removeAll()
    }

    deinit {
        stop()
    }
}
