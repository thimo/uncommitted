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

/// One open issue, already classified against the viewer. `authorLogin` is
/// "" for a deleted GitHub account (the API returns a null author).
public struct IssueSummary: Equatable, Codable, Identifiable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let url: String
    public let authorLogin: String
    /// Whether the viewer is among the issue's assignees, compared
    /// case-insensitively — GitHub logins are case-insensitive but
    /// GraphQL returns them as typed.
    public let isAssignedToMe: Bool
    /// Nobody is assigned, on a live repo the viewer runs (admin or
    /// maintainer — see `GitHubAPI.viewerCanAct`). Nobody else is going
    /// to pick it up, so it counts as the viewer's. Always false
    /// elsewhere — 900 unassigned issues on someone else's project
    /// aren't the viewer's job.
    public let isUnclaimed: Bool
    /// Pink in the UI; everything else (assigned to somebody else, or
    /// open on a repo the viewer doesn't maintain) is grey.
    public var needsMe: Bool { isAssignedToMe || isUnclaimed }
    /// Whether the viewer opened the issue (same case-insensitive
    /// compare). Lets the hover panel drop the "@author" caption when
    /// it would only tell the viewer their own name.
    public let isAuthoredByMe: Bool
    public let updatedAt: Date
    /// Label names attached to the issue, exactly as typed on GitHub.
    /// Matched against `Config.gitHubIgnoredIssueLabel` at the point of
    /// use (`isIgnored(label:)`) rather than baked into a stored flag —
    /// ignoring is a display-time decision driven by config, not fetched
    /// state.
    public let labels: [String]

    public init(
        number: Int,
        title: String,
        url: String,
        authorLogin: String,
        isAssignedToMe: Bool,
        isUnclaimed: Bool = false,
        isAuthoredByMe: Bool = false,
        updatedAt: Date,
        labels: [String] = []
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.authorLogin = authorLogin
        self.isAssignedToMe = isAssignedToMe
        self.isUnclaimed = isUnclaimed
        self.isAuthoredByMe = isAuthoredByMe
        self.updatedAt = updatedAt
        self.labels = labels
    }

    // Custom decoder, same philosophy as `GitHubRepoStatus`'s: the on-disk
    // cache (`github-status.json`) already holds issues written before
    // `labels` existed. A synthesized decoder throws on a missing key
    // with no default, and the scheduler wraps its whole cache load in
    // `try?` — one issue missing `labels` would silently discard every
    // repo's cached GitHub status, not just this field.
    enum CodingKeys: String, CodingKey {
        case number, title, url, authorLogin, isAssignedToMe, isUnclaimed, isAuthoredByMe, updatedAt, labels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.number = try c.decode(Int.self, forKey: .number)
        self.title = try c.decode(String.self, forKey: .title)
        self.url = try c.decode(String.self, forKey: .url)
        self.authorLogin = try c.decode(String.self, forKey: .authorLogin)
        self.isAssignedToMe = try c.decode(Bool.self, forKey: .isAssignedToMe)
        self.isUnclaimed = try c.decodeIfPresent(Bool.self, forKey: .isUnclaimed) ?? false
        self.isAuthoredByMe = try c.decodeIfPresent(Bool.self, forKey: .isAuthoredByMe) ?? false
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
    }

    /// Whether this issue carries `label`, compared case-insensitively
    /// after trimming whitespace off both sides. An empty (or
    /// whitespace-only) label means the ignore feature is off, so
    /// nothing ever matches — callers don't need a separate "is the
    /// feature enabled" check.
    public func isIgnored(label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return labels.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}

/// Open issue breakdown for one repo's badge: how many need the viewer
/// (assigned to them, or unclaimed on a repo they maintain), how many
/// are somebody else's, and how many are ignored via the configured
/// label. Analogous to `PRCount`.
public struct IssueCount: Equatable {
    public let mine: Int
    public let other: Int
    /// Listed issues carrying the ignored label. Counted separately so a
    /// repo whose only open issues are ignored still reads as "nothing
    /// to do" — see `total`/`isEmpty`.
    public let ignored: Int

