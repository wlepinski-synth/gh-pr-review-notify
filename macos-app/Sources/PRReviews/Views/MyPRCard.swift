import AppKit
import SwiftUI

struct MyPRCard: View {
    let pr: MyPullRequest
    let store: MyPRsStore
    @StateObject private var action = QueueAction()

    var body: some View {
        Card(url: pr.url) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PRStatus.displayTitle(pr))
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                MetaLine(pr: pr)
            }
            if pr.snapshot.isOpen {
                StatusGrid(pr: pr)
            }
            if let queue = queueAction {
                HStack(spacing: 8) {
                    Button {
                        action.tap(queue.perform)
                    } label: {
                        if action.phase == .working {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(action.phase == .confirming ? "Confirm \(queue.title.lowercased())?" : queue.title)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: action.phase == .confirming ? .purple : .primary))
                    .disabled(action.phase == .working)

                    Button("Open") { NSWorkspace.shared.open(pr.url) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if let error = action.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(pr.snapshot.isOpen ? 1 : 0.65)
    }

    private var queueAction: (title: String, perform: () async throws -> Void)? {
        if PRStatus.canEnqueue(pr) { return ("Add to queue", { try await store.addToQueue(pr) }) }
        if PRStatus.canDequeue(pr) { return ("Remove from queue", { try await store.removeFromQueue(pr) }) }
        return nil
    }
}

private struct MetaLine: View {
    let pr: MyPullRequest

    var body: some View {
        HStack(spacing: 6) {
            // Plain String so SwiftUI doesn't format the PR number as "31,432".
            Text(verbatim: "\(pr.shortRepo) #\(pr.number)")
            if let linear = pr.linear {
                dot
                LinearLink(issue: linear)
            }
            dot
            Text(verbatim: age)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var dot: some View { Text("·") }

    private var age: String {
        guard !pr.snapshot.isOpen, let closedAt = pr.closedAt else { return Age.short(since: pr.createdAt) }
        let verb = pr.snapshot.state == "MERGED" ? "merged" : "closed"
        return "\(verb) \(Age.short(since: closedAt)) ago"
    }
}

private struct LinearLink: View {
    let issue: LinearIssue
    @StateObject private var hover = HoverState()

    var body: some View {
        if let url = issue.url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(issue.key)
                    .underline(hover.isHovering)
                    .foregroundStyle(hover.isHovering ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .onHover { hover.isHovering = $0 }
            .help("Open \(issue.key) in Linear")
        } else {
            Text(issue.key)
        }
    }
}

private struct StatusGrid: View {
    let pr: MyPullRequest
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 0) {
            ReviewGridCell(pr: pr)
            Divider()
            ChecksGridCell(pr: pr)
            Divider()
            GridCell(cell: PRStatus.mergeCell(pr))
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(colorScheme == .dark ? Color.black.opacity(0.22) : Color.primary.opacity(0.04)))
        .clipShape(shape)
    }
}

private struct GridCell: View {
    let cell: StatusCell

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(cell.value)
                .font(.callout)
                .foregroundStyle(cell.tone.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct ChecksGridCell: View {
    let pr: MyPullRequest
    @StateObject private var popover = HoverPopover()

    private var attention: [CheckItem] { pr.checks.filter { $0.state != .passing } }

    var body: some View {
        GridCell(cell: PRStatus.checksCell(pr))
            .onHover { hovering in
                if !attention.isEmpty { popover.hoverAnchor(hovering) }
            }
            .popover(isPresented: $popover.isPresented, arrowEdge: .bottom) {
                ChecksPopover(checks: attention)
                    .onHover { popover.hoverContent($0) }
            }
    }
}

private struct ReviewGridCell: View {
    let pr: MyPullRequest
    @StateObject private var popover = HoverPopover()

    var body: some View {
        GridCell(cell: PRStatus.reviewCell(pr))
            .onHover { hovering in
                if !pr.reviewers.isEmpty { popover.hoverAnchor(hovering) }
            }
            .popover(isPresented: $popover.isPresented, arrowEdge: .bottom) {
                ReviewersPopover(reviewers: pr.reviewers)
                    .onHover { popover.hoverContent($0) }
            }
    }
}

private struct ReviewersPopover: View {
    let reviewers: [Reviewer]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Changes requested", .changesRequested)
            section("Approved", .approved)
            section("Commented", .commented)
            section("Pending", .pending)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ title: String, _ state: Reviewer.State) -> some View {
        let items = reviewers.filter { $0.state == state }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                ForEach(items, id: \.self) { ReviewerLine(reviewer: $0) }
            }
        }
    }
}

