import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        appState.selectedSettingsTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(appState.selectedSettingsTab == tab
                                          ? Color.accentColor.opacity(0.15)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch appState.selectedSettingsTab {
                case .general, .none:
                    GeneralSettingsView()
                case .runLog:
                    RunLogView()
                case .debug:
                    DebugSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var apiKeyInput: String = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var keyValidationSuccess = false
    @State private var customVocabularyInput: String = ""
    @State private var micPermissionGranted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                apiKeySection
                Divider()
                hotkeySection
                Divider()
                vocabularySection
                Divider()
                permissionsSection
            }
            .padding(24)
        }
        .onAppear {
            apiKeyInput = appState.apiKey
            customVocabularyInput = appState.customVocabulary
            checkMicPermission()
        }
    }

    // MARK: API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API Key")
                .font(.headline)
            Text("Voice to Text uses Groq's whisper-large-v3 model for transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                SecureField("Enter your Groq API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isValidatingKey)
                    .onChange(of: apiKeyInput) { _ in
                        keyValidationError = nil
                        keyValidationSuccess = false
                    }

                Button(isValidatingKey ? "Validating..." : "Save") {
                    validateAndSaveKey()
                }
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)
            }

            if let error = keyValidationError {
                Label(error, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if keyValidationSuccess {
                Label("API key saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    private func validateAndSaveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isValidatingKey = true
        keyValidationError = nil
        keyValidationSuccess = false

        Task {
            let valid = await TranscriptionService.validateAPIKey(key)
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    appState.apiKey = key
                    keyValidationSuccess = true
                } else {
                    keyValidationError = "Invalid API key. Please check and try again."
                }
            }
        }
    }

    // MARK: Push-to-Talk Key

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Push-to-Talk Key")
                .font(.headline)
            Text("Hold this key to record, release to transcribe.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(HotkeyOption.allCases) { option in
                    HotkeyOptionRow(
                        option: option,
                        isSelected: appState.selectedHotkey == option,
                        action: {
                            appState.selectedHotkey = option
                        }
                    )
                }
            }

            if appState.selectedHotkey == .fnKey {
                Text("Tip: If Fn opens Emoji picker, go to System Settings > Keyboard and change \"Press fn key to\" to \"Do Nothing\".")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Custom Vocabulary

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom Vocabulary")
                .font(.headline)
            Text("Words and phrases to preserve during post-processing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $customVocabularyInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: customVocabularyInput) { newValue in
                    appState.customVocabulary = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }

            Text("Separate entries with commas, new lines, or semicolons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(.headline)

            permissionRow(
                title: "Microphone",
                icon: "mic.fill",
                granted: micPermissionGranted,
                action: {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            micPermissionGranted = granted
                        }
                    }
                }
            )

            permissionRow(
                title: "Accessibility",
                icon: "hand.raised.fill",
                granted: appState.hasAccessibility,
                action: {
                    appState.openAccessibilitySettings()
                }
            )

            permissionRow(
                title: "Screen Recording",
                icon: "camera.viewfinder",
                granted: appState.hasScreenRecordingPermission,
                action: {
                    appState.requestScreenCapturePermission()
                }
            )
        }
    }

    private func permissionRow(title: String, icon: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(title)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access") {
                    action()
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

// MARK: - Run Log

struct RunLogView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run Log")
                    .font(.headline)
                Spacer()
                Button("Clear History") {
                    appState.pipelineHistory = []
                }
                .disabled(appState.pipelineHistory.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if appState.pipelineHistory.isEmpty {
                VStack {
                    Spacer()
                    Text("No runs yet. Use dictation to populate history.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(appState.pipelineHistory) { item in
                            DisclosureGroup(
                                content: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Custom Vocabulary")
                                            .font(.headline)
                                        Text(item.customVocabulary.isEmpty ? "No custom vocabulary configured." : item.customVocabulary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(6)

                                        PipelineDebugContentView(
                                            statusMessage: item.debugStatus,
                                            postProcessingStatus: item.postProcessingStatus,
                                            contextSummary: item.contextSummary,
                                            contextScreenshotStatus: item.contextScreenshotStatus,
                                            contextScreenshotDataURL: item.contextScreenshotDataURL,
                                            rawTranscript: item.rawTranscript,
                                            postProcessedTranscript: item.postProcessedTranscript,
                                            postProcessingPrompt: item.postProcessingPrompt ?? ""
                                        )
                                    }
                                    .padding(.leading, 4)
                                },
                                label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.timestamp.formatted(date: .numeric, time: .standard))
                                            .font(.headline)
                                        Text(item.postProcessingStatus)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(item.rawTranscript.isEmpty ? "Raw: (none)" : "Raw: \(item.rawTranscript)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                            )
                            .padding(12)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

// MARK: - Debug

struct DebugSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Debug")
                    .font(.headline)
                Spacer()
                Button(appState.isDebugOverlayActive ? "Stop Debug Overlay" : "Start Debug Overlay") {
                    appState.toggleDebugOverlay()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PipelineDebugContentView(
                        statusMessage: appState.debugStatusMessage,
                        postProcessingStatus: appState.lastPostProcessingStatus,
                        contextSummary: appState.lastContextSummary,
                        contextScreenshotStatus: appState.lastContextScreenshotStatus,
                        contextScreenshotDataURL: appState.lastContextScreenshotDataURL,
                        rawTranscript: appState.lastRawTranscript,
                        postProcessedTranscript: appState.lastPostProcessedTranscript,
                        postProcessingPrompt: appState.lastPostProcessingPrompt
                    )

                    if appState.lastContextSummary.isEmpty && appState.lastRawTranscript.isEmpty {
                        Text("Run a dictation pass to populate debug output.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        }
    }
}
