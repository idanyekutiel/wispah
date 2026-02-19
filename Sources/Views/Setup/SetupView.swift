import SwiftUI
import AVFoundation
import Combine
import Foundation
import ServiceManagement

struct SetupView: View {
    var onComplete: () -> Void
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    private let repoURL = URL(string: "https://github.com/idanyekutiel/wispah")!
    private enum SetupStep: Int, CaseIterable {
        case welcome = 0
        case apiKey
        case micPermission
        case accessibility
        case screenRecording
        case hotkey
        case vocabulary
        case language
        case launchAtLogin
        case testTranscription
        case ready
    }

    @State private var currentStep = SetupStep.welcome
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = false
    @State private var apiKeyInput: String = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var accessibilityTimer: Timer?
    @State private var screenRecordingTimer: Timer?
    @State private var customVocabularyInput: String = ""
    @State private var showSkipScreenRecordingAlert = false
    @State private var fnEmojiPickerEnabled = true
    @StateObject private var githubCache = GitHubMetadataCache.shared

    // Test transcription state
    private enum TestPhase: Equatable {
        case idle, recording, transcribing, done
    }
    @State private var testPhase: TestPhase = .idle
    @State private var testAudioRecorder: AudioRecorder? = nil
    @State private var testAudioLevel: Float = 0.0
    @State private var testTranscript: String = ""
    @State private var testError: String? = nil
    @State private var testAudioLevelCancellable: AnyCancellable? = nil
    @State private var testMicPulsing = false
    @State private var testRecordingStartTime: Date? = nil

    private let totalSteps: [SetupStep] = SetupStep.allCases

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch currentStep {
                case .welcome:
                    welcomeStep
                case .apiKey:
                    apiKeyStep
                case .micPermission:
                    micPermissionStep
                case .accessibility:
                    accessibilityStep
                case .screenRecording:
                    screenRecordingStep
                case .hotkey:
                    hotkeyStep
                case .vocabulary:
                    vocabularyStep
                case .language:
                    languageStep
                case .launchAtLogin:
                    launchAtLoginStep
                case .testTranscription:
                    testTranscriptionStep
                case .ready:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)

            Divider()

