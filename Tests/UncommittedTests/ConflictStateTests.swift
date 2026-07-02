import Foundation
import UncommittedCore

enum ConflictStateTests {
    /// Fresh temp repo-shaped directory (no real git needed — the
    /// operation detection is pure filesystem).
    private static func makeTempRepo(gitIsDirectory: Bool = true) throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncommitted-conflict-tests-\(UUID().uuidString)")
        let gitDir = repo.appendingPathComponent(".git")
        if gitIsDirectory {
            try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        }
        return repo
    }

    private static func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    static func register() {
        // MARK: - porcelain `u` lines

        test("ConflictParser/unmergedLine_landsInConflictedOnly") {
            let output = """
            # branch.oid 1111111111111111111111111111111111111111
            # branch.head main
            u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc src/routes.ts
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.conflictedPaths, ["src/routes.ts"])
            try expectEqual(status.staged, 0)
            try expectEqual(status.unstaged, 0)
            try expectEqual(status.deleted, 0)
            try expectEqual(status.totalUncommitted, 1)
            try expect(!status.isClean)
        }

        test("ConflictParser/unmergedPathWithSpaces_staysIntact") {
            let output = """
            # branch.oid 1111111111111111111111111111111111111111
            # branch.head main
            u AA N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc My Notes/todo list.md
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.conflictedPaths, ["My Notes/todo list.md"])
        }

        test("ConflictParser/mixedOutput_conflictsAndRegularChangesCoexist") {
            let output = """
            # branch.oid 1111111111111111111111111111111111111111
            # branch.head feature
            1 .M N... 100644 100644 100644 aaaaaaa aaaaaaa README.md
            u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc merge-me.swift
            ? scratch.txt
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.conflictedPaths, ["merge-me.swift"])
            try expectEqual(status.unstagedPaths, ["README.md"])
            try expectEqual(status.untrackedPaths, ["scratch.txt"])
            try expectEqual(status.totalUncommitted, 3)
        }

        test("ConflictParser/malformedUnmergedLine_isIgnored") {
            let output = """
            # branch.oid 1111111111111111111111111111111111111111
            u UU N... 100644
            """
            let status = try requireNotNil(GitService.parse(output))
            try expect(status.conflictedPaths.isEmpty)
        }

        // MARK: - git dir resolution

        test("GitDirectory/plainClone_returnsDotGit") {
            let repo = try makeTempRepo()
            let dir = try requireNotNil(GitService.gitDirectory(for: repo))
            try expectEqual(dir.lastPathComponent, ".git")
        }

        test("GitDirectory/worktreeStyleGitFile_resolvesRelativeGitdir") {
            let repo = try makeTempRepo(gitIsDirectory: false)
            let real = repo.appendingPathComponent("actual-git-dir")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try "gitdir: actual-git-dir\n".write(
                to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

            let dir = try requireNotNil(GitService.gitDirectory(for: repo))
            try expectEqual(dir.lastPathComponent, "actual-git-dir")
        }

        test("GitDirectory/missingDotGit_returnsNil") {
            let repo = FileManager.default.temporaryDirectory
                .appendingPathComponent("uncommitted-conflict-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try expectNil(GitService.gitDirectory(for: repo))
        }

        // MARK: - operation detection

        test("Operation/mergeHead_readsAsMerge") {
            let repo = try makeTempRepo()
            try touch(repo.appendingPathComponent(".git/MERGE_HEAD"))
            try expectEqual(GitService.operationInProgress(at: repo), .merge)
        }

        test("Operation/rebaseMergeDir_readsAsRebase") {
            let repo = try makeTempRepo()
            try FileManager.default.createDirectory(
                at: repo.appendingPathComponent(".git/rebase-merge"),
                withIntermediateDirectories: true)
            try expectEqual(GitService.operationInProgress(at: repo), .rebase)
        }

        test("Operation/rebaseWins_overCherryPickMarker") {
            // A rebase stopped on a conflict also writes CHERRY_PICK_HEAD —
            // it must still read as a rebase.
            let repo = try makeTempRepo()
            try FileManager.default.createDirectory(
                at: repo.appendingPathComponent(".git/rebase-merge"),
                withIntermediateDirectories: true)
            try touch(repo.appendingPathComponent(".git/CHERRY_PICK_HEAD"))
            try expectEqual(GitService.operationInProgress(at: repo), .rebase)
        }

        test("Operation/cherryPickRevertBisect_eachDetected") {
            let cherry = try makeTempRepo()
            try touch(cherry.appendingPathComponent(".git/CHERRY_PICK_HEAD"))
            try expectEqual(GitService.operationInProgress(at: cherry), .cherryPick)

            let revert = try makeTempRepo()
            try touch(revert.appendingPathComponent(".git/REVERT_HEAD"))
            try expectEqual(GitService.operationInProgress(at: revert), .revert)

            let bisect = try makeTempRepo()
            try touch(bisect.appendingPathComponent(".git/BISECT_LOG"))
            try expectEqual(GitService.operationInProgress(at: bisect), .bisect)
        }

        test("Operation/cleanGitDir_returnsNil") {
            let repo = try makeTempRepo()
            try expectNil(GitService.operationInProgress(at: repo))
        }

        // MARK: - RepoStatus semantics

        test("RepoStatus/operationInProgress_makesRepoDirtyAtZeroCounts") {
            let status = RepoStatus(branch: "main", operation: .rebase)
            try expect(!status.isClean)
            try expectEqual(status.totalUncommitted, 0)
        }

        test("RepoStatus/goneBranches_excludesCurrentAndNonGone") {
            let status = RepoStatus(branch: "main", branches: [
                BranchStatus(name: "main", upstream: "origin/main", ahead: 0, behind: 0, isCurrent: true, isGone: true),
                BranchStatus(name: "feature", upstream: "origin/feature", ahead: 0, behind: 0, isCurrent: false, isGone: true),
                BranchStatus(name: "develop", upstream: "origin/develop", ahead: 1, behind: 0, isCurrent: false, isGone: false),
            ])
            try expectEqual(status.goneBranches.map(\.name), ["feature"])
        }
    }
}
