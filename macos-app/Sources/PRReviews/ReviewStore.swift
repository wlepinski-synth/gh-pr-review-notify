import Foundation
import Observation

enum ReviewTab: String, CaseIterable, Identifiable {
    case direct = "Direct"
    case team = "Team"

    var id: String { rawValue }

    var queueURL: URL {
        let query = self == .direct ? GitHubClient.directQuery : GitHubClient.allQuery
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
    private var myTeams: Set<String>?
    private var failures = 0
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let base = Double(Prefs.pollMinutes) * 60
                let backoff = Double(min(1 << self.failures, 8))
                try? await Task.sleep(for: .seconds(base * backoff))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
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
            failures = 0

            Notifier.shared.process(direct)
        } catch {
            failures += 1
            errorMessage = (error as? GHError)?.userMessage ?? error.localizedDescription
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
