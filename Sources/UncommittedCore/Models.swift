import Foundation

public struct Repo: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public var status: RepoStatus?

    public var name: String { url.lastPathComponent }

    public init(id: UUID, url: URL, status: RepoStatus? = nil) {
        self.id = id
        self.url = url
        self.status = status
    }
}

/// Per-branch divergence for a single local branch that tracks an upstream.
/// Populated by `GitService.branchStatuses` from one `git for-each-ref` call.
/// Only branches with an upstream are represented — a branch with nothing to
/// pull or push against isn't actionable here.
public struct BranchStatus: Equatable {
    /// Local branch short name (e.g. "main", "release/0.8").
    public let name: String
    /// Upstream short name (e.g. "origin/main"). Empty if the upstream ref is
    /// gone (deleted on the remote) — see `isGone`.
    public let upstream: String
    /// Commits the local branch has that the upstream doesn't (unpushed).
    public let ahead: Int
    /// Commits the upstream has that the local branch doesn't (to pull).
    public let behind: Int
    /// True for the currently checked-out branch. The "Other branches" panel
    /// section filters this one out — it's already shown in the detail block.
    public let isCurrent: Bool
    /// True when the tracked upstream no longer exists on the remote
    /// (`for-each-ref` reports "gone"). Nothing to pull/push cleanly.
    public let isGone: Bool

    public init(
        name: String,
        upstream: String,
        ahead: Int,
        behind: Int,
        isCurrent: Bool,
        isGone: Bool = false
    ) {
        self.name = name
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isCurrent = isCurrent
        self.isGone = isGone
    }

    /// Both sides have moved — can't be reconciled by a fast-forward, so
    /// neither the pull nor the push button applies. Rendered greyed out.
    public var isDiverged: Bool { ahead > 0 && behind > 0 }
    /// Behind only — `git fetch <remote> <branch>:<branch>` fast-forwards it.
    public var isFastForwardable: Bool { behind > 0 && ahead == 0 && !isGone }
    /// Ahead only — a plain `git push` publishes it.
    public var isPushable: Bool { ahead > 0 && behind == 0 && !isGone }

    /// Remote name from the upstream short ref ("origin/main" → "origin").
    /// Remote names can't contain "/", so the first segment is the remote and
    /// everything after is the (possibly slashed) branch.
    public var remoteName: String {
        String(upstream.prefix(while: { $0 != "/" }))
    }

    /// Remote-side branch name ("origin/release/0.8" → "release/0.8"). Empty
    /// when the upstream has no "/" (shouldn't happen for a real upstream).
    public var remoteBranch: String {
        guard let slash = upstream.firstIndex(of: "/") else { return "" }
        return String(upstream[upstream.index(after: slash)...])
    }
}

public struct RepoStatus: Equatable {
    /// Current branch name, or "(detached)" when HEAD is detached.
    public var branch: String
    /// Full HEAD object id (porcelain=v2 `branch.oid`), or nil if unavailable.
    public var headOid: String?
    public var ahead: Int
    public var behind: Int
    /// Repo-relative paths for each file state. Populated by the porcelain=v2
    /// parser; the `staged` / `unstaged` / `untracked` counts are computed
    /// from these so they can never drift from the paths themselves.
    public var stagedPaths: [String]
    public var unstagedPaths: [String]
    public var untrackedPaths: [String]
    /// Commit subjects (first line only) for ahead/behind commits, newest
    /// first. Populated by an extra `git log` call after parsing; empty
    /// when there's no upstream divergence.
    public var aheadCommits: [String]
    public var behindCommits: [String]
    /// Every local branch that tracks an upstream, including the current one.
    /// Drives the "Other branches" panel section (which filters out the
    /// current branch). Populated by `GitService.status`, not by `parse`.
    public var branches: [BranchStatus]
    /// Most recent timestamp of *local* activity on this repo — the newest
    /// working-tree file modification or, if newer, the newest unpushed
    /// commit. Pull-only "behind" state is excluded: that's remote work, not
    /// the user's. nil when nothing is pending or no timestamp could be read.
    /// Set by `GitService.status`, not by `parse`. The time since this is how
    /// long the pending work has gone untouched — drives the "stale" age
    /// suffix. We track the *newest* change (not the oldest) so a repo the
    /// user is actively editing never reads as abandoned just because it
    /// holds one old file.
    public var lastActivityDate: Date?

    public var staged: Int { stagedPaths.count }
    public var unstaged: Int { unstagedPaths.count }
    public var untracked: Int { untrackedPaths.count }

