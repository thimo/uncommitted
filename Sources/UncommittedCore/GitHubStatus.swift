import Foundation
import os.log

private let log = Logger(subsystem: "nl.defrog.uncommitted", category: "github")

/// owner/repo pair extracted from a GitHub remote URL. Holds the original
/// URL string so callers can surface it in errors/logs.
public struct GitHubRemote: Equatable {
    public let owner: String
    public let repo: String
    public let originalURL: String

    public var slug: String { "\(owner)/\(repo)" }

    public init(owner: String, repo: String, originalURL: String) {
        self.owner = owner
        self.repo = repo
        self.originalURL = originalURL
    }
}

/// CI conclusion for a single commit. `.none` means there is no remote
/// branch to look at (local-only) or no check-runs were ever attached;
/// the UI renders nothing for both, since "no signal" isn't actionable.
public enum CIStatus: String, Equatable, Codable {
    case success
    case failure
    case pending
    case unknown
    case none
}

/// Open PR breakdown for one repo. Bots are dependabot/renovate and
/// anyone else GitHub flags as `user.type == "Bot"`.
public struct PRCount: Equatable, Codable {
    public let humans: Int
    public let bots: Int

    public var total: Int { humans + bots }
    public var isEmpty: Bool { total == 0 }

    public init(humans: Int, bots: Int) {
        self.humans = humans
        self.bots = bots
    }
}

/// Aggregate GitHub state for a repo at a moment in time.
public struct GitHubRepoStatus: Equatable, Codable {
    public var prCount: PRCount?
    public var ciStatus: CIStatus
    /// Names of the check-runs whose conclusion put the aggregate into
    /// `.failure`. Useful for the detail popover so the user knows
    /// *which* check broke (e.g. "lint" vs. "test"), since GitHub's
    /// Actions tab only shows workflow runs and may hide third-party
    /// app checks that nevertheless fail the aggregate.
    public var failingCheckNames: [String]
    public var ciTargetSHA: String?
    public var fetchedAt: Date

    public init(
        prCount: PRCount? = nil,
        ciStatus: CIStatus = .none,
        failingCheckNames: [String] = [],
        ciTargetSHA: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.prCount = prCount
        self.ciStatus = ciStatus
        self.failingCheckNames = failingCheckNames
        self.ciTargetSHA = ciTargetSHA
        self.fetchedAt = fetchedAt
    }

    // Custom decoder so adding a new field (failingCheckNames) doesn't
    // invalidate cache files written by older versions — missing keys
    // fall back to the type's default rather than nuking the entry.
    enum CodingKeys: String, CodingKey {
        case prCount, ciStatus, failingCheckNames, ciTargetSHA, fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.prCount = try c.decodeIfPresent(PRCount.self, forKey: .prCount)
        self.ciStatus = try c.decodeIfPresent(CIStatus.self, forKey: .ciStatus) ?? .none
        self.failingCheckNames = try c.decodeIfPresent([String].self, forKey: .failingCheckNames) ?? []
        self.ciTargetSHA = try c.decodeIfPresent(String.self, forKey: .ciTargetSHA)
        self.fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
    }
}

// MARK: - Remote URL parsing

public enum GitHubRemoteParser {
    /// Recognises the three forms `git remote get-url origin` produces and
    /// returns nil for anything that doesn't point at github.com.
    /// Forms covered:
    ///  - SSH    `git@github.com:owner/repo.git`
    ///  - SSH    `ssh://git@github.com/owner/repo.git`
    ///  - HTTPS  `https://github.com/owner/repo.git`
    ///  - HTTPS  `https://github.com/owner/repo`
    /// Returns nil for GitHub Enterprise hosts — we only support
    /// github.com for now.
    public static func parse(_ urlString: String) -> GitHubRemote? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // SCP-like SSH: `git@github.com:owner/repo[.git]`
        if let slugRange = scpStyleSlug(in: trimmed) {
            return makeRemote(from: slugRange, original: trimmed)
        }

