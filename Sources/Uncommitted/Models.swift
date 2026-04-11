import Foundation

struct Repo: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var status: RepoStatus?

    var name: String { url.lastPathComponent }
}

struct RepoStatus: Equatable {
    /// Current branch name, or "(detached)" when HEAD is detached.
    var branch: String
    /// Full HEAD object id (porcelain=v2 `branch.oid`), or nil if unavailable.
    var headOid: String?
    var ahead: Int
    var behind: Int
    var staged: Int
    var unstaged: Int
    var untracked: Int

    /// Number of working-tree files with changes (staged + unstaged + untracked).
    var totalUncommitted: Int { staged + unstaged + untracked }
    /// Number of commits ahead of the upstream (unpushed).
    var totalUnpushed: Int { ahead }
    /// Total "dirty" count for compatibility — uncommitted files + unpushed commits.
    var totalDirty: Int { totalUncommitted + totalUnpushed }
    var isClean: Bool { totalDirty == 0 && behind == 0 }

    var isDetached: Bool { branch == "(detached)" }

    /// Friendly branch label for UI — replaces "(detached)" with short SHA.
    var displayBranch: String {
        guard isDetached else { return branch }
        if let oid = headOid, oid.count >= 7 {
            return "detached · \(oid.prefix(7))"
        }
        return "detached"
    }
}