private struct ReviewerLine: View {
    let reviewer: Reviewer
    @StateObject private var hover = HoverState()

    var body: some View {
        Button {
            if let url = reviewer.profileURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Avatar(reviewer: reviewer)
                VStack(alignment: .leading, spacing: 0) {
                    Text(reviewer.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: symbol)
                    .foregroundStyle(tone.color)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hover.isHovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(reviewer.profileURL == nil)
        .onHover { hover.isHovering = $0 }
    }

    private var subtitle: String? {
        if reviewer.isTeam { return "team" }
        return reviewer.displayName == reviewer.login ? nil : "@\(reviewer.login)"
    }

    private var symbol: String {
        switch reviewer.state {
        case .approved: return "checkmark.circle.fill"
        case .changesRequested: return "xmark.circle.fill"
        case .commented: return "text.bubble"
        case .pending: return "clock"
        }
    }

    private var tone: Tone {
        switch reviewer.state {
        case .approved: return .green
        case .changesRequested: return .red
        case .commented, .pending: return .grey
        }
    }
}

private struct Avatar: View {
    let reviewer: Reviewer

    var body: some View {
        let shape = reviewer.isTeam ? AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous)) : AnyShape(Circle())
        AsyncImage(url: reviewer.avatarURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.primary.opacity(0.12)
                    Text(reviewer.displayName.prefix(1).uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(shape)
    }
}

private struct ChecksPopover: View {
    let checks: [CheckItem]
    private let limit = 12

    var body: some View {
        let failing = checks.filter { $0.state == .failing }
        let running = checks.filter { $0.state == .running }
        VStack(alignment: .leading, spacing: 10) {
            section("Failing", failing, symbol: "xmark.circle.fill", tone: .red)
            section("Running", running, symbol: "circle.dotted", tone: .grey)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [CheckItem], symbol: String, tone: Tone) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                ForEach(items.prefix(limit), id: \.self) { check in
                    CheckLine(check: check, symbol: symbol, tone: tone)
                }
                if items.count > limit {
                    Text("and \(items.count - limit) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct CheckLine: View {
    let check: CheckItem
    let symbol: String
    let tone: Tone
    @StateObject private var hover = HoverState()

    var body: some View {
        Button {
            if let url = check.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tone.color)
                Text(check.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if check.url != nil {
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 4).fill(hover.isHovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(check.url == nil)
        .onHover { hover.isHovering = $0 }
    }
}

/// Two-step button state: the first click asks for confirmation, the second runs the action.
final class QueueAction: ObservableObject {
    enum Phase { case idle, confirming, working }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var error: String?
    private var resetWork: DispatchWorkItem?

    @MainActor
    func tap(_ perform: @escaping () async throws -> Void) {
        switch phase {
        case .idle:
            phase = .confirming
            error = nil
            let work = DispatchWorkItem { [weak self] in
                if self?.phase == .confirming { self?.phase = .idle }
            }
            resetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        case .confirming:
            resetWork?.cancel()
            phase = .working
            Task { @MainActor in
                do {
                    try await perform()
                } catch {
                    self.error = (error as? GHError)?.userMessage ?? error.localizedDescription
                }
                self.phase = .idle
            }
        case .working:
            break
        }
    }
}

/// Keeps a hover popover open while the pointer is over the anchor or the popover itself.
final class HoverPopover: ObservableObject {
    @Published var isPresented = false
    private var overAnchor = false
    private var overContent = false
    private var pending: DispatchWorkItem?

    func hoverAnchor(_ hovering: Bool) {
        overAnchor = hovering
        update()
    }

    func hoverContent(_ hovering: Bool) {
        overContent = hovering
        update()
    }

    private func update() {
        pending?.cancel()
        let show = overAnchor || overContent
        guard show != isPresented else { return }
        // Short delays so passing over the cell or moving into the popover doesn't flicker.
        let work = DispatchWorkItem { [weak self] in self?.isPresented = show }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (show ? 0.25 : 0.3), execute: work)
    }
}
