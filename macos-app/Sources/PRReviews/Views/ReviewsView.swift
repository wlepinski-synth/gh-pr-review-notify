import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let direct: Int
    let team: Int
    let mine: Int
    let hasError: Bool

    // The menu bar drops images inside Text and ignores spacing,
    // so the whole label is drawn into a single image.
    var body: some View {
        Image(nsImage: renderedLabel)
    }

    private var renderedLabel: NSImage {
        let content = HStack(spacing: 4) {
            icon
                .frame(width: 16, height: 16)
                .padding(.trailing, 4)
            Image(systemName: "person.fill")
            Text("\(direct)")
                .padding(.trailing, 6)
            Image(systemName: "person.2.fill")
            Text("\(team)")
                .padding(.trailing, 6)
            Image(systemName: "arrow.triangle.branch")
            Text("\(mine)")
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        // Template images get tinted by macOS to match light/dark menu bars.
        image.isTemplate = true
        return image
    }

    @ViewBuilder
    private var icon: some View {
        if hasError {
            Image(systemName: "exclamationmark.triangle")
        } else if let mark = Self.githubMark {
            Image(nsImage: mark).resizable().scaledToFit()
        } else {
            Image(systemName: "arrow.triangle.pull")
        }
    }

    private static let githubMark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "mark-github", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()
}

struct ReviewsView: View {
    let store: ReviewStore
    let myStore: MyPRsStore
    @AppStorage("selectedTab") private var tab: ReviewTab = .direct
    @Environment(\.openSettings) private var openSettings

    private var errorMessage: String? { tab == .mine ? myStore.errorMessage : store.errorMessage }
    private var lastRefreshed: Date? { tab == .mine ? myStore.lastRefreshed : store.lastRefreshed }
    private var isRefreshing: Bool { tab == .mine ? myStore.isRefreshing : store.isRefreshing }

    var body: some View {
        VStack(spacing: 0) {
            PillTabBar(selection: $tab, counts: [
                .direct: store.direct.count,
                .team: store.team.count,
                .mine: myStore.openCount,
            ])
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            list
                // A fixed height keeps the popover from resizing (or staying tiny) when tabs switch.
                .frame(height: 480)

            Divider()
            footer
        }
        .frame(width: 460)
    }

    @ViewBuilder
    private var list: some View {
        switch tab {
        case .direct, .team:
            let prs = tab == .direct ? store.direct : store.team
            if prs.isEmpty {
                EmptyMessage(text: tab == .direct ? "No PRs request you directly." : "No team review requests.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(prs) { pr in
                            ReviewCard(pr: pr, teams: tab == .team ? store.teamBadges(for: pr) : [])
                        }
                    }
                    .padding(14)
                }
            }
        case .mine:
            if myStore.prs.isEmpty {
                EmptyMessage(text: "You have no open PRs.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(PRGroup.allCases) { group in
                            let prs = myStore.prs.filter { PRStatus.group($0.snapshot) == group }
                            if !prs.isEmpty {
                                SectionHeader(title: group.title, count: prs.count, tone: group.tone)
                                    .padding(.top, group == firstGroup ? 0 : 10)
                                ForEach(prs) { pr in
                                    MyPRCard(pr: pr, store: myStore)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var firstGroup: PRGroup? {
        PRGroup.allCases.first { group in myStore.prs.contains { PRStatus.group($0.snapshot) == group } }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let lastRefreshed {
                Text("Updated \(Text(lastRefreshed, style: .relative)) ago")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(help: "Refresh") {
                Task {
                    if tab == .mine { await myStore.refresh() } else { await store.refresh() }
                }
            } label: {
                SpinningIcon(systemName: "arrow.clockwise", isSpinning: isRefreshing)
            }
            .disabled(isRefreshing)

            IconButton(help: "Open on GitHub") {
                NSWorkspace.shared.open(tab.queueURL)
            } label: {
                Image(systemName: "safari")
            }

            IconButton(help: "Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }

            IconButton(help: "Quit") {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }
}

private struct EmptyMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReviewCard: View {
    let pr: PullRequest
    let teams: [String]

    var body: some View {
        Card(url: pr.url) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pr.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(verbatim: meta)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if pr.isDraft || !teams.isEmpty {
                HStack(spacing: 6) {
                    if pr.isDraft { Badge(text: "draft") }
                    ForEach(teams, id: \.self) { Badge(text: $0) }
                }
            }
        }
    }

    private var meta: String {
        var parts = ["\(pr.shortRepo) #\(pr.url.lastPathComponent)"]
        if !pr.author.isEmpty { parts.append("@\(pr.author)") }
        parts.append(Age.short(since: pr.createdAt))
        return parts.joined(separator: " · ")
    }
}
