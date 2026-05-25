import SwiftUI
import AVFoundation

// MARK: - Run Log Entry

struct RunLogEntryView: View {
    let item: PipelineHistoryItem
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = false
    @State private var showContextPrompt = false
    @State private var showPostProcessingPrompt = false
    @State private var retryState: RetryState = .idle
    @State private var retryStep: String = ""
    @State private var retryElapsed: TimeInterval = 0
    @State private var retryTimer: Timer?
    @State private var retryTask: Task<Void, Never>?

    private enum RetryState: Equatable {
        case idle
        case retrying
        case succeeded
        case failed(String)
    }

    private var isError: Bool {
        item.postProcessingStatus.hasPrefix("Error:")
    }

    private var canRetry: Bool {
        item.audioFileName != nil && retryState != .retrying
    }

    private var retryButtonHelp: String {
        if isError || item.postProcessedTranscript.isEmpty {
            return "Retry transcription"
        }
        return "Retranscribe audio"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Retry banner
            if retryState == .retrying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(retryStep)
                            .font(.caption.weight(.semibold))
                        Text(formatRetryElapsed(retryElapsed))
                            .font(.caption2)
                            .opacity(0.8)
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue)
            } else if retryState == .succeeded {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                    Text("Transcription succeeded — copied to clipboard")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green)
            } else if case .failed(let msg) = retryState {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                    Text("Retry failed: \(msg)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        withAnimation { retryState = .idle }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red)
            }

            // Collapsed header
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        if isError && retryState != .retrying {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if item.postProcessedTranscript.isEmpty && retryState != .retrying {
                            Image(systemName: "minus.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.timestamp.formatted(date: .numeric, time: .standard))
                                .font(.subheadline.weight(.semibold))
                            Text(item.postProcessedTranscript.isEmpty ? "(no transcript)" : item.postProcessedTranscript)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if canRetry {
                    Button {
                        performRetry()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(retryButtonHelp)
                }

                Button {
                    retryTask?.cancel()
                    stopRetryTimer()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.deleteHistoryEntry(id: item.id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete transcript")
                .disabled(retryState == .retrying)
            }
            .padding(12)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 16) {
                    // Audio player
                    if let audioFileName = item.audioFileName,
                       FileManager.default.fileExists(atPath: AppState.audioStorageDirectory().appendingPathComponent(audioFileName).path) {
                        let audioURL = AppState.audioStorageDirectory().appendingPathComponent(audioFileName)
                        HStack {
                            AudioPlayerView(audioURL: audioURL)
                            Text(formattedFileSize(url: audioURL))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            HStack(spacing: 0) {
                                Button {
                                    saveAudioToDesktop(audioURL: audioURL)
                                } label: {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.caption)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Save audio to Desktop")
                                Button {
                                    deleteAudioFile(audioURL: audioURL)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Delete audio recording")
                            }
                        }
                    } else if item.audioFileName != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Audio file deleted")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Audio file not retained")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Custom vocabulary
                    if !item.customVocabulary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Custom Vocabulary")
                                .font(.caption.weight(.semibold))
                            FlowLayout(spacing: 4) {
                                ForEach(parseVocabulary(item.customVocabulary), id: \.self) { word in
                                    Text(word)
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.12))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }

                    // Pipeline steps
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pipeline")
                            .font(.caption.weight(.semibold))

                        // Step 1: Context Capture
                        PipelineStepView(
                            number: 1,
                            title: "Capture Context",
                            content: {
                                VStack(alignment: .leading, spacing: 6) {
                                    if item.contextScreenshotStatus == "Screen recording disabled" {
                                        HStack(spacing: 6) {
                                            Image(systemName: "camera.viewfinder")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text("Screen recording disabled — text-only context")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } else if let dataURL = item.contextScreenshotDataURL,
                                       let image = imageFromDataURL(dataURL) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxHeight: 120)
                                            .cornerRadius(4)
                                    }

                                    if let prompt = item.contextPrompt, !prompt.isEmpty {
                                        Button {
                                            showContextPrompt.toggle()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text(showContextPrompt ? "Hide Prompt" : "Show Prompt")
                                                    .font(.caption)
                                                Image(systemName: showContextPrompt ? "chevron.up" : "chevron.down")
                                                    .font(.caption2)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)

                                        if showContextPrompt {
                                            Text(prompt)
                                                .font(.system(.caption2, design: .monospaced))
                                                .textSelection(.enabled)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(nsColor: .controlBackgroundColor))
                                                .cornerRadius(4)
                                        }
                                    }

                                    if !item.contextSummary.isEmpty {
                                        Text(item.contextSummary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    } else {
                                        Text("No context captured")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        )

                        // Step 2: Transcribe Audio
                        PipelineStepView(
                            number: 2,
                            title: "Transcribe Audio",
                            content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Sent audio to \(appState.apiProvider.displayName) (\(appState.whisperModelId))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    if !item.rawTranscript.isEmpty {
                                        Text(item.rawTranscript)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(4)
                                    } else {
                                        Text("(empty transcript)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        )

                        // Step 3: Post-Process
                        PipelineStepView(
                            number: 3,
                            title: "Post-Process",
                            content: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.postProcessingStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)

                                    if let prompt = item.postProcessingPrompt, !prompt.isEmpty {
                                        Button {
                                            showPostProcessingPrompt.toggle()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text(showPostProcessingPrompt ? "Hide Prompt" : "Show Prompt")
                                                    .font(.caption)
                                                Image(systemName: showPostProcessingPrompt ? "chevron.up" : "chevron.down")
                                                    .font(.caption2)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)

                                        if showPostProcessingPrompt {
                                            Text(prompt)
                                                .font(.system(.caption2, design: .monospaced))
                                                .textSelection(.enabled)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(nsColor: .controlBackgroundColor))
                                                .cornerRadius(4)
                                        }
                                    }

                                    if !item.postProcessedTranscript.isEmpty {
                                        Text(item.postProcessedTranscript)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(4)
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isError ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onDisappear {
            retryTask?.cancel()
            stopRetryTimer()
        }
    }

    private func startRetryTimer() {
        retryElapsed = 0
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            retryElapsed += 0.1
        }
    }

    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func formatRetryElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private func performRetry() {
        guard let audioFileName = item.audioFileName else { return }
        let audioURL = AppState.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            withAnimation { retryState = .failed("Audio file no longer exists") }
            return
        }

        retryStep = "Uploading audio..."
        startRetryTimer()
        withAnimation { retryState = .retrying }

        retryTask = Task {
            do {
                let transcriptionService = TranscriptionService(
                    apiKey: appState.activeAPIKey,
                    baseURL: appState.activeBaseURL,
                    model: appState.whisperModelId,
                    language: appState.transcriptionLanguage
                )
                let retryAttempt = try await appState.transcribeSavedAudioAttempt(
                    sourceURL: audioURL,
                    savedAudioFileName: item.audioFileName,
                    transcriptionService: transcriptionService,
                    customVocabulary: item.customVocabulary,
                    applySpeechTrimming: false,
                    trimDuration: item.recordingDurationSeconds ?? 0,
                    speechStart: 0,
                    replaceSavedAudio: true,
                    useVocabularyPrompt: true,
                    debugStatusMessage: "Transcribing audio..."
                )
                defer {
                    if let temporaryUploadURL = retryAttempt.temporaryUploadURL {
                        try? FileManager.default.removeItem(at: temporaryUploadURL)
                    }
                }

                let rawTranscript = retryAttempt.transcriptionResult.transcript
                let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                let updatedAudioFileName = retryAttempt.effectiveAudioFileName ?? item.audioFileName

                let finalTranscript: String
                let processingStatus: String
                let postProcessingPrompt: String

                if appState.postProcessingEnabled && !trimmedRawTranscript.isEmpty {
                    await MainActor.run { retryStep = "Post-processing..." }
                    let postProcessingService = PostProcessingService(
                        apiKey: appState.activeAPIKey,
                        baseURL: appState.activeBaseURL,
                        model: appState.llmModelId
                    )
                    do {
                        let result = try await postProcessingService.postProcess(
                            transcript: trimmedRawTranscript,
                            context: historyAppContext(),
                            customVocabulary: item.customVocabulary,
                            smartFormatting: appState.smartFormattingEnabled,
                            smartCorrections: appState.smartCorrectionsEnabled,
                            developerMode: appState.developerModeEnabled,
                            customPrompt: appState.customPostProcessingPrompt
                        )
                        finalTranscript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        processingStatus = "Retranscribed successfully"
                        postProcessingPrompt = result.prompt
                    } catch {
                        finalTranscript = trimmedRawTranscript
                        processingStatus = "Post-processing failed on retranscribe, using raw transcript"
                        postProcessingPrompt = ""
                    }
                } else {
                    finalTranscript = trimmedRawTranscript
                    processingStatus = appState.postProcessingEnabled
                        ? "Retranscribed successfully"
                        : "Post-processing disabled"
                    postProcessingPrompt = ""
                }

                await MainActor.run {
                    retryStep = "Copying to clipboard..."
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finalTranscript, forType: .string)

                    if let index = appState.pipelineHistory.firstIndex(where: { $0.id == item.id }) {
                        let updated = PipelineHistoryItem(
                            id: item.id,
                            timestamp: item.timestamp,
                            rawTranscript: trimmedRawTranscript,
                            postProcessedTranscript: finalTranscript,
                            postProcessingPrompt: postProcessingPrompt,
                            contextSummary: item.contextSummary,
                            contextPrompt: item.contextPrompt,
                            contextScreenshotDataURL: item.contextScreenshotDataURL,
                            contextScreenshotStatus: item.contextScreenshotStatus,
                            postProcessingStatus: processingStatus,
                            debugStatus: "Retranscribe · STT: full_saved_audio",
                            customVocabulary: item.customVocabulary,
                            audioFileName: updatedAudioFileName,
                            recordingDurationSeconds: item.recordingDurationSeconds
                        )
                        appState.pipelineHistory[index] = updated
                        try? appState.updateHistoryEntry(updated)
                    }

                    stopRetryTimer()
                    withAnimation { retryState = .succeeded }
                }

                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    withAnimation { retryState = .idle }
                }
            } catch {
                await MainActor.run {
                    stopRetryTimer()
                    withAnimation { retryState = .failed(error.localizedDescription) }
                }
            }
        }
    }

    private func historyAppContext() -> AppContext {
        AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: nil,
            currentActivity: item.contextSummary.isEmpty ? "No context captured" : item.contextSummary,
            contextPrompt: item.contextPrompt,
            screenshotDataURL: item.contextScreenshotDataURL,
            screenshotMimeType: nil,
            screenshotError: item.contextScreenshotStatus.hasPrefix("available") ? nil : item.contextScreenshotStatus
        )
    }

    private func deleteAudioFile(audioURL: URL) {
        try? FileManager.default.removeItem(at: audioURL)
    }

    private func saveAudioToDesktop(audioURL: URL) {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            appState.errorMessage = "Could not locate Desktop folder"
            return
        }
        let timestamp = item.timestamp.formatted(date: .numeric, time: .standard)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        let destURL = desktop.appendingPathComponent("wispah-\(timestamp).\(audioURL.pathExtension)")
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: audioURL, to: destURL)
            NSWorkspace.shared.selectFile(destURL.path, inFileViewerRootedAtPath: desktop.path)
        } catch {
            appState.errorMessage = "Failed to save audio: \(error.localizedDescription)"
        }
    }

    private func formattedFileSize(url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func parseVocabulary(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
