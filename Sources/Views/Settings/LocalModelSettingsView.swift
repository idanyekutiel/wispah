import SwiftUI

struct LocalModelSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var modelManager = LocalModelManager.shared
    @State private var showDeleteAllConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Whisper Models Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Whisper Models")
                    .font(.subheadline.weight(.semibold))
                Text("Choose a model for speech-to-text transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    ForEach(APIProvider.local.whisperModels, id: \.id) { model in
                        LocalModelRow(
                            name: model.name,
                            description: model.description,
                            status: modelManager.whisperModelStatuses[model.id] ?? .notDownloaded,
                            isSelected: appState.whisperModelId == model.id && (modelManager.whisperModelStatuses[model.id]?.isDownloaded ?? false),
                            onDownload: {
                                Task {
                                    await modelManager.downloadWhisperModel(model.id)
                                    if modelManager.whisperModelStatuses[model.id]?.isDownloaded == true {
                                        appState.whisperModelId = model.id
                                    }
                                }
                            },
                            onSelect: {
                                appState.whisperModelId = model.id
                            },
                            onDelete: {
                                if appState.whisperModelId == model.id {
                                    // Switch to default before deleting
                                    appState.whisperModelId = APIProvider.local.defaultWhisperModel
                                }
                                modelManager.deleteWhisperModel(model.id)
                            }
                        )
                    }
                }
            }

            Divider()

            // LLM Models Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Language Models")
                    .font(.subheadline.weight(.semibold))
                Text("Choose a model for post-processing (formatting, spelling, context).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    ForEach(APIProvider.local.llmModels, id: \.id) { model in
                        LocalModelRow(
                            name: model.name,
                            description: model.description,
                            status: modelManager.llmModelStatuses[model.id] ?? .notDownloaded,
                            isSelected: appState.llmModelId == model.id && (modelManager.llmModelStatuses[model.id]?.isDownloaded ?? false),
                            onDownload: {
                                Task {
                                    await modelManager.downloadLLMModel(model.id)
                                    if modelManager.llmModelStatuses[model.id]?.isDownloaded == true {
                                        appState.llmModelId = model.id
                                    }
                                }
                            },
                            onSelect: {
                                appState.llmModelId = model.id
                            },
                            onDelete: {
                                if appState.llmModelId == model.id {
                                    appState.llmModelId = APIProvider.local.defaultLLMModel
                                }
                                modelManager.deleteLLMModel(model.id)
                            }
                        )
                    }
                }
            }

            Divider()

            // Disk usage + delete all
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                let whisperBytes = modelManager.diskUsage(for: .whisper)
                let llmBytes = modelManager.diskUsage(for: .llm)
                let totalBytes = whisperBytes + llmBytes
                Text("Total storage: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if totalBytes > 0 {
                    Button("Delete All Models") {
                        showDeleteAllConfirmation = true
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .alert("Delete All Local Models?", isPresented: $showDeleteAllConfirmation) {
                        Button("Cancel", role: .cancel) {}
                        Button("Delete All", role: .destructive) {
                            modelManager.deleteAllModels()
                        }
                    } message: {
                        Text("This will remove all downloaded models (\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))). You can re-download them later.")
                    }
                }
            }
        }
    }
}
