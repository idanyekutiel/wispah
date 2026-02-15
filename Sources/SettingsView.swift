import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button("Clear History") {
                    appState.pipelineHistory = []
                }
                .font(.body)
            }

            if appState.pipelineHistory.isEmpty {
                Text("No prompts yet. Run a dictation pass to populate history.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 16) {
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
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(16)
        .frame(width: 760, height: 640, alignment: .topLeading)
    }
}