        // URL-form (ssh://, https://, http://, git://)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return makeRemote(from: path, original: trimmed)
    }

    /// Pulls the `owner/repo` part out of an SCP-style SSH URL like
    /// `git@github.com:owner/repo.git`. Returns nil for other forms.
    private static func scpStyleSlug(in input: String) -> String? {
        guard input.contains(":"),
              !input.contains("://"),
              let colonIdx = input.firstIndex(of: ":") else {
            return nil
        }
        let host = input[..<colonIdx]
        let after = input[input.index(after: colonIdx)...]
        // Accept any user prefix on github.com (e.g. `org-1234@github.com`).
        guard host.lowercased().hasSuffix("github.com") else { return nil }
        return String(after)
    }

    private static func makeRemote(from slug: String, original: String) -> GitHubRemote? {
        let stripped = slug.hasSuffix(".git") ? String(slug.dropLast(4)) : slug
        let parts = stripped.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let repo = String(parts[1])
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return GitHubRemote(owner: owner, repo: repo, originalURL: original)
    }
}

// MARK: - gh CLI service

/// Thin wrapper around the `gh` CLI for GitHub API calls. Mirrors
/// GitService's process patterns (concurrent pipe drain, post-exit
/// timeout) but talks to `gh api ...` instead of git.
public enum GHService {
    public struct ExecuteResult {
        public let exitStatus: Int32
        public let stdout: Data
        public let stderr: Data
        public let launchFailure: Error?

        public var isSuccess: Bool { exitStatus == 0 && launchFailure == nil }
    }

