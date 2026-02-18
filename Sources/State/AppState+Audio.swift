import Foundation
import AppKit
import CoreAudio
import os.log

extension AppState {
    func refreshAvailableMicrophones() {
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    // MARK: - Media Playback Detection & Control
    //
    // macOS 15.4+ blocks direct MediaRemote access for third-party apps.
    // Detection: mediaremote-adapter (Perl trick — /usr/bin/perl has com.apple.perl bundle ID)
    // Pause/Resume: CGEvent media key simulation (works universally)

    func handleAudioOnRecordingStart() {
        switch audioWhileRecording {
        case .doNothing:
            break
        case .pauseMedia:
            isMediaCurrentlyPlaying { [weak self] isPlaying in
                guard let self, self.isRecording else { return } // Ignore if recording already stopped
                if let isPlaying {
                    os_log(.info, log: recordingLog, "pauseMedia: detected isPlaying=%{public}@", isPlaying ? "yes" : "no")
                    self.wasMediaPlayingBeforeRecording = isPlaying
                    if isPlaying { self.sendMediaKeyEvent() }
                } else {
                    // Detection failed — do nothing (don't risk starting/stopping music blindly)
                    os_log(.info, log: recordingLog, "pauseMedia: detection failed, skipping")
                    self.wasMediaPlayingBeforeRecording = false
                }
            }
        case .muteSystem:
            wasSystemMutedBeforeRecording = isSystemMuted()
            if !wasSystemMutedBeforeRecording {
                setSystemMute(true)
            }
        }
    }

    func handleAudioOnRecordingStop() {
        switch audioWhileRecording {
        case .doNothing:
            break
        case .pauseMedia:
            if wasMediaPlayingBeforeRecording {
                os_log(.info, log: recordingLog, "pauseMedia: resuming playback")
                sendMediaKeyEvent()
                wasMediaPlayingBeforeRecording = false
            }
        case .muteSystem:
            if !wasSystemMutedBeforeRecording {
                setSystemMute(false)
            }
            wasSystemMutedBeforeRecording = false
        }
    }

    /// Detect if media is playing via mediaremote-adapter (works on macOS 15.4+).
    /// Uses /usr/bin/perl which has com.apple.perl bundle ID — allowed to use MediaRemote.
    /// Returns Bool? — true/false if detection worked, nil if it failed.
    private func isMediaCurrentlyPlaying(completion: @escaping (Bool?) -> Void) {
        guard let bundleResources = Bundle.main.resourcePath else {
            os_log(.error, log: recordingLog, "mediaremote-adapter: no bundle resource path")
            completion(nil); return
        }
        let scriptPath = (bundleResources as NSString).appendingPathComponent("mediaremote-adapter.pl")
        let frameworkPath = (bundleResources as NSString).appendingPathComponent("MediaRemoteAdapter.framework")

        // Verify files exist
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            os_log(.error, log: recordingLog, "mediaremote-adapter: script not found at %{public}@", scriptPath)
            completion(nil); return
        }
        guard FileManager.default.fileExists(atPath: frameworkPath) else {
            os_log(.error, log: recordingLog, "mediaremote-adapter: framework not found at %{public}@", frameworkPath)
            completion(nil); return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [scriptPath, frameworkPath, "get"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try task.run()
                // Read output BEFORE waitUntilExit to avoid pipe buffer deadlock
                // (adapter output with artwork can be >64KB, exceeding pipe buffer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    os_log(.info, log: recordingLog, "mediaremote-adapter: exit=%d output_bytes=%d", task.terminationStatus, data.count)
                    if output == "null" || output.isEmpty || task.terminationStatus != 0 {
                        os_log(.info, log: recordingLog, "mediaremote-adapter: no media detected")
                        completion(nil)
                        return
                    }
                    if let jsonData = output.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let playing = json["playing"] as? Bool {
                        let title = json["title"] as? String ?? "unknown"
                        os_log(.info, log: recordingLog, "mediaremote-adapter: playing=%{public}@ title=%{public}@", playing ? "yes" : "no", title)
                        completion(playing)
                    } else {
                        os_log(.error, log: recordingLog, "mediaremote-adapter: failed to parse JSON, first 200 chars: %{public}@", String(output.prefix(200)))
                        completion(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    os_log(.error, log: recordingLog, "mediaremote-adapter error: %{public}@", error.localizedDescription)
                    completion(nil)
                }
            }
        }
    }

    /// Simulate media play/pause key event (works on all macOS versions)
    private func sendMediaKeyEvent() {
        let keyCode: UInt16 = 0x10  // NX_KEYTYPE_PLAY
        let downEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((Int(keyCode) << 16) | (0xa << 8)),
            data2: -1
        )
        downEvent?.cgEvent?.post(tap: .cghidEventTap)

        let upEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((Int(keyCode) << 16) | (0xb << 8)),
            data2: -1
        )
        upEvent?.cgEvent?.post(tap: .cghidEventTap)
    }

    private func isSystemMuted() -> Bool {
        var defaultOutputID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &defaultOutputID) == noErr else {
            return false
        }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteValue: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(defaultOutputID, &muteAddress, 0, nil, &muteSize, &muteValue) == noErr else {
            return false
        }
        return muteValue != 0
    }

    private func setSystemMute(_ mute: Bool) {
        var defaultOutputID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &defaultOutputID) == noErr else {
            return
        }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteValue: UInt32 = mute ? 1 : 0
        AudioObjectSetPropertyData(defaultOutputID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteValue)
    }

    func installAudioDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAvailableMicrophones()
            }
        }
        audioDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }
}
