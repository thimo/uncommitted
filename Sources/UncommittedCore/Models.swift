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
        self.lastActivityDate = lastActivityDate
    }

    /// Number of working-tree files with changes (staged + unstaged + untracked).
    public var totalUncommitted: Int { staged + unstaged + untracked }
    /// Number of commits ahead of the upstream (unpushed).
    public var totalUnpushed: Int { ahead }
    /// Total "dirty" count for compatibility — uncommitted files + unpushed commits.
    public var totalDirty: Int { totalUncommitted + totalUnpushed }
    public var isClean: Bool { totalDirty == 0 && behind == 0 }

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
