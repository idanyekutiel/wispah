import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case stats
    case runLog
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stats: return "Stats"
        case .runLog: return "Transcriptions"
        case .general: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .stats: return "chart.bar"
        case .runLog: return "list.bullet.rectangle"
        case .general: return "gearshape"
        }
    }
}
