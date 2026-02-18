import SwiftUI
import Foundation

struct GitHubRepoInfo: Decodable {
    let stargazersCount: Int

    private enum CodingKeys: String, CodingKey {
        case stargazersCount = "stargazers_count"
    }
}

struct GitHubStarRecord: Decodable, Identifiable {
    let user: GitHubStarUser

    var id: Int {
        user.id
    }
}

struct GitHubStarUser: Decodable {
    let id: Int
    let login: String
    let avatarUrl: URL
    let htmlUrl: URL

    /// Avatar URL resized to 44px (2x for 22pt display) for efficient loading
    var avatarThumbnailUrl: URL {
        // GitHub avatar URLs already have query params, so append with &
        let separator = avatarUrl.absoluteString.contains("?") ? "&" : "?"
        return URL(string: avatarUrl.absoluteString + "\(separator)s=44")!
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case avatarUrl = "avatar_url"
        case htmlUrl = "html_url"
    }
}

@MainActor
class GitHubMetadataCache: ObservableObject {
    static let shared = GitHubMetadataCache()

    @Published var starCount: Int?
    @Published var recentStargazers: [GitHubStarRecord] = []
    @Published var isLoading = true

    private var lastFetchDate: Date?
    private let cacheDuration: TimeInterval = 5 * 60 // 5 minutes
    private let repoAPIURL = URL(string: "https://api.github.com/repos/idanyekutiel/wispah")!

    private init() {}

    func fetchIfNeeded() async {
        if let lastFetch = lastFetchDate, Date().timeIntervalSince(lastFetch) < cacheDuration {
            return
        }

        isLoading = true

        do {
            let repoResult = try await URLSession.shared.data(from: repoAPIURL)
            guard let repoHTTP = repoResult.1 as? HTTPURLResponse,
                  (200..<300).contains(repoHTTP.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let count = try JSONDecoder().decode(GitHubRepoInfo.self, from: repoResult.0).stargazersCount

            var recent: [GitHubStarRecord] = []
            if count > 0 {
                let perPage = 100
                let lastPage = max(1, Int(ceil(Double(count) / Double(perPage))))
                let stargazersURL = URL(string: "https://api.github.com/repos/idanyekutiel/wispah/stargazers?per_page=\(perPage)&page=\(lastPage)")!
                var request = URLRequest(url: stargazersURL)
                request.setValue("application/vnd.github.v3.star+json", forHTTPHeaderField: "Accept")
                let starredResult = try await URLSession.shared.data(for: request)
                if let starredHTTP = starredResult.1 as? HTTPURLResponse,
                   (200..<300).contains(starredHTTP.statusCode) {
                    let all = try JSONDecoder().decode([GitHubStarRecord].self, from: starredResult.0)
                    recent = Array(all.suffix(15).reversed())
                }
            }

            starCount = count
            recentStargazers = recent
            isLoading = false
            lastFetchDate = Date()
        } catch {
            isLoading = false
        }
    }
}

struct InlineTranscribingDots: View {
    @State private var activeDot = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.blue.opacity(activeDot == index ? 1.0 : 0.3))
                    .frame(width: 12, height: 12)
                    .scaleEffect(activeDot == index ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: activeDot)
            }
        }
        .onReceive(timer) { _ in
            activeDot = (activeDot + 1) % 3
        }
    }
}

struct HowToRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.blue)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
