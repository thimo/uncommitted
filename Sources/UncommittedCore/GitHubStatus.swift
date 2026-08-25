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

/// Why a PR lands in `.mine` or `.waiting` — drives the trailing caption
/// in the hover panel's PR list. `.label` is the human-readable phrase;
/// `.waitingOnAuthor`'s carries a literal `<author>` placeholder that the
/// UI substitutes with `pr.authorLogin` (it's the one reason that needs
/// to say who it's waiting on, so the caption doesn't repeat "@author").
public enum PRReason: String, Codable, Equatable {
    // mine
    case changesRequestedOnMine
    case ciFailingOnMine
    case approvedReadyToMerge
    case reviewRequested
    case newCommitsSinceReview
    // waiting
    case awaitingReview
    case waitingOnAuthor
    case notInvolved
    case bot
    // draft
    case draft

    public var label: String {
        switch self {
        case .changesRequestedOnMine: return "changes requested"
        case .ciFailingOnMine: return "CI failing"
        case .approvedReadyToMerge: return "approved · merge"
        case .reviewRequested: return "your review requested"
        case .newCommitsSinceReview: return "new commits since your review"
        case .awaitingReview: return "waiting for review"
        case .waitingOnAuthor: return "waiting on @<author>"
        case .notInvolved: return ""
        case .bot: return "bot"
        case .draft: return "draft"
        }
    }
}

/// Whose turn a PR is, plus why. `.mine` means the viewer has something
/// to do; `.waiting` means it's someone else's move (or the viewer isn't
/// involved, or the author is a bot); `.draft` is neither — GitHub hides
/// drafts from reviewers, so they never need the viewer's attention.
public enum PRAttention: Equatable, Codable {
    case mine(PRReason)
    case waiting(PRReason)
    case draft

    public var isMine: Bool {
        if case .mine = self { return true }
        return false
    }

    public var isDraft: Bool {
        if case .draft = self { return true }
        return false
    }

    public var reason: PRReason {
        switch self {
        case .mine(let reason), .waiting(let reason): return reason
        case .draft: return .draft
        }
    }

    /// Sort rank for the hover panel's PR list: mine first, then waiting
    /// (non-bot before bot, so dependabot piles sink to the bottom without
    /// needing a separate section), drafts last.
    public var sortRank: Int {
        switch self {
        case .mine: return 0
        case .waiting(let reason): return reason == .bot ? 2 : 1
        case .draft: return 3
        }
    }
}

/// One open PR, already classified against the viewer. `authorLogin` is
/// "" for a deleted GitHub account (the API returns a null author).
public struct PRSummary: Equatable, Codable, Identifiable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let url: String
    public let authorLogin: String
    public let isBotAuthor: Bool
    public let isDraft: Bool
    public let attention: PRAttention
    public let updatedAt: Date

    public init(
        number: Int,
        title: String,
        url: String,
        authorLogin: String,
        isBotAuthor: Bool,
        isDraft: Bool,
        attention: PRAttention,
        updatedAt: Date
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.authorLogin = authorLogin
        self.isBotAuthor = isBotAuthor
        self.isDraft = isDraft
        self.attention = attention
        self.updatedAt = updatedAt
    }
}

/// Open PR breakdown for one repo's badge: how many need the viewer vs.
/// how many are just open. Drafts don't count either way — they never
/// need the viewer and GitHub hides them from reviewers anyway.
public struct PRCount: Equatable, Codable {
    public let mine: Int
    public let waiting: Int

    public var total: Int { mine + waiting }
    public var isEmpty: Bool { total == 0 }

    public init(mine: Int, waiting: Int) {
        self.mine = mine
        self.waiting = waiting
    }

    /// Derives the badge counts from a repo's full PR list.
    public init(prs: [PRSummary]) {
        var mine = 0
        var waiting = 0
        for pr in prs {
            switch pr.attention {
            case .mine: mine += 1
            case .waiting: waiting += 1
            case .draft: continue
            }
        }
        self.init(mine: mine, waiting: waiting)
    }
}

