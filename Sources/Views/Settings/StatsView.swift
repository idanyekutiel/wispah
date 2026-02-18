import SwiftUI

enum StatsPeriod: String, CaseIterable {
    case week = "This Week"
    case month = "This Month"
    case allTime = "All Time"

    var startDate: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .week:
            return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))
        case .month:
            return cal.date(byAdding: .month, value: -1, to: cal.startOfDay(for: now))
        case .allTime:
            return nil
        }
    }
}

struct StatsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedPeriod: StatsPeriod = .week
    @State private var showResetConfirmation = false

    private var periodStats: TranscriptionStats {
        appState.statsStore.stats(from: selectedPeriod.startDate)
    }

    private var allTimeStats: TranscriptionStats {
        appState.statsStore.stats
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if allTimeStats.totalTranscriptions == 0 {
                    emptyView
                } else if periodStats.totalTranscriptions == 0 {
                    noPeriodDataView
                    resetSection
                } else {
                    overviewCard
                    speedCard
                    activityCard
                    resetSection
                }
            }
            .padding(24)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stats")
                    .font(.title2.bold())
                Text("Local only — never leaves your device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if allTimeStats.totalTranscriptions > 0 {
                Picker("", selection: $selectedPeriod) {
                    ForEach(StatsPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
        }
    }

    // MARK: - Empty / No Data States

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No transcriptions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Stats will appear after your first recording")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var noPeriodDataView: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No transcriptions \(selectedPeriod == .week ? "this week" : "this month")")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Switch to All Time to see your full stats")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Overview Card

    private var overviewCard: some View {
        let s = periodStats
        return statsCard("Overview", icon: "number") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                statBox(value: "\(s.totalTranscriptions)", label: "Transcriptions")
                statBox(value: formatNumber(s.totalWords), label: "Words")
                statBox(value: formatDuration(s.totalRecordingSeconds), label: "Recording Time")
                statBox(value: s.avgWordsPerTranscription > 0 ? "\(s.avgWordsPerTranscription)" : "—", label: "Avg Words / Session")
            }
        }
    }

    // MARK: - Speed Card

    private var speedCard: some View {
        let s = periodStats
        return statsCard("Speed", icon: "gauge.with.dots.needle.33percent") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                statBox(value: s.avgWPM > 0 ? "\(s.avgWPM)" : "—", label: "Avg WPM")
                statBox(value: s.wpmMax > 0 ? "\(s.wpmMax)" : "—", label: "Fastest")
                statBox(value: s.wpmMin > 0 ? "\(s.wpmMin)" : "—", label: "Slowest")
            }
            if s.wpmCount == 0 {
                Text("WPM requires recording duration data — will populate with new transcriptions")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Activity Card

    private var activityCard: some View {
        let s = periodStats
        return statsCard("Activity", icon: "flame") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                statBox(value: "\(allTimeStats.currentStreak)", label: "Day Streak")
                statBox(value: s.peakHour, label: "Peak Hour")
                statBox(value: s.avgPerDay > 0 ? String(format: "%.1f", s.avgPerDay) : "—", label: "Avg / Day")
            }
        }
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label("Reset All Data", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
            .alert("Reset All Data?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    appState.statsStore.reset()
                    appState.clearPipelineHistory()
                }
            } message: {
                Text("This will permanently delete all transcription history, audio files, and stats. This cannot be undone.")
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Reusable Components

    private func statsCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
    }
}