    /// Locations we'll try in order. `gh` doesn't have a canonical install
    /// path the way `/usr/bin/git` does — Homebrew puts it in different
    /// places on Apple Silicon vs. Intel, MacPorts uses /opt/local. We
    /// look at common locations and cache the first hit per process.
    /// Nil cache slot means "not yet probed"; nil result means "not found".
    private static let candidatePaths: [String] = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/opt/local/bin/gh",
    ]

    private static let pathCache = OSAllocatedUnfairLock<String??>(initialState: nil)

    /// Returns the absolute path to the `gh` binary, or nil if it isn't
    /// installed in any of the common locations. Result is cached for the
    /// life of the process — if the user installs `gh` while the app is
    /// running, they'll need to relaunch to pick it up.
    public static func ghPath() -> String? {
        pathCache.withLock { cache in
            if let cached = cache {
                return cached
            }
            let found = candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            cache = .some(found)
            return found
        }
    }

    /// Whether `gh` is installed AND `gh auth status` reports an
    /// authenticated host. Cheap enough to call from Settings to drive
    /// the graceful-degrade banner; result is NOT cached because the user
    /// may run `gh auth login` while the app is open.
    public static func isAvailable() -> Bool {
        guard ghPath() != nil else { return false }
        let result = execute(["auth", "status"])
        return result.isSuccess
    }

    /// Runs `gh <args>` and captures stdout/stderr.
    /// Same concurrent-drain + post-exit timeout shape as GitService.execute().
    @discardableResult
    public static func execute(_ args: [String]) -> ExecuteResult {
        guard let path = ghPath() else {
            let err = NSError(
                domain: "nl.defrog.uncommitted.gh",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "gh CLI not found in PATH"]
            )
            return ExecuteResult(exitStatus: -1, stdout: Data(), stderr: Data(), launchFailure: err)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = buildEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ExecuteResult(exitStatus: -1, stdout: Data(), stderr: Data(), launchFailure: error)
        }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "nl.defrog.uncommitted.gh-drain", attributes: .concurrent)

        var stdoutData = Data()
        var stderrData = Data()

        func drain(_ handle: FileHandle) -> Data {
            var data = Data()
            do {
                while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                    data.append(chunk)
                }
            } catch {
                // Reader closed mid-read — return what we have.
            }
            return data
        }

        group.enter()
        queue.async {
            stdoutData = drain(stdoutPipe.fileHandleForReading)
            group.leave()
        }
        group.enter()
        queue.async {
            stderrData = drain(stderrPipe.fileHandleForReading)
            group.leave()
        }

        process.waitUntilExit()

        let drained = group.wait(timeout: .now() + .seconds(pipeDrainTimeoutSeconds))
        if drained == .timedOut {
            let pgid = getpgid(process.processIdentifier)
            if pgid > 0 { Foundation.kill(-pgid, SIGKILL) }
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            log.error("gh \(args.joined(separator: " "), privacy: .public): pipe drain timed out")
            return ExecuteResult(
                exitStatus: process.terminationStatus,
                stdout: stdoutData,
                stderr: stderrData,
                launchFailure: nil
            )
        }

        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        return ExecuteResult(
            exitStatus: process.terminationStatus,
            stdout: stdoutData,
            stderr: stderrData,
            launchFailure: nil
        )
    }

    /// Convenience for typed REST calls: `gh api <endpoint>` with stdout
    /// JSON-decoded into the requested type. Returns nil on any failure
    /// (non-zero exit, decode error, missing gh) — caller can treat that
    /// as "no data yet" and try again next refresh cycle.
    /// Uses `.convertFromSnakeCase` so endpoint payloads (`total_count`,
    /// `check_runs`, …) map to natural Swift camelCase fields.
    public static func api<T: Decodable>(_ endpoint: String, as type: T.Type) -> T? {
        let result = execute(["api", "--method", "GET", endpoint])
        guard result.isSuccess else {
            if !result.stderr.isEmpty,
               let text = String(data: result.stderr, encoding: .utf8) {
                log.error("gh api \(endpoint, privacy: .public) failed: \(text, privacy: .public)")
            }
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: result.stdout)
        } catch {
            log.error("gh api \(endpoint, privacy: .public) decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let pipeDrainTimeoutSeconds: Int = 2

    private static func buildEnvironment() -> [String: String] {
        // gh respects HOME and reads its config from ~/.config/gh.
        // No special tweaks needed — pass the parent environment through.
        ProcessInfo.processInfo.environment
    }
}

// MARK: - Typed API endpoints

/// Higher-level fetchers built on `GHService.api(...)`. Each returns nil
/// on any failure (auth, decode, network) — callers treat that as "no
/// data this cycle, try again next refresh."
public enum GitHubAPI {
    /// Slim subset of the `pulls` response — only the fields we need to
    /// classify a PR as human-or-bot. Decoder ignores everything else.
    struct PullSummary: Decodable {
        struct User: Decodable {
            let login: String
            let type: String?
        }
        let user: User?
    }

    /// Fetches the open PRs for a repo and returns the human-vs-bot
    /// breakdown. `per_page=100` covers any realistic repo in one call;
    /// repos with >100 open PRs are vanishingly rare and the under-count
    /// just means the badge caps at 100 — acceptable for a glanceable
    /// signal.
    public static func fetchPRCount(for remote: GitHubRemote) -> PRCount? {
        let endpoint = "repos/\(remote.owner)/\(remote.repo)/pulls?state=open&per_page=100"
        guard let pulls = GHService.api(endpoint, as: [PullSummary].self) else {
            return nil
        }
        var humans = 0
        var bots = 0
        for pr in pulls {
            if isBotAuthor(login: pr.user?.login, type: pr.user?.type) {
                bots += 1
            } else {
                humans += 1
            }
        }
        return PRCount(humans: humans, bots: bots)
    }

    /// Bot heuristic. Public so tests can exercise the patterns directly.
    /// Order: explicit `user.type == "Bot"` wins; then the `[bot]` login
    /// suffix that GitHub Apps universally carry; then a small allowlist
    /// for well-known bots that may slip the other two.
    public static func isBotAuthor(login: String?, type: String?) -> Bool {
        if let type, type.caseInsensitiveCompare("Bot") == .orderedSame {
            return true
        }
        guard let login = login?.lowercased() else { return false }
        if login.hasSuffix("[bot]") { return true }
        let knownBots: Set<String> = [
            "dependabot",
            "renovate",
            "renovate-bot",
            "github-actions",
        ]
        return knownBots.contains(login)
    }

    // MARK: - CI / workflow runs

    /// Slim subset of the GitHub workflow run payload. We use the
    /// workflow-level conclusion (instead of per-job check-runs)
    /// because it matches what GitHub's own UI shows next to a commit:
    /// a workflow that has a `continue-on-error` job is considered
    /// successful as a whole even though one of its jobs technically
    /// failed.
    public struct WorkflowRun: Decodable, Equatable {
        public let name: String
        public let status: String
        public let conclusion: String?
        public let workflowId: Int

        public init(name: String = "", status: String, conclusion: String?, workflowId: Int = 0) {
            self.name = name
            self.status = status
            self.conclusion = conclusion
            self.workflowId = workflowId
        }
    }

    struct WorkflowRunsResponse: Decodable {
        let workflowRuns: [WorkflowRun]
    }

    /// Returns the most recent run per `workflowId`. The API returns
    /// runs sorted by created_at descending, so a simple first-seen
    /// dedupe gives us "latest per workflow" without an extra sort.
    public static func latestPerWorkflow(_ runs: [WorkflowRun]) -> [WorkflowRun] {
        var seen = Set<Int>()
        var out: [WorkflowRun] = []
        for run in runs {
            guard seen.insert(run.workflowId).inserted else { continue }
            out.append(run)
        }
        return out
    }

    /// Fetches CI status for a branch by inspecting the **workflow-level**
    /// conclusion of each workflow's most recent run on that branch.
    /// Caller must ensure the branch exists on the remote — `gh api`
    /// just returns an empty list otherwise, which we surface as `.none`.
    /// Returns the aggregate status plus the names of workflows whose
    /// latest run is in a failure state.
    public static func fetchCIStatus(for remote: GitHubRemote, ref: String) -> (CIStatus, [String]) {
        let encoded = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
        let endpoint = "repos/\(remote.owner)/\(remote.repo)/actions/runs?branch=\(encoded)&per_page=20"
        guard let response = GHService.api(endpoint, as: WorkflowRunsResponse.self) else {
            return (.none, [])
        }
        let latest = latestPerWorkflow(response.workflowRuns)
        return (aggregate(workflowRuns: latest), failingNames(in: latest))
    }

    /// Names of the workflows whose latest run is in the "failure"
    /// bucket. Dedupes by workflow name and preserves first-seen order.
    public static func failingNames(in runs: [WorkflowRun]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for run in runs {
            guard run.status == "completed" else { continue }
            switch run.conclusion {
            case "success", "neutral", "skipped", "stale", nil:
                continue
            default:
                let name = run.name
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                ordered.append(name)
            }
        }
        return ordered
    }

    /// Maps a list of workflow runs to a single `CIStatus`. Public so
    /// tests can drive the conclusion/status combinations without the
    /// network. Mapping mirrors GitHub's own UI:
    ///   success/neutral/skipped/stale → green (silent)
    ///   failure/timed_out/cancelled/action_required/startup_failure → red
    ///   anything not yet completed → pending
    public static func aggregate(workflowRuns: [WorkflowRun]) -> CIStatus {
        if workflowRuns.isEmpty { return .none }

        var anyPending = false
        var anyFailure = false

        for run in workflowRuns {
            guard run.status == "completed" else {
                anyPending = true
                continue
            }
            switch run.conclusion {
            case "success", "neutral", "skipped", "stale", nil:
                continue
            default:
                anyFailure = true
            }
        }

        if anyFailure { return .failure }
        if anyPending { return .pending }
        return .success
    }
}