/// Aggregate GitHub state for a repo at a moment in time.
public struct GitHubRepoStatus: Equatable, Codable {
    public var prs: [PRSummary]
    public var ciStatus: CIStatus
    /// Names of the check-runs whose conclusion put the aggregate into
    /// `.failure`. Useful for the detail popover so the user knows
    /// *which* check broke (e.g. "lint" vs. "test"), since GitHub's
    /// Actions tab only shows workflow runs and may hide third-party
    /// app checks that nevertheless fail the aggregate.
    public var failingCheckNames: [String]
    public var ciTargetSHA: String?
    public var fetchedAt: Date

    /// Badge counts derived from `prs`. Drafts excluded.
    public var prCount: PRCount { PRCount(prs: prs) }
    public var hasOpenPRs: Bool { !prCount.isEmpty }

    public init(
        prs: [PRSummary] = [],
        ciStatus: CIStatus = .none,
        failingCheckNames: [String] = [],
        ciTargetSHA: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.prs = prs
        self.ciStatus = ciStatus
        self.failingCheckNames = failingCheckNames
        self.ciTargetSHA = ciTargetSHA
        self.fetchedAt = fetchedAt
    }

    // Custom decoder so adding/renaming a field doesn't invalidate cache
    // files written by older versions — missing keys fall back to the
    // type's default rather than nuking the entry. `prs` replaced the old
    // `prCount: {humans, bots}` key; old cache files simply lose their
    // stale PR data for one refresh cycle instead of failing to decode.
    enum CodingKeys: String, CodingKey {
        case prs, ciStatus, failingCheckNames, ciTargetSHA, fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.prs = try c.decodeIfPresent([PRSummary].self, forKey: .prs) ?? []
        self.ciStatus = try c.decodeIfPresent(CIStatus.self, forKey: .ciStatus) ?? .none
        self.failingCheckNames = try c.decodeIfPresent([String].self, forKey: .failingCheckNames) ?? []
        self.ciTargetSHA = try c.decodeIfPresent(String.self, forKey: .ciTargetSHA)
        self.fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
    }
}

// MARK: - Classifier

/// Pure "whose turn is it" logic for one PR — no networking, fully
/// testable. Kept separate from the GraphQL decoding so the rules can be
/// pinned in tests without a fixture round-trip.
public enum PRClassifier {
    /// Raw facts pulled from GraphQL for one PR — everything `classify`
    /// needs and nothing it has to re-derive.
    public struct Facts: Equatable {
        public var authorLogin: String
        public var authorIsBot: Bool
        public var isDraft: Bool
        /// REVIEW_REQUIRED | CHANGES_REQUESTED | APPROVED | nil
        public var reviewDecision: String?
        public var requestedUserLogins: [String]
        /// Any Team in `reviewRequests` — counted as "mine" deliberately.
        /// We can't cheaply know the viewer's team memberships; a false
        /// positive here beats a missed review.
        public var teamReviewRequested: Bool
        /// APPROVED | CHANGES_REQUESTED | COMMENTED | nil
        public var myLatestReviewState: String?
        public var myLatestReviewAt: Date?
        public var lastCommitAt: Date?
        /// statusCheckRollup.state: SUCCESS|FAILURE|ERROR|PENDING|EXPECTED|nil
        public var ciState: String?

        public init(
            authorLogin: String,
            authorIsBot: Bool = false,
            isDraft: Bool = false,
            reviewDecision: String? = nil,
            requestedUserLogins: [String] = [],
            teamReviewRequested: Bool = false,
            myLatestReviewState: String? = nil,
            myLatestReviewAt: Date? = nil,
            lastCommitAt: Date? = nil,
            ciState: String? = nil
        ) {
            self.authorLogin = authorLogin
            self.authorIsBot = authorIsBot
            self.isDraft = isDraft
            self.reviewDecision = reviewDecision
            self.requestedUserLogins = requestedUserLogins
            self.teamReviewRequested = teamReviewRequested
            self.myLatestReviewState = myLatestReviewState
            self.myLatestReviewAt = myLatestReviewAt
            self.lastCommitAt = lastCommitAt
            self.ciState = ciState
        }
    }

