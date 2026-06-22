import Foundation
import UncommittedCore

enum BranchStatusTests {
    static func register() {
        // Field separator matches the `%09` (tab) in GitService's for-each-ref
        // format string. Each line: name<TAB>upstream<TAB>track.
        let T = "\t"

        test("BranchStatus/parsesBehindAheadDivergedAndUpToDate") {
            let output = [
                "main\(T)origin/main\(T)behind 3",
                "develop\(T)origin/develop\(T)ahead 2, behind 1",
                "release/0.8\(T)origin/release/0.8\(T)ahead 1",
                "stable\(T)origin/stable\(T)",
            ].joined(separator: "\n")

            let branches = GitService.parseBranchStatuses(output, current: "develop")
            try expectEqual(branches.count, 4)

            let main = try requireNotNil(branches.first { $0.name == "main" })
            try expectEqual(main.ahead, 0)
            try expectEqual(main.behind, 3)
            try expect(main.isFastForwardable)
            try expect(!main.isDiverged)
            try expect(!main.isCurrent)

            let develop = try requireNotNil(branches.first { $0.name == "develop" })
            try expectEqual(develop.ahead, 2)
            try expectEqual(develop.behind, 1)
            try expect(develop.isDiverged)
            try expect(!develop.isFastForwardable)
            try expect(!develop.isPushable)
            try expect(develop.isCurrent)

            let release = try requireNotNil(branches.first { $0.name == "release/0.8" })
            try expect(release.isPushable)
            try expect(!release.isFastForwardable)

            let stable = try requireNotNil(branches.first { $0.name == "stable" })
            try expectEqual(stable.ahead, 0)
            try expectEqual(stable.behind, 0)
            try expect(!stable.isFastForwardable)
            try expect(!stable.isPushable)
        }

        test("BranchStatus/dropsBranchesWithoutUpstream") {
            // A local-only branch has an empty upstream field — nothing to
            // pull or push against, so it's excluded entirely.
            let output = [
                "main\(T)origin/main\(T)behind 1",
                "scratch\(T)\(T)",
            ].joined(separator: "\n")

            let branches = GitService.parseBranchStatuses(output, current: "main")
            try expectEqual(branches.count, 1)
            try expectEqual(branches[0].name, "main")
        }

        test("BranchStatus/goneUpstreamIsNotActionable") {
            let output = "feature\torigin/feature\tgone"
            let branches = GitService.parseBranchStatuses(output, current: "main")
            let feature = try requireNotNil(branches.first)
            try expect(feature.isGone)
            try expect(!feature.isFastForwardable)
            try expect(!feature.isPushable)
            try expect(!feature.isDiverged)
        }

        test("BranchStatus/remoteSplitHandlesSlashedBranch") {
            let b = BranchStatus(
                name: "release/0.8",
                upstream: "origin/release/0.8",
                ahead: 1, behind: 0, isCurrent: false
            )
            try expectEqual(b.remoteName, "origin")
            try expectEqual(b.remoteBranch, "release/0.8")
        }

        test("BranchStatus/otherBranchesFiltersCurrentAndGoneAndClean") {
            let status = RepoStatus(
                branch: "develop",
                branches: [
                    BranchStatus(name: "develop", upstream: "origin/develop",
                                 ahead: 2, behind: 0, isCurrent: true),
                    BranchStatus(name: "main", upstream: "origin/main",
                                 ahead: 0, behind: 3, isCurrent: false),
                    BranchStatus(name: "stable", upstream: "origin/stable",
                                 ahead: 0, behind: 0, isCurrent: false),
                    BranchStatus(name: "old", upstream: "origin/old",
                                 ahead: 0, behind: 0, isCurrent: false, isGone: true),
                ]
            )
            let others = status.otherBranches
            try expectEqual(others.count, 1)
            try expectEqual(others[0].name, "main")
        }
    }
}
