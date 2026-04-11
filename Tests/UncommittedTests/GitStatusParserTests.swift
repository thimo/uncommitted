import Foundation
import UncommittedCore

enum GitStatusParserTests {
    static func register() {
        test("GitStatusParser/emptyOutput_returnsNil") {
            try expectNil(GitService.parse(""))
        }

        test("GitStatusParser/outputWithoutBranchOid_returnsNil") {
            // No `# branch.oid` line → parser refuses to guess a clean state.
            let output = """
            # branch.head main
            # branch.ab +0 -0
            """
            try expectNil(GitService.parse(output))
        }

        test("GitStatusParser/cleanRepoOnMain_noCounts") {
            let output = """
            # branch.oid 1234567890abcdef
            # branch.head main
            # branch.upstream origin/main
            # branch.ab +0 -0
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.branch, "main")
            try expectEqual(status.headOid, "1234567890abcdef")
            try expectEqual(status.ahead, 0)
            try expectEqual(status.behind, 0)
            try expectEqual(status.staged, 0)
            try expectEqual(status.unstaged, 0)
            try expectEqual(status.untracked, 0)
            try expect(status.isClean)
        }

        test("GitStatusParser/detachedHead_reportsShortSha") {
            let output = """
            # branch.oid abc1234def5678
            # branch.head (detached)
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.branch, "(detached)")
            try expect(status.isDetached)
            try expectEqual(status.displayBranch, "detached · abc1234")
        }

        test("GitStatusParser/aheadOnly") {
            let output = """
            # branch.oid 1234567890abcdef
            # branch.head main
            # branch.ab +5 -0
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.ahead, 5)
            try expectEqual(status.behind, 0)
        }

        test("GitStatusParser/behindOnly") {
            let output = """
            # branch.oid 1234567890abcdef
            # branch.head main
            # branch.ab +0 -3
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.ahead, 0)
            try expectEqual(status.behind, 3)
        }

        test("GitStatusParser/diverged") {
            let output = """
            # branch.oid 1234567890abcdef
            # branch.head main
            # branch.ab +2 -1
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.ahead, 2)
            try expectEqual(status.behind, 1)
        }

        test("GitStatusParser/unstagedModification") {
            // ".M" → unchanged in index, modified in worktree → unstaged++
            let output = """
            # branch.oid 1234567890abcdef
            # branch.head main
            1 .M N... 100644 100644 100644 aaa bbb routes.ts
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.staged, 0)
            try expectEqual(status.unstaged, 1)
            try expectEqual(status.untracked, 0)
        }

        test("GitStatusParser/stagedAddition") {
            // "A." → added in index, unchanged in worktree → staged++
            let output = """
            # branch.oid 1234567890abcdef
            # branch.head main
            1 A. N... 000000 100644 100644 000 ccc routes.ts
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.staged, 1)
            try expectEqual(status.unstaged, 0)
        }

        test("GitStatusParser/stagedAndThenModified_countsBoth") {
            // "MM" → modified in both index and worktree
            let output = """
            # branch.oid 1234567890abcdef
            # branch.head main
            1 MM N... 100644 100644 100644 aaa bbb routes.ts
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.staged, 1)
            try expectEqual(status.unstaged, 1)
        }

        test("GitStatusParser/untrackedFiles") {
            let output = """
            # branch.oid 1234567890abcdef
            # branch.head main
            ? new-file.txt
            ? another.txt
            ? third.txt
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.untracked, 3)
        }

        test("GitStatusParser/kitchenSink") {
            // ↑2 ↓1, 1 staged, 2 unstaged, 3 untracked
            let output = """
            # branch.oid 1234567890abcdef
            # branch.head main
            # branch.ab +2 -1
            1 A. N... 000000 100644 100644 000 aaa tax.rb
            1 .M N... 100644 100644 100644 bbb ccc cart.rb
            1 .M N... 100644 100644 100644 ddd eee session.rb
            ? new1.rb
            ? new2.rb
            ? new3.rb
            """
            let status = try requireNotNil(GitService.parse(output))
            try expectEqual(status.ahead, 2)
            try expectEqual(status.behind, 1)
            try expectEqual(status.staged, 1)
            try expectEqual(status.unstaged, 2)
            try expectEqual(status.untracked, 3)
            try expect(status.isClean == false)
            try expectEqual(status.totalUncommitted, 6)
            try expectEqual(status.totalUnpushed, 2)
        }
    }
}
