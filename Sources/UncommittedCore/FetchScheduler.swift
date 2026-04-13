import Foundation
import Combine
import AppKit
import os.log

private let log = Logger(subsystem: "nl.thimo.uncommitted", category: "fetch-scheduler")

/// Runs `git fetch` on tracked repos in the background at a tiered cadence
/// (24h for repos active in the last 7 days, 7d otherwise). Failures back
/// off exponentially up to a 30-day cap, then the repo is treated as
/// disabled until a manual fetch revives it. See docs/auto-fetch.md.
public final class FetchScheduler: ObservableObject {
    /// How often the scheduler wakes up to look for work. Each tick is
    /// cheap when there's nothing to do.
    public static let tickInterval: TimeInterval = 5 * 60
    /// Delay before the very first tick after `start()`. Avoids slamming
    /// the network during app launch.
    public static let startupDelay: TimeInterval = 2 * 60
    /// Maximum simultaneous `git fetch` invocations.
    public static let parallelLimit: Int = 3

    /// Cadence for repos with recent local activity.
    public static let activeInterval: TimeInterval = 24 * 60 * 60
    /// Cadence for everything else.
    public static let idleInterval: TimeInterval = 7 * 24 * 60 * 60
    /// "Active" if `.git/HEAD` was touched within this window.
    public static let activeThreshold: TimeInterval = 7 * 24 * 60 * 60
    /// Once the back-off interval would exceed this, the repo is disabled
    /// and the scheduler stops touching it until a manual fetch.
    public static let maxBackoff: TimeInterval = 30 * 24 * 60 * 60

