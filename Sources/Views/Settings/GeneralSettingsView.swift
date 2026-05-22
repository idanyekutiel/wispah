import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @State private var apiKeyInput: String = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var keyValidationSuccess = false
    @State private var customVocabularyInput: String = ""
    @State private var showStatsDeleteConfirmation = false
    @State private var micPermissionGranted = false
    @StateObject private var githubCache = GitHubMetadataCache.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    private let repoURL = URL(string: "https://github.com/idanyekutiel/wispah")!

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // App branding header
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)

                    Text("Wispah Flow")
                        .font(.system(size: 20, weight: .bold, design: .rounded))

                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // GitHub card
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            AsyncImage(url: URL(string: "https://avatars.githubusercontent.com/u/54131016")) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().aspectRatio(contentMode: .fill)
                                default:
                                    Color.gray.opacity(0.2)
                                }
                            }
                            .frame(width: 22, height: 22)
                            .clipShape(Circle())

                            Button {
                                openURL(repoURL)
                            } label: {
                                Text("idanyekutiel/wispah")
                                    .font(.system(.caption, design: .monospaced).weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)

                            Spacer()

                            if githubCache.isLoading {
                                ProgressView().scaleEffect(0.5)
                            } else if let count = githubCache.starCount, count > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                        .font(.caption2)
                                    Text("\(count.formatted()) \(count == 1 ? "star" : "stars")")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.yellow.opacity(0.14)))
                            }

                            Button {
                                openURL(repoURL)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "star")
                                    Text("Star")
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.yellow.opacity(0.18)))
                            }
                            .buttonStyle(.plain)
                        }

                        if !githubCache.recentStargazers.isEmpty {
                            Divider()
                            HStack(spacing: 8) {
                                HStack(spacing: -6) {
                                    ForEach(githubCache.recentStargazers) { star in
                                        Button {
                                            openURL(star.user.htmlUrl)
                                        } label: {
                                            AsyncImage(url: star.user.avatarThumbnailUrl) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().aspectRatio(contentMode: .fill)
                                                default:
                                                    Color.gray.opacity(0.2)
                                                }
                                            }
                                            .frame(width: 22, height: 22)
                                            .clipShape(Circle())
                                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .clipped()
                                Text("recently starred")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                                Spacer()
                            }
                            .clipped()
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 4)

                settingsCard("Startup", icon: "power") {
                    startupSection
                }
                settingsCard("Updates", icon: "arrow.triangle.2.circlepath") {
                    updatesSection
                }

                sectionHeader("Recording")

                settingsCard("Recording Keys", icon: "keyboard.fill") {
                    hotkeySection
                }
                settingsCard("Microphone", icon: "mic.fill") {
                    microphoneSection
                }
                settingsCard("Sound", icon: "speaker.wave.2.fill") {
                    soundSection
                }
                settingsCard("Audio Behavior", icon: "speaker.wave.2.circle") {
                    audioBehaviorSection
                }

                sectionHeader("Transcription")

                settingsCard("API Key", icon: "key.fill") {
                    apiKeySection
                }
                settingsCard("Transcription", icon: "waveform") {
                    transcriptionSection
                }
                settingsCard("Language", icon: "globe") {
                    languageSection
                }
                settingsCard("Post-Processing", icon: "sparkles") {
                    postProcessingSection
                }

                sectionHeader("Data & Privacy")

                settingsCard("Log Settings", icon: "clock.arrow.circlepath") {
                    logSettingsSection
                }
                settingsCard("Permissions", icon: "lock.shield.fill") {
                    permissionsSection
                }

            }
            .padding(24)
        }
        .onAppear {
            apiKeyInput = appState.activeAPIKey
            customVocabularyInput = appState.customVocabulary
            checkMicPermission()
            appState.refreshLaunchAtLoginStatus()
            Task { await githubCache.fetchIfNeeded() }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private func settingsCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: Startup

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Launch Wispah Flow at login", isOn: $appState.launchAtLogin)

            if SMAppService.mainApp.status == .requiresApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Login item requires approval in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updateManager.autoCheckEnabled },
                set: { updateManager.autoCheckEnabled = $0 }
            ))

            HStack(spacing: 10) {
                Button {
                    Task {
                        await updateManager.checkForUpdates(userInitiated: true)
                    }
                } label: {
                    if updateManager.isChecking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking...")
                        }
                    } else {
                        Text("Check for Updates Now")
                    }
                }
                .disabled(updateManager.isChecking || updateManager.updateStatus != .idle)

                if let lastCheck = updateManager.lastCheckDate {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if updateManager.updateAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    switch updateManager.updateStatus {
                    case .downloading:
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Downloading update...")
                                    .font(.caption.weight(.semibold))
                                ProgressView(value: updateManager.downloadProgress ?? 0)
                                    .progressViewStyle(.linear)
                                if let progress = updateManager.downloadProgress {
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Cancel") {
                                updateManager.cancelDownload()
                            }
                            .font(.caption)
                        }

                    case .installing:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing update...")
                                .font(.caption.weight(.semibold))
                        }

                    case .readyToRelaunch:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Relaunching...")
                                .font(.caption.weight(.semibold))
                        }

                    case .error(let message):
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Spacer()
                            Button("Retry") {
                                updateManager.updateStatus = .idle
                                if let release = updateManager.latestRelease {
                                    updateManager.downloadAndInstall(release: release)
                                }
                            }
                            .font(.caption)
                        }

                    case .idle:
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                            Text("A new version of Wispah Flow is available!")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Button("Update Now") {
                                if let release = updateManager.latestRelease {
                                    updateManager.downloadAndInstall(release: release)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    // MARK: API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Provider", selection: $appState.apiProvider) {
                ForEach(APIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: appState.apiProvider) { _ in
                apiKeyInput = appState.activeAPIKey
                keyValidationError = nil
                keyValidationSuccess = false
            }

            HStack(spacing: 4) {
                Text("Get an API key at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(appState.apiProvider.keyHelpLabel, destination: URL(string: appState.apiProvider.keyHelpURL)!)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                SecureField(appState.apiProvider.keyPlaceholder, text: $apiKeyInput)
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
            let valid = await TranscriptionService.validateAPIKey(key, baseURL: appState.apiProvider.baseURL)
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    switch appState.apiProvider {
                    case .groq:
                        appState.apiKey = key
                    case .openai:
                        appState.openaiAPIKey = key
                    }
                    keyValidationSuccess = true
                } else {
                    keyValidationError = "Invalid API key. Please check and try again."
                }
            }
        }
    }

    // MARK: Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Transcription model:", selection: $appState.whisperModelId) {
                ForEach(appState.apiProvider.whisperModels, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }

            if let currentModel = appState.apiProvider.whisperModels.first(where: { $0.id == appState.whisperModelId }) {
                Text(currentModel.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Picker("Post-processing model:", selection: $appState.llmModelId) {
                ForEach(appState.apiProvider.llmModels, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }

            if let currentModel = appState.apiProvider.llmModels.first(where: { $0.id == appState.llmModelId }) {
                Text(currentModel.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Transcription language:", selection: Binding(
                get: { appState.transcriptionLanguage ?? "" },
                set: { appState.transcriptionLanguage = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(AppState.supportedLanguages, id: \.displayName) { lang in
                    Text(lang.displayName).tag(lang.code ?? "")
                }
            }

            Text("Setting a specific language improves accuracy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Push-to-Talk Key

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Toggle to Record")
                    .font(.subheadline.weight(.semibold))
                Text("Press once to start, press again to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HotkeyRecorderButton(
                    label: "Toggle Key",
                    binding: $appState.toggleHotkey
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Hold to Record")
                    .font(.subheadline.weight(.semibold))
                Text("Hold the key to record, release to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HotkeyRecorderButton(
                    label: "Hold Key",
                    binding: $appState.holdHotkey
                )
            }

            if appState.toggleHotkey.usesFunctionModifier || appState.holdHotkey.usesFunctionModifier {
                Text("Tip: If Fn opens Emoji picker, go to System Settings > Keyboard and change \"Press fn key to\" to \"Do Nothing\".")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select which microphone to use for recording.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                MicrophoneOptionRow(
                    name: "System Default",
                    isSelected: appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty,
                    action: { appState.selectedMicrophoneID = "default" }
                )
                ForEach(appState.availableMicrophones) { device in
                    MicrophoneOptionRow(
                        name: device.name,
                        isSelected: appState.selectedMicrophoneID == device.uid,
                        action: { appState.selectedMicrophoneID = device.uid }
                    )
                }
            }
        }
        .onAppear {
            appState.refreshAvailableMicrophones()
        }
    }

    // MARK: Post-Processing

    private var postProcessingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable post-processing", isOn: $appState.postProcessingEnabled)
            Text("Cleans up transcription using an LLM — fixes spelling, punctuation, and applies the settings below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                Toggle("Smart formatting", isOn: $appState.smartFormattingEnabled)
                Text("Automatically detects structure in your speech and formats it (numbered lists, bullet points, paragraphs).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Smart corrections", isOn: $appState.smartCorrectionsEnabled)
                Text("Removes verbal self-corrections (e.g. \"I want apples, wait no, oranges\" becomes \"I want oranges\"). Only triggers on explicit correction words like \"wait no\", \"actually\", \"I mean\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Developer mode", isOn: $appState.developerModeEnabled)
                Text("Optimized for coding context — recognizes variable names, code keywords, and technical terms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom instructions")
                        .font(.caption.weight(.semibold))
                    TextEditor(text: $appState.customPostProcessingPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .frame(minHeight: 60, maxHeight: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    Text("e.g. \"I say 'so like' a lot, remove it\" or \"keep sentences short\"")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(!appState.postProcessingEnabled)
            .opacity(appState.postProcessingEnabled ? 1 : 0.5)
        }
    }

    // MARK: Custom Vocabulary

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 10) {
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

    // MARK: Audio Behavior

    private var audioBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("While recording:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: $appState.audioWhileRecording) {
                ForEach(AudioWhileRecording.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(appState.audioWhileRecording.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Log Settings

    private var logSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Save run history", isOn: $appState.saveRunHistory)
            Text("Keep a log of each transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.saveRunHistory {
                HStack {
                    Text("Maximum history entries:")
                        .font(.caption)
                    TextField("", value: $appState.maxPipelineHistoryCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.center)
                        .onSubmit {
                            appState.maxPipelineHistoryCount = max(1, appState.maxPipelineHistoryCount)
                        }
                }

                Toggle("Save audio files", isOn: $appState.saveAudioFiles)
                Text("Keep the recorded audio for playback and retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !appState.saveAudioFiles {
                    Toggle("Keep audio on errors", isOn: $appState.keepAudioOnErrors)
                        .padding(.leading, 16)
                    Text("When transcription fails, keep the audio so you can retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }

                HStack(spacing: 12) {
                    Button("Clear History") {
                        appState.clearPipelineHistory()
                    }
                    .disabled(appState.pipelineHistory.isEmpty)

                    Text("Currently storing \(appState.pipelineHistory.count) \(appState.pipelineHistory.count == 1 ? "entry" : "entries").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Toggle("Collect usage stats (local)", isOn: Binding(
                    get: { appState.collectStats },
                    set: { newValue in
                        if !newValue && appState.statsStore.stats.totalTranscriptions > 0 {
                            showStatsDeleteConfirmation = true
                        } else {
                            appState.collectStats = newValue
                        }
                    }
                ))
                .alert("Delete Stats?", isPresented: $showStatsDeleteConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        appState.statsStore.reset()
                        appState.collectStats = false
                    }
                } message: {
                    Text("Disabling stats will permanently delete all collected data. This cannot be undone.")
                }
                Text("Track words, speed, and activity locally on this device. Nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sound

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Play sounds", isOn: $appState.playSoundsEnabled)
            Text("Plays a sound when recording starts and stops.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "camera.viewfinder")
                        .frame(width: 20)
                        .foregroundStyle(.blue)
                    Text("Screen Context")
                    Spacer()
                    Toggle("", isOn: $appState.screenRecordingEnabled)
                        .labelsHidden()
                }

                if appState.screenRecordingEnabled {
                    Text("Captures a screenshot to improve transcription accuracy based on what's on screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !appState.hasScreenRecordingPermission {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Permission required")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Grant Access") {
                                appState.requestScreenCapturePermission()
                            }
                            .font(.caption)
                        }
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text("Permission granted")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
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