    /// Deliberately excludes `ignored`: a repo whose only open issues
    /// carry the ignored label has no badge, is allowed the green
    /// all-clear checkmark, and doesn't stay visible under "hide clean
    /// repos" — same treatment as if those issues didn't exist.
    public var total: Int { mine + other }
    public var isEmpty: Bool { total == 0 }

    public init(mine: Int, other: Int, ignored: Int = 0) {
        self.mine = mine
        self.other = other
        self.ignored = ignored
    }

    /// Derives the badge counts from a repo's fetched issue list plus the
    /// GraphQL total open count, filtering out anything matching
    /// `ignoringLabel` (case-insensitive, trimmed; empty label turns the
    /// filter off — see `IssueSummary.isIgnored(label:)`). Ignored wins
    /// over everything: an issue that's assigned to the viewer (or
    /// unclaimed) and carries the ignored label counts as ignored.
    ///
    /// `totalOpen`, `unclaimedOpen` and `exactIgnored` are GraphQL totals
    /// and can exceed what `issues` shows — we only ever list the 50 most
    /// recently updated issues, and parked issues are exactly the ones
    /// nobody touches, so on a big repo most of them fall outside that
    /// window. The listed rows act as a floor under each total, so a
    /// caller without totals (or a cache from before they existed) still
    /// gets counts that agree with the rows on screen. Known limit:
    /// "assigned to me" only sees the listed 50.
    public init(
        issues: [IssueSummary],
        totalOpen: Int,
        unclaimedOpen: Int = 0,
        exactIgnored: ExactIgnoredIssueCounts? = nil,
        ignoringLabel label: String
    ) {
        var assignedToMe = 0
        var unclaimedListed = 0
        var ignoredListed = 0
        var ignoredUnclaimedListed = 0
        for issue in issues {
            if issue.isIgnored(label: label) {
                ignoredListed += 1
                if issue.isUnclaimed { ignoredUnclaimedListed += 1 }
            } else if issue.isAssignedToMe {
                assignedToMe += 1
            } else if issue.isUnclaimed {
                unclaimedListed += 1
            }
        }
        let ignored = max(ignoredListed, exactIgnored?.total ?? 0)
        let ignoredUnclaimed = max(ignoredUnclaimedListed, exactIgnored?.unclaimed ?? 0)
        let mine = assignedToMe + max(unclaimedListed, unclaimedOpen - ignoredUnclaimed)
        self.mine = mine
        self.ignored = ignored
        self.other = max(0, totalOpen - mine - ignored)
    }
}

/// Exact GraphQL counts of open issues carrying the ignored label, plus
/// the label they were counted for. Ignoring is otherwise a display-time
/// decision, but these come from the server, so they're only valid while
/// the configured label still matches — `GitHubRepoStatus` checks that
/// and falls back to the listed rows until the next refresh.
public struct ExactIgnoredIssueCounts: Equatable, Codable {
    public let label: String
    public let total: Int
    /// Of those, the ones nobody is assigned to on a repo the viewer can
    /// act on — what has to come off `unclaimedIssueCount`.
    public let unclaimed: Int

    public init(label: String, total: Int, unclaimed: Int) {
        self.label = label
        self.total = total
        self.unclaimed = unclaimed
    }
}

