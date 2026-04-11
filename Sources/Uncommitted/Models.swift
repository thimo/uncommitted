import Foundation

struct Repo: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var status: RepoStatus?

    var name: String { url.lastPathComponent }
}

struct RepoStatus: Equatable {
    var branch: String
    var ahead: Int
    var behind: Int
    var staged: Int
    var unstaged: Int
    var untracked: Int

    var totalDirty: Int { ahead + staged + unstaged + untracked }
    var isClean: Bool { totalDirty == 0 && behind == 0 }
}
