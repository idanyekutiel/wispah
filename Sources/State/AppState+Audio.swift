import Foundation
import AppKit
import CoreAudio

extension AppState {
    func refreshAvailableMicrophones() {
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    // MARK: - Audio While Recording

    func handleAudioOnRecordingStart() {
        switch audioWhileRecording {
        case .doNothing:
            break
        case .pauseMedia:
            wasMediaPlayingBeforeRecording = true
            sendMediaPlayPause()
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
                sendMediaPlayPause()
                wasMediaPlayingBeforeRecording = false
            }
        case .muteSystem:
            if !wasSystemMutedBeforeRecording {
                setSystemMute(false)
            }
            wasSystemMutedBeforeRecording = false
        }
    }

    private func sendMediaPlayPause() {
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
