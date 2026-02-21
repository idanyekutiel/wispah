import Foundation
import os
import WhisperKit
import Hub
import MLXLLM
import MLXLMCommon

enum LocalModelStatus: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case loaded
    case error(String)

    var isDownloaded: Bool {
        switch self {
        case .downloaded, .loading, .loaded: return true
        default: return false
        }
    }
}

@MainActor
final class LocalModelManager: ObservableObject {
    static let shared = LocalModelManager()

    @Published var whisperModelStatuses: [String: LocalModelStatus] = [:]
    @Published var llmModelStatuses: [String: LocalModelStatus] = [:]

    private(set) var whisperPipeline: WhisperKit?
    private(set) var llmContainer: ModelContainer?

    private var idleTimer: Timer?
    private let idleTimeoutSeconds: TimeInterval = 300 // 5 minutes

    /// Base directory for all model downloads (~/Library/Caches/Wispah/)
    private let modelsBaseDir: URL

    /// HubApi instance with our custom download base, used for LLM downloads
    private let hubApi: HubApi

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Wispah"
        modelsBaseDir = cachesDir.appendingPathComponent(appName, isDirectory: true)

        // HubApi stores models at downloadBase/models/{repo-id}/
        // Both WhisperKit and our LLM downloads share this base so Hub's cache is consistent
        hubApi = HubApi(downloadBase: modelsBaseDir)

        try? FileManager.default.createDirectory(at: modelsBaseDir, withIntermediateDirectories: true)

