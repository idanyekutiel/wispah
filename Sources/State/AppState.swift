import Foundation
import Combine
import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import ApplicationServices
import ScreenCaptureKit
import os.log

let recordingLog = OSLog(subsystem: "com.idanyekutiel.wispah", category: "Recording")

enum RecordingTrigger {
    case direct
    case hold
    case toggle
}

enum RecordingStartPresentation {
    case normal
    case speculativeHiddenUntilCommit
}

enum SpeculativeToggleState {
    case none
    case startingHidden
    case recordingHidden
}

final class AppState: ObservableObject, @unchecked Sendable {
    let apiKeyStorageKey = "groq_api_key"
    private let customVocabularyStorageKey = "custom_vocabulary"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let unavailablePreferredMicrophoneStorageKey = "unavailable_preferred_microphone_id"
    private let screenRecordingEnabledStorageKey = "screen_recording_enabled"
    private let recordingModeStorageKey = "recording_mode"
    let transcribingIndicatorDelay: TimeInterval = 1.0
    /// How long transcription may run before the overlay shows a "still working" notice.
    let transcribingLongWaitThreshold: TimeInterval = 10.0

    @Published var maxPipelineHistoryCount: Int {
        didSet {
            UserDefaults.standard.set(maxPipelineHistoryCount, forKey: "max_pipeline_history_count")
        }
    }

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            persistAPIKey(apiKey, account: apiKeyStorageKey)
            if apiProvider == .groq {
                contextService = AppContextService(apiKey: activeAPIKey, baseURL: apiProvider.baseURL, llmModel: llmModelId, visionModel: apiProvider.defaultVisionModel)
            }
        }
    }

    @Published var toggleHotkey: HotkeyBinding {
        didSet {
            if let data = try? JSONEncoder().encode(toggleHotkey) {
                UserDefaults.standard.set(data, forKey: "toggle_hotkey")
            }
            // Clear hold key if it's now the same — one key can't serve both modes
            if !toggleHotkey.isDisabled && toggleHotkey == holdHotkey {
                holdHotkey = .disabled
            }
            restartHotkeyMonitoring()
        }
    }

    @Published var holdHotkey: HotkeyBinding {
        didSet {
            if let data = try? JSONEncoder().encode(holdHotkey) {
                UserDefaults.standard.set(data, forKey: "hold_hotkey")
            }
            // Clear toggle key if it's now the same — one key can't serve both modes
            if !holdHotkey.isDisabled && holdHotkey == toggleHotkey {
                toggleHotkey = .disabled
            }
            restartHotkeyMonitoring()
        }
    }

    @Published var screenRecordingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(screenRecordingEnabled, forKey: screenRecordingEnabledStorageKey)
        }
    }

    @Published var recordingMode: RecordingMode {
        didSet {
            UserDefaults.standard.set(recordingMode.rawValue, forKey: recordingModeStorageKey)
        }
    }

    @Published var customVocabulary: String {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: customVocabularyStorageKey)
        }
    }

    @Published var playSoundsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(playSoundsEnabled, forKey: "play_sounds_enabled")
        }
    }

    @Published var saveRunHistory: Bool {
        didSet {
            UserDefaults.standard.set(saveRunHistory, forKey: "save_run_history")
        }
    }

    @Published var saveAudioFiles: Bool {
        didSet {
            UserDefaults.standard.set(saveAudioFiles, forKey: "save_audio_files")
        }
    }

    @Published var keepAudioOnErrors: Bool {
        didSet {
            UserDefaults.standard.set(keepAudioOnErrors, forKey: "keep_audio_on_errors")
        }
    }

    @Published var collectStats: Bool {
        didSet {
            UserDefaults.standard.set(collectStats, forKey: "collect_stats")
        }
    }

    @Published var apiProvider: APIProvider {
        didSet {
            UserDefaults.standard.set(apiProvider.rawValue, forKey: "api_provider")
            whisperModelId = apiProvider.defaultWhisperModel
            llmModelId = apiProvider.defaultLLMModel
            contextService = AppContextService(apiKey: activeAPIKey, baseURL: apiProvider.baseURL, llmModel: llmModelId, visionModel: apiProvider.defaultVisionModel)
        }
    }

    @Published var openaiAPIKey: String {
        didSet {
            persistAPIKey(openaiAPIKey, account: "openai_api_key")
            if apiProvider == .openai {
                contextService = AppContextService(apiKey: activeAPIKey, baseURL: apiProvider.baseURL, llmModel: llmModelId, visionModel: apiProvider.defaultVisionModel)
            }
        }
    }

    @Published var whisperModelId: String {
        didSet {
            UserDefaults.standard.set(whisperModelId, forKey: "whisper_model_id")
        }
    }

    @Published var llmModelId: String {
        didSet {
            UserDefaults.standard.set(llmModelId, forKey: "llm_model_id")
            contextService = AppContextService(
                apiKey: activeAPIKey,
                baseURL: apiProvider.baseURL,
                llmModel: llmModelId,
                visionModel: apiProvider.defaultVisionModel
            )
        }
    }

    var activeAPIKey: String {
        switch apiProvider {
        case .groq: return apiKey
        case .openai: return openaiAPIKey
        }
    }

    var activeBaseURL: String {
        apiProvider.baseURL
    }

    @Published var transcriptionLanguage: String? {
        didSet {
            UserDefaults.standard.set(transcriptionLanguage ?? "", forKey: "transcription_language")
        }
    }

    @Published var postProcessingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(postProcessingEnabled, forKey: "post_processing_enabled")
        }
    }

    @Published var smartFormattingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(smartFormattingEnabled, forKey: "smart_formatting_enabled")
        }
    }

    @Published var smartCorrectionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(smartCorrectionsEnabled, forKey: "smart_corrections_enabled")
        }
    }

    @Published var developerModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(developerModeEnabled, forKey: "developer_mode_enabled")
        }
    }

    @Published var customPostProcessingPrompt: String {
        didSet {
            UserDefaults.standard.set(customPostProcessingPrompt, forKey: "custom_post_processing_prompt")
        }
    }

    @Published var audioWhileRecording: AudioWhileRecording {
        didSet {
            UserDefaults.standard.set(audioWhileRecording.rawValue, forKey: "audio_while_recording")
        }
    }

    static let supportedLanguages: [(code: String?, displayName: String)] = [
        (nil, "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("pl", "Polish"),
        ("uk", "Ukrainian"),
        ("he", "Hebrew"),
    ]

    @Published var isRecording = false
    /// True while the audio engine is still starting (between beginRecording and startRecording success/failure)
    var isStartingRecording = false
    /// True while the user is responding to the first-time microphone permission prompt.
    var isAwaitingMicrophonePermission = false
    /// Remembers what triggered the pending microphone permission request so hold-to-record can be cancelled correctly.
    var pendingPermissionRecordingTrigger: RecordingTrigger?
    /// Set when user releases hold key during engine startup — deferred stop fires once engine is ready
    var pendingStop = false
    /// Tracks user intent separately from capture-session startup. The audio file can
    /// contain about a second of startup padding even when Start and Stop were tapped
    /// immediately, so its media duration cannot identify an accidental empty recording.
    var recordingIntentStartTime: CFAbsoluteTime?
    var pendingStopIntentDuration: TimeInterval?
    var recordingStartPresentation: RecordingStartPresentation = .normal
    var speculativeToggleState: SpeculativeToggleState = .none
    var speculativeToggleCommitted = false
    var speculativeToggleCancellationRequested = false
    @Published var isTranscribing = false
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var hasAccessibility = false
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = nil {
        didSet {
            if let tab = selectedSettingsTab {
                UserDefaults.standard.set(tab.rawValue, forKey: "selected_settings_tab")
            }
        }
    }
    @Published var settingsWindowWasOpen: Bool = false {
        didSet { UserDefaults.standard.set(settingsWindowWasOpen, forKey: "settings_window_was_open") }
    }
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var lastRawTranscript = ""
    @Published var lastPostProcessedTranscript = ""
    @Published var lastPostProcessingPrompt = ""
    @Published var lastContextSummary = ""
    @Published var lastPostProcessingStatus = ""
    @Published var lastContextScreenshotDataURL: String? = nil
    @Published var lastContextScreenshotStatus = "No screenshot"
    @Published var hasScreenRecordingPermission = false
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
            guard !isApplyingAutomaticMicrophoneSelection else { return }
            temporarilyUnavailablePreferredMicrophoneID = nil
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    var accessibilityTimer: Timer?
    var audioLevelCancellable: AnyCancellable?
    var debugOverlayTimer: Timer?
    var transcribingIndicatorTask: Task<Void, Never>?
    /// Fires once if transcription is still running after `transcribingLongWaitThreshold`,
    /// surfacing a "still working" notice (with a cancel affordance) in the overlay.
    var transcribingLongWaitTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?
    var contextService: AppContextService
    var contextCaptureTask: Task<AppContext?, Never>?
    var capturedContext: AppContext?
    var hasShownScreenshotPermissionAlert = false
    var audioDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    var defaultInputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    let pipelineHistoryStore = PipelineHistoryStore()
    let statsStore = StatsStore()
    var wasMediaPlayingBeforeRecording = false
    var didPauseMediaForRecording = false
    var mediaPlaybackControlSessionID = UUID()
    var wasSystemMutedBeforeRecording = false
    var temporarilyUnavailablePreferredMicrophoneID: String? {
        didSet {
            if let temporarilyUnavailablePreferredMicrophoneID,
               !temporarilyUnavailablePreferredMicrophoneID.isEmpty {
                UserDefaults.standard.set(
                    temporarilyUnavailablePreferredMicrophoneID,
                    forKey: unavailablePreferredMicrophoneStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(forKey: unavailablePreferredMicrophoneStorageKey)
            }
        }
    }
    private var isApplyingAutomaticMicrophoneSelection = false

    init() {
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let apiKey = Self.loadStoredAPIKey(account: apiKeyStorageKey)
        let toggleHotkey = Self.loadHotkeyBinding(forKey: "toggle_hotkey", default: .fnKey)
        let holdHotkey = Self.loadHotkeyBinding(forKey: "hold_hotkey", default: .disabled)
        let customVocabulary = UserDefaults.standard.string(forKey: customVocabularyStorageKey) ?? ""
        let initialAccessibility = AXIsProcessTrusted()
        let initialScreenCapturePermission = CGPreflightScreenCaptureAccess()
        let storedMaxHistory = UserDefaults.standard.object(forKey: "max_pipeline_history_count") as? Int ?? 50
        self.maxPipelineHistoryCount = storedMaxHistory
        var removedAudioFileNames: [String] = []
        do {
            removedAudioFileNames = try pipelineHistoryStore.trim(to: storedMaxHistory)
        } catch {
            os_log(.error, "Failed to trim pipeline history during init: %{public}@", error.localizedDescription)
        }
        for audioFileName in removedAudioFileNames {
            Self.deleteAudioFile(audioFileName)
        }
        let savedHistory = pipelineHistoryStore.loadAllHistory()

        let selectedMicrophoneID: String
        if let storedMic = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) {
            selectedMicrophoneID = storedMic
        } else if let builtIn = AudioDevice.builtInMicrophoneUID() {
            // First launch: prefer built-in mic over system default (which often picks headphones)
            selectedMicrophoneID = builtIn
        } else {
            selectedMicrophoneID = "default"
        }

        let screenRecordingEnabled: Bool
        if UserDefaults.standard.object(forKey: "screen_recording_enabled") != nil {
            screenRecordingEnabled = UserDefaults.standard.bool(forKey: "screen_recording_enabled")
        } else {
            screenRecordingEnabled = true
        }
        let recordingMode = RecordingMode(rawValue: UserDefaults.standard.string(forKey: "recording_mode") ?? "") ?? .holdToRecord

        let playSoundsEnabled: Bool
        if UserDefaults.standard.object(forKey: "play_sounds_enabled") != nil {
            playSoundsEnabled = UserDefaults.standard.bool(forKey: "play_sounds_enabled")
        } else {
            playSoundsEnabled = true
        }

        let saveRunHistory: Bool
        if UserDefaults.standard.object(forKey: "save_run_history") != nil {
            saveRunHistory = UserDefaults.standard.bool(forKey: "save_run_history")
        } else {
            saveRunHistory = true
        }

        let saveAudioFiles: Bool
        if UserDefaults.standard.object(forKey: "save_audio_files") != nil {
            saveAudioFiles = UserDefaults.standard.bool(forKey: "save_audio_files")
        } else {
            saveAudioFiles = true
        }

        let keepAudioOnErrors: Bool
        if UserDefaults.standard.object(forKey: "keep_audio_on_errors") != nil {
            keepAudioOnErrors = UserDefaults.standard.bool(forKey: "keep_audio_on_errors")
        } else {
            keepAudioOnErrors = true
        }

        let collectStats: Bool
        if UserDefaults.standard.object(forKey: "collect_stats") != nil {
            collectStats = UserDefaults.standard.bool(forKey: "collect_stats")
        } else {
            collectStats = true
        }

        let apiProvider = APIProvider(rawValue: UserDefaults.standard.string(forKey: "api_provider") ?? "") ?? .groq
        let openaiAPIKey = Self.loadStoredAPIKey(account: "openai_api_key")
        let storedWhisperModel = UserDefaults.standard.string(forKey: "whisper_model_id")
            ?? UserDefaults.standard.string(forKey: "whisper_model")
        let whisperModelId = apiProvider.whisperModels.contains { $0.id == storedWhisperModel }
            ? storedWhisperModel!
            : apiProvider.defaultWhisperModel

        // Retired/deleted picker values are migrated immediately instead of failing every
        // request forever behind a generic raw-transcript fallback.
        let storedLLMModel = UserDefaults.standard.string(forKey: "llm_model_id")
        let llmModelId = apiProvider.llmModels.contains { $0.id == storedLLMModel }
            ? storedLLMModel!
            : apiProvider.defaultLLMModel

        let storedLanguage = UserDefaults.standard.string(forKey: "transcription_language") ?? ""
        let transcriptionLanguage: String? = storedLanguage.isEmpty ? nil : storedLanguage

        let postProcessingEnabled: Bool
        if UserDefaults.standard.object(forKey: "post_processing_enabled") != nil {
            postProcessingEnabled = UserDefaults.standard.bool(forKey: "post_processing_enabled")
        } else {
            postProcessingEnabled = true
        }

        let smartFormattingEnabled: Bool
        if UserDefaults.standard.object(forKey: "smart_formatting_enabled") != nil {
            smartFormattingEnabled = UserDefaults.standard.bool(forKey: "smart_formatting_enabled")
        } else {
            smartFormattingEnabled = true
        }

        let smartCorrectionsEnabled: Bool
        if UserDefaults.standard.object(forKey: "smart_corrections_enabled") != nil {
            smartCorrectionsEnabled = UserDefaults.standard.bool(forKey: "smart_corrections_enabled")
        } else {
            smartCorrectionsEnabled = true
        }

        let developerModeEnabled = UserDefaults.standard.bool(forKey: "developer_mode_enabled")
        let customPostProcessingPrompt = UserDefaults.standard.string(forKey: "custom_post_processing_prompt") ?? ""

        let audioWhileRecording = AudioWhileRecording(rawValue: UserDefaults.standard.string(forKey: "audio_while_recording") ?? "") ?? .doNothing

        let activeKey = apiProvider == .groq ? apiKey : openaiAPIKey
        self.contextService = AppContextService(apiKey: activeKey, baseURL: apiProvider.baseURL, llmModel: llmModelId, visionModel: apiProvider.defaultVisionModel)
        self.hasCompletedSetup = hasCompletedSetup
        self.apiKey = apiKey
        self.toggleHotkey = toggleHotkey
        self.holdHotkey = holdHotkey
        self.screenRecordingEnabled = screenRecordingEnabled
        self.recordingMode = recordingMode
        self.customVocabulary = customVocabulary
        self.pipelineHistory = savedHistory
        self.hasAccessibility = initialAccessibility
        self.hasScreenRecordingPermission = initialScreenCapturePermission
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID
        self.playSoundsEnabled = playSoundsEnabled
        self.saveRunHistory = saveRunHistory
        self.saveAudioFiles = saveAudioFiles
        self.keepAudioOnErrors = keepAudioOnErrors
        self.collectStats = collectStats
        self.apiProvider = apiProvider
        self.openaiAPIKey = openaiAPIKey
        self.whisperModelId = whisperModelId
        self.llmModelId = llmModelId
        self.transcriptionLanguage = transcriptionLanguage
        self.postProcessingEnabled = postProcessingEnabled
        self.smartFormattingEnabled = smartFormattingEnabled
        self.smartCorrectionsEnabled = smartCorrectionsEnabled
        self.developerModeEnabled = developerModeEnabled
        self.customPostProcessingPrompt = customPostProcessingPrompt
        self.audioWhileRecording = audioWhileRecording
        if let savedTab = UserDefaults.standard.string(forKey: "selected_settings_tab"),
           let tab = SettingsTab(rawValue: savedTab) {
            self.selectedSettingsTab = tab
        } else {
            self.selectedSettingsTab = collectStats ? .stats : .runLog
        }
        self.settingsWindowWasOpen = UserDefaults.standard.bool(forKey: "settings_window_was_open")
        self.temporarilyUnavailablePreferredMicrophoneID = UserDefaults.standard.string(
            forKey: unavailablePreferredMicrophoneStorageKey
        )

        UserDefaults.standard.set(whisperModelId, forKey: "whisper_model_id")
        UserDefaults.standard.set(llmModelId, forKey: "llm_model_id")

        refreshAvailableMicrophones()
        installAudioDeviceListener()
        wireRecordingErrorHandler()
    }

    func applyAutomaticMicrophoneSelection(_ microphoneID: String) {
        isApplyingAutomaticMicrophoneSelection = true
        selectedMicrophoneID = microphoneID
        isApplyingAutomaticMicrophoneSelection = false
    }

    /// Load a HotkeyBinding from UserDefaults, migrating from legacy string format if needed
    private static func loadHotkeyBinding(forKey key: String, default defaultBinding: HotkeyBinding) -> HotkeyBinding {
        // Try JSON data (new format)
        if let data = UserDefaults.standard.data(forKey: key),
           let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            return binding
        }
        // Try legacy string format (old HotkeyOption rawValue)
        if let legacyString = UserDefaults.standard.string(forKey: key),
           let binding = HotkeyBinding.fromLegacy(legacyString) {
            // Migrate: save as JSON
            if let data = try? JSONEncoder().encode(binding) {
                UserDefaults.standard.set(data, forKey: key)
            }
            return binding
        }
        return defaultBinding
    }
}
