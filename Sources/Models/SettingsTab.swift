import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case runLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .runLog: return "Run Log"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .runLog: return "clock.arrow.circlepath"
        }
    }
}
