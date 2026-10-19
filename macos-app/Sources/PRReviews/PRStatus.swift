import Foundation

/// The parts of a PR's state that drive its headline, needs-action and banners.
/// Values are GitHub's GraphQL enum strings (e.g. "APPROVED", "CLEAN", "FAILURE").
struct PRSnapshot: Codable, Hashable {
    var state: String
    var isDraft: Bool
    var reviewDecision: String?
    var checks: String?
    var mergeState: String?
    var mergeable: String?
    var inQueue: Bool
    var queuePosition: Int?
    var autoMerge: Bool

    var isOpen: Bool { state == "OPEN" }

    /// GitHub computes merge state lazily and answers UNKNOWN until it's done,
    /// so keep the last known value instead of flapping.
    func resolvingUnknowns(from previous: PRSnapshot?) -> PRSnapshot {
        guard let previous else { return self }
        var resolved = self
        if mergeState == nil || mergeState == "UNKNOWN" { resolved.mergeState = previous.mergeState }
        if mergeable == nil || mergeable == "UNKNOWN" { resolved.mergeable = previous.mergeable }
        return resolved
    }
}

enum Tone {
    case red, green, purple, orange, grey, neutral
}

/// Sections of the My PRs tab, in display order.
enum PRGroup: Int, CaseIterable, Identifiable {
    case attention, queue, waiting, drafts, closed

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .attention: return "Needs your attention"
        case .queue: return "In merge queue"
        case .waiting: return "Waiting on others"
        case .drafts: return "Drafts"
        case .closed: return "Merged & closed"
        }
    }

    var tone: Tone {
        switch self {
        case .attention: return .red
        case .queue: return .purple
        case .waiting: return .orange
        case .drafts: return .grey
        case .closed: return .green
        }
    }
}

enum Headline: Equatable {
    case merged
    case closed
    case draft
    case inQueue(position: Int?)
    case conflicts
    case checksFailing
    case changesRequested
    case readyToMerge
    case behind
    case checksRunning
    case waitingForReview
    case blocked
    case open

    var text: String {
        switch self {
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .draft: return "Draft"
        case .inQueue(let position): return position.map { "In merge queue #\($0)" } ?? "In merge queue"
        case .conflicts: return "Merge conflicts"
        case .checksFailing: return "Checks failing"
        case .changesRequested: return "Changes requested"
        case .readyToMerge: return "Ready to merge"
        case .behind: return "Behind base branch"
        case .checksRunning: return "Checks running"
        case .waitingForReview: return "Waiting for review"
        case .blocked: return "Blocked"
        case .open: return "Open"
        }
    }

    var tone: Tone {
        switch self {
        case .conflicts, .checksFailing, .changesRequested: return .red
        case .readyToMerge, .merged: return .green
        case .inQueue: return .purple
        case .behind, .blocked: return .orange
        case .closed, .draft, .checksRunning, .waitingForReview, .open: return .grey
        }
    }
}

enum Transition: String, CaseIterable {
    // Declared in priority order: when several happen at once, only the first is shown.
    case merged
    case checksFailed
    case changesRequested
    case leftQueue
    case enteredQueue
    case readyToMerge
    case approved

    var title: String {
        switch self {
        case .merged: return "Merged"
        case .checksFailed: return "Checks failed"
        case .changesRequested: return "Changes requested"
        case .leftQueue: return "Removed from merge queue"
        case .enteredQueue: return "In merge queue"
        case .readyToMerge: return "Ready to merge"
        case .approved: return "Approved"
        }
    }
}

enum PRStatus {
    static func headline(_ s: PRSnapshot) -> Headline {
        if s.state == "MERGED" { return .merged }
        if s.state == "CLOSED" { return .closed }
        if s.isDraft { return .draft }
        if s.inQueue { return .inQueue(position: s.queuePosition) }
        if s.mergeable == "CONFLICTING" || s.mergeState == "DIRTY" { return .conflicts }
        if isFailing(s.checks) { return .checksFailing }
        if s.reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
        if isReady(s) { return .readyToMerge }
        if s.mergeState == "BEHIND" { return .behind }
        if isRunning(s.checks) { return .checksRunning }
        if s.reviewDecision == "REVIEW_REQUIRED" { return .waitingForReview }
        if s.mergeState == "BLOCKED" { return .blocked }
        return .open
    }

