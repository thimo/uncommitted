import SwiftUI
import AppKit
import UncommittedCore

struct MenuContentView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissPopover) private var dismissPopover
    @Environment(\.hoverDetail) private var hoverDetail

    private var visibleRepos: [Repo] {
        guard configStore.config.hideCleanRepos else { return store.repos }
        return store.repos.filter { !($0.status?.isClean ?? false) }
    }

    /// Cap the repo list at ~55% of the current screen's visible height
    /// so the popover grows with the display instead of sitting at a
    /// hardcoded 440pt. Falls back to 440 if we can't read the screen.
    private var maxListHeight: CGFloat {
        guard let screenHeight = NSScreen.main?.visibleFrame.height else {
            return 440
        }
        return max(300, screenHeight * 0.55)
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
        .onDisappear {
            // Popup closed — drop any lingering hover detail panel.
            hoverDetail?.dismissImmediately()
        }
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
                            },
                            onHoverChange: { hovering, rowFrameOnScreen in
                                if hovering, let frame = rowFrameOnScreen {
                                    hoverDetail?.showDetail(
                                        for: repo,
                                        rowFrameOnScreen: frame,
                                        actions: configStore.config.actions,
                                        onAction: { action in
                                            ActionRunner.run(repoURL: repo.url, action: action)
                                            dismissPopover()
                                        }
                                    )
                                } else {
                                    hoverDetail?.scheduleDismiss(for: repo.id)
                                }
                            }
                        )
                        if index < visible.count - 1 {
                            Divider().padding(.horizontal, 10)
                        }
                    }
                }
            }
            .frame(maxHeight: maxListHeight)
        }
    }

    private var header: some View {
        HStack {
            Text("Uncommitted")
                .font(.headline)
                .padding(.horizontal, 6)
            Spacer()
            Button {
                store.rebuildFromConfig()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.primary.opacity(0.70))
            }
            .buttonStyle(GhostButtonStyle())
            .pointingHandCursor()
            .help("Rescan sources and refresh all")
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var emptyNoSources: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.primary.opacity(0.70))
            Text("No repositories configured")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.70))
            Text("Open Settings to add a folder.")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.50))
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
                .foregroundStyle(.primary.opacity(0.70))
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
            .foregroundStyle(.primary.opacity(0.70))
            .font(.callout)
            .keyboardShortcut(",")
            .pointingHandCursor()

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(GhostButtonStyle())
            .foregroundStyle(.primary.opacity(0.70))
            .font(.callout)
            .keyboardShortcut("q")
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 14)
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

/// Shared corner radius for interactive elements (ghost buttons, action
/// badges, row hover highlights). Kept in one place so adjusting the
/// overall "roundness" is a single-constant change.
let interactiveCornerRadius: CGFloat = 6

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
                RoundedRectangle(cornerRadius: interactiveCornerRadius)
                    .fill(fill)
                    // Animate ONLY on press state changes so the click
                    // fades in/out instead of snapping. Scoping to
                    // `value: isPressed` keeps the animation from
                    // bleeding into other properties.
                    .animation(.easeOut(duration: 0.35), value: isPressed)
            )
            .contentShape(RoundedRectangle(cornerRadius: interactiveCornerRadius))
            .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if isPressed { return Color.primary.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.08) }
        return .clear
    }
}

struct RepoRow: View {
    let repo: Repo
    let actions: [Action]
    let onDefault: () -> Void
    let onAlternate: (Action) -> Void
    /// Reports hover state changes along with the row's screen-space
    /// frame so the hover detail controller can position its floating
    /// panel next to the correct row. Frame is nil on hover-out.
    let onHoverChange: (Bool, NSRect?) -> Void

    @EnvironmentObject var store: RepoStore
    @State private var isHovered = false
    @StateObject private var frameRef = RowFrameReference()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Name + branch. Clickable area for the default action.
            Button(action: onDefault) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(repo.status?.displayBranch ?? "Loading…")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.70))
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
            RoundedRectangle(cornerRadius: interactiveCornerRadius)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
        )
        // Outer padding: the "gap" between rows at the popup edge still
        // counts as part of the row for hover purposes. Without
        // contentShape the outer padding is empty space and the hover
        // flickers off when the cursor drifts into it.
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(RowFrameReader(reference: frameRef))
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering, hovering ? frameRef.currentFrameOnScreen : nil)
        }
        .contextMenu {
            Section("Open with") {
                ForEach(actions) { action in
                    Button {
                        onAlternate(action)
                    } label: {
                        Label {
                            Text(action.name)
                        } icon: {
                            if let nsImage = AppIcons.icon(for: action) {
                                Image(nsImage: resized(nsImage, to: 16))
                            } else {
                                Image(systemName: "terminal")
                            }
                        }
                    }
                }
            }
        }
    }

    private func resized(_ image: NSImage, to size: CGFloat) -> NSImage {
        let target = NSSize(width: size, height: size)
        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }
}

