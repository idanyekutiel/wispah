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
                    Text("Transcriptions")
                        .font(.headline)
                    if appState.saveRunHistory {
                        Text("Stored locally. Only the \(appState.maxPipelineHistoryCount) most recent are kept.")
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
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Run history is disabled")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Enable it in Settings > Log Settings")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else if appState.pipelineHistory.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No transcriptions yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Use dictation to populate history")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
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
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)
                            Text("No results for \"\(searchText)\"")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Try a different search term")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
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
