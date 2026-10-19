import Foundation

struct PullRequest: Identifiable, Hashable {
    let url: URL
    let title: String
    let repo: String
    let author: String
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    /// Requested teams as "org/slug".
    let requestedTeams: [String]

    var id: URL { url }
    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

struct MyPullRequest: Identifiable, Hashable {
    let nodeID: String
    let url: URL
    let number: Int
    let title: String
    let repo: String
    let createdAt: Date
    let closedAt: Date?
    let reviewers: [Reviewer]
    let linear: LinearIssue?
    let checks: [CheckItem]
    let hasMergeQueue: Bool
    var snapshot: PRSnapshot

    var id: URL { url }
    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var approvers: [String] { reviewers.filter { $0.state == .approved }.map(\.login) }
    var pendingReviewers: Int { reviewers.filter { $0.state == .pending }.count }
}

struct Reviewer: Hashable {
    enum State: Int {
        // Display order in the review popover.
        case changesRequested, approved, commented, pending
    }

    let login: String
    let name: String?
    let avatarURL: URL?
    let isTeam: Bool
    let profileURL: URL?
    let state: State

    var displayName: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? login }
}

enum GHError: Error {
    case notFound
    case notAuthenticated
    case rateLimited
    case failed(String)

    var userMessage: String {
        switch self {
        case .notFound: return "GitHub CLI (gh) not found. Install it or set its path in Settings."
        case .notAuthenticated: return "gh is not authenticated. Run: gh auth login"
        case .rateLimited: return "GitHub rate limit hit. Retrying later."
        case .failed(let detail): return "GitHub request failed: \(detail)"
        }
    }

    static func classify(_ stderr: String) -> GHError {
        let text = stderr.lowercased()
        if text.contains("gh auth login") || text.contains("not logged") || text.contains("http 401") {
            return .notAuthenticated
        }
        if text.contains("rate limit") { return .rateLimited }
        let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? "unknown error"
        return .failed(firstLine.trimmingCharacters(in: .whitespaces))
    }
}

struct GitHubClient {
    static let directQuery = "is:pr is:open archived:false user-review-requested:@me"
    static let allQuery = "is:pr is:open archived:false review-requested:@me"

    private static let graphQL = """
    query($direct: String!, $all: String!) {
      direct: search(query: $direct, type: ISSUE, first: 100) { nodes { ...PR } }
      all: search(query: $all, type: ISSUE, first: 100) { nodes { ...PR } }
    }
    fragment PR on PullRequest {
      url title isDraft createdAt updatedAt
      repository { nameWithOwner }
      author { login }
      reviewRequests(first: 30) {
        nodes { requestedReviewer { ... on Team { slug organization { login } } } }
      }
    }
    """

    static let myOpenQuery = "is:pr is:open author:@me archived:false"

    private static let myPRsGraphQL = """
    query($open: String!, $recent: String!) {
      open: search(query: $open, type: ISSUE, first: 50) { nodes { ...Mine } }
      recent: search(query: $recent, type: ISSUE, first: 20) { nodes { ...Mine } }
    }
    fragment Mine on PullRequest {
      id url number title body isDraft state createdAt closedAt
      repository { nameWithOwner }
      reviewDecision mergeStateStatus mergeable isInMergeQueue
      mergeQueue { url }
      mergeQueueEntry { position }
      autoMergeRequest { enabledAt }
      reviewRequests(first: 20) {
        nodes {
          requestedReviewer {
            ... on User { login name avatarUrl(size: 64) }
            ... on Team { slug name avatarUrl(size: 64) }
          }
        }
      }
      latestReviews(first: 20) { nodes { state author { __typename login avatarUrl(size: 64) ... on User { name } } } }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              state
              contexts(first: 100) {
                nodes {
                  ... on CheckRun { name conclusion status detailsUrl }
                  ... on StatusContext { context state targetUrl }
                }
              }
            }
          }
        }
      }
    }
    """

    private static let enqueueMutation = """
    mutation($id: ID!) { enqueuePullRequest(input: { pullRequestId: $id }) { mergeQueueEntry { position } } }
    """

    private static let dequeueMutation = """
    mutation($id: ID!) { dequeuePullRequest(input: { id: $id }) { mergeQueueEntry { id } } }
    """