    /// `viewer` is compared case-insensitively throughout — GitHub logins
    /// are case-insensitive but GraphQL returns them as typed.
    public static func classify(_ f: Facts, viewer: String) -> PRAttention {
        if f.isDraft { return .draft }

        let viewerLC = viewer.lowercased()
        if f.authorLogin.lowercased() == viewerLC {
            // My own PR.
            if f.reviewDecision == "CHANGES_REQUESTED" {
                return .mine(.changesRequestedOnMine)
            }
            if f.ciState == "FAILURE" || f.ciState == "ERROR" {
                return .mine(.ciFailingOnMine)
            }
            if f.reviewDecision == "APPROVED" {
                return .mine(.approvedReadyToMerge)
            }
            return .waiting(.awaitingReview)
        }

        // Someone else's PR.
        let requested = f.requestedUserLogins.contains { $0.lowercased() == viewerLC }
        if requested || f.teamReviewRequested {
            return .mine(.reviewRequested)
        }
        if let reviewedAt = f.myLatestReviewAt,
           let lastCommit = f.lastCommitAt,
           lastCommit > reviewedAt {
            return .mine(.newCommitsSinceReview)
        }
        if f.myLatestReviewAt != nil {
            return .waiting(.waitingOnAuthor)
        }
        if f.authorIsBot {
            return .waiting(.bot)
        }
        return .waiting(.notInvolved)
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
            DiagnosticsLog.shared.warning("github", "gh \(args.joined(separator: " ")): pipe drain timed out")
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
                DiagnosticsLog.shared.warning("github", "gh api \(endpoint) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: result.stdout)
        } catch {
            DiagnosticsLog.shared.warning("github", "gh api \(endpoint) decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Runs `gh api graphql -f query=<query> -F key=value ...` and decodes
    /// stdout into `T`. Unlike `api()`, does NOT convert snake_case — GraphQL
    /// field names are camelCase already — and uses ISO-8601 dates, since
    /// that's what GraphQL's `DateTime` scalar serializes to. Logs failures
    /// the same way `api()` does.
    public static func graphql<T: Decodable>(query: String, variables: [String: String], as: T.Type) -> T? {
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (key, value) in variables {
            args.append("-F")
            args.append("\(key)=\(value)")
        }
        let result = execute(args)
        guard result.isSuccess else {
            if !result.stderr.isEmpty,
               let text = String(data: result.stderr, encoding: .utf8) {
                DiagnosticsLog.shared.warning("github", "gh api graphql failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: result.stdout)
        } catch {
            DiagnosticsLog.shared.warning("github", "gh api graphql decode failed: \(error.localizedDescription)")
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
    // MARK: - Pull requests (GraphQL)

    /// Slim decode target for the `fetchPullRequests` GraphQL query —
    /// only the fields `PRClassifier.Facts` needs. Nested to mirror the
    /// query's own nesting so the two stay easy to compare by eye.
    public struct PullRequestsResponse: Decodable {
        public let data: ResponseData

        public struct ResponseData: Decodable {
            public let viewer: Viewer?
            public let repository: Repository?
        }
        public struct Viewer: Decodable {
            public let login: String
        }
        public struct Repository: Decodable {
            public let pullRequests: PullRequestConnection
        }
        public struct PullRequestConnection: Decodable {
            public let nodes: [PullRequestNode]
        }
        public struct PullRequestNode: Decodable {
            public let number: Int
            public let title: String
            public let url: String
            public let isDraft: Bool
            public let updatedAt: Date
            public let author: Author?
            public let reviewDecision: String?
            public let reviewRequests: ReviewRequestConnection
            public let latestReviews: ReviewConnection
            public let commits: CommitConnection
        }
        public struct Author: Decodable {
            public let login: String
            public let __typename: String
        }
        public struct ReviewRequestConnection: Decodable {
            public let nodes: [ReviewRequestNode]
        }
        public struct ReviewRequestNode: Decodable {
            public let requestedReviewer: RequestedReviewer?
        }
        public struct RequestedReviewer: Decodable {
            public let __typename: String
            public let login: String?
            public let slug: String?
        }
        public struct ReviewConnection: Decodable {
            public let nodes: [ReviewSummary]
        }
        public struct ReviewSummary: Decodable {
            public let author: ReviewAuthor?
            public let state: String
            public let submittedAt: Date?
        }
        public struct ReviewAuthor: Decodable {
            public let login: String
        }
        public struct CommitConnection: Decodable {
            public let nodes: [CommitEntry]
        }
        public struct CommitEntry: Decodable {
            public let commit: CommitDetail
        }
        public struct CommitDetail: Decodable {
            public let committedDate: Date
            public let statusCheckRollup: StatusCheckRollup?
        }
        public struct StatusCheckRollup: Decodable {
            public let state: String
        }
    }

    private static let pullRequestsQuery = """
    query($owner:String!,$name:String!){
      viewer { login }
      repository(owner:$owner,name:$name){
        pullRequests(states:OPEN, first:100, orderBy:{field:UPDATED_AT,direction:DESC}){
          nodes {
            number title url isDraft updatedAt
            author { login __typename }
            reviewDecision
            reviewRequests(first:20){ nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } } }
            latestReviews(first:30){ nodes { author { login } state submittedAt } }
            commits(last:1){ nodes { commit { committedDate statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    /// Pure transform from the raw GraphQL response to classified,
    /// display-ready summaries. Split out from `fetchPullRequests` so
    /// tests can feed fixture JSON without shelling out to `gh`.
    public static func summaries(from response: PullRequestsResponse, viewer: String) -> [PRSummary] {
        guard let nodes = response.data.repository?.pullRequests.nodes else { return [] }
        let viewerLC = viewer.lowercased()

        return nodes.map { node in
            let authorLogin = node.author?.login ?? ""
            let authorIsBot = isBotAuthor(
                login: authorLogin.isEmpty ? nil : authorLogin,
                type: node.author?.__typename
            )
            let requestedUserLogins = node.reviewRequests.nodes.compactMap { $0.requestedReviewer?.login }
            let teamReviewRequested = node.reviewRequests.nodes.contains {
                $0.requestedReviewer?.__typename == "Team"
            }
            // "My latest review" = the most recent non-pending, non-dismissed
            // review authored by the viewer.
            let myReviews = node.latestReviews.nodes.filter {
                $0.author?.login.lowercased() == viewerLC
                    && $0.state != "PENDING" && $0.state != "DISMISSED"
            }
            let myReview = myReviews.max { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }
            let lastCommitAt = node.commits.nodes.first?.commit.committedDate
            let ciState = node.commits.nodes.first?.commit.statusCheckRollup?.state

            let facts = PRClassifier.Facts(
                authorLogin: authorLogin,
                authorIsBot: authorIsBot,
                isDraft: node.isDraft,
                reviewDecision: node.reviewDecision,
                requestedUserLogins: requestedUserLogins,
                teamReviewRequested: teamReviewRequested,
                myLatestReviewState: myReview?.state,
                myLatestReviewAt: myReview?.submittedAt,
                lastCommitAt: lastCommitAt,
                ciState: ciState
            )

            return PRSummary(
                number: node.number,
                title: node.title,
                url: node.url,
                authorLogin: authorLogin,
                isBotAuthor: authorIsBot,
                isDraft: node.isDraft,
                attention: PRClassifier.classify(facts, viewer: viewer),
                updatedAt: node.updatedAt
            )
        }
    }

    /// Fetches every open PR for a repo, classified against the
    /// authenticated `gh` user. `first:100` covers any realistic repo in
    /// one call; returns nil on any failure (auth, decode, network) or
    /// when `repository` comes back null (no access to the repo).
    public static func fetchPullRequests(for remote: GitHubRemote) -> [PRSummary]? {
        let variables = ["owner": remote.owner, "name": remote.repo]
        guard let response = GHService.graphql(query: pullRequestsQuery, variables: variables, as: PullRequestsResponse.self),
              response.data.repository != nil else {
            return nil
        }
        let viewer = response.data.viewer?.login ?? ""
        return summaries(from: response, viewer: viewer)
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
