import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case stats
    case dictionary
    case runLog
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stats: return "Stats"
        case .runLog: return "Transcriptions"
        case .dictionary: return "Dictionary"
        case .general: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .stats: return "chart.bar"
        case .runLog: return "list.bullet.rectangle"
        case .dictionary: return "text.book.closed.fill"
        case .general: return "gearshape"
        }
    }
}
