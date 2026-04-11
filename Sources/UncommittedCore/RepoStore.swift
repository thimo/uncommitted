import Foundation
import Combine
import AppKit

public enum InFlightAction {
    case push
    case pull
}

public final class RepoStore: ObservableObject {
    @Published public private(set) var repos: [Repo] = []
    @Published public private(set) var inFlight: [UUID: InFlightAction] = [:]

    private let configStore: ConfigStore
    private var cancellables = Set<AnyCancellable>()
    private var watcher: RepoWatcher?
    private let statusQueue = DispatchQueue(label: "nl.thimo.uncommitted.git-status", qos: .utility)
    private let actionQueue = DispatchQueue(label: "nl.thimo.uncommitted.git-action", qos: .userInitiated)

    public var totalUncommitted: Int {
        repos.reduce(0) { $0 + ($1.status?.totalUncommitted ?? 0) }
    }

    public var totalUnpushed: Int {
        repos.reduce(0) { $0 + ($1.status?.totalUnpushed ?? 0) }
    }

    public var totalUnpulled: Int {
        repos.reduce(0) { $0 + ($1.status?.behind ?? 0) }
    }

    public init(configStore: ConfigStore) {
        self.configStore = configStore

        self.watcher = RepoWatcher { [weak self] changedURL in
            self?.handleFileChange(at: changedURL)
        }

        configStore.$config
            .map(\.sources)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sources in
                self?.rebuild(from: sources)
            }
            .store(in: &cancellables)
    }

    public func refreshAll() {
        for index in repos.indices {
            refresh(repoAt: index)
        }
    }

    /// Runs `git push` on the given repo. Marks it in-flight so the UI can
    /// show a spinner, refreshes status on completion, shows an alert on
    /// failure with git's stderr.
    public func push(repo: Repo) {
        runAction(.push, on: repo) { url in
            GitService.push(at: url)
        }
    }

    /// Runs `git pull --ff-only` on the given repo. Uses `--ff-only` so a
    /// diverged branch fails loudly instead of silently rebasing or creating
    /// a merge commit.
    public func pull(repo: Repo) {
        runAction(.pull, on: repo) { url in
            GitService.pull(at: url)
        }
    }

    private func runAction(
        _ kind: InFlightAction,
        on repo: Repo,
        command: @escaping (URL) -> GitService.ActionResult
    ) {
        guard inFlight[repo.id] == nil else { return }
        inFlight[repo.id] = kind
        let url = repo.url
        let id = repo.id
        let repoName = repo.name

        actionQueue.async { [weak self] in
            let result = command(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight[id] = nil
                if !result.success {
                    Self.presentError(
                        title: "\(kind == .push ? "Push" : "Pull") failed — \(repoName)",
                        message: result.errorOutput ?? "Unknown error"
                    )
                }
                if let index = self.repos.firstIndex(where: { $0.id == id }) {
                    self.refresh(repoAt: index)
                }
            }
        }
    }

    private static func presentError(title: String, message: String) {
        // NSAlert.runModal() takes focus on its own — don't yank the whole
        // app forward just to display a warning sheet.
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Re-resolve sources from config and refresh every repo. Unlike
    /// `refreshAll`, this also picks up new repos that appeared under a
    /// watched source folder since the last scan.
    public func rebuildFromConfig() {
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
        // Require a trailing separator after the repo path so a change inside
        // `/repos/foobar/x.txt` doesn't accidentally match a repo at
        // `/repos/foo`. Also allow the exact repo path itself.
        guard let index = repos.firstIndex(where: { repo in
            let repoPath = repo.url.standardizedFileURL.path
            return changed == repoPath || changed.hasPrefix(repoPath + "/")
        }) else { return }
        refresh(repoAt: index)
    }

    /// Resolve user-configured sources to concrete repo URLs, honouring each
    /// source's scanDepth. Stops descending into a directory as soon as a `.git`
    /// is found so we don't treat submodules or nested checkouts as separate repos.
    /// Public so the test runner can exercise it directly.
    public static func resolve(sources: [Source]) -> [URL] {
        // Dedup by standardized path so case-insensitive volumes and symlinked
        // siblings don't produce duplicate rows.
        var urls = [String: URL]()
        let fm = FileManager.default

        for source in sources {
            let expanded = (source.path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            scan(url: url, remainingDepth: max(0, source.scanDepth), into: &urls, fm: fm)
        }

        return Array(urls.values).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private static func scan(url: URL, remainingDepth: Int, into urls: inout [String: URL], fm: FileManager) {
        if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
            let key = url.standardizedFileURL.path.lowercased()
            urls[key] = url.standardizedFileURL
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
                scan(url: child.standardizedFileURL, remainingDepth: remainingDepth - 1, into: &urls, fm: fm)
            }
        }
    }
}
