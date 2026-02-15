import Foundation
import Combine
import AppKit

class AppState: ObservableObject {
    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "assemblyai_api_key")
        }
    }

    @Published var selectedHotkey: HotkeyOption {
        didSet {
            UserDefaults.standard.set(selectedHotkey.rawValue, forKey: "hotkey_option")
            restartHotkeyMonitoring()
        }
    }

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()

    init() {
        self.hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        self.apiKey = UserDefaults.standard.string(forKey: "assemblyai_api_key") ?? ""

        let savedHotkey = UserDefaults.standard.string(forKey: "hotkey_option") ?? "fn"
        self.selectedHotkey = HotkeyOption(rawValue: savedHotkey) ?? .fnKey
    }

    func startHotkeyMonitoring() {
        hotkeyManager.onKeyDown = { [weak self] in
            DispatchQueue.main.async {
                self?.handleHotkeyDown()
            }
        }
        hotkeyManager.onKeyUp = { [weak self] in
            DispatchQueue.main.async {
                self?.handleHotkeyUp()
            }
        }
        hotkeyManager.start(option: selectedHotkey)
    }

    private func restartHotkeyMonitoring() {
        hotkeyManager.start(option: selectedHotkey)
    }

    private func handleHotkeyDown() {
        guard !isRecording && !isTranscribing else { return }
        startRecording()
    }

    private func handleHotkeyUp() {
        guard isRecording else { return }
        stopAndTranscribe()
    }

    func toggleRecording() {
        if isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        errorMessage = nil
        do {
            try audioRecorder.startRecording()
            isRecording = true
            statusText = "Recording..."
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            statusText = "Error"
        }
    }

    private func stopAndTranscribe() {
        guard let fileURL = audioRecorder.stopRecording() else {
            errorMessage = "No audio recorded"
            isRecording = false
            statusText = "Error"
            return
        }
        isRecording = false
        isTranscribing = true
        statusText = "Transcribing..."

        let service = TranscriptionService(apiKey: apiKey)

        Task {
            do {
                let text = try await service.transcribe(fileURL: fileURL)
                await MainActor.run {
                    self.lastTranscript = text
                    self.isTranscribing = false
                    self.statusText = "Copied to clipboard!"

                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.pasteAtCursor()
                    }

                    self.audioRecorder.cleanup()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.statusText == "Copied to clipboard!" {
                            self.statusText = "Ready"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isTranscribing = false
                    self.statusText = "Error"
                    self.audioRecorder.cleanup()
                }
            }
        }
    }

    private func pasteAtCursor() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
