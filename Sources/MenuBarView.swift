import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 4) {
            // Status
            if appState.isRecording {
                Label("Recording...", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else if appState.isTranscribing {
                Label("Transcribing...", systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                Text("Hold \(appState.selectedHotkey.displayName) to dictate")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Divider()

            // Manual toggle
            Button(appState.isRecording ? "Stop Recording" : "Start Dictating") {
                appState.toggleRecording()
            }
            .disabled(appState.isTranscribing)

            if let error = appState.errorMessage {
                Divider()
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            if !appState.lastTranscript.isEmpty && !appState.isRecording && !appState.isTranscribing {
                Divider()
                Text(appState.lastTranscript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .lineLimit(4)
                    .frame(maxWidth: 280, alignment: .leading)

                Button("Copy Again") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.lastTranscript, forType: .string)
                }
            }

            Divider()

            // Hotkey picker
            Menu("Push-to-Talk Key") {
                ForEach(HotkeyOption.allCases) { option in
                    Button {
                        appState.selectedHotkey = option
                    } label: {
                        if appState.selectedHotkey == option {
                            Text("✓ \(option.displayName)")
                        } else {
                            Text("  \(option.displayName)")
                        }
                    }
                }
            }

            Divider()

            Button("Quit Voice to Text") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }
}