    public init(
        branch: String,
        headOid: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        stagedPaths: [String] = [],
        unstagedPaths: [String] = [],
        untrackedPaths: [String] = [],
        aheadCommits: [String] = [],
        behindCommits: [String] = [],
        branches: [BranchStatus] = [],
        lastActivityDate: Date? = nil
    ) {
        self.branch = branch
        self.headOid = headOid
        self.ahead = ahead
        self.behind = behind
        self.stagedPaths = stagedPaths
        self.unstagedPaths = unstagedPaths
        self.untrackedPaths = untrackedPaths
        self.aheadCommits = aheadCommits
        self.behindCommits = behindCommits
        self.branches = branches
        self.lastActivityDate = lastActivityDate
    }

    /// Number of working-tree files with changes (staged + unstaged + untracked).
    public var totalUncommitted: Int { staged + unstaged + untracked }
    /// Number of commits ahead of the upstream (unpushed).
    public var totalUnpushed: Int { ahead }
    /// Total "dirty" count for compatibility — uncommitted files + unpushed commits.
    public var totalDirty: Int { totalUncommitted + totalUnpushed }
    public var isClean: Bool { totalDirty == 0 && behind == 0 }

    /// Branches for the "Other branches" panel section: every tracking branch
    /// except the checked-out one, that has actual divergence to act on. Gone
    /// upstreams are dropped (nothing to pull/push cleanly).
    public var otherBranches: [BranchStatus] {
        branches.filter { !$0.isCurrent && !$0.isGone && ($0.ahead > 0 || $0.behind > 0) }
    }

    public var isDetached: Bool { branch == "(detached)" }

    /// Friendly branch label for UI — replaces "(detached)" with short SHA.
    public var displayBranch: String {
        guard isDetached else { return branch }
        if let oid = headOid, oid.count >= 7 {
            return "detached · \(oid.prefix(7))"
        }
        return "detached"
    }
}

/// Age formatting for the "stale work" nudge. A repo carrying uncommitted
/// or unpushed work past the configured threshold gets a compact age suffix
/// (e.g. "11d", "3w") in the popup; the hover panel spells the same value
/// out in full ("11 days"). Both render off one computed `Age` so the row
/// and the panel can never disagree on the unit.
public enum Staleness {
    public enum Unit {
        /// Under a minute — rendered without a number ("now" / "just now")
        /// so a freshly-touched repo never reads "0m" / "0 minutes".
        case justNow
        case minute, hour, day, week, month, year

        var shortSuffix: String {
            switch self {
            case .justNow: return ""
            case .minute:  return "m"
            case .hour:    return "h"
            case .day:     return "d"
            case .week:    return "w"
            case .month:   return "mo"
            case .year:    return "y"
            }
        }

        var longName: String {
            switch self {
            case .justNow: return ""
            case .minute:  return "minute"
            case .hour:    return "hour"
            case .day:     return "day"
            case .week:    return "week"
            case .month:   return "month"
            case .year:    return "year"
            }
        }
    }

    public struct Age {
        public let value: Int
        public let unit: Unit

        /// Row suffix form: "now", "10d", "3w", "5mo".
        public var compact: String {
            unit == .justNow ? "now" : "\(value)\(unit.shortSuffix)"
        }
        /// Panel form: "just now", "10 days", "1 week", "5 months".
        public var full: String {
            unit == .justNow ? "just now" : "\(value) \(unit.longName)\(value == 1 ? "" : "s")"
        }
        /// Past-tense phrase for the panel: "just now", "10 days ago".
        public var ago: String {
            unit == .justNow ? "just now" : "\(full) ago"
        }
    }

    private static let minute = 60.0
    private static let hour = 3_600.0
    private static let day = 86_400.0
    private static let twoWeeks = 14 * day
    private static let month = 30 * day
    private static let year = 365 * day

    /// Single-unit age rounded down to whole units. Days stay days up to a
    /// fortnight ("7d"…"13d") before switching to weeks, then months/years.
    /// Falls back to hours/minutes for very recent times, which the threshold
    /// normally keeps off-screen anyway.
    public static func age(since date: Date, now: Date = Date()) -> Age {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case year...:     return Age(value: Int(seconds / year), unit: .year)
        case month...:    return Age(value: Int(seconds / month), unit: .month)
        case twoWeeks...: return Age(value: Int(seconds / (7 * day)), unit: .week)
        case day...:      return Age(value: Int(seconds / day), unit: .day)
        case hour...:     return Age(value: Int(seconds / hour), unit: .hour)
        case minute...:   return Age(value: Int(seconds / minute), unit: .minute)
        default:          return Age(value: 0, unit: .justNow)
        }
    }
}
