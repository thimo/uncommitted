import Foundation
import Combine

final class RepoStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []

    private let configStore: ConfigStore
    private var cancellables = Set<AnyCancellable>()
    private var watcher: RepoWatcher?
    private let statusQueue = DispatchQueue(label: "nl.thimo.uncommitted.git-status", qos: .utility)

    var totalUncommitted: Int {
        repos.reduce(0) { $0 + ($1.status?.totalUncommitted ?? 0) }
    }

    var totalUnpushed: Int {
        repos.reduce(0) { $0 + ($1.status?.totalUnpushed ?? 0) }
    }

    var totalUnpulled: Int {
        repos.reduce(0) { $0 + ($1.status?.behind ?? 0) }
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

    /// Re-resolve sources from config and refresh every repo. Unlike
    /// `refreshAll`, this also picks up new repos that appeared under a
    /// watched source folder since the last scan.
    func rebuildFromConfig() {
        rebuild(from: configStore.config.sources)
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
                // Preserve the previous status on failure — a nil result from
                // GitService means we couldn't trust the output (git errored,
                // or the parse didn't see a branch.oid). Overwriting the last
                // good status with nothing would make repos "flicker to clean".
                guard let status else { return }
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

    /// Resolve user-configured sources to concrete repo URLs, honouring each
    /// source's scanDepth. Stops descending into a directory as soon as a `.git`
    /// is found so we don't treat submodules or nested checkouts as separate repos.
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
            scan(url: url, remainingDepth: max(0, source.scanDepth), into: &urls, fm: fm)
        }

        return Array(urls).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private static func scan(url: URL, remainingDepth: Int, into urls: inout Set<URL>, fm: FileManager) {
        if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
            urls.insert(url)
            return
        }
        guard remainingDepth > 0 else { return }

        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                scan(url: child, remainingDepth: remainingDepth - 1, into: &urls, fm: fm)
            }
        }
    }
}
