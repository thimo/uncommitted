import SwiftUI
import AppKit
import UncommittedCore

struct MenuContentView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissPopover) private var dismissPopover

    private var visibleRepos: [Repo] {
        guard configStore.config.hideCleanRepos else { return store.repos }
        return store.repos.filter { !($0.status?.isClean ?? false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            repoList(for: visibleRepos)
            Divider()
            footer
        }
        .frame(width: 360)
    }

    @ViewBuilder
    private func repoList(for visible: [Repo]) -> some View {
        if store.repos.isEmpty {
            emptyNoSources
        } else if visible.isEmpty {
            emptyAllClean
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, repo in
                        RepoRow(
                            repo: repo,
                            actions: configStore.config.actions,
                            defaultAction: configStore.config.actions.first,
                            onDefault: {
                                guard let first = configStore.config.actions.first else { return }
                                ActionRunner.run(repoURL: repo.url, action: first)
                                // The other app becoming active should auto-close a
                                // transient popover, but the timing isn't reliable —
                                // sometimes the popover stays open. Explicit dismiss.
                                dismissPopover()
                            },
                            onAlternate: { action in
                                ActionRunner.run(repoURL: repo.url, action: action)
                                dismissPopover()
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if index < visible.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
            .frame(maxHeight: 440)
        }
    }

    private var header: some View {
        HStack {
            Text("Uncommitted")
                .font(.headline)
                .padding(.horizontal, 6) // match GhostButtonStyle internal padding
            Spacer()
            Button {
                store.rebuildFromConfig()
            } label: {
                RefreshIcon(isWorking: store.runningRefreshes > 0)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(GhostButtonStyle())
            .pointingHandCursor()
            .help("Rescan sources and refresh all")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var emptyNoSources: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No repositories configured")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open Settings to add a folder.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var emptyAllClean: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("You're fully committed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                // LSUIElement apps don't auto-activate when a SwiftUI window
                // opens, so without this the Settings window comes up with
                // an inactive titlebar. dismissPopover() is hosted by our
                // AppDelegate via the DismissPopoverKey environment.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                dismissPopover()
            }
            .buttonStyle(GhostButtonStyle())
            .foregroundStyle(.secondary)
            .font(.callout)
            .keyboardShortcut(",")
            .pointingHandCursor()

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(GhostButtonStyle())
            .foregroundStyle(.secondary)
            .font(.callout)
            .keyboardShortcut("q")
            .pointingHandCursor()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}

// MARK: - Refresh icon

/// The header refresh icon. When something is in flight (status refresh
/// in progress), the icon rotates continuously so the user sees the app
/// is actually doing work. Driven off wall-clock time via TimelineView
/// so there's no "animate from 0 to 360 and snap back" rocking — the
/// angle is a pure function of `now`, always monotonic.
struct RefreshIcon: View {
    let isWorking: Bool

    var body: some View {
        if isWorking {
            TimelineView(.animation) { context in
                let seconds = context.date.timeIntervalSinceReferenceDate
                let angle = (seconds * 360).truncatingRemainder(dividingBy: 360)
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(angle))
            }
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }
}

// MARK: - Hover cursor helper

extension View {
    /// Changes the cursor to a pointing hand while hovering this view so
    /// clickable controls read as clickable (macOS doesn't do this by
    /// default the way web browsers do).
    func pointingHandCursor() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Ghost button style

/// A compact button style with a rounded-rect hover fill and a pressed
/// state — used for the popover's chrome (Settings, Quit, Refresh).
/// Adds 6pt horizontal / 3pt vertical internal padding so the fill has
/// room to breathe around the label.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct GhostButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if isPressed { return Color.primary.opacity(0.15) }
        if isHovered { return Color.primary.opacity(0.1) }
        return .clear
    }
}

struct RepoRow: View {
    let repo: Repo
    let actions: [Action]
    let defaultAction: Action?
    let onDefault: () -> Void
    let onAlternate: (Action) -> Void

    @EnvironmentObject var store: RepoStore
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Left: the default action's app icon, so the row visually
            // telegraphs "click opens this in <X>".
            defaultActionIcon
                .frame(width: 18, height: 18)

            // Name + branch. Clickable area for the default action.
            Button(action: onDefault) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(repo.status?.displayBranch ?? "Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            // Right: status badges. Push and pull badges are independently
            // clickable; the rest are read-only counts.
            if let status = repo.status {
                StatusBadges(
                    status: status,
                    inFlight: store.inFlight[repo.id],
                    onPush: { store.push(repo: repo) },
                    onPull: { store.pull(repo: repo) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            ForEach(actions) { action in
                Button {
                    onAlternate(action)
                } label: {
                    Label {
                        Text(action.name)
                    } icon: {
                        if let nsImage = AppIcons.icon(for: action) {
                            Image(nsImage: nsImage)
                        } else {
                            Image(systemName: "terminal")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var defaultActionIcon: some View {
        if let action = defaultAction, let nsImage = AppIcons.icon(for: action) {
            Image(nsImage: nsImage)
                .resizable()
        } else {
            // Custom shell command or unresolvable app — fall back to a
            // neutral symbol so the column is never empty.
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusBadges: View {
    let status: RepoStatus
    let inFlight: InFlightAction?
    let onPush: () -> Void
    let onPull: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if status.isClean {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                // Commit-level state first (ahead / behind), then file-level
                // as a progression (untracked → unstaged → staged). Unicode
                // arrows for direction, git porcelain letters for file state.
                // The ahead/behind badges are interactive — click to push/pull.
                if status.ahead > 0 {
                    ActionBadge(
                        glyph: "↑",
                        count: status.ahead,
                        color: .blue,
                        isInFlight: inFlight == .push,
                        action: onPush,
                        help: "Push \(status.ahead) commit\(status.ahead == 1 ? "" : "s")"
                    )
                }
                if status.behind > 0 {
                    ActionBadge(
                        glyph: "↓",
                        count: status.behind,
                        color: .purple,
                        isInFlight: inFlight == .pull,
                        action: onPull,
                        help: "Pull \(status.behind) commit\(status.behind == 1 ? "" : "s"). Aborts if your branch has diverged."
                    )
                }
                if status.untracked > 0 {
                    ReadOnlyBadge(glyph: "★", count: status.untracked, color: .green)
                }
                if status.unstaged > 0 {
                    ReadOnlyBadge(glyph: "●", count: status.unstaged, color: .orange)
                }
                if status.staged > 0 {
                    ReadOnlyBadge(glyph: "+", count: status.staged, color: .teal)
                }
            }
        }
    }
}

/// Read-only status indicator — untracked / modified / staged. No hover state.
private struct ReadOnlyBadge: View {
    let glyph: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Text(glyph)
            Text("\(count)")
        }
        .font(.body.weight(.medium).monospacedDigit())
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }
}

/// Interactive push/pull badge. Shows a hover-fill and a pointing-hand
/// cursor so it's obviously clickable, and swaps to a spinner while the
/// command is running.
private struct ActionBadge: View {
    let glyph: String
    let count: Int
    let color: Color
    let isInFlight: Bool
    let action: () -> Void
    let help: String

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 14)
                } else {
                    HStack(spacing: 2) {
                        Text(glyph)
                        Text("\(count)")
                    }
                }
            }
            .font(.body.weight(.medium).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? color.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(color.opacity(isHovered ? 0.0 : 0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(isInFlight)
        .pointingHandCursor()
        .help(help)
        .onHover { isHovered = $0 }
    }
}
