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
    public let fetchStateStore: FetchStateStore
    /// Wired up by AppDelegate after init to cancel in-flight fetches
    /// before push/pull (avoids circular RepoStore ↔ FetchScheduler dep).
    public var onCancelFetch: ((URL) -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var watcher: RepoWatcher?
    private var refreshTimer: Timer?
    /// Per-repo debounce for FSEvents-triggered refreshes. Rapid file
    /// changes (build output, scripts writing data) can fire hundreds of
    /// events per second — without debounce each one spawns a `git status`.
    /// The work item is keyed by repo URL; replacing it within the window
    /// coalesces the burst into a single refresh.
    private var pendingRefresh: [URL: DispatchWorkItem] = [:]
    private static let refreshDebounce: TimeInterval = 1.0

    // Belt-and-suspenders backstop against missed updates. FSEvents handles
    // the fast path, but its stream can drift after sleep/wake and other
    // tools (IDE git plugins, cron-ish dependabot, background fetches) can
    // make changes out-of-band. Running a full rebuild on a slow timer
    // catches what FSEvents misses without being felt. Local git only, no
    // network, so the cost is essentially zero.
    private static let periodicRefreshInterval: TimeInterval = 10 * 60
    // Concurrent — `git status` is read-only and safe to run in parallel.
    // Serial here meant a full refresh of N repos took N × ~150ms, which
    // felt noticeably sluggish on the refresh button.
    private let statusQueue = DispatchQueue(
        label: "nl.defrog.uncommitted.git-status",
        qos: .utility,
        attributes: .concurrent
    )
    private let actionQueue = DispatchQueue(label: "nl.defrog.uncommitted.git-action", qos: .userInitiated)

    public var totalUncommitted: Int {
        repos.reduce(0) { $0 + ($1.status?.totalUncommitted ?? 0) }
    }

    public var totalUnpushed: Int {
        repos.reduce(0) { $0 + ($1.status?.totalUnpushed ?? 0) }
    }

    public var totalUnpulled: Int {
        repos.reduce(0) { $0 + ($1.status?.behind ?? 0) }
    }

    public init(configStore: ConfigStore, fetchStateStore: FetchStateStore) {
        self.configStore = configStore
        self.fetchStateStore = fetchStateStore

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

        // Rebuild from scratch when the machine wakes — the FSEvents stream
        // can fall into an unusable state during sleep, and any in-band
        // changes that happened while we were out are not replayed. This
        // posts on NSWorkspace's own notification center, not the default
        // one; easy to miss.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        startPeriodicRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleSystemWake() {
        rebuildFromConfig()
    }

    private func startPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.periodicRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.rebuildFromConfig()
        }
    }

    public func refreshAll() {
        for index in repos.indices {
            refresh(repoAt: index)
        }
    }

    /// Refresh a single repo by URL. Used by the `FetchScheduler` after a
    /// successful background fetch so the unpulled count updates without
    /// waiting for the next periodic refresh tick.
    public func refresh(url: URL) {
        guard let index = repos.firstIndex(where: { $0.url == url }) else { return }
        refresh(repoAt: index)
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
        // Cancel any in-flight background fetch for this repo so the
        // push/pull doesn't collide on index.lock.
        onCancelFetch?(repo.url)
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
                    // Prefer the classified friendly message when we
                    // have one, falling back to raw stderr for cases
                    // we haven't classified yet.
                    let friendly = result.kind?.userMessage
                    let message = friendly ?? result.errorOutput ?? "Unknown error"
                    Self.presentError(
                        title: "\(kind == .push ? "Push" : "Pull") failed — \(repoName)",
                        message: message,
                        detail: friendly != nil ? result.errorOutput : nil
                    )
                }
                if let index = self.repos.firstIndex(where: { $0.id == id }) {
                    self.refresh(repoAt: index)
                }
            }
        }
    }

    private static func presentError(title: String, message: String, detail: String? = nil) {
        // NSAlert.runModal() takes focus on its own — don't yank the whole
        // app forward just to display a warning sheet.
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let detail, !detail.isEmpty {
            // Raw git stderr available via a disclosure so the friendly
            // message can stay short but power users can still read
            // git's own output.
            let accessory = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
            accessory.string = detail
            accessory.isEditable = false
            accessory.isSelectable = true
            accessory.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            accessory.textContainerInset = NSSize(width: 4, height: 4)
            let scroll = NSScrollView(frame: accessory.frame)
            scroll.documentView = accessory
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .lineBorder
            alert.accessoryView = scroll
        }
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

        // Drop fetch state entries for repos that no longer exist so the
        // persisted file doesn't grow without bound.
        fetchStateStore.prune(to: resolvedURLs)

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

    /// Paths inside `.git/` that don't affect `git status` output.
    /// Changes here (gc, reflog, loose object writes) are noise.
    private static let ignoredGitSubdirs = ["/.git/objects/", "/.git/logs/"]

    private func handleFileChange(at url: URL) {
        let changed = url.standardizedFileURL.path

        // Skip .git internals that don't affect status (object packing,
        // reflog writes, etc.). Changes in .git/refs/, .git/HEAD, and
        // .git/index DO matter and are NOT filtered.
        if Self.ignoredGitSubdirs.contains(where: { changed.contains($0) }) {
            return
        }

        // Require a trailing separator after the repo path so a change inside
        // `/repos/foobar/x.txt` doesn't accidentally match a repo at
        // `/repos/foo`. Also allow the exact repo path itself.
        guard let index = repos.firstIndex(where: { repo in
            let repoPath = repo.url.standardizedFileURL.path
            return changed == repoPath || changed.hasPrefix(repoPath + "/")
        }) else { return }

        // Debounce: cancel any pending refresh for this repo and schedule
        // a new one. Rapid FSEvents (build output, scripts) coalesce into
        // a single git-status instead of one per file event.
        let repoURL = repos[index].url
        pendingRefresh[repoURL]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh.removeValue(forKey: repoURL)
            if let i = self.repos.firstIndex(where: { $0.url == repoURL }) {
                self.refresh(repoAt: i)
            }
        }
        pendingRefresh[repoURL] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDebounce, execute: work)
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
            guard let vals = try? child.resourceValues(forKeys: [.isDirectoryKey]),
                  vals.isDirectory == true else { continue }
            scan(url: child.standardizedFileURL, remainingDepth: remainingDepth - 1, into: &urls, fm: fm)
        }
    }
}