    static var resolvedGHPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let custom = (Prefs.ghPath as NSString).expandingTildeInPath
        let candidates = [custom, "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.asdf/shims/gh"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    func fetchReviewRequests() async throws -> (direct: [PullRequest], all: [PullRequest]) {
        let data = try await run([
            "api", "graphql",
            "-f", "query=\(Self.graphQL)",
            "-f", "direct=\(Self.directQuery)",
            "-f", "all=\(Self.allQuery)",
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(SearchResponse.self, from: data)
        return (response.data.direct.pullRequests, response.data.all.pullRequests)
    }

    /// Your open PRs plus the ones merged or closed since `closedSince`.
    func fetchMyPRs(closedSince: Date) async throws -> [MyPullRequest] {
        let since = ISO8601DateFormatter().string(from: closedSince)
        let data = try await run([
            "api", "graphql",
            "-f", "query=\(Self.myPRsGraphQL)",
            "-f", "open=\(Self.myOpenQuery)",
            "-f", "recent=is:pr is:closed author:@me closed:>=\(since)",
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(MyPRsResponse.self, from: data)
        let recent = response.data.recent.nodes.compactMap { $0?.pullRequest }
            .filter { ($0.closedAt ?? .distantPast) >= closedSince }
        return response.data.open.nodes.compactMap { $0?.pullRequest } + recent
    }

    func enqueue(_ pr: MyPullRequest) async throws {
        _ = try await run(["api", "graphql", "-f", "query=\(Self.enqueueMutation)", "-f", "id=\(pr.nodeID)"])
    }

    func dequeue(_ pr: MyPullRequest) async throws {
        _ = try await run(["api", "graphql", "-f", "query=\(Self.dequeueMutation)", "-f", "id=\(pr.nodeID)"])
    }

    func myTeams() async throws -> Set<String> {
        let data = try await run(["api", "user/teams", "--paginate", "--jq", #".[] | .organization.login + "/" + .slug"#])
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        return Set(lines)
    }

    private func run(_ arguments: [String]) async throws -> Data {
        guard let gh = Self.resolvedGHPath else { throw GHError.notFound }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gh)
                process.arguments = arguments

                // Apps launched from Finder get a bare PATH, which breaks asdf shims.
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.asdf/shims:\(home)/.asdf/bin:/usr/bin:/bin"
                process.environment = env

                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: GHError.failed(error.localizedDescription))
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if process.isRunning { process.terminate() }
                }

                // Drain stderr on its own queue so a full pipe can't stall the process.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                } else {
                    continuation.resume(throwing: GHError.classify(String(decoding: errData, as: UTF8.self)))
                }
            }
        }
    }
}

private struct SearchResponse: Decodable {
    struct Payload: Decodable {
        let direct: Search
        let all: Search
    }

    struct Search: Decodable {
        let nodes: [Node?]

        var pullRequests: [PullRequest] {
            nodes.compactMap { $0?.pullRequest }
        }
    }

    struct Node: Decodable {
        let url: URL
        let title: String
        let isDraft: Bool
        let createdAt: Date
        let updatedAt: Date
        let repository: Repository
        let author: Login?
        let reviewRequests: Requests?

        var pullRequest: PullRequest {
            let teams = (reviewRequests?.nodes ?? []).compactMap { node -> String? in
                guard let reviewer = node?.requestedReviewer, let slug = reviewer.slug, let org = reviewer.organization else {
                    return nil
                }
                return "\(org.login)/\(slug)"
            }
            return PullRequest(
                url: url,
                title: title,
                repo: repository.nameWithOwner,
                author: author?.login ?? "",
                isDraft: isDraft,
                createdAt: createdAt,
                updatedAt: updatedAt,
                requestedTeams: teams
            )
        }
    }

    struct Repository: Decodable { let nameWithOwner: String }
    struct Login: Decodable { let login: String }
    struct Requests: Decodable { let nodes: [Request?] }
    struct Request: Decodable { let requestedReviewer: Reviewer? }
    struct Reviewer: Decodable {
        let slug: String?
        let organization: Login?
    }

    let data: Payload
}

private struct MyPRsResponse: Decodable {
    struct Payload: Decodable {
        let open: Search
        let recent: Search
    }

    struct Search: Decodable { let nodes: [Node?] }

    struct Node: Decodable {
        let id: String
        let url: URL
        let number: Int
        let title: String
        let body: String?
        let isDraft: Bool
        let state: String
        let createdAt: Date
        let closedAt: Date?
        let repository: Repository
        let reviewDecision: String?
        let mergeStateStatus: String?
        let mergeable: String?
        let isInMergeQueue: Bool
        let mergeQueue: MergeQueue?
        let mergeQueueEntry: QueueEntry?
        let autoMergeRequest: AutoMerge?
        let reviewRequests: Requests
        let latestReviews: Reviews
        let commits: Commits

