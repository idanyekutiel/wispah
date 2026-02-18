import Foundation

enum RecordingMode: String, CaseIterable, Identifiable {
    case holdToRecord
    case toggleToRecord

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .holdToRecord: return "Hold to Record"
        case .toggleToRecord: return "Toggle to Record"
        }
    }

    var description: String {
        switch self {
        case .holdToRecord: return "Hold the key to record, release to stop and transcribe."
        case .toggleToRecord: return "Press once to start recording, press again to stop and transcribe."
        }
    }
}
