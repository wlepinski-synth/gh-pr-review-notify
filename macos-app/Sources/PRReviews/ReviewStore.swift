import Foundation
import Observation

enum ReviewTab: String, CaseIterable, Identifiable {
    case direct = "Direct"
    case team = "Team"
    case mine = "My PRs"

    var id: String { rawValue }

    var queueURL: URL {
        let query: String
        switch self {
        case .direct: query = GitHubClient.directQuery
        case .team: query = GitHubClient.allQuery
        case .mine: query = GitHubClient.myOpenQuery
        }
        var components = URLComponents(string: "https://github.com/pulls")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}

@MainActor
@Observable
final class ReviewStore {
    static let shared = ReviewStore()

    private(set) var direct: [PullRequest] = []
    private(set) var team: [PullRequest] = []
    private(set) var lastRefreshed: Date?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false

    private let client = GitHubClient()
    private let poller = Poller()
    private var myTeams: Set<String>?

    func start() {
        poller.start(interval: { Prefs.pollMinutes }) { [weak self] in
            await self?.refresh() ?? false
        }
    }

    func pause() { poller.pause() }
    func resume() { poller.resume() }

    @discardableResult
    func refresh() async -> Bool {
        guard !isRefreshing else { return true }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            if myTeams == nil {
                myTeams = try? await client.myTeams()
            }
            let result = try await client.fetchReviewRequests()
            let keep = makeFilter()

            let directPRs = result.direct.filter(keep)
            let directURLs = Set(directPRs.map(\.url))
            let teamPRs = result.all.filter { keep($0) && !directURLs.contains($0.url) }

            direct = directPRs.sorted { $0.createdAt > $1.createdAt }
            team = teamPRs.sorted { $0.createdAt > $1.createdAt }
            lastRefreshed = Date()
            errorMessage = nil

            Notifier.shared.process(direct)
            return true
        } catch {
            errorMessage = (error as? GHError)?.userMessage ?? error.localizedDescription
            return false
        }
    }

    /// Team slugs to show on a row, limited to teams you belong to when known.
    func teamBadges(for pr: PullRequest) -> [String] {
        pr.requestedTeams
            .filter { myTeams?.contains($0) ?? true }
            .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
    }

    private func makeFilter() -> (PullRequest) -> Bool {
        let includeDrafts = Prefs.includeDrafts
        let pattern = Prefs.excludeTitleRegex
        let regex = pattern.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)

        return { pr in
            if pr.isDraft && !includeDrafts { return false }
            if let regex {
                let range = NSRange(pr.title.startIndex..., in: pr.title)
                if regex.firstMatch(in: pr.title, range: range) != nil { return false }
            }
            return true
        }
    }
}