            HStack {
                if currentStep != .welcome {
                    Button("Back") {
                        keyValidationError = nil
                        withAnimation {
                            currentStep = previousStep(currentStep)
                        }
                    }
                    .disabled(isValidatingKey)
                }
                Spacer()
                if currentStep != .ready {
                    if currentStep == .apiKey {
                        // API key step: validate before continuing
                        Button(isValidatingKey ? "Validating..." : "Continue") {
                            validateAndContinue()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)
                    } else if currentStep == .vocabulary {
                        Button("Continue") {
                            saveCustomVocabularyAndContinue()
                        }
                        .keyboardShortcut(.defaultAction)
                    } else if currentStep == .testTranscription {
                        Button("Skip") {
                            stopTestHotkeyMonitoring()
                            withAnimation {
                                currentStep = nextStep(currentStep)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button("Continue") {
                            stopTestHotkeyMonitoring()
                            withAnimation {
                                currentStep = nextStep(currentStep)
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(testPhase != .done || testTranscript.isEmpty || testError != nil)
                    } else {
                        if currentStep == .screenRecording && !appState.hasScreenRecordingPermission && appState.screenRecordingEnabled {
                            Button("Skip") {
                                showSkipScreenRecordingAlert = true
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .alert("Skip Screen Recording?", isPresented: $showSkipScreenRecordingAlert) {
                                Button("Go Back", role: .cancel) {}
                                Button("Skip Anyway") {
                                    appState.screenRecordingEnabled = false
                                    withAnimation {
                                        currentStep = nextStep(currentStep)
                                    }
                                }
                            } message: {
                                Text("Screen context helps Wispah Flow spell names correctly, match formatting to what you're working on, and adapt to the app you're in. Without it, transcriptions will still work but won't be as accurate.")
                            }
                        }

                        Button("Continue") {
                            withAnimation {
                                currentStep = nextStep(currentStep)
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinueFromCurrentStep)
                    }
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear {
            apiKeyInput = appState.apiKey
            customVocabularyInput = appState.customVocabulary
            checkMicPermission()
            checkAccessibility()
            // Resume from where we left off if the app restarted mid-setup
            let savedStep = UserDefaults.standard.integer(forKey: "setupResumeStep")
            if savedStep > 0, let step = SetupStep(rawValue: savedStep) {
                currentStep = step
            }
            Task {
                await githubCache.fetchIfNeeded()
            }
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
            screenRecordingTimer?.invalidate()
        }
        .onChange(of: currentStep) { newStep in
            UserDefaults.standard.set(newStep.rawValue, forKey: "setupResumeStep")
        }
    }

    // MARK: - Steps

    var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)

            VStack(spacing: 6) {
                Text("Welcome to Wispah Flow")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text("Dictate text anywhere on your Mac.\nHold a key to record, release to transcribe.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                    .frame(width: 26, height: 26)
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

                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                        if githubCache.isLoading {
                            ProgressView().scaleEffect(0.5)
                        } else if let count = githubCache.starCount {
                            Text("\(count.formatted()) \(count == 1 ? "star" : "stars")")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.yellow.opacity(0.14)))

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

            stepIndicator
        }
    }

    var apiKeyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Groq API Key")
                .font(.title)
                .fontWeight(.bold)

            Text("Wispah Flow uses Groq for fast, high-accuracy transcription.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How to get a free API key:")
                        .font(.subheadline.weight(.semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        instructionRow(number: "1", text: "Go to [console.groq.com/keys](https://console.groq.com/keys)")
                        instructionRow(number: "2", text: "Create a free account (if you don't have one)")
                        instructionRow(number: "3", text: "Click **Create API Key** and copy it")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.06))
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.headline)
                    SecureField("Paste your Groq API key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isValidatingKey)
                        .onChange(of: apiKeyInput) { _ in
                            keyValidationError = nil
                        }

                    if let error = keyValidationError {
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }

            stepIndicator
        }
    }

    var micPermissionStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Microphone Access")
                .font(.title)
                .fontWeight(.bold)

            Text("Wispah Flow needs access to your microphone to record audio for transcription.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "mic.fill")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Text("Microphone")
                Spacer()
                if micPermissionGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Granted")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        requestMicPermission()
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            stepIndicator
        }
    }

    var accessibilityStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Accessibility Access")
                .font(.title)
                .fontWeight(.bold)

            Text("Wispah Flow needs Accessibility access to paste transcribed text into your apps.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "hand.raised.fill")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Text("Accessibility")
                Spacer()
                if accessibilityGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Granted")
                        .foregroundStyle(.green)
                } else {
                    Button("Open Settings") {
                        requestAccessibility()
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            if !accessibilityGranted && Bundle.main.infoDictionary?["WispahBuildTag"] == nil {
                Text("Note: If you rebuilt the app, you may need to\nremove and re-add it in Accessibility settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            stepIndicator
        }
        .onAppear {
            startAccessibilityPolling()
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
        }
    }

    var screenRecordingStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Screen Recording")
                .font(.title)
                .fontWeight(.bold)

            Text("Wispah Flow intelligently adapts the transcription to the current app you're working in (ex. spelling names in an email correctly).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("It needs this permission to see which app you're working in and any in-progress work. Nothing is stored on Wispah Flow's servers (Wispah Flow doesn't have servers).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)


            HStack {
                Image(systemName: "camera.viewfinder")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Text("Screen Recording")
                Spacer()
                if appState.hasScreenRecordingPermission {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Granted")
                        .foregroundStyle(.green)
                } else if !appState.screenRecordingEnabled {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("Skipped")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Grant Access") {
                        appState.requestScreenCapturePermission()
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            stepIndicator
        }
        .onAppear {
            startScreenRecordingPolling()
        }
        .onDisappear {
            screenRecordingTimer?.invalidate()
        }
    }

    var hotkeyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Recording Keys")
                .font(.title)
                .fontWeight(.bold)

            Text("Set up one or both recording modes.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hold to Record")
                            .font(.subheadline.weight(.semibold))
                        Text("Hold the key to record, release to stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HotkeyRecorderButton(
                        label: "Hold Key",
                        binding: $appState.holdHotkey
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Toggle to Record")
                            .font(.subheadline.weight(.semibold))
                        Text("Press once to start, press again to stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HotkeyRecorderButton(
                        label: "Toggle Key",
                        binding: $appState.toggleHotkey
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }

            if appState.toggleHotkey.keyCode == 63 || appState.holdHotkey.keyCode == 63 {
                if fnEmojiPickerEnabled {
                    VStack(spacing: 8) {
                        Label("Fn key opens the Emoji picker by default", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("Change \"Press \u{1F310} key to\" to **Do Nothing** in Keyboard settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        } label: {
                            Text("Open Keyboard Settings")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
                } else {
                    Label("Fn key is ready to use", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            stepIndicator
        }
        .onAppear {
            checkFnSetting()
            resizeSetupWindow(height: 620)
        }
        .onDisappear {
            resizeSetupWindow(height: 480)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if currentStep == .hotkey { checkFnSetting() }
        }
    }

    private func resizeSetupWindow(height: CGFloat) {
        guard let window = (NSApp.delegate as? AppDelegate)?.setupWindow else { return }
        guard abs(window.frame.size.height - height) > 1 else { return }
        var frame = window.frame
        let delta = height - frame.size.height
        frame.origin.y -= delta
        frame.size.height = height
        window.minSize = NSSize(width: 520, height: min(height, 480))
        window.animator().setFrame(frame, display: true)
    }

    private func checkFnSetting() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.HIToolbox", "AppleFnUsageType"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let val = Int(str) {
            fnEmojiPickerEnabled = val != 0
        } else {
            fnEmojiPickerEnabled = true
        }
    }

    var vocabularyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Custom Vocabulary")
                .font(.title)
                .fontWeight(.bold)

            Text("Add words and phrases that should be preserved in post-processing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Vocabulary")
                    .font(.headline)

                TextEditor(text: $customVocabularyInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 130)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                Text("Separate entries with commas, new lines, or semicolons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            stepIndicator
        }
    }

    var languageStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Preferences")
                .font(.title)
                .fontWeight(.bold)

            Text("Fine-tune how transcription works for you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "globe")
                            .frame(width: 24)
                            .foregroundStyle(.blue)
                        Text("Language")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { appState.transcriptionLanguage ?? "" },
                            set: { appState.transcriptionLanguage = $0.isEmpty ? nil : $0 }
                        )) {
                            ForEach(AppState.supportedLanguages, id: \.displayName) { lang in
                                Text(lang.displayName).tag(lang.code ?? "")
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    Text("Setting a specific language improves accuracy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 36)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "curlybraces")
                            .frame(width: 24)
                            .foregroundStyle(.blue)
                        Toggle("Developer Mode", isOn: $appState.developerModeEnabled)
                    }

                    Text("Recognizes camelCase, snake_case, technical terms, and code keywords.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 36)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 24)
                            .foregroundStyle(.blue)
                        Toggle("Smart Corrections", isOn: $appState.smartCorrectionsEnabled)
                    }

                    Text("Removes verbal self-corrections like \"wait no\" and \"I mean\" — keeps only your final intent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 36)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }

            stepIndicator
        }
    }

    var launchAtLoginStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "sunrise.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Launch at Login")
                .font(.title)
                .fontWeight(.bold)

            Text("Start Wispah Flow automatically when you log in so it's always ready.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "sunrise.fill")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Toggle("Launch Wispah Flow at login", isOn: $appState.launchAtLogin)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            stepIndicator
        }
    }

    /// Microphones shown in onboarding: built-in mic + system default only.
    /// Full list is available in Settings.
    private var onboardingMicOptions: [(uid: String, name: String)] {
        var options: [(uid: String, name: String)] = []
        if let builtIn = appState.availableMicrophones.first(where: { $0.isBuiltIn }) {
            options.append((uid: builtIn.uid, name: builtIn.name))
        }
        options.append((uid: "default", name: "System Default"))
        return options
    }

    var testTranscriptionStep: some View {
        VStack(spacing: 20) {
            // Simplified microphone picker (full list in Settings)
            VStack(spacing: 4) {
                Picker("Microphone:", selection: $appState.selectedMicrophoneID) {
                    ForEach(onboardingMicOptions, id: \.uid) { option in
                        Text(option.name).tag(option.uid)
                    }
                }
                .frame(maxWidth: 340)

                Text("More options available in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Group {
                switch testPhase {
                case .idle:
                    VStack(spacing: 20) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)
                            .scaleEffect(testMicPulsing ? 1.15 : 1.0)
                            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: testMicPulsing)

                        Text("Let's Try It Out!")
                            .font(.title)
                            .fontWeight(.bold)

                        VStack(spacing: 4) {
                            Text("Hold **\(appState.holdHotkey.displayName)** to dictate")
                            Text("Press **\(appState.toggleHotkey.displayName)** to toggle")
                        }
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(10)

                        Text("Say anything — a sentence or two is perfect.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                case .recording:
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.65))
                                .frame(width: 100, height: 100)

                            Circle()
                                .stroke(Color.blue.opacity(0.8), lineWidth: 3)
                                .frame(width: 100, height: 100)
                                .shadow(color: .blue.opacity(0.5), radius: 10)

                            WaveformView(audioLevel: testAudioLevel)
                        }

                        Text("Listening...")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                    }

                case .transcribing:
                    VStack(spacing: 20) {
                        InlineTranscribingDots()

                        Text("Transcribing...")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }

                case .done:
                    VStack(spacing: 16) {
                        if testError != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(.green)
                        }

                        if let error = testError {
                            Text("Something went wrong")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Text("Hold **\(appState.holdHotkey.displayName)** or press **\(appState.toggleHotkey.displayName)** to try again")
                                .multilineTextAlignment(.center)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if testTranscript.isEmpty {
                            Text("No speech detected")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            Text("Hold **\(appState.holdHotkey.displayName)** or press **\(appState.toggleHotkey.displayName)** to try again")
                                .multilineTextAlignment(.center)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Perfect — Wispah Flow is ready to go.")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(testTranscript)
                                .font(.body)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(10)
                                .transition(.move(edge: .bottom).combined(with: .opacity))

                            Text("Hold **\(appState.holdHotkey.displayName)** or press **\(appState.toggleHotkey.displayName)** to try again")
                                .multilineTextAlignment(.center)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .transition(.opacity)
            .id(testPhase)

            Spacer()
            stepIndicator
        }
        .onAppear {
            appState.refreshAvailableMicrophones()
            testMicPulsing = true
            startTestHotkeyMonitoring()
        }
        .onDisappear {
            stopTestHotkeyMonitoring()
        }
    }

    var readyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title)
                .fontWeight(.bold)

            Text("Wispah Flow lives in your menu bar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HowToRow(icon: "keyboard", text: "Hold \(appState.holdHotkey.displayName) to record, release to stop")
                HowToRow(icon: "keyboard", text: "Press \(appState.toggleHotkey.displayName) to toggle recording")
                HowToRow(icon: "doc.on.clipboard", text: "Text is typed at your cursor & copied")
            }
            .padding(.top, 10)

            stepIndicator
        }
    }

    var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(totalSteps, id: \.rawValue) { step in
                Circle()
                    .fill(step == currentStep ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.top, 20)
    }

    private var canContinueFromCurrentStep: Bool {
        switch currentStep {
        case .micPermission:
            return micPermissionGranted
        case .accessibility:
            return accessibilityGranted
        case .screenRecording:
            return appState.hasScreenRecordingPermission || !appState.screenRecordingEnabled
        case .testTranscription:
            return testPhase == .done && !testTranscript.isEmpty && testError == nil
        default:
            return true
        }
    }

    // MARK: - Helpers

    private func instructionRow(number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number + ".")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.subheadline)
                .tint(.blue)
        }
    }

