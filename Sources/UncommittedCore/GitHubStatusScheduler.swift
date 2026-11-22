import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "nl.defrog.uncommitted", category: "github-status-scheduler")

/// Polls GitHub for PR + CI status across tracked repos at a tiered
/// cadence. Multi-clone aware — repos sharing an `owner/repo` slug
/// collapse PR-count fetches to one call; repos on the same branch of
/// the same slug collapse CI fetches too.
///
/// Cadence:
///  - "active" repo (`.git/HEAD` touched within `activeThreshold`): every `activeInterval`
///  - else: every `idleInterval`
///
/// Failures don't back off — GitHub failures are usually transient, so
/// we retry at the normal cadence. The rate limit is the exception: a
/// sweep stops at the first refusal and `GitHubRateLimitGate` holds
/// further calls back for a few minutes.
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
    /// Opening the popup refetches a repo only when its data is older than
    /// this. A sweep costs about six GraphQL points per repository, so
    /// with 38 repositories some twenty popup opens spent the hourly
    /// budget of 5000 and took every other `gh` user down with it
    /// (2026-11-22).
    public static let popupMinimumAge: TimeInterval = 5 * 60

    /// A tick or popup sweep that hasn't reported back after this long is
    /// no longer counted as running: `gh` has no timeout of its own, and
    /// one hung call must not block a repo's refreshes for good.
    public static let inFlightTimeout: TimeInterval = 3 * 60

    /// Whether opening the popup should refetch a repo last refreshed at
    /// `last`. Pending and failing CI keep their one-minute cadence here
    /// too, so the badge still clears promptly. `localStateChanged` — a
    /// commit, push or checkout since that refresh — always refetches:
    /// that is when the user opens the popup to watch CI start.
    public static func popupRefreshDue(last: Date?, ciStatus: CIStatus?, localStateChanged: Bool, now: Date) -> Bool {
        guard let last, !localStateChanged else { return true }
        let minimumAge: TimeInterval
        switch ciStatus {
        case .pending, .failure: minimumAge = pendingInterval
        default: minimumAge = popupMinimumAge
        }
        return now.timeIntervalSince(last) >= minimumAge
    }

    /// What a push, commit or checkout changes, as one comparable value.
    static func localState(of repo: Repo) -> String {
        guard let status = repo.status else { return "" }
        return "\(status.branch)|\(status.headOid ?? "")|\(status.ahead)"
    }

    /// Repos with a tick or popup sweep under way, and since when, so the
    /// two don't fetch the same repo twice. Main thread only.
    private var inFlightSince: [URL: Date] = [:]

    /// `localState` of each repo at its last refresh. Main thread only.
    private var lastRefreshState: [URL: String] = [:]

    private func isInFlight(_ url: URL, now: Date) -> Bool {
        guard let since = inFlightSince[url] else { return false }
        return now.timeIntervalSince(since) < Self.inFlightTimeout
    }

    private func markInFlight(_ urls: [URL], at now: Date) {
        for url in urls { inFlightSince[url] = now }
    }

    /// Only entries this sweep set: after a timeout a newer sweep may own it.
    private func clearInFlight(_ urls: [URL], startedAt: Date) {
        for url in urls where inFlightSince[url] == startedAt {
            inFlightSince.removeValue(forKey: url)
        }
    }

    private let repoStore: RepoStore
    private let configStore: ConfigStore
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var stopped: Bool = true

    /// Last successful (or attempted) refresh per repo, drives cadence.
    private var lastRefreshAt: [URL: Date] = [:]

    /// Latest run per workflow from the previous CI fetch, keyed
    /// `slug#branch` — see `GitHubAPI.newestRuns`. Main thread only.
    private var lastCIRuns: [String: [GitHubAPI.WorkflowRun]] = [:]

    /// Commit statuses from the previous CI fetch, same key — the
    /// fallback when a fetch fails. Main thread only.
    private var lastCommitStatuses: [String: [GitHubAPI.CommitStatus]] = [:]

    private let queue = DispatchQueue(
        label: "nl.defrog.uncommitted.github-status",
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

        // Issues are left out of the query while the toggle is off, so
        // turning it on has nothing current to show until a refresh —
        // fetch right away instead of waiting out the cadence slot.
        // `eagerRefresh`, not `tick()`: it resolves specs off the main
        // thread. `$config` publishes on willSet, so hop to the next
        // runloop turn before `eagerRefresh` reads the new value back.
        configStore.$config
            .map(\.showGitHubIssues)
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.eagerRefresh(self.repoStore.repos)
            }
            .store(in: &cancellables)

        // The exact ignored-issue counts are fetched for one label; a new
        // label needs new counts. Until they land the UI falls back to
        // the listed rows, so this is accuracy, not correctness.
        configStore.$config
            .map(\.gitHubIgnoredIssueLabel)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.eagerRefresh(self.repoStore.repos)
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

    /// Refresh on popover-open: only repos whose data is older than
    /// `popupMinimumAge` or that changed locally since, and never a repo a
    /// running sweep already covers. Call on the main thread.
    public func popupRefresh(_ repos: [Repo]) {
        guard !stopped, !GitHubRateLimitGate.shared.isAnyPaused() else { return }
        let now = Date()
        let due = repos.filter { repo in
            !isInFlight(repo.url, now: now) && Self.popupRefreshDue(
                last: lastRefreshAt[repo.url],
                ciStatus: statuses[repo.url]?.ciStatus,
                localStateChanged: lastRefreshState[repo.url] != Self.localState(of: repo),
                now: now
            )
        }
        guard !due.isEmpty else { return }
        let urls = due.map(\.url)
        markInFlight(urls, at: now)
        eagerRefresh(due) { [weak self] in self?.clearInFlight(urls, startedAt: now) }
    }

    /// A deploy of this repo, started from its menu, just ended: ask GitHub
    /// for its deployments right away, so the pill doesn't wait for the
    /// next poll, minutes later. `deployedHead` is the commit Kamal
    /// shipped — the local HEAD at launch. Call on the main thread.
    public func refreshAfterDeploy(of url: URL, deployedHead: String?) {
        checkDeployment(of: url, deployedHead: deployedHead, retriesLeft: 1)
    }

    /// The deployment a finished deploy was seen to have recorded, per
    /// slug. For a short while an answer naming another commit is taken
    /// for a sweep that asked before the record existed. Main thread only.
    private var confirmedDeploys: [String: (sha: String, at: Date)] = [:]
    private static let confirmedDeployWindow: TimeInterval = 2 * 60

    private func checkDeployment(of url: URL, deployedHead: String?, retriesLeft: Int) {
        guard !stopped, let repo = repoStore.repos.first(where: { $0.url == url }) else { return }
        queue.async { [weak self] in
            guard let self, let spec = self.resolvedSpec(for: repo) else { return }
            let result = GitHubAPI.fetchDeploymentLag(for: spec.remote)
            DispatchQueue.main.async {
                let slug = spec.remote.slug
                // The record is written by the deploy's own hook just
                // before it ends; one more look gives GitHub a moment.
                func retry() -> Bool {
                    guard retriesLeft > 0 else { return false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                        self?.checkDeployment(of: url, deployedHead: deployedHead, retriesLeft: retriesLeft - 1)
                    }
                    return true
                }
                // No answer (network, rate limit) is never a verdict; the
                // normal cadence catches up.
                guard let result else {
                    _ = retry()
                    return
                }
                if case .lag(let lag) = result, deployedHead == nil || lag.deployedSHA == deployedHead {
                    self.confirmedDeploys[slug] = (lag.deployedSHA, Date())
                    self.applyDeploymentLagToClones(result, slug: slug, of: url)
                    return
                }
                if retry() { return }
                self.applyDeploymentLagToClones(result, slug: slug, of: url)
                // The one place this failure is visible: the terminal tab
                // with the hook's output has closed itself by now.
                let commit = deployedHead.map { " for \($0.prefix(7))" } ?? ""
                DiagnosticsLog.shared.warning("deploy", "\(url.lastPathComponent) was deployed, but GitHub has no successful production Deployment\(commit): the deploy was not recorded")
            }
        }
    }

    /// The pill shows on one clone per remote, so every clone gets it.
    private func applyDeploymentLagToClones(_ result: GitHubAPI.DeploymentLagResult, slug: String, of url: URL) {
        for repo in repoStore.repos where repo.url == url || statuses[repo.url]?.slug == slug {
            applyDeploymentLag(result, slug: slug, to: repo.url)
        }
    }

    /// Refresh now, bypassing cadence. Use on manual refresh. Off-thread
    /// under the hood; results and `completion` post on main.
    public func eagerRefresh(_ repos: [Repo], completion: (() -> Void)? = nil) {
        guard !stopped else {
            completion?()
            return
        }
        // `resolvedSpec` shells out to `git remote get-url` per repo.
        // Done on the caller (main) thread this blocked the run loop for
        // ~900ms with a dozen repos — measured: it stalled the popup's
        // window-key/activation and every keystroke until it returned.
        // The actual fetch in `runFetch` was already off-main; the spec
        // resolution wasn't. Push the whole thing to the background
        // queue so opening the popup never waits on git.
        // Config is main-thread state — read it here, not on the queue.
        let issueOptions = issueFetchOptions
        queue.async { [weak self] in
            guard let self, !self.stopped else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            let specs = repos.compactMap(self.resolvedSpec(for:))
            self.runFetch(specs: specs, issueOptions: issueOptions, completion: completion)
        }
    }

    /// Drop cached status for a repo — useful when its remote URL just
    /// changed or the repo was reconfigured. Next tick repopulates.
    public func invalidate(url: URL) {
        statuses.removeValue(forKey: url)
        lastRefreshAt.removeValue(forKey: url)
        lastRefreshState.removeValue(forKey: url)
    }

    // MARK: - Tick

    private func tick() {
        guard !stopped else { return }
        let now = Date()
        let due: [RepoSpec] = repoStore.repos.compactMap { repo in
            guard !isInFlight(repo.url, now: now) else { return nil }
            guard let spec = resolvedSpec(for: repo) else { return nil }
            let last = lastRefreshAt[repo.url]
            let interval: TimeInterval = {
                // Pending and failing CI both get the fast cadence
                // regardless of local-activity tier — pending so we
                // catch the moment a run concludes, failing so the
                // menu-bar shield clears within a minute of someone
                // fixing it (otherwise it lingers for up to 15 min on
                // active repos, 24 h on idle ones).
                switch statuses[repo.url]?.ciStatus {
                case .pending, .failure:
                    return Self.pendingInterval
                default:
                    return isActive(repo: repo) ? Self.activeInterval : Self.idleInterval
                }
            }()
            if let last, now.timeIntervalSince(last) < interval {
                return nil
            }
            return spec
        }
        guard !due.isEmpty else { return }
        let urls = due.map(\.url)
        markInFlight(urls, at: now)
        runFetch(specs: due, issueOptions: issueFetchOptions) { [weak self] in
            self?.clearInFlight(urls, startedAt: now)
        }
    }

    // MARK: - Specs + fetch

    /// Internal "what to fetch for this repo" record. Branch may be nil
    /// for detached HEAD or never-tracked branches; in that case we still
    /// fetch PR-count (slug-only) but skip CI.
    private struct RepoSpec {
        let url: URL
        let remote: GitHubRemote
        let branch: String?
        /// `localState(of:)` when the spec was made.
        let localState: String
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
        return RepoSpec(url: repo.url, remote: remote, branch: branch, localState: Self.localState(of: repo))
    }

    private func isActive(repo: Repo) -> Bool {
        let head = repo.url.appendingPathComponent(".git/HEAD")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: head.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(mtime) <= Self.activeThreshold
    }

    /// The issue-related config a fetch needs. Config is main-thread
    /// state and fetches run on the queue, so it's snapshotted on main
    /// and carried along rather than read where it's used.
    private struct IssueFetchOptions {
        let include: Bool
        let ignoredLabel: String
    }

    private var issueFetchOptions: IssueFetchOptions {
        IssueFetchOptions(
            include: configStore.config.showGitHubIssues,
            ignoredLabel: configStore.config.gitHubIgnoredIssueLabel
        )
    }

    private func runFetch(specs: [RepoSpec], issueOptions: IssueFetchOptions, completion: (() -> Void)? = nil) {
        guard !specs.isEmpty else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        // Rate-limited: nothing is asked, and the repos are forgotten as
        // refreshed so the first tick after the pause picks them up —
        // a refresh the user asked for mid-pause is late, not lost.
        guard !GitHubRateLimitGate.shared.isAnyPaused() else {
            DispatchQueue.main.async { [weak self] in
                for spec in specs {
                    self?.lastRefreshAt.removeValue(forKey: spec.url)
                    self?.lastRefreshState.removeValue(forKey: spec.url)
                }
                completion?()
            }
            return
        }

        // Dedup PR-count fetches by slug.
        let bySlug = Dictionary(grouping: specs) { $0.remote.slug }
        // Dedup CI fetches by (slug, branch); skip specs without a branch.
        let byCI = Dictionary(grouping: specs.filter { $0.branch != nil }) { spec in
            "\(spec.remote.slug)#\(spec.branch ?? "")"
        }

        let gate = GitHubRateLimitGate.shared

        queue.async { [weak self] in
            guard let self else { return }
            // Set when GitHub refused a call for the rate limit: the rest
            // of the sweep is dropped, with both budgets left alone.
            var cutShort = false
            // What was asked and answered (or failed for another reason).
            var doneSlugs = Set<String>()
            var doneCIKeys = Set<String>()

            for (slugKey, slugRepos) in bySlug {
                if gate.isAnyPaused() { cutShort = true; break }
                guard let firstRemote = slugRepos.first?.remote else { continue }
                // Independent of the PR fetch below: neither may skip the other.
                if let lag = GitHubAPI.fetchDeploymentLag(for: firstRemote) {
                    let urlsForSlug = slugRepos.map(\.url)
                    let slug = firstRemote.slug
                    DispatchQueue.main.async {
                        for url in urlsForSlug {
                            self.applyDeploymentLag(lag, slug: slug, to: url)
                        }
                    }
                }
                let signals = GitHubAPI.fetchRepoSignals(
                    for: firstRemote,
                    includeIssues: issueOptions.include,
                    ignoredLabel: issueOptions.ignoredLabel
                )
                // Refused during this slug: it counts as not asked.
                if gate.isAnyPaused() { cutShort = true; break }
                doneSlugs.insert(slugKey)
                guard let signals else { continue }
                let urlsForSlug = slugRepos.map(\.url)
                let slug = firstRemote.slug
                DispatchQueue.main.async {
                    let now = Date()
                    for url in urlsForSlug {
                        self.applySignals(
                            signals,
                            includingIssues: issueOptions.include,
                            slug: slug,
                            to: url,
                            at: now
                        )
                    }
                }
            }

            for (ciKey, ciRepos) in byCI {
                if cutShort || gate.isAnyPaused() { cutShort = true; break }
                guard let firstSpec = ciRepos.first,
                      let branch = firstSpec.branch else { continue }
                let fetched = GitHubAPI.fetchLatestWorkflowRuns(for: firstSpec.remote, ref: branch)
                let fetchedStatuses = GitHubAPI.fetchCommitStatuses(for: firstSpec.remote, ref: branch)
                // A refusal is not an answer: applying the half that did
                // arrive could flip a red badge green.
                if gate.isAnyPaused() { cutShort = true; break }
                doneCIKeys.insert(ciKey)
                let urlsForCI = ciRepos.map(\.url)
                let slug = firstSpec.remote.slug
                DispatchQueue.main.async {
                    let now = Date()
                    let key = "\(slug)#\(branch)"
                    // A failed call falls back to this branch's last answer:
                    // aggregating only the half that arrived would flip a red
                    // badge green for a round. Per branch, not per clone, so
                    // a checkout never inherits the other branch's badge; a
                    // call that never succeeds counts as empty and leaves
                    // the other half to decide.
                    let runs = fetched.map { GitHubAPI.newestRuns(fresh: $0, previous: self.lastCIRuns[key] ?? []) }
                        ?? self.lastCIRuns[key] ?? []
                    let commitStatuses = fetchedStatuses ?? self.lastCommitStatuses[key] ?? []
                    self.lastCIRuns[key] = runs
                    self.lastCommitStatuses[key] = commitStatuses
                    let ci = GitHubAPI.aggregate(workflowRuns: runs, commitStatuses: commitStatuses)
                    let failingNames = GitHubAPI.failingNames(in: runs, commitStatuses: commitStatuses)
                    let notGreen = runs.filter { GitHubAPI.aggregate(workflowRuns: [$0]) != .success }
                    let notGreenStatuses = commitStatuses.filter { GitHubAPI.aggregate(workflowRuns: [], commitStatuses: [$0]) != .success }
                    for url in urlsForCI {
                        self.logCIChange(to: ci, runs: notGreen, statuses: notGreenStatuses, url: url, slug: slug, branch: branch)
                        self.applyCI(ci, failingNames: failingNames, to: url, at: now)
                    }
                }
            }

            // Mark every repo that was asked about as attempted (even if PR
            // or CI returned nil) so a persistent error doesn't tight-loop.
            // What a rate-limit cut left unasked is forgotten instead, so
            // the first tick after the pause fetches exactly that part.
            let finishedSlugs = doneSlugs
            let finishedCIKeys = doneCIKeys
            DispatchQueue.main.async {
                let now = Date()
                for spec in specs {
                    let ciDone = spec.branch.map { finishedCIKeys.contains("\(spec.remote.slug)#\($0)") } ?? true
                    if finishedSlugs.contains(spec.remote.slug) && ciDone {
                        self.lastRefreshAt[spec.url] = now
                        self.lastRefreshState[spec.url] = spec.localState
                    } else {
                        self.lastRefreshAt.removeValue(forKey: spec.url)
                        self.lastRefreshState.removeValue(forKey: spec.url)
                    }
                }
                completion?()
            }
        }
    }

    // MARK: - State writes (main thread)

    /// `includingIssues` is false when the fetch left issues out of the
    /// query. The stored ones are then kept rather than blanked: the queue is
    /// concurrent, so a slow issue-less fetch started just before the
    /// user turned issues on can land after the refresh that toggle
    /// kicked off, and would otherwise wipe what it just fetched.
    /// `status(for:)` hides the leftovers while the toggle is off.
    private func applySignals(
        _ signals: GitHubAPI.RepoSignals,
        includingIssues: Bool,
        slug: String,
        to url: URL,
        at when: Date
    ) {
        var current = statuses[url] ?? GitHubRepoStatus()
        current.prs = signals.prs
        if includingIssues {
            current.issues = signals.issues
            current.openIssueCount = signals.openIssueCount
            current.unclaimedIssueCount = signals.unclaimedIssueCount
            current.exactIgnoredIssues = signals.exactIgnoredIssues
        }
        current.slug = slug
        current.fetchedAt = when
        statuses[url] = current
    }

    private func applyDeploymentLag(_ result: GitHubAPI.DeploymentLagResult, slug: String, to url: URL) {
        if let confirmed = confirmedDeploys[slug] {
            if Date().timeIntervalSince(confirmed.at) >= Self.confirmedDeployWindow {
                confirmedDeploys.removeValue(forKey: slug)
            } else if case .lag(let lag) = result, lag.deployedSHA == confirmed.sha {
                // Agrees with what was just confirmed.
            } else {
                // Asked before the deploy was recorded, landed after it.
                return
            }
        }
        var current = statuses[url] ?? GitHubRepoStatus()
        switch result {
        case .noDeployment: current.deploymentLag = nil
        case .lag(let lag): current.deploymentLag = lag
        }
        current.slug = slug
        statuses[url] = current
    }

    // MARK: - Display lookup

    /// What the UI should render for a repo. Same as `statuses[url]`
    /// except that PR and issue data are stripped for every clone of a
    /// remote but the first in the user's repo order — both belong to the
    /// remote, so four clones of one repo shouldn't shout the same badges
    /// four times. CI is left alone: it's per branch, and clones may
    /// differ there. Issues are also dropped while `showGitHubIssues` is
    /// off — here rather than per view, so no consumer can forget: the
    /// last fetched set lingers in `statuses` after the toggle goes off.
    /// Main thread only (reads `repoStore.repos` and the config).
    public func status(for url: URL) -> GitHubRepoStatus? {
        guard var status = statuses[url] else { return nil }
        if !configStore.config.showGitHubIssues { status = status.withoutIssues }
        guard status.slug != nil,
              !status.prs.isEmpty || !status.issues.isEmpty || status.deploymentLag != nil
        else { return status }
        return primaryRemoteURLs.contains(url) ? status : status.withoutRemoteWideSignals
    }

    private var primaryRemoteURLs: Set<URL> {
        let ordered = repoStore.repos.map(\.url)
        let slugs = statuses.compactMapValues(\.slug)
        return PrimaryClonePicker.primaryURLs(orderedURLs: ordered, slugs: slugs)
    }

    /// One line per CI transition, naming the runs and commit statuses
    /// behind a non-green result — a red badge is otherwise untraceable
    /// once GitHub has moved on.
    private func logCIChange(to new: CIStatus, runs: [GitHubAPI.WorkflowRun], statuses commitStatuses: [GitHubAPI.CommitStatus], url: URL, slug: String, branch: String) {
        let old = statuses[url]?.ciStatus ?? .none
        guard old != new else { return }
        var message = "\(url.lastPathComponent) (\(slug)#\(branch)): \(old) → \(new)"
        let parts = runs.map(\.logDescription) + commitStatuses.map(\.logDescription)
        if !parts.isEmpty {
            message += " — " + parts.joined(separator: "; ")
        }
        if new == .failure {
            DiagnosticsLog.shared.warning("ci", message)
        } else {
            DiagnosticsLog.shared.info("ci", message)
        }
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
            DiagnosticsLog.shared.error("github-status-scheduler", "github-status save failed: \(error.localizedDescription)")
        }
    }

    private func loadCacheFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(CacheFile.self, from: data) else {
            DiagnosticsLog.shared.warning("github-status-scheduler", "github-status cache present but undecodable, ignoring")
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
