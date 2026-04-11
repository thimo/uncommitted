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
    public var staged: Int
    public var unstaged: Int
    public var untracked: Int

    public init(
        branch: String,
        headOid: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        staged: Int = 0,
        unstaged: Int = 0,
        untracked: Int = 0
    ) {
        self.branch = branch
        self.headOid = headOid
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
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
