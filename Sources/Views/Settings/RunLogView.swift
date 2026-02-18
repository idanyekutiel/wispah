import SwiftUI

// MARK: - Run Log

struct RunLogView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""

    private var filteredHistory: [PipelineHistoryItem] {
        if searchText.isEmpty { return appState.pipelineHistory }
        let query = searchText.lowercased()
        return appState.pipelineHistory.filter {
            $0.postProcessedTranscript.lowercased().contains(query)
            || $0.rawTranscript.lowercased().contains(query)
            || $0.contextSummary.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Log")
                        .font(.headline)
                    if appState.saveRunHistory {
                        Text("Stored locally. Only the \(appState.maxPipelineHistoryCount) most recent runs are kept.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if appState.saveRunHistory {
                    Button("Clear History") {
                        appState.clearPipelineHistory()
                    }
                    .disabled(appState.pipelineHistory.isEmpty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if !appState.saveRunHistory {
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Run history is disabled.")
                            .foregroundStyle(.secondary)
                        Text("Enable it in Settings > Log Settings.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if appState.pipelineHistory.isEmpty {
                VStack {
                    Spacer()
                    Text("No runs yet. Use dictation to populate history.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search transcriptions...", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                    if filteredHistory.isEmpty {
                        VStack {
                            Spacer()
                            Text("No results for \"\(searchText)\"")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            VStack(spacing: 12) {
                                ForEach(filteredHistory) { item in
                                    RunLogEntryView(item: item)
                                }
                            }
                            .padding(20)
                        }
                    }
                }
            }
        }
    }
}
