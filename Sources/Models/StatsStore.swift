import Foundation

struct DailyStats: Codable {
    var transcriptions: Int = 0
    var words: Int = 0
    var recordingSeconds: Double = 0
    var wpmSum: Int = 0
    var wpmCount: Int = 0
    var wpmMin: Int = 0
    var wpmMax: Int = 0
    var hourCounts: [String: Int] = [:]  // hour string -> count
}

struct TranscriptionStats: Codable {
    var totalTranscriptions: Int = 0
    var totalWords: Int = 0
    var totalRecordingSeconds: Double = 0
    var wpmSum: Int = 0
    var wpmCount: Int = 0
    var wpmMin: Int = 0
    var wpmMax: Int = 0
    var hourCounts: [Int] = Array(repeating: 0, count: 24)
    var activeDays: Set<String> = []
    var dailyStats: [String: DailyStats] = [:]

    // Backward-compatible decoding — old stats.json files won't have dailyStats
    enum CodingKeys: String, CodingKey {
        case totalTranscriptions, totalWords, totalRecordingSeconds
        case wpmSum, wpmCount, wpmMin, wpmMax
        case hourCounts, activeDays, dailyStats
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTranscriptions = try c.decode(Int.self, forKey: .totalTranscriptions)
        totalWords = try c.decode(Int.self, forKey: .totalWords)
        totalRecordingSeconds = try c.decode(Double.self, forKey: .totalRecordingSeconds)
        wpmSum = try c.decode(Int.self, forKey: .wpmSum)
        wpmCount = try c.decode(Int.self, forKey: .wpmCount)
        wpmMin = try c.decode(Int.self, forKey: .wpmMin)
        wpmMax = try c.decode(Int.self, forKey: .wpmMax)
        hourCounts = try c.decode([Int].self, forKey: .hourCounts)
        activeDays = try c.decode(Set<String>.self, forKey: .activeDays)
        dailyStats = try c.decodeIfPresent([String: DailyStats].self, forKey: .dailyStats) ?? [:]
    }

    var avgWordsPerTranscription: Int {
        guard totalTranscriptions > 0 else { return 0 }
        return totalWords / totalTranscriptions
    }

    var avgWPM: Int {
        guard wpmCount > 0 else { return 0 }
        return wpmSum / wpmCount
    }

    var peakHour: String {
        guard let maxIdx = hourCounts.enumerated().max(by: { $0.element < $1.element }),
              maxIdx.element > 0 else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        var components = DateComponents()
        components.hour = maxIdx.offset
        guard let date = Calendar.current.date(from: components) else { return "—" }
        return formatter.string(from: date).lowercased()
    }

    var currentStreak: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let sortedDays = activeDays.compactMap { formatter.date(from: $0) }
            .map { cal.startOfDay(for: $0) }
            .sorted(by: >)

        guard let first = sortedDays.first else { return 0 }
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        guard first >= yesterday else { return 0 }

        var streak = 0
        var expected = first
        for day in sortedDays {
            if day == expected {
                streak += 1
                expected = cal.date(byAdding: .day, value: -1, to: day)!
            } else if day < expected {
                break
            }
        }
        return streak
    }

    var avgPerDay: Double {
        guard !activeDays.isEmpty else { return 0 }
        return Double(totalTranscriptions) / Double(activeDays.count)
    }
}

final class StatsStore {
    private let fileURL: URL
    private(set) var stats: TranscriptionStats
    private let saveQueue = DispatchQueue(label: "com.wispah.stats.save")

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Wispah"
        let dir = appSupport.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("stats.json")
        stats = Self.load(from: fileURL)
    }

    func record(wordCount: Int, recordingDurationSeconds: Double?, timestamp: Date) {
        stats.totalTranscriptions += 1
        stats.totalWords += wordCount

        let hour = Calendar.current.component(.hour, from: timestamp)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dayKey = formatter.string(from: timestamp)

        var wpm: Int?

        if let duration = recordingDurationSeconds, duration > 5, wordCount > 0 {
            stats.totalRecordingSeconds += duration
            wpm = Int(Double(wordCount) / (duration / 60.0))
            stats.wpmSum += wpm!
            stats.wpmCount += 1
            if stats.wpmMin == 0 || wpm! < stats.wpmMin { stats.wpmMin = wpm! }
            if wpm! > stats.wpmMax { stats.wpmMax = wpm! }
        } else if let duration = recordingDurationSeconds, duration > 0 {
            stats.totalRecordingSeconds += duration
        }

        stats.hourCounts[hour] += 1
        stats.activeDays.insert(dayKey)

        // Daily breakdown for period filtering
        var daily = stats.dailyStats[dayKey] ?? DailyStats()
        daily.transcriptions += 1
        daily.words += wordCount
        if let wpm = wpm, let duration = recordingDurationSeconds {
            daily.recordingSeconds += duration
            daily.wpmSum += wpm
            daily.wpmCount += 1
            if daily.wpmMin == 0 || wpm < daily.wpmMin { daily.wpmMin = wpm }
            if wpm > daily.wpmMax { daily.wpmMax = wpm }
        } else if let duration = recordingDurationSeconds, duration > 0 {
            daily.recordingSeconds += duration
        }
        daily.hourCounts["\(hour)", default: 0] += 1
        stats.dailyStats[dayKey] = daily

        save()
    }

    /// Aggregate stats for a date range. Pass nil for all-time.
    func stats(from startDate: Date?) -> TranscriptionStats {
        guard let start = startDate else { return stats }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)

        var result = TranscriptionStats()

        for (dayKey, daily) in stats.dailyStats {
            guard let date = formatter.date(from: dayKey),
                  cal.startOfDay(for: date) >= startDay else { continue }

            result.totalTranscriptions += daily.transcriptions
            result.totalWords += daily.words
            result.totalRecordingSeconds += daily.recordingSeconds
            result.wpmSum += daily.wpmSum
            result.wpmCount += daily.wpmCount
            if daily.wpmMin > 0 && (result.wpmMin == 0 || daily.wpmMin < result.wpmMin) {
                result.wpmMin = daily.wpmMin
            }
            if daily.wpmMax > result.wpmMax {
                result.wpmMax = daily.wpmMax
            }
            for (hourStr, count) in daily.hourCounts {
                if let h = Int(hourStr), h >= 0, h < 24 {
                    result.hourCounts[h] += count
                }
            }
            result.activeDays.insert(dayKey)
        }

        return result
    }

    func reset() {
        stats = TranscriptionStats()
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(stats) else { return }
        let url = fileURL
        saveQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func load(from url: URL) -> TranscriptionStats {
        guard let data = try? Data(contentsOf: url),
              let stats = try? JSONDecoder().decode(TranscriptionStats.self, from: data) else {
            return TranscriptionStats()
        }
        return stats
    }
}