    static func needsAction(_ s: PRSnapshot) -> Bool {
        switch headline(s) {
        case .conflicts, .checksFailing, .changesRequested, .behind: return true
        case .readyToMerge: return !s.autoMerge
        default: return false
        }
    }

    /// The three status cells: who reviewed, how CI is doing, and whether it can merge.
    static func reviewCell(_ pr: MyPullRequest) -> StatusCell {
        if pr.snapshot.reviewDecision == "CHANGES_REQUESTED" {
            return StatusCell(label: "Review", value: "Changes requested", tone: .red)
        }
        let pending = pr.pendingReviewers > 0 ? "\(pr.pendingReviewers) pending" : nil
        if !pr.approvers.isEmpty {
            let value = ["\(pr.approvers.count) ✓", pending].compactMap { $0 }.joined(separator: " · ")
            return StatusCell(label: "Review", value: value, tone: .green)
        }
        return StatusCell(label: "Review", value: pending ?? "None", tone: .grey)
    }

    static func checksCell(_ pr: MyPullRequest) -> StatusCell {
        let total = pr.checks.count
        guard total > 0 else { return StatusCell(label: "Checks", value: "None", tone: .grey) }
        let passed = pr.checks.filter { $0.state == .passing }.count
        let value = "\(passed)/\(total)"
        if pr.checks.contains(where: { $0.state == .failing }) { return StatusCell(label: "Checks", value: value, tone: .red) }
        if pr.checks.contains(where: { $0.state == .running }) { return StatusCell(label: "Checks", value: value, tone: .grey) }
        return StatusCell(label: "Checks", value: value, tone: .green)
    }

    static func mergeCell(_ pr: MyPullRequest) -> StatusCell {
        let s = pr.snapshot
        let auto = s.autoMerge ? " · auto" : ""
        func cell(_ value: String, _ tone: Tone) -> StatusCell { StatusCell(label: "Merge", value: value, tone: tone) }

        if s.isDraft { return cell("Draft", .neutral) }
        if s.inQueue { return cell(s.queuePosition.map { "#\($0) in queue" } ?? "Queued", .purple) }
        if s.mergeable == "CONFLICTING" || s.mergeState == "DIRTY" { return cell("Conflicts", .red) }
        switch s.mergeState {
        case "BEHIND": return cell("Behind base\(auto)", .orange)
        case "CLEAN", "HAS_HOOKS", "UNSTABLE": return cell("Mergeable\(auto)", .neutral)
        case "BLOCKED": return cell("Blocked\(auto)", .grey)
        default: return cell("Checking…", .grey)
        }
    }

    static func group(_ s: PRSnapshot) -> PRGroup {
        if !s.isOpen { return .closed }
        if s.isDraft { return .drafts }
        if s.inQueue { return .queue }
        return needsAction(s) ? .attention : .waiting
    }

    /// Drops a trailing Linear key like "#GRO-692" since it's shown separately.
    static func displayTitle(_ pr: MyPullRequest) -> String {
        guard let key = pr.linear?.key else { return pr.title }
        let pattern = #"\s*[#\[(]?"# + NSRegularExpression.escapedPattern(for: key) + #"[\])]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return pr.title }
        let range = NSRange(pr.title.startIndex..., in: pr.title)
        let trimmed = regex.stringByReplacingMatches(in: pr.title, range: range, withTemplate: "")
        return trimmed.isEmpty ? pr.title : trimmed
    }

    /// GitHub accepts a queue entry once required checks and reviews pass;
    /// UNSTABLE only means optional checks are failing.
    static func canEnqueue(_ pr: MyPullRequest) -> Bool {
        let s = pr.snapshot
        guard pr.hasMergeQueue, s.isOpen, !s.isDraft, !s.inQueue else { return false }
        return ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(s.mergeState ?? "")
    }

