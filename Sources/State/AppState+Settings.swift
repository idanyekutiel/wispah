import Foundation
import ServiceManagement
import os.log

extension AppState {
    private static let defaultSavedAudioExtension = "m4a"

    static func loadStoredAPIKey(account: String) -> String {
        if let storedKey = AppSettingsStorage.load(account: account), !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedKey
        }
        return ""
    }

    func persistAPIKey(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: account)
        } else {
            AppSettingsStorage.save(trimmed, account: account)
        }
    }

    static func audioStorageDirectory() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            os_log(.error, log: recordingLog, "Application Support directory not found, falling back to temporary directory")
            return FileManager.default.temporaryDirectory.appendingPathComponent("WispahAudio", isDirectory: true)
        }
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Wispah"
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    static func saveAudioFile(from tempURL: URL) -> String? {
        saveAudioFile(from: tempURL, preferredExtension: nil)
    }

    static func saveAudioFile(from sourceURL: URL, preferredExtension: String?) -> String? {
        let fileExtension = normalizedAudioFileExtension(preferredExtension ?? sourceURL.pathExtension)
        let fileName = UUID().uuidString + "." + fileExtension
        let destURL = audioStorageDirectory().appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destURL.path)
            return fileName
        } catch {
            return nil
        }
    }

    static func replaceAudioFile(named existingFileName: String?, with sourceURL: URL, preferredExtension: String? = nil) -> String? {
        guard let newFileName = saveAudioFile(from: sourceURL, preferredExtension: preferredExtension) else {
            return existingFileName
        }
        if let existingFileName, existingFileName != newFileName {
            deleteAudioFile(existingFileName)
        }
        return newFileName
    }

    static func deleteAudioFile(_ fileName: String) {
        let fileURL = audioStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func normalizedAudioFileExtension(_ pathExtension: String?) -> String {
        let trimmed = pathExtension?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !trimmed.isEmpty else {
            return defaultSavedAudioExtension
        }
        return trimmed
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let current = SMAppService.mainApp.status == .enabled
            if current != launchAtLogin {
                launchAtLogin = current
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        let current = SMAppService.mainApp.status == .enabled
        if current != launchAtLogin {
            launchAtLogin = current
        }
    }
}
