import Foundation

enum AudioWhileRecording: String, CaseIterable, Identifiable {
    case doNothing
    case pauseMedia
    case muteSystem

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .doNothing: return "Do nothing"
        case .pauseMedia: return "Pause media playback"
        case .muteSystem: return "Mute media playback"
        }
    }
    var description: String {
        switch self {
        case .doNothing: return "No change to audio while recording."
        case .pauseMedia: return "Pauses music/media when recording starts, resumes when recording stops."
        case .muteSystem: return "Mutes media playback when recording starts, unmutes when recording stops."
        }
    }
}
