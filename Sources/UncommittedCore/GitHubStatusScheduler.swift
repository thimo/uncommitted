import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "nl.thimo.uncommitted", category: "github-status-scheduler")

/// Polls GitHub for PR + CI status across tracked repos at a tiered
/// cadence. Multi-clone aware — repos sharing an `owner/repo` slug
/// collapse PR-count fetches to one call; repos on the same branch of
/// the same slug collapse CI fetches too.
///
/// Cadence:
///  - "active" repo (`.git/HEAD` touched within `activeThreshold`): every `activeInterval`
///  - else: every `idleInterval`
///
/// Failures don't back off — GitHub failures are usually transient
/// (rate limit, network blip), so we retry at the normal cadence.
/// Repos without a GitHub remote silently never appear in `statuses`,
/// so the UI naturally renders nothing for them.
public final class GitHubStatusScheduler: ObservableObject {
    /// Per-repo GitHub state. Read by SwiftUI views.
    @Published public private(set) var statuses: [URL: GitHubRepoStatus] = [:]

    public static let activeInterval: TimeInterval = 15 * 60
    public static let idleInterval: TimeInterval = 24 * 60 * 60
    /// While a repo's CI is `.pending`, refresh much more aggressively
    /// so the row flips to red/clean within a minute of the run
    /// concluding instead of waiting for the next 15-min slot.
    public static let pendingInterval: TimeInterval = 60
    public static let activeThreshold: TimeInterval = 24 * 60 * 60
    public static let tickInterval: TimeInterval = 60
    public static let startupDelay: TimeInterval = 30

    private let repoStore: RepoStore
    private let configStore: ConfigStore
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var stopped: Bool = true

    /// Last successful (or attempted) refresh per repo, drives cadence.
    private var lastRefreshAt: [URL: Date] = [:]

    private let queue = DispatchQueue(
        label: "nl.thimo.uncommitted.github-status",
        qos: .utility,
        attributes: .concurrent
    )

    /// Disk path for persisting `statuses` across launches. Same
    /// directory pattern as ConfigStore (~/Library/Application Support/
    /// Uncommitted/). Without this, the popover would render no GitHub
    /// info for the first ~30 seconds after every relaunch.
    private let cacheURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = support.appendingPathComponent("Uncommitted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("github-status.json")
    }()

    private var saveWorkItem: DispatchWorkItem?

