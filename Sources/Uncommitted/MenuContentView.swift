import SwiftUI
import AppKit

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
                            onDefault: {
                                guard let first = configStore.config.actions.first else { return }
                                ActionRunner.run(repoURL: repo.url, action: first)
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
            Spacer()
            Button {
                store.rebuildFromConfig()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Rescan sources and refresh all")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
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
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
            .keyboardShortcut(",")

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct RepoRow: View {
    let repo: Repo
    let actions: [Action]
    let onDefault: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onDefault) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(repo.status?.displayBranch ?? "Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let status = repo.status {
                    StatusBadges(status: status)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            ForEach(actions) { action in
                Button(action.name) {
                    ActionRunner.run(repoURL: repo.url, action: action)
                }
            }
        }
    }
}

struct StatusBadges: View {
    let status: RepoStatus

    var body: some View {
        HStack(spacing: 10) {
            if status.isClean {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                // Commit-level state first (ahead / behind), then file-level
                // as a progression (untracked → unstaged → staged). All text,
                // using Unicode arrows for direction and git's porcelain
                // single-letter codes for file state — universal convention.
                if status.ahead > 0 {
                    badge("↑", count: status.ahead, color: .blue)
                }
                if status.behind > 0 {
                    badge("↓", count: status.behind, color: .purple)
                }
                if status.untracked > 0 {
                    badge("★", count: status.untracked, color: .green)
                }
                if status.unstaged > 0 {
                    badge("M", count: status.unstaged, color: .orange)
                }
                if status.staged > 0 {
                    badge("A", count: status.staged, color: .teal)
                }
            }
        }
    }

    private func badge(_ glyph: String, count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(glyph)
            Text("\(count)")
        }
        .font(.body.weight(.medium).monospacedDigit())
        .foregroundStyle(color)
    }
}
