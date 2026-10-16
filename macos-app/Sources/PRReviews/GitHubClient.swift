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