    static func canDequeue(_ pr: MyPullRequest) -> Bool {
        pr.snapshot.isOpen && pr.snapshot.inQueue
    }

    static func isReady(_ s: PRSnapshot) -> Bool {
        guard s.isOpen, !s.isDraft, !s.inQueue else { return false }
        if s.mergeState == "CLEAN" || s.mergeState == "HAS_HOOKS" { return true }
        // Only guess from review + checks while GitHub hasn't computed a merge state yet.
        guard s.mergeState == nil || s.mergeState == "UNKNOWN" else { return false }
        return s.reviewDecision == "APPROVED" && s.checks == "SUCCESS" && s.mergeable == "MERGEABLE"
    }

    /// The single banner-worthy change between two polls, if any.
    static func transition(old: PRSnapshot, new: PRSnapshot) -> Transition? {
        Transition.allCases.first { happened($0, old: old, new: new) }
    }

    private static func happened(_ t: Transition, old: PRSnapshot, new: PRSnapshot) -> Bool {
        if t == .merged { return new.state == "MERGED" && old.state != "MERGED" }
        guard new.isOpen, !new.isDraft else { return false }

        switch t {
        case .merged: return false
        case .checksFailed: return isFailing(new.checks) && !isFailing(old.checks)
        case .changesRequested: return new.reviewDecision == "CHANGES_REQUESTED" && old.reviewDecision != "CHANGES_REQUESTED"
        case .leftQueue: return old.inQueue && !new.inQueue
        case .enteredQueue: return new.inQueue && !old.inQueue
        case .readyToMerge: return isReady(new) && !isReady(old)
        case .approved: return new.reviewDecision == "APPROVED" && old.reviewDecision != "APPROVED"
        }
    }

    private static func isFailing(_ checks: String?) -> Bool { checks == "FAILURE" || checks == "ERROR" }
    private static func isRunning(_ checks: String?) -> Bool { checks == "PENDING" || checks == "EXPECTED" }
}

struct StatusCell: Equatable {
    let label: String
    let value: String
    let tone: Tone
}

struct CheckItem: Hashable {
    enum State: Int, Hashable {
        // Ordered so the worst state wins when two runs share a name.
        case passing, running, failing

        static func from(checkRunStatus status: String?, conclusion: String?) -> State {
            if let status, status != "COMPLETED" { return .running }
            switch conclusion {
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failing
            default: return .passing
            }
        }

        static func from(statusState state: String?) -> State {
            switch state {
            case "FAILURE", "ERROR": return .failing
            case "PENDING", "EXPECTED": return .running
            default: return .passing
            }
        }
    }

    let name: String
    let state: State
    let url: URL?

    /// One entry per check name, keeping the worst state, sorted by name.
    static func deduplicated(_ items: [CheckItem]) -> [CheckItem] {
        var byName: [String: CheckItem] = [:]
        for item in items where (byName[item.name]?.state.rawValue ?? -1) < item.state.rawValue {
            byName[item.name] = item
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct LinearIssue: Hashable {
    let key: String
    let url: URL?

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https://linear\.app/[\w-]+/issue/([A-Za-z][A-Za-z0-9]*-\d+)[^\s)\]>"']*"#
    )
    private static let keyPattern = try! NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]{1,9}-\d+)\b"#)

    /// Prefers a linear.app issue link in the PR body; falls back to a key like GRO-123 in the title.
    static func find(body: String, title: String) -> LinearIssue? {
        let bodyRange = NSRange(body.startIndex..., in: body)
        if let match = urlPattern.firstMatch(in: body, range: bodyRange),
           let whole = Range(match.range, in: body),
           let key = Range(match.range(at: 1), in: body) {
            return LinearIssue(key: body[key].uppercased(), url: URL(string: String(body[whole])))
        }
        let titleRange = NSRange(title.startIndex..., in: title)
        if let match = keyPattern.firstMatch(in: title, range: titleRange),
           let key = Range(match.range(at: 1), in: title) {
            return LinearIssue(key: String(title[key]), url: nil)
        }
        return nil
    }
}