    public init(repoStore: RepoStore, configStore: ConfigStore) {
        self.repoStore = repoStore
        self.configStore = configStore

        // Restore the last persisted snapshot synchronously so the menu
        // bar tint and popover badges paint correctly the moment the
        // app comes up — before the first scheduler tick.
        loadCacheFromDisk()

        configStore.$config
            .map(\.showGitHubStatus)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.start()
                } else {
                    self?.stop()
                }
            }
            .store(in: &cancellables)

        // Persist on every change, debounced 300ms. Mirrors ConfigStore.
        $statuses
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSave() }
            .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Start / stop

    public func start() {
        stop()
        guard GHService.ghPath() != nil else {
            log.info("gh CLI not found — GitHub status scheduler stays off")
            return
        }
        stopped = false
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.startupDelay,
            repeats: false
        ) { [weak self] _ in
            self?.tick()
            self?.scheduleRecurring()
        }
    }

    public func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    private func scheduleRecurring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.tickInterval,
            repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: - Public refresh entry points

    /// Refresh now, bypassing cadence. Use on popover-open and manual
    /// refresh. Off-thread under the hood; results post on main.
    public func eagerRefresh(_ repos: [Repo]) {
        guard !stopped else { return }
        let specs = repos.compactMap(resolvedSpec(for:))
        runFetch(specs: specs)
    }

    /// Drop cached status for a repo — useful when its remote URL just
    /// changed or the repo was reconfigured. Next tick repopulates.
    public func invalidate(url: URL) {
        statuses.removeValue(forKey: url)
        lastRefreshAt.removeValue(forKey: url)
    }

    // MARK: - Tick

    private func tick() {
        guard !stopped else { return }
        let now = Date()
        let due: [RepoSpec] = repoStore.repos.compactMap { repo in
            guard let spec = resolvedSpec(for: repo) else { return nil }
            let last = lastRefreshAt[repo.url]
            let interval: TimeInterval = {
                // Pending CI gets the fast cadence regardless of
                // local-activity tier — we want to know the moment a
                // run concludes.
                if statuses[repo.url]?.ciStatus == .pending {
                    return Self.pendingInterval
                }
                return isActive(repo: repo) ? Self.activeInterval : Self.idleInterval
            }()
            if let last, now.timeIntervalSince(last) < interval {
                return nil
            }
            return spec
        }
        runFetch(specs: due)
    }

    // MARK: - Specs + fetch

    /// Internal "what to fetch for this repo" record. Branch may be nil
    /// for detached HEAD or never-tracked branches; in that case we still
    /// fetch PR-count (slug-only) but skip CI.
    private struct RepoSpec {
        let url: URL
        let remote: GitHubRemote
        let branch: String?
    }

    private func resolvedSpec(for repo: Repo) -> RepoSpec? {
        guard let urlString = GitService.remoteURL(at: repo.url),
              let remote = GitHubRemoteParser.parse(urlString) else {
            return nil
        }
        let branch: String? = {
            guard let status = repo.status, !status.isDetached else { return nil }
            return status.branch
        }()
        return RepoSpec(url: repo.url, remote: remote, branch: branch)
    }

    private func isActive(repo: Repo) -> Bool {
        let head = repo.url.appendingPathComponent(".git/HEAD")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: head.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(mtime) <= Self.activeThreshold
    }

    private func runFetch(specs: [RepoSpec]) {
        guard !specs.isEmpty else { return }

        // Dedup PR-count fetches by slug.
        let bySlug = Dictionary(grouping: specs) { $0.remote.slug }
        // Dedup CI fetches by (slug, branch); skip specs without a branch.
        let byCI = Dictionary(grouping: specs.filter { $0.branch != nil }) { spec in
            "\(spec.remote.slug)#\(spec.branch ?? "")"
        }

        let urls = specs.map(\.url)

        queue.async { [weak self] in
            guard let self else { return }

            for (_, slugRepos) in bySlug {
                guard let firstRemote = slugRepos.first?.remote else { continue }
                guard let prCount = GitHubAPI.fetchPRCount(for: firstRemote) else { continue }
                let urlsForSlug = slugRepos.map(\.url)
                DispatchQueue.main.async {
                    let now = Date()
                    for url in urlsForSlug {
                        self.applyPR(prCount, to: url, at: now)
                    }
                }
            }

            for (_, ciRepos) in byCI {
                guard let firstSpec = ciRepos.first,
                      let branch = firstSpec.branch else { continue }
                let (ci, failingNames) = GitHubAPI.fetchCIStatus(for: firstSpec.remote, ref: branch)
                let urlsForCI = ciRepos.map(\.url)
                DispatchQueue.main.async {
                    let now = Date()
                    for url in urlsForCI {
                        self.applyCI(ci, failingNames: failingNames, to: url, at: now)
                    }
                }
            }

            // Mark all dispatched URLs as attempted (even if PR or CI
            // returned nil) so a persistent error doesn't tight-loop.
            DispatchQueue.main.async {
                let now = Date()
                for url in urls {
                    self.lastRefreshAt[url] = now
                }
            }
        }
    }

    // MARK: - State writes (main thread)

    private func applyPR(_ count: PRCount, to url: URL, at when: Date) {
        var current = statuses[url] ?? GitHubRepoStatus()
        current.prCount = count
        current.fetchedAt = when
        statuses[url] = current
    }

    private func applyCI(_ status: CIStatus, failingNames: [String], to url: URL, at when: Date) {
        var current = statuses[url] ?? GitHubRepoStatus()
        current.ciStatus = status
        current.failingCheckNames = failingNames
        current.fetchedAt = when
        statuses[url] = current
    }

    // MARK: - Disk persistence

    /// On-disk shape: dictionary keyed by absolute path strings, since
    /// JSON dictionary keys must be strings. Converted back to URL on
    /// load.
    private struct CacheFile: Codable {
        let entries: [String: GitHubRepoStatus]
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveCacheToDisk() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func saveCacheToDisk() {
        let entries = Dictionary(uniqueKeysWithValues: statuses.map { ($0.key.path, $0.value) })
        let payload = CacheFile(entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(payload)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            log.error("github-status save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadCacheFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(CacheFile.self, from: data) else {
            log.info("github-status cache present but undecodable, ignoring")
            return
        }
        let restored = Dictionary(uniqueKeysWithValues: payload.entries.map { (path, status) in
            (URL(fileURLWithPath: path), status)
        })
        statuses = restored
    }
}

/// Aggregate view of all CI statuses — useful for the menu-bar "any red?"
/// signal driven from the published `statuses` dict.
public extension GitHubStatusScheduler {
    var hasAnyCIFailure: Bool {
        statuses.values.contains { $0.ciStatus == .failure }
    }
}