    private let configStore: ConfigStore
    private let repoStore: RepoStore
    private let fetchStateStore: FetchStateStore

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// True once `stop()` has been called. In-flight fetch operations
    /// check this before talking to git AND before posting their main-
    /// thread completion blocks, so disabling the toggle while fetches
    /// are running can't write stale state into FetchStateStore.
    private var stopped: Bool = true
    /// URLs whose `hasRemote` has been verified during this app run.
    /// Spec says noRemote is re-checked once per launch — we use a
    /// per-launch Set so the check fires exactly once per repo per
    /// launch rather than being tied to whether `lastAttemptAt` is nil
    /// (which silently skips repos whose remote was added or removed
    /// between sessions). Mutated only on the main thread.
    private var remoteCheckedThisLaunch = Set<String>()
    /// Bounded by `parallelLimit` via `maxConcurrentOperationCount`. We
    /// don't reuse the existing GitService dispatch queues because the
    /// fetch operation needs strict parallelism limits and a separate
    /// QoS so a runaway fetch can't starve the user-initiated push/pull
    /// path.
    private let fetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "nl.thimo.uncommitted.fetch-scheduler"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = FetchScheduler.parallelLimit
        return q
    }()

    public init(
        configStore: ConfigStore,
        repoStore: RepoStore,
        fetchStateStore: FetchStateStore
    ) {
        self.configStore = configStore
        self.repoStore = repoStore
        self.fetchStateStore = fetchStateStore

        // Track the toggle. Off → stop. On → start (after the startup delay).
        configStore.$config
            .map(\.fetchFromRemotes)
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

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Start / stop

    public func start() {
        stop()
        stopped = false
        // Schedule a one-shot timer for the startup delay, then switch to
        // the recurring tick. This avoids firing immediately when the app
        // launches with the toggle on.
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
        // cancelAllOperations only marks queued operations; running
        // ones must self-check `stopped` (they do, via the closures
        // captured in enqueueFetch). Cancelling here just prevents
        // anything sitting in the queue from spawning a git process.
        fetchQueue.cancelAllOperations()
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

    @objc private func handleSystemWake() {
        // Don't fire all overdue work in one burst — let the normal cadence
        // catch up over the next few ticks. Just make sure the timer is
        // still alive (sleep can pause it on some macOS versions).
        guard configStore.config.fetchFromRemotes else { return }
        if timer == nil {
            scheduleRecurring()
        }
    }

    // MARK: - Tick

    private func tick() {
        let now = Date()
        let candidates = repoStore.repos.filter { repo in
            let state = fetchStateStore.state(for: repo.url)
            if state.noRemote { return false }
            if Self.isDisabled(state) { return false }
            return shouldFetch(repo: repo, state: state, now: now)
        }
        // The OperationQueue's maxConcurrentOperationCount enforces the
        // parallel limit. We can enqueue everything and let the queue
        // drain; remaining work just waits its turn this tick.
        for repo in candidates {
            enqueueFetch(repo: repo, manual: false)
        }
    }

    /// True if this repo is overdue based on its tier (active vs idle)
    /// and any back-off from prior failures.
    private func shouldFetch(repo: Repo, state: FetchState, now: Date) -> Bool {
        Self.shouldFetch(active: isActive(repo: repo), state: state, now: now)
    }

    /// Pure-function counterpart of `shouldFetch(repo:state:now:)`.
    /// Public so unit tests can drive it without a real Repo on disk.
    public static func shouldFetch(active: Bool, state: FetchState, now: Date) -> Bool {
        guard let last = state.lastAttemptAt else {
            // Never tried — fetch on the first eligible tick.
            return true
        }
        let interval = nextInterval(active: active, state: state)
        return now.timeIntervalSince(last) >= interval
    }

    /// Returns the wait interval before the next attempt: the tier base
    /// interval, doubled for each consecutive failure, capped at maxBackoff.
    /// Public so unit tests can verify the back-off ladder directly.
    public static func nextInterval(active: Bool, state: FetchState) -> TimeInterval {
        let base = active ? Self.activeInterval : Self.idleInterval
        let failures = state.consecutiveFailures
        guard failures > 0 else { return base }
        let multiplier = pow(2.0, Double(failures - 1))
        return min(base * multiplier, Self.maxBackoff)
    }

    /// "Active" if the repo's `.git/HEAD` was touched within the activity
    /// window. Cheap proxy for "had a local commit, checkout, merge, or
    /// rebase recently" — every git op that moves HEAD bumps that mtime.
    private func isActive(repo: Repo) -> Bool {
        let head = repo.url.appendingPathComponent(".git/HEAD")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: head.path),
              let mtime = attrs[.modificationDate] as? Date else {
            // Couldn't read mtime — treat as idle to err on the side of
            // less network traffic.
            return false
        }
        return Date().timeIntervalSince(mtime) <= Self.activeThreshold
    }

    /// True once the next computed back-off would push the next attempt
    /// past `maxBackoff` (~30 days). The repo is then dormant until a
    /// manual fetch. Public so views can render a muted "disabled" hint
    /// next to the row name without duplicating policy constants.
    public static func isDisabled(_ state: FetchState) -> Bool {
        guard state.consecutiveFailures > 0 else { return false }
        // Same calculation as nextInterval but without needing a Repo —
        // we use idleInterval as the base because the worst case is
        // applied uniformly here: if even an "idle" interval × backoff
        // exceeds the cap, we're done auto-trying.
        let multiplier = pow(2.0, Double(state.consecutiveFailures - 1))
        return Self.idleInterval * multiplier >= Self.maxBackoff
    }

    /// True if this repo's fetch failures should already be visible to
    /// the user. Auto failures need 3+ to surface; manual failures
    /// surface on the very first one (the user just asked, they should
    /// know immediately).
    public static func shouldSurfaceFailure(_ state: FetchState) -> Bool {
        if state.consecutiveFailures == 0 { return false }
        if state.lastAttemptWasManual { return true }
        return state.consecutiveFailures >= 3
    }

    // MARK: - Manual fetch

    /// Force-fetches the given repos immediately, bypassing cadence and
    /// back-off. Marks `lastAttemptWasManual = true` so the row glyph
    /// surfaces failures right away (threshold drops to 1).
    public func manualFetch(repos: [Repo]) {
        for repo in repos {
            enqueueFetch(repo: repo, manual: true)
        }
    }

    // MARK: - Fetch execution

    private func enqueueFetch(repo: Repo, manual: Bool) {
        let url = repo.url
        let key = url.standardizedFileURL.path
        // Decide on the main thread whether we need to verify the remote
        // configuration this launch. Reading and updating the
        // `remoteCheckedThisLaunch` set on a background thread would race
        // with the rebuild() pruning path.
        let shouldVerifyRemote = !remoteCheckedThisLaunch.contains(key)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation, !operation.isCancelled else { return }
            if self.stopped && !manual { return }

            // Skip silently if we already know this repo has no remote
            // — but only once per launch. `remoteCheckedThisLaunch` is
            // populated below as soon as a verification finishes, so we
            // don't repeatedly hit `git remote` for the same repo.
            let cachedState = self.fetchStateStore.state(for: url)
            if cachedState.noRemote && !shouldVerifyRemote && !manual {
                return
            }

            // First check this launch (or a manual fetch) — verify the
            // remote configuration. If absent, mark noRemote and bail
            // without counting it as a failure. This makes manual
            // fetches on local-only repos quiet instead of surfacing
            // the orange row glyph.
            if shouldVerifyRemote || manual {
                let hasRemote = GitService.hasRemote(at: url)
                DispatchQueue.main.async {
                    self.remoteCheckedThisLaunch.insert(key)
                    self.fetchStateStore.update(url) { $0.noRemote = !hasRemote }
                }
                if !hasRemote { return }
            }

            if operation.isCancelled || (self.stopped && !manual) { return }
            let result = GitService.fetch(at: url)
            let now = Date()

            DispatchQueue.main.async {
                // Bail if the user disabled the feature while this
                // operation was running, OR if the repo was removed
                // from sources between scheduling and completion. In
                // either case writing state would surprise the user.
                if self.stopped && !manual { return }
                guard self.repoStore.repos.contains(where: { $0.url == url }) else { return }

                self.fetchStateStore.update(url) { state in
                    state.lastAttemptAt = now
                    state.lastAttemptWasManual = manual
                    if result.success {
                        state.lastSuccessAt = now
                        state.consecutiveFailures = 0
                        // A successful fetch on a repo we'd previously
                        // marked "no remote" means a remote got added.
                        state.noRemote = false
                    } else {
                        state.consecutiveFailures += 1
                        log.info("fetch failed for \(url.lastPathComponent, privacy: .public): \(result.errorOutput ?? "unknown", privacy: .public)")
                    }
                }
                if result.success {
                    self.repoStore.refresh(url: url)
                }
            }
        }
        fetchQueue.addOperation(operation)
    }
}