        scanDownloadedModels()
    }

    // MARK: - Path Helpers

    /// WhisperKit downloads to: modelsBaseDir/models/argmaxinc/whisperkit-coreml/{variant}/
    private func whisperModelDir(variant: String) -> URL {
        modelsBaseDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
    }

    /// Hub downloads LLMs to: modelsBaseDir/models/{repo-id}/
    private func llmModelDir(modelId: String) -> URL {
        hubApi.localRepoLocation(Hub.Repo(id: modelId))
    }

    // MARK: - Scanning

    func scanDownloadedModels() {
        // Scan Whisper models
        for model in APIProvider.local.whisperModels {
            let modelDir = whisperModelDir(variant: model.id)
            if FileManager.default.fileExists(atPath: modelDir.path) {
                if whisperModelStatuses[model.id] == nil || whisperModelStatuses[model.id] == .notDownloaded {
                    whisperModelStatuses[model.id] = .downloaded
                }
            } else {
                if whisperModelStatuses[model.id] == nil {
                    whisperModelStatuses[model.id] = .notDownloaded
                }
            }
        }

        // Scan LLM models — check Hub's local repo location
        for model in APIProvider.local.llmModels {
            let modelDir = llmModelDir(modelId: model.id)
            // Check if there are actual model files (not just an empty dir)
            let hasFiles = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path))?.contains(where: { $0.hasSuffix(".safetensors") || $0 == "config.json" }) ?? false
            if hasFiles {
                if llmModelStatuses[model.id] == nil || llmModelStatuses[model.id] == .notDownloaded {
                    llmModelStatuses[model.id] = .downloaded
                }
            } else {
                if llmModelStatuses[model.id] == nil {
                    llmModelStatuses[model.id] = .notDownloaded
                }
            }
        }
    }

    // MARK: - Whisper Model Management

    func downloadWhisperModel(_ variant: String) async {
        whisperModelStatuses[variant] = .downloading(progress: 0)
        do {
            // WhisperKit uses Hub internally; pass our base dir so it stores under modelsBaseDir
            let folder = try await WhisperKit.download(
                variant: "openai_whisper-\(variant)",
                downloadBase: modelsBaseDir,
                useBackgroundSession: false
            ) { progress in
                Task { @MainActor in
                    self.whisperModelStatuses[variant] = .downloading(progress: progress.fractionCompleted)
                }
            }
            os_log(.info, "WhisperKit model downloaded to: %{public}@", folder.path)
            whisperModelStatuses[variant] = .downloaded
        } catch {
            os_log(.error, "WhisperKit download failed for %{public}@: %{public}@", variant, error.localizedDescription)
            whisperModelStatuses[variant] = .error(error.localizedDescription)
        }
    }

    func loadWhisperModel(_ variant: String) async throws {
        // Already loaded with matching variant
        if case .loaded = whisperModelStatuses[variant], whisperPipeline != nil {
            resetIdleTimer()
            return
        }

        // Unload any previously loaded whisper model
        whisperPipeline = nil
        for key in whisperModelStatuses.keys {
            if case .loaded = whisperModelStatuses[key] {
                whisperModelStatuses[key] = .downloaded
            }
        }

        whisperModelStatuses[variant] = .loading
        do {
            let config = WhisperKitConfig(
                model: "openai_whisper-\(variant)",
                downloadBase: modelsBaseDir,
                verbose: false,
                prewarm: true
            )
            let pipeline = try await WhisperKit(config)
            whisperPipeline = pipeline
            whisperModelStatuses[variant] = .loaded
            resetIdleTimer()
        } catch {
            whisperModelStatuses[variant] = .error(error.localizedDescription)
            throw error
        }
    }

    func deleteWhisperModel(_ variant: String) {
        if case .loaded = whisperModelStatuses[variant] {
            whisperPipeline = nil
        }
        let modelDir = whisperModelDir(variant: variant)
        try? FileManager.default.removeItem(at: modelDir)
        whisperModelStatuses[variant] = .notDownloaded
    }

    // MARK: - LLM Model Management

    func downloadLLMModel(_ modelId: String) async {
        llmModelStatuses[modelId] = .downloading(progress: 0)
        do {
            let repo = Hub.Repo(id: modelId)
            // Download model files only — don't load into GPU memory
            let downloadedDir = try await hubApi.snapshot(from: repo, matching: []) { progress in
                Task { @MainActor in
                    self.llmModelStatuses[modelId] = .downloading(progress: progress.fractionCompleted)
                }
            }
            os_log(.info, "LLM model downloaded to: %{public}@", downloadedDir.path)
            llmModelStatuses[modelId] = .downloaded
        } catch {
            os_log(.error, "LLM download failed for %{public}@: %{public}@", modelId, error.localizedDescription)
            llmModelStatuses[modelId] = .error(error.localizedDescription)
        }
    }

    func loadLLMModel(_ modelId: String) async throws {
        // Already loaded with matching model
        if case .loaded = llmModelStatuses[modelId], llmContainer != nil {
            resetIdleTimer()
            return
        }

        // Unload any previously loaded LLM
        llmContainer = nil
        for key in llmModelStatuses.keys {
            if case .loaded = llmModelStatuses[key] {
                llmModelStatuses[key] = .downloaded
            }
        }

        llmModelStatuses[modelId] = .loading
        do {
            let modelDir = llmModelDir(modelId: modelId)
            os_log(.info, "Loading LLM from directory: %{public}@", modelDir.path)

            // List files to verify download completeness
            let files = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
            os_log(.info, "LLM model files: %{public}@", files.joined(separator: ", "))

            let config = ModelConfiguration(directory: modelDir)
            os_log(.info, "LLM ModelConfiguration created, calling loadContainer...")
            let container = try await LLMModelFactory.shared.loadContainer(hub: hubApi, configuration: config) { progress in
                Task { @MainActor in
                    if progress.fractionCompleted < 1.0 {
                        self.llmModelStatuses[modelId] = .loading
                    }
                }
            }
            os_log(.info, "LLM container loaded successfully")
            llmContainer = container
            llmModelStatuses[modelId] = .loaded
            resetIdleTimer()
        } catch {
            os_log(.error, "LLM load failed for %{public}@: %{public}@", modelId, error.localizedDescription)
            llmModelStatuses[modelId] = .error(error.localizedDescription)
            throw error
        }
    }

    func deleteLLMModel(_ modelId: String) {
        if case .loaded = llmModelStatuses[modelId] {
            llmContainer = nil
        }
        // Remove from Hub's local cache
        let modelDir = llmModelDir(modelId: modelId)
        try? FileManager.default.removeItem(at: modelDir)
        llmModelStatuses[modelId] = .notDownloaded
    }

    // MARK: - Unload / Idle

    func unloadAll() {
        whisperPipeline = nil
        llmContainer = nil
        idleTimer?.invalidate()
        idleTimer = nil

        for key in whisperModelStatuses.keys {
            if case .loaded = whisperModelStatuses[key] {
                whisperModelStatuses[key] = .downloaded
            }
        }
        for key in llmModelStatuses.keys {
            if case .loaded = llmModelStatuses[key] {
                llmModelStatuses[key] = .downloaded
            }
        }
    }

    func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeoutSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.unloadAll()
            }
        }
    }

    // MARK: - Disk Usage

    func diskUsage(for type: ModelType) -> Int64 {
        let dirs: [URL]
        switch type {
        case .whisper:
            dirs = APIProvider.local.whisperModels.map { whisperModelDir(variant: $0.id) }
        case .llm:
            dirs = APIProvider.local.llmModels.map { llmModelDir(modelId: $0.id) }
        }

        var total: Int64 = 0
        for dir in dirs {
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    func deleteAllModels() {
        unloadAll()

        for model in APIProvider.local.whisperModels {
            deleteWhisperModel(model.id)
        }
        for model in APIProvider.local.llmModels {
            deleteLLMModel(model.id)
        }
    }

    enum ModelType {
        case whisper
        case llm
    }
}
