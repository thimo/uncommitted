import Foundation
import Combine

final class RepoStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []

    private var watcher: RepoWatcher?
    private let statusQueue = DispatchQueue(label: "nl.thimo.uncommitted.git-status", qos: .utility)

    var totalDirty: Int {
        repos.reduce(0) { $0 + ($1.status?.totalDirty ?? 0) }
    }

    init() {
        // v0.1: hardcoded repo list. Settings UI lands in v0.2.
        let hardcodedPaths = [
            "~/vonk",
            "~/src/clawbridge",
            "~/src/uncommitted",
        ]

        self.repos = hardcodedPaths.map { path in
            Repo(
                id: UUID(),
                url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                status: nil
            )
        }

        watcher = RepoWatcher { [weak self] changedURL in
            self?.handleFileChange(at: changedURL)
        }

        refreshAll()
        watcher?.watch(repos.map(\.url))
    }

    func refreshAll() {
        for index in repos.indices {
            refresh(repoAt: index)
        }
    }

    private func refresh(repoAt index: Int) {
        let url = repos[index].url
        statusQueue.async { [weak self] in
            let status = GitService.status(at: url)
            DispatchQueue.main.async {
                guard let self else { return }
                if let i = self.repos.firstIndex(where: { $0.url == url }) {
                    self.repos[i].status = status
                }
            }
        }
    }

    private func handleFileChange(at url: URL) {
        let changed = url.standardizedFileURL.path
        // Match the repo whose path is a prefix of the event path.
        guard let index = repos.firstIndex(where: {
            changed.hasPrefix($0.url.standardizedFileURL.path)
        }) else { return }
        refresh(repoAt: index)
    }
}
