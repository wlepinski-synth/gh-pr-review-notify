import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let store: ReviewStore

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
            Text("\(store.direct.count)")
                .padding(.trailing, 6)
            Image(systemName: "person.2.fill")
            Text("\(store.team.count)")
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
        if store.errorMessage != nil {
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
    @AppStorage("selectedTab") private var tab: ReviewTab = .direct
    @Environment(\.openSettings) private var openSettings

    private var prs: [PullRequest] { tab == .direct ? store.direct : store.team }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $tab, counts: [.direct: store.direct.count, .team: store.team.count])

            Divider()

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }

            Group {
                if prs.isEmpty {
                    Text(tab == .direct ? "No PRs request you directly." : "No team review requests.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(prs) { pr in
                                PRRow(pr: pr, teams: tab == .team ? store.teamBadges(for: pr) : [])
                                Divider()
                            }
                        }
                    }
                }
            }
            // A fixed height keeps the popover from resizing (or staying tiny) when tabs switch.
            .frame(height: 380)

            Divider()
            footer
        }
        .frame(width: 420)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let date = store.lastRefreshed {
                Text("Updated \(Text(date, style: .relative)) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .help("Refresh")

            Button {
                NSWorkspace.shared.open(tab.queueURL)
            } label: {
                Image(systemName: "safari")
            }
            .help("Open on GitHub")

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit")
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}

private struct TabBar: View {
    @Binding var selection: ReviewTab
    let counts: [ReviewTab: Int]
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 20) {
            ForEach(ReviewTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Text(tab.rawValue)
                                .fontWeight(isSelected ? .semibold : .regular)
                            CountPill(count: counts[tab] ?? 0, highlighted: isSelected)
                        }
                        .foregroundStyle(isSelected ? .primary : .secondary)

                        ZStack {
                            Color.clear.frame(height: 2)
                            if isSelected {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }
}

private struct CountPill: View {
    let count: Int
    let highlighted: Bool

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(highlighted ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08)))
    }
}

private struct PRRow: View {
    let pr: PullRequest
    let teams: [String]
    @StateObject private var hover = HoverState()

    var body: some View {
        Button {
            NSWorkspace.shared.open(pr.url)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(pr.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if pr.isDraft { Badge(text: "draft") }
                    ForEach(teams, id: \.self) { Badge(text: $0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hover.isHovering ? Color.primary.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
    }

    private var meta: String {
        var parts = [pr.shortRepo]
        if !pr.author.isEmpty { parts.append("@\(pr.author)") }
        parts.append(Age.short(since: pr.createdAt))
        return parts.joined(separator: " · ")
    }
}

// SwiftUI's @State is a macro, and Command Line Tools ship without its plugin.
private final class HoverState: ObservableObject {
    @Published var isHovering = false
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
    }
}