    // MARK: - Actions

    func validateAndContinue() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isValidatingKey = true
        keyValidationError = nil

        Task {
            let valid = await TranscriptionService.validateAPIKey(key)
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    appState.apiKey = key
                    withAnimation {
                        currentStep = nextStep(currentStep)
                    }
                } else {
                    keyValidationError = "Invalid API key. Please check and try again."
                }
            }
        }
    }

    func saveCustomVocabularyAndContinue() {
        appState.customVocabulary = customVocabularyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation {
            currentStep = nextStep(currentStep)
        }
    }

    private func previousStep(_ step: SetupStep) -> SetupStep {
        let previous = SetupStep(rawValue: step.rawValue - 1)
        return previous ?? .welcome
    }

    private func nextStep(_ step: SetupStep) -> SetupStep {
        let next = SetupStep(rawValue: step.rawValue + 1)
        return next ?? .ready
    }

    func checkMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionGranted = true
        default:
            break
        }
    }

    func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micPermissionGranted = granted
            }
        }
    }

    func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                checkAccessibility()
            }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func startScreenRecordingPolling() {
        screenRecordingTimer?.invalidate()
        screenRecordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                appState.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
            }
        }
    }

    // MARK: - Test Transcription

    private let minimumRecordingDuration: TimeInterval = 0.5

    private func startTestRecording() {
        guard testPhase == .idle || testPhase == .done else { return }
        if testPhase == .done {
            resetTest()
        }
        do {
            let recorder = AudioRecorder()
            try recorder.startRecording(deviceUID: appState.selectedMicrophoneID)
            testAudioRecorder = recorder
            testRecordingStartTime = Date()
            testAudioLevelCancellable = recorder.$audioLevel
                .receive(on: DispatchQueue.main)
                .sink { level in
                    testAudioLevel = level
                }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                testPhase = .recording
            }
        } catch {
            testError = error.localizedDescription
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                testPhase = .done
            }
        }
    }

    private func stopTestRecordingAndTranscribe() {
        guard testPhase == .recording, let recorder = testAudioRecorder else { return }

        // Ignore recordings that are too short
        if let startTime = testRecordingStartTime,
           Date().timeIntervalSince(startTime) < minimumRecordingDuration {
            _ = recorder.stopRecording()
            recorder.cleanup()
            testAudioLevelCancellable?.cancel()
            testAudioLevelCancellable = nil
            testAudioLevel = 0.0
            testRecordingStartTime = nil
            resetTest()
            return
        }

        let fileURL = recorder.stopRecording()
        testAudioLevelCancellable?.cancel()
        testAudioLevelCancellable = nil
        testAudioLevel = 0.0
        testRecordingStartTime = nil

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            testPhase = .transcribing
        }

        guard let url = fileURL else {
            testError = "No audio file was created."
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                testPhase = .done
            }
            return
        }

        Task {
            do {
                let service = TranscriptionService(apiKey: appState.apiKey)
                let transcript = try await service.transcribe(fileURL: url)
                await MainActor.run {
                    testTranscript = transcript
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                        testPhase = .done
                    }
                }
            } catch {
                await MainActor.run {
                    testError = error.localizedDescription
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                        testPhase = .done
                    }
                }
            }
            recorder.cleanup()
        }
    }

    private func startTestHotkeyMonitoring() {
        appState.hotkeyManager.onKeyDown = { [self] binding in
            DispatchQueue.main.async {
                if binding == appState.holdHotkey && binding != appState.toggleHotkey {
                    startTestRecording()
                } else if binding == appState.toggleHotkey && binding != appState.holdHotkey {
                    if testPhase == .recording {
                        stopTestRecordingAndTranscribe()
                    } else {
                        startTestRecording()
                    }
                } else {
                    // Same key for both — use recordingMode
                    switch appState.recordingMode {
                    case .holdToRecord:
                        startTestRecording()
                    case .toggleToRecord:
                        if testPhase == .recording {
                            stopTestRecordingAndTranscribe()
                        } else {
                            startTestRecording()
                        }
                    }
                }
            }
        }

        appState.hotkeyManager.onKeyUp = { [self] binding in
            DispatchQueue.main.async {
                if binding == appState.holdHotkey && binding != appState.toggleHotkey {
                    stopTestRecordingAndTranscribe()
                } else if binding == appState.toggleHotkey && binding != appState.holdHotkey {
                    // Toggle key released — no action
                } else {
                    switch appState.recordingMode {
                    case .holdToRecord:
                        stopTestRecordingAndTranscribe()
                    case .toggleToRecord:
                        break
                    }
                }
            }
        }

        let uniqueBindings = Array(Set([appState.toggleHotkey, appState.holdHotkey]))
        appState.hotkeyManager.start(bindings: uniqueBindings)
    }

    private func stopTestHotkeyMonitoring() {
        appState.hotkeyManager.stop()
        appState.hotkeyManager.onKeyDown = nil
        appState.hotkeyManager.onKeyUp = nil
        testAudioLevelCancellable?.cancel()
        testAudioLevelCancellable = nil
        if let recorder = testAudioRecorder, recorder.isRecording {
            _ = recorder.stopRecording()
            recorder.cleanup()
        }
        testAudioRecorder = nil
    }

    private func resetTest() {
        testPhase = .idle
        testTranscript = ""
        testError = nil
        testAudioLevel = 0.0
        testMicPulsing = true
        if let recorder = testAudioRecorder {
            if recorder.isRecording {
                _ = recorder.stopRecording()
            }
            recorder.cleanup()
            testAudioRecorder = nil
        }
    }

}