/// Aggregate GitHub state for a repo at a moment in time.
public struct GitHubRepoStatus: Equatable, Codable {
    public var prs: [PRSummary]
    public var issues: [IssueSummary]
    public var ciStatus: CIStatus
    /// Names of the check-runs whose conclusion put the aggregate into
    /// `.failure`. Useful for the detail popover so the user knows
    /// *which* check broke (e.g. "lint" vs. "test"), since GitHub's
    /// Actions tab only shows workflow runs and may hide third-party
    /// app checks that nevertheless fail the aggregate.
    public var failingCheckNames: [String]
    public var ciTargetSHA: String?
    public var fetchedAt: Date
    /// `owner/repo` this status was fetched for. Lets the scheduler tell
    /// which repos are clones of the same remote without shelling out to
    /// `git remote get-url` on the main thread — PR signals are shown on
    /// one clone per slug, not on every clone.
    public var slug: String?
    /// Total open issues on the remote, from GraphQL's `totalCount` —
    /// can exceed `issues.count` since only the 50 most recently updated
    /// are fetched. Drives `issueCount.other` and the hover panel's
    /// "+N more" line.
    public var openIssueCount: Int
    /// How many of those nobody is assigned to — exact, from its own
    /// GraphQL count — on a repo the viewer can act on. 0 on a repo the
    /// viewer only reads; see `IssueSummary.isUnclaimed`.
    public var unclaimedIssueCount: Int
    /// Server-side counts for the ignored label; nil when no label was
    /// configured at fetch time (or the cache predates this).
    public var exactIgnoredIssues: ExactIgnoredIssueCounts?

    /// Badge counts derived from `prs`. Drafts excluded.
    public var prCount: PRCount { PRCount(prs: prs) }
    public var hasOpenPRs: Bool { !prCount.isEmpty }

    /// Badge counts derived from `issues` + `openIssueCount`, filtered
    /// against the configured ignore label. Deliberately a function, not
    /// a computed property like `prCount` — ignoring is config, not
    /// fetched state, so every caller must supply the current label
    /// rather than risk one call site forgetting to filter.
    public func issueCount(ignoringLabel label: String) -> IssueCount {
        // The exact counts belong to the label they were fetched for —
        // right after the user edits it, only the listed rows are valid.
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = exactIgnoredIssues.flatMap {
            $0.label.caseInsensitiveCompare(trimmed) == .orderedSame ? $0 : nil
        }
        return IssueCount(
            issues: issues,
            totalOpen: openIssueCount,
            unclaimedOpen: unclaimedIssueCount,
            exactIgnored: exact,
            ignoringLabel: label
        )
    }

    public func hasOpenIssues(ignoringLabel label: String) -> Bool {
        !issueCount(ignoringLabel: label).isEmpty
    }

    public init(
        prs: [PRSummary] = [],
        issues: [IssueSummary] = [],
        ciStatus: CIStatus = .none,
        failingCheckNames: [String] = [],
        ciTargetSHA: String? = nil,
        fetchedAt: Date = Date(),
        slug: String? = nil,
        openIssueCount: Int = 0,
        unclaimedIssueCount: Int = 0,
        exactIgnoredIssues: ExactIgnoredIssueCounts? = nil
    ) {
        self.prs = prs
        self.issues = issues
        self.ciStatus = ciStatus
        self.failingCheckNames = failingCheckNames
        self.ciTargetSHA = ciTargetSHA
        self.fetchedAt = fetchedAt
        self.slug = slug
        self.openIssueCount = openIssueCount
        self.unclaimedIssueCount = unclaimedIssueCount
        self.exactIgnoredIssues = exactIgnoredIssues
    }