        /// Pending requests win over an earlier review, since GitHub re-requested that person.
        var reviewers: [Reviewer] {
            let org = repository.nameWithOwner.split(separator: "/").first.map(String.init) ?? ""
            let pending = reviewRequests.nodes.compactMap { $0?.requestedReviewer?.reviewer(org: org) }
            let pendingLogins = Set(pending.map(\.login))
            let reviewed = latestReviews.nodes.compactMap { node -> Reviewer? in
                guard let node, let author = node.author, !pendingLogins.contains(author.login) else { return nil }
                let state: Reviewer.State
                switch node.state {
                case "APPROVED": state = .approved
                case "CHANGES_REQUESTED": state = .changesRequested
                case "COMMENTED": state = .commented
                default: return nil
                }
                let path = author.__typename == "Bot" ? "apps/\(author.login)" : author.login
                return Reviewer(
                    login: author.login, name: author.name, avatarURL: author.avatarUrl, isTeam: false,
                    profileURL: URL(string: "https://github.com/\(path)"), state: state
                )
            }
            return (reviewed + pending).sorted { $0.state.rawValue < $1.state.rawValue }
        }

        var pullRequest: MyPullRequest {
            let rollup = commits.nodes.first??.commit.statusCheckRollup
            return MyPullRequest(
                nodeID: id,
                url: url,
                number: number,
                title: title,
                repo: repository.nameWithOwner,
                createdAt: createdAt,
                closedAt: closedAt,
                reviewers: reviewers,
                linear: LinearIssue.find(body: body ?? "", title: title),
                checks: CheckItem.deduplicated((rollup?.contexts.nodes ?? []).compactMap { $0?.checkItem }),
                hasMergeQueue: mergeQueue != nil,
                snapshot: PRSnapshot(
                    state: state,
                    isDraft: isDraft,
                    reviewDecision: reviewDecision,
                    checks: rollup?.state,
                    mergeState: mergeStateStatus,
                    mergeable: mergeable,
                    inQueue: isInMergeQueue,
                    queuePosition: mergeQueueEntry?.position,
                    autoMerge: autoMergeRequest != nil
                )
            )
        }
    }

    struct Repository: Decodable { let nameWithOwner: String }
    struct MergeQueue: Decodable { let url: URL? }
    struct QueueEntry: Decodable { let position: Int? }
    struct AutoMerge: Decodable { let enabledAt: Date? }
    struct Requests: Decodable { let nodes: [Request?] }
    struct Request: Decodable { let requestedReviewer: RequestedReviewer? }
    struct RequestedReviewer: Decodable {
        let login: String?
        let slug: String?
        let name: String?
        let avatarUrl: URL?

        func reviewer(org: String) -> Reviewer? {
            if let login {
                return Reviewer(
                    login: login, name: name, avatarURL: avatarUrl, isTeam: false,
                    profileURL: URL(string: "https://github.com/\(login)"), state: .pending
                )
            }
            if let slug {
                return Reviewer(
                    login: slug, name: name, avatarURL: avatarUrl, isTeam: true,
                    profileURL: URL(string: "https://github.com/orgs/\(org)/teams/\(slug)"), state: .pending
                )
            }
            return nil
        }
    }
    struct Reviews: Decodable { let nodes: [Review?] }
    struct Review: Decodable {
        let state: String
        let author: Author?
    }
    struct Author: Decodable {
        let __typename: String?
        let login: String
        let name: String?
        let avatarUrl: URL?
    }
    struct Login: Decodable { let login: String }
    struct Commits: Decodable { let nodes: [CommitNode?] }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable {
        let state: String
        let contexts: Contexts
    }
    struct Contexts: Decodable { let nodes: [Context?] }

    /// A CheckRun or a legacy StatusContext; only one set of fields is filled.
    struct Context: Decodable {
        let name: String?
        let conclusion: String?
        let status: String?
        let detailsUrl: URL?
        let context: String?
        let state: String?
        let targetUrl: URL?

        var checkItem: CheckItem? {
            if let name {
                return CheckItem(name: name, state: .from(checkRunStatus: status, conclusion: conclusion), url: detailsUrl)
            }
            if let context {
                return CheckItem(name: context, state: .from(statusState: state), url: targetUrl)
            }
            return nil
        }
    }

    let data: Payload
}
