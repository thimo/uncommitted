import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.openSettings) private var openSettings

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
        .frame(width: 340)
    }

    @ViewBuilder
    private func repoList(for visible: [Repo]) -> some View {
        if store.repos.isEmpty {
            emptyNoSources
        } else if visible.isEmpty {
            emptyAllClean
        } else {
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

    private var header: some View {
        HStack {
            Text("Uncommitted")
                .font(.headline)
            Spacer()
            Button {
                store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh all")
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
            Text("You're fully committed 🎉")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                // LSUIElement apps don't auto-activate when a SwiftUI window opens,
                // so without this the Settings window comes up with an inactive
                // titlebar and can't be raised again after focusing another app.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
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
        HStack(spacing: 8) {
            if status.isClean {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                if status.ahead > 0 {
                    badge("arrow.up", count: status.ahead, color: .blue)
                }
                if status.behind > 0 {
                    badge("arrow.down", count: status.behind, color: .purple)
                }
                if status.staged > 0 {
                    badge("plus", count: status.staged, color: .green)
                }
                if status.unstaged > 0 {
                    badge("pencil", count: status.unstaged, color: .orange)
                }
                if status.untracked > 0 {
                    badge("questionmark", count: status.untracked, color: .gray)
                }
            }
        }
    }

    private func badge(_ symbol: String, count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            Text("\(count)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(color)
    }
}