    // Custom decoder so adding/renaming a field doesn't invalidate cache
    // files written by older versions — missing keys fall back to the
    // type's default rather than nuking the entry. `prs` replaced the old
    // `prCount: {humans, bots}` key; old cache files simply lose their
    // stale PR data for one refresh cycle instead of failing to decode.
    enum CodingKeys: String, CodingKey {
        case prs, issues, ciStatus, failingCheckNames, ciTargetSHA, fetchedAt, slug
        case openIssueCount, unclaimedIssueCount, exactIgnoredIssues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.prs = try c.decodeIfPresent([PRSummary].self, forKey: .prs) ?? []
        self.issues = try c.decodeIfPresent([IssueSummary].self, forKey: .issues) ?? []
        self.ciStatus = try c.decodeIfPresent(CIStatus.self, forKey: .ciStatus) ?? .none
        self.failingCheckNames = try c.decodeIfPresent([String].self, forKey: .failingCheckNames) ?? []
        self.ciTargetSHA = try c.decodeIfPresent(String.self, forKey: .ciTargetSHA)
        self.fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
        self.openIssueCount = try c.decodeIfPresent(Int.self, forKey: .openIssueCount) ?? 0
        self.unclaimedIssueCount = try c.decodeIfPresent(Int.self, forKey: .unclaimedIssueCount) ?? 0
        self.exactIgnoredIssues = try c.decodeIfPresent(ExactIgnoredIssueCounts.self, forKey: .exactIgnoredIssues)
    }

    /// Copy with remote-wide GitHub signals removed — what a non-primary
    /// clone of a remote gets to display. PRs and issues both belong to
    /// the remote, not the clone, so showing either on four clones of one
    /// repo would just be the same signal four times over. CI stays,
    /// since that's per branch and each clone may sit on a different one.
    public var withoutRemoteWideSignals: GitHubRepoStatus {
        var copy = withoutIssues
        copy.prs = []
        return copy
    }

    /// Copy with issue data removed — hides issues from the UI while the
    /// user has `showGitHubIssues` turned off. The scheduler stops
    /// requesting them too, but the last fetched set lingers in
    /// `statuses` (and the disk cache) until the next refresh overwrites
    /// it, so the UI can't rely on the data simply being absent.
    public var withoutIssues: GitHubRepoStatus {
        var copy = self
        copy.issues = []
        copy.openIssueCount = 0
        copy.unclaimedIssueCount = 0
        copy.exactIgnoredIssues = nil
        return copy
    }
}

