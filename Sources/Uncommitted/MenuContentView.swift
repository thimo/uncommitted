import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.repos.isEmpty {
                emptyState
            } else {
                ForEach(Array(store.repos.enumerated()), id: \.element.id) { index, repo in
                    RepoRow(repo: repo) {
                        ClickActionRunner.open(
                            repoURL: repo.url,
                            action: configStore.config.clickAction,
                            customCommand: configStore.config.customCommand
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if index < store.repos.count - 1 {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 340)
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

    private var emptyState: some View {
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

    private var footer: some View {
        HStack {
            SettingsLink {
                Text("Settings…")
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
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(repo.status?.branch ?? "Loading…")
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