/// Rich hover detail for a repo row. Shows every pending state as its own
/// section with a colored glyph, count, and the paths or commit subjects
/// backing it. Matches the glyph/color scheme of the inline badges so the
/// popover reads as "the badges, expanded".
struct RepoDetailPopover: View {
    let repoName: String
    let status: RepoStatus
    var actions: [Action] = []
    var onAction: (Action) -> Void = { _ in }

    /// Max paths/commits to list per section before "+N more".
    private static let itemLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if status.isClean {
                cleanMessage
            } else {
                sections
            }
        }
        .padding(14)
        .frame(minWidth: 260, idealWidth: 320, maxWidth: 420, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(repoName)
                .font(.headline)
            Text(status.displayBranch)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.70))
                .monospaced()
        }
    }

    private var cleanMessage: some View {
        Label("No pending changes", systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
    }

    @ViewBuilder
    private var sections: some View {
        if status.ahead > 0 {
            DetailSection(
                glyph: "↑",
                noun: "commit to push",
                count: status.ahead,
                items: status.aheadCommits,
                color: .blue,
                limit: Self.itemLimit
            )
        }
        if status.behind > 0 {
            DetailSection(
                glyph: "↓",
                noun: "commit to pull",
                count: status.behind,
                items: status.behindCommits,
                color: .purple,
                limit: Self.itemLimit
            )
        }
        if status.untracked > 0 {
            DetailSection(
                glyph: "★",
                noun: "untracked file",
                count: status.untracked,
                items: status.untrackedPaths,
                color: .green,
                limit: Self.itemLimit
            )
        }
        if status.unstaged > 0 {
            DetailSection(
                glyph: "●",
                noun: "modified file",
                count: status.unstaged,
                items: status.unstagedPaths,
                color: .orange,
                limit: Self.itemLimit
            )
        }
        if status.staged > 0 {
            DetailSection(
                glyph: "+",
                noun: "staged file",
                count: status.staged,
                items: status.stagedPaths,
                color: .teal,
                limit: Self.itemLimit
            )
        }
    }
}

private struct DetailSection: View {
    let glyph: String
    let noun: String
    let count: Int
    let items: [String]
    let color: Color
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(glyph)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                Text(headerText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            if items.isEmpty {
                // `git log` follow-up failed (rare) — header alone is fine.
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary.opacity(0.70))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if items.count > limit {
                        Text("+\(items.count - limit) more")
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.50))
                    }
                }
                .padding(.leading, 18) // align under the header text, not the glyph
            }
        }
    }

    private var headerText: String {
        let word = count == 1 ? noun : noun + "s"
        return "\(count) \(word)"
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
                        action: onPush
                    )
                }
                if status.behind > 0 {
                    ActionBadge(
                        glyph: "↓",
                        count: status.behind,
                        color: .purple,
                        isInFlight: inFlight == .pull,
                        action: onPull
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

/// Read-only status indicator — untracked / modified / staged. No hover
/// state, no tooltip — the enclosing row's detail popover surfaces the
/// full breakdown on hover.
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
/// command is running. Details (counts, commit subjects) are surfaced
/// via the enclosing row's hover popover instead of a per-badge tooltip.
private struct ActionBadge: View {
    let glyph: String
    let count: Int
    let color: Color
    let isInFlight: Bool
    let action: () -> Void

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
                RoundedRectangle(cornerRadius: interactiveCornerRadius)
                    .fill(isHovered ? color.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: interactiveCornerRadius)
                    .strokeBorder(color.opacity(isHovered ? 0.0 : 0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: interactiveCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isInFlight)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Actions menu button

/// A "⋯" button that shows the configured actions as a native NSMenu.
/// Replaces SwiftUI's `.contextMenu` which doesn't work inside an
/// NSMenu custom-view item (the menu's tracking loop swallows events).
private struct ActionsMenuButton: View {
    let actions: [Action]
    let onAction: (Action) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            showMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.primary.opacity(isHovered ? 0.70 : 0.40))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for action in actions {
            let item = ActionMenuItem(title: action.name, callback: { onAction(action) })
            if let nsImage = AppIcons.icon(for: action) {
                let size: CGFloat = 16
                let resized = NSImage(size: NSSize(width: size, height: size))
                resized.lockFocus()
                nsImage.draw(in: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
                             from: .zero, operation: .sourceOver, fraction: 1.0)
                resized.unlockFocus()
                item.image = resized
            }
            menu.addItem(item)
        }

        // Show at the mouse location.
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }
}

/// NSMenuItem subclass that holds a closure callback instead of
/// relying on target-action with a stable `self` reference.
private final class ActionMenuItem: NSMenuItem {
    private let callback: () -> Void

    init(title: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { callback() }
}