/// Picks one "primary" clone per `owner/repo` slug: the first in the
/// user's repo order. PRs are a property of the remote, so showing the
/// same badge on four clones of one repo is noise — only the primary
/// carries it. Repos without a known slug are all primary (nothing to
/// collapse). Pure so the choice can be pinned in tests.
public enum PrimaryClonePicker {
    public static func primaryURLs(orderedURLs: [URL], slugs: [URL: String]) -> Set<URL> {
        var seen = Set<String>()
        var primary = Set<URL>()
        for url in orderedURLs {
            guard let slug = slugs[url] else {
                primary.insert(url)
                continue
            }
            if seen.insert(slug).inserted {
                primary.insert(url)
            }
        }
        return primary
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

    /// Runs `gh api graphql -f query=<query> -f key=value ...` and decodes
    /// stdout into `T`. Unlike `api()`, does NOT convert snake_case — GraphQL
    /// field names are camelCase already — and uses ISO-8601 dates, since
    /// that's what GraphQL's `DateTime` scalar serializes to. Logs failures
    /// the same way `api()` does.
    ///
    /// String variables go through `-f` (raw), booleans through `-F`
    /// (typed). `-F` on a string would coerce a repo named `2048` or
    /// `true` into an Int/Bool and read `@…` as a file path — GraphQL
    /// then rejects it for a `String!` variable.
    public static func graphql<T: Decodable>(
        query: String,
        variables: [String: String],
        boolVariables: [String: Bool] = [:],
        as: T.Type
    ) -> T? {
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (key, value) in variables {
            args.append("-f")
            args.append("\(key)=\(value)")
        }
        for (key, value) in boolVariables {
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

    /// Slim decode target for the `fetchRepoSignals` GraphQL query —
    /// only the fields `PRClassifier.Facts` (and the issue summaries)
    /// need. Nested to mirror the query's own nesting so the two stay
    /// easy to compare by eye.
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
            /// Optional so a fixture or cached response captured before
            /// issues were fetched still decodes — synthesized
            /// `Decodable` treats a missing or null key on an `Optional`
            /// property as `nil` rather than throwing.
            public let issues: IssueConnection?
            /// ADMIN | MAINTAIN | WRITE | TRIAGE | READ | nil
            public let viewerPermission: String?
            /// Exact count of open issues with no assignee — its own
            /// connection because the listed 50 can't say how many more
            /// there are.
            public let unassignedIssues: CountOnly?
            public let isArchived: Bool?
            /// Open issues carrying the configured ignored label, and the
            /// unassigned ones among them. Absent when no label is set.
            public let ignoredIssues: CountOnly?
            public let ignoredUnassignedIssues: CountOnly?
        }
        public struct CountOnly: Decodable {
            public let totalCount: Int
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
        public struct IssueConnection: Decodable {
            /// GraphQL total, not just what `nodes` carries — the query
            /// only fetches the 50 most recently updated issues.
            public let totalCount: Int
            public let nodes: [IssueNode]
        }
        public struct IssueNode: Decodable {
            public let number: Int
            public let title: String
            public let url: String
            public let updatedAt: Date
            public let author: Author?
            public let assignees: AssigneeConnection
            /// Optional for the same reason `Repository.issues` is — an
            /// older fixture or cached response predating labels still
            /// decodes, with an empty label list.
            public let labels: LabelConnection?
        }
        public struct AssigneeConnection: Decodable {
            public let nodes: [Assignee]
        }
        public struct Assignee: Decodable {
            public let login: String
        }
        public struct LabelConnection: Decodable {
            public let nodes: [LabelNode]
        }
        public struct LabelNode: Decodable {
            public let name: String
        }
    }

    private static let pullRequestsQuery = """
    query($owner:String!,$name:String!,$includeIssues:Boolean!,$ignoredLabel:String!,$countIgnored:Boolean!){
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
        issues(states:OPEN, first:50, orderBy:{field:UPDATED_AT,direction:DESC}) @include(if:$includeIssues){
          totalCount
          nodes {
            number title url updatedAt
            author { login __typename }
            assignees(first:10){ nodes { login } }
            labels(first:20){ nodes { name } }
          }
        }
        viewerPermission
        isArchived
        unassignedIssues: issues(states:OPEN, filterBy:{assignee:null}) @include(if:$includeIssues){ totalCount }
        ignoredIssues: issues(states:OPEN, filterBy:{labels:[$ignoredLabel]}) @include(if:$countIgnored){ totalCount }
        ignoredUnassignedIssues: issues(states:OPEN, filterBy:{labels:[$ignoredLabel], assignee:null}) @include(if:$countIgnored){ totalCount }
      }
    }
    """

    /// Pure transform from the raw GraphQL response to classified,
    /// display-ready summaries. Split out from `fetchRepoSignals` so
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

    /// Pure transform from the raw GraphQL response to classified issue
    /// summaries. Split out like `summaries(from:viewer:)` so tests can
    /// feed fixture JSON without shelling out to `gh`.
    public static func issueSummaries(from response: PullRequestsResponse, viewer: String) -> [IssueSummary] {
        guard let nodes = response.data.repository?.issues?.nodes else { return [] }
        let viewerLC = viewer.lowercased()
        let canAct = viewerCanAct(in: response.data.repository)

        return nodes.map { node in
            let authorLogin = node.author?.login ?? ""
            let isAssignedToMe = node.assignees.nodes.contains { $0.login.lowercased() == viewerLC }
            let isUnclaimed = canAct && node.assignees.nodes.isEmpty
            let labels = node.labels?.nodes.map(\.name) ?? []
            return IssueSummary(
                number: node.number,
                title: node.title,
                url: node.url,
                authorLogin: authorLogin,
                isAssignedToMe: isAssignedToMe,
                isUnclaimed: isUnclaimed,
                isAuthoredByMe: !viewerLC.isEmpty && authorLogin.lowercased() == viewerLC,
                updatedAt: node.updatedAt,
                labels: labels
            )
        }
    }

    /// Whether an unassigned issue on this repo is the viewer's to deal
    /// with: they run the repo (admin or maintainer) and it's live. The
    /// bar is deliberately above write access — on a team repo forty
    /// people have that, and "nobody's assigned" then means "somebody
    /// else might", not "yours". An archived repo's leftovers need no
    /// one. The one gate for both the per-row flag and the counts.
    public static func viewerCanAct(onRepoWithPermission permission: String?, isArchived: Bool = false) -> Bool {
        guard !isArchived else { return false }
        switch permission {
        case "ADMIN", "MAINTAIN": return true
        default: return false
        }
    }

    private static func viewerCanAct(in repository: PullRequestsResponse.Repository?) -> Bool {
        viewerCanAct(
            onRepoWithPermission: repository?.viewerPermission,
            isArchived: repository?.isArchived ?? false
        )
    }

    /// PRs and issues fetched together from one GraphQL call, so the
    /// scheduler can apply both without a second network round trip.
    public struct RepoSignals {
        public let prs: [PRSummary]
        public let issues: [IssueSummary]
        public let openIssueCount: Int
        public let unclaimedIssueCount: Int
        public let exactIgnoredIssues: ExactIgnoredIssueCounts?
    }

    /// Pure transform from the raw response to everything the scheduler
    /// stores — split from `fetchRepoSignals` so the count gating can be
    /// pinned with fixture JSON.
    public static func signals(from response: PullRequestsResponse, ignoredLabel: String) -> RepoSignals {
        let viewer = response.data.viewer?.login ?? ""
        let repository = response.data.repository
        let canAct = viewerCanAct(in: repository)
        let exactIgnored = repository?.ignoredIssues.map { ignored in
            ExactIgnoredIssueCounts(
                label: ignoredLabel,
                total: ignored.totalCount,
                unclaimed: canAct ? (repository?.ignoredUnassignedIssues?.totalCount ?? 0) : 0
            )
        }
        return RepoSignals(
            prs: summaries(from: response, viewer: viewer),
            issues: issueSummaries(from: response, viewer: viewer),
            openIssueCount: repository?.issues?.totalCount ?? 0,
            unclaimedIssueCount: canAct ? (repository?.unassignedIssues?.totalCount ?? 0) : 0,
            exactIgnoredIssues: exactIgnored
        )
    }

    /// Fetches every open PR and issue for a repo, classified against the
    /// authenticated `gh` user. `first:100`/`first:50` cover any realistic
    /// repo in one call; returns nil on any failure (auth, decode,
    /// network) or when `repository` comes back null (no access to the
    /// repo).
    ///
    /// `includeIssues: false` drops the issues connection from the query
    /// via `@include` — no wasted payload for a user who turned issues
    /// off, and an escape hatch when a token can read PRs but not issues
    /// (an error on `issues` would otherwise take the PR data down with
    /// it, since both ride one call).
    ///
    /// `ignoredLabel` (the configured one, may be empty) lets GitHub
    /// count the parked issues exactly. They're the ones nobody touches,
    /// so on a repo with more than 50 open issues most of them sit
    /// outside the listed window and can't be counted client-side.
    public static func fetchRepoSignals(
        for remote: GitHubRemote,
        includeIssues: Bool = true,
        ignoredLabel: String = ""
    ) -> RepoSignals? {
        let label = ignoredLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let variables = ["owner": remote.owner, "name": remote.repo, "ignoredLabel": label]
        guard let response = GHService.graphql(
                  query: pullRequestsQuery,
                  variables: variables,
                  boolVariables: [
                      "includeIssues": includeIssues,
                      "countIgnored": includeIssues && !label.isEmpty,
                  ],
                  as: PullRequestsResponse.self
              ),
              response.data.repository != nil else {
            return nil
        }
        return signals(from: response, ignoredLabel: label)
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
