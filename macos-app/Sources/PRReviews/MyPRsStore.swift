import Foundation
import Observation

@MainActor
@Observable
final class MyPRsStore {
    static let shared = MyPRsStore()

    /// How long a merged or closed PR stays in the list.
    static let recentWindow: TimeInterval = 3600

    private(set) var prs: [MyPullRequest] = []
    private(set) var lastRefreshed: Date?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false

    private let client = GitHubClient()
    private let poller = Poller()

    var openCount: Int { prs.filter(\.snapshot.isOpen).count }

    func start() {
        poller.start(interval: { Prefs.myPRsPollMinutes }) { [weak self] in
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
            let fetched = try await client.fetchMyPRs(closedSince: Date().addingTimeInterval(-Self.recentWindow))
            let previous = prs.isEmpty
                ? Notifier.shared.storedMyPRSnapshots()
                : Dictionary(prs.map { ($0.url.absoluteString, $0.snapshot) }, uniquingKeysWith: { first, _ in first })

            prs = fetched
                .map { pr in
                    var resolved = pr
                    resolved.snapshot = pr.snapshot.resolvingUnknowns(from: previous[pr.url.absoluteString])
                    return resolved
                }
                .sorted(by: Self.displayOrder)
            lastRefreshed = Date()
            errorMessage = nil

            Notifier.shared.processMyPRs(prs, notify: Prefs.myPRsBanners)
            return true
        } catch {
            errorMessage = (error as? GHError)?.userMessage ?? error.localizedDescription
            return false
        }
    }

    func addToQueue(_ pr: MyPullRequest) async throws {
        try await client.enqueue(pr)
        await refresh()
    }

    func removeFromQueue(_ pr: MyPullRequest) async throws {
        try await client.dequeue(pr)
        await refresh()
    }

    /// Grouped like the tab (needs you, in queue, waiting, drafts, closed), newest first within a group.
    private static func displayOrder(_ a: MyPullRequest, _ b: MyPullRequest) -> Bool {
        let (ga, gb) = (PRStatus.group(a.snapshot).rawValue, PRStatus.group(b.snapshot).rawValue)
        return ga != gb ? ga < gb : a.createdAt > b.createdAt
    }
}
