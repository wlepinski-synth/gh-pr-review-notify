import AppKit
import SwiftUI

// SwiftUI's @State is a macro, and Command Line Tools ship without its plugin.
final class HoverState: ObservableObject {
    @Published var isHovering = false
}

/// Text colour that reads on a `Color.primary` fill, in both light and dark mode.
let invertedText = Color(nsColor: .windowBackgroundColor)

/// Rounded card that highlights on hover and opens `url` when clicked.
struct Card<Content: View>: View {
    var url: URL?
    @ViewBuilder let content: () -> Content
    @StateObject private var hover = HoverState()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.primary.opacity(hover.isHovering ? 0.075 : 0.05)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(shape)
            .onHover { hover.isHovering = $0 }
            .onTapGesture {
                if let url { NSWorkspace.shared.open(url) }
            }
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int
    let tone: Tone

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tone.color)
                .frame(width: 7, height: 7)
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 4)
    }
}

struct PillTabBar: View {
    @Binding var selection: ReviewTab
    let counts: [ReviewTab: Int]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ReviewTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.15)) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.rawValue)
                        Text("\(counts[tab] ?? 0)")
                            .monospacedDigit()
                            .opacity(0.55)
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isSelected ? invertedText : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(isSelected ? Color.primary.opacity(0.9) : .clear))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.15)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(invertedText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(configuration.isPressed ? 0.7 : 0.9)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.03)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.18)))
            .contentShape(shape)
    }
}

/// Icon-only button with a soft rounded highlight on hover.
struct IconButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @StateObject private var hover = HoverState()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            label()
                .frame(width: 28, height: 28)
                .foregroundStyle(hover.isHovering && isEnabled ? Color.primary : Color.secondary)
                .background(shape.fill(Color.primary.opacity(hover.isHovering && isEnabled ? 0.08 : 0)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.isHovering)
        .help(help)
    }
}

/// SF Symbol that spins continuously while `isSpinning` is true.
struct SpinningIcon: View {
    let systemName: String
    let isSpinning: Bool

    var body: some View {
        TimelineView(.animation(paused: !isSpinning)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Image(systemName: systemName)
                .rotationEffect(.degrees(isSpinning ? turn * 360 : 0))
        }
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
    }
}

extension Tone {
    var color: Color {
        switch self {
        case .red: return .red
        case .green: return .green
        case .purple: return .purple
        case .orange: return .orange
        case .grey: return .secondary
        case .neutral: return .primary
        }
    }
}
