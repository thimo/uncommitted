import Foundation
import Combine

final class RepoStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []

    private let configStore: ConfigStore
    private var cancellables = Set<AnyCancellable>()
    private var watcher: RepoWatcher?
    private let statusQueue = DispatchQueue(label: "nl.thimo.uncommitted.git-status", qos: .utility)

    var totalDirty: Int {
        repos.reduce(0) { $0 + ($1.status?.totalDirty ?? 0) }
    }

    init(configStore: ConfigStore) {
        self.configStore = configStore

        self.watcher = RepoWatcher { [weak self] changedURL in
            self?.handleFileChange(at: changedURL)
        }

        configStore.$config
            .map(\.sources)
            .removeDuplicates()
            .sink { [weak self] sources in
                self?.rebuild(from: sources)
            }
            .store(in: &cancellables)
    }

    func refreshAll() {
        for index in repos.indices {
            refresh(repoAt: index)
        }
    }

    private func rebuild(from sources: [Source]) {
        let resolvedURLs = Self.resolve(sources: sources)

        let existing = Dictionary(uniqueKeysWithValues: repos.map { ($0.url, $0) })
        self.repos = resolvedURLs.map { url in
            existing[url] ?? Repo(id: UUID(), url: url, status: nil)
        }

        watcher?.watch(resolvedURLs)
        refreshAll()
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
        guard let index = repos.firstIndex(where: {
            changed.hasPrefix($0.url.standardizedFileURL.path)
        }) else { return }
        refresh(repoAt: index)
    }

    /// Resolve a list of user-configured source paths to concrete repo URLs.
    /// If a path is itself a git repo, it's added directly. Otherwise it's
    /// scanned one level deep for child `.git` directories.
    private static func resolve(sources: [Source]) -> [URL] {
        var urls = Set<URL>()
        let fm = FileManager.default

        for source in sources {
            let expanded = (source.path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                urls.insert(url)
                continue
            }

            if let children = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for child in children {
                    if fm.fileExists(atPath: child.appendingPathComponent(".git").path) {
                        urls.insert(child)
                    }
                }
            }
        }

        return Array(urls).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
