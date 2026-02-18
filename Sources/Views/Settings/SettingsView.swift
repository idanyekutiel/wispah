import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { tab in
            if tab == .stats && !appState.collectStats { return false }
            return true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleTabs) { tab in
                    Button {
                        appState.selectedSettingsTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(appState.selectedSettingsTab == tab
                                          ? Color.accentColor.opacity(0.15)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch appState.selectedSettingsTab {
                case .stats:
                    if appState.collectStats {
                        StatsView()
                    } else {
                        RunLogView()
                    }
                case .runLog, .none:
                    RunLogView()
                case .general:
                    GeneralSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: appState.collectStats) { enabled in
            if !enabled && appState.selectedSettingsTab == .stats {
                appState.selectedSettingsTab = .runLog
            }
        }
    }
}
