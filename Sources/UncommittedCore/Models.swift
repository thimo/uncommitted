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
        behindCommits: [String] = []
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
