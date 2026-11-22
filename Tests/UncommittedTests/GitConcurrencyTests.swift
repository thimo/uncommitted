import Foundation
import UncommittedCore

/// Regression test for the FETCH_HEAD race: a background `git fetch` and a
/// user's `git pull --rebase` running in the same repo at once tore
/// `.git/FETCH_HEAD` in half, and the pull read the fragment as a second
/// merge head — "fatal: Cannot rebase onto multiple branches". Shells out to
/// real git against a local file remote, so it's slower than the rest of the
/// suite but stays offline.
enum GitConcurrencyTests {
    static func register() {
        test("GitService/concurrentFetchAndPull_doNotCorruptFetchHead") {
            guard FileManager.default.fileExists(atPath: "/usr/bin/git") else { return }
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("uncommitted-tests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }

            let upstream = root.appendingPathComponent("upstream")
            let clone = root.appendingPathComponent("clone")
            try makeUpstream(at: upstream)
            try run(["clone", "--quiet", upstream.path, clone.path], at: root)

            let queue = DispatchQueue(label: "test.gitconcurrency", attributes: .concurrent)
            for _ in 0..<8 {
                try commit(at: upstream)
                var pullResult: GitService.ActionResult?
                let group = DispatchGroup()
                queue.async(group: group) {
                    _ = GitService.fetch(at: clone)
                }
                queue.async(group: group) {
                    pullResult = GitService.pull(at: clone, strategy: .rebase)
                }
                group.wait()

                let result = try requireNotNil(pullResult)
                try expect(
                    result.success,
                    "pull raced a fetch and failed: \(result.errorOutput ?? "unknown")"
                )
            }
        }

        test("GitService/commitCount_countsCommitsAfterTheGivenOne") {
            // What the deploy pill does after a push: count from the
            // deployed commit to the branch, in the clone, without GitHub.
            let repo = FileManager.default.temporaryDirectory
                .appendingPathComponent("uncommitted-count-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: repo) }
            try makeUpstream(at: repo)
            let deployed = try requireNotNil(GitService.status(at: repo)?.headOid)
            try expectEqual(GitService.commitCount(from: deployed, to: "main", at: repo), 0)
            try commit(at: repo)
            try commit(at: repo)
            try expectEqual(GitService.commitCount(from: deployed, to: "main", at: repo), 2)
            try expectEqual(GitService.commitSubjects(from: deployed, to: "main", limit: 12, at: repo), ["tick", "tick"])
            try expectEqual(GitService.commitSubjects(from: deployed, to: "main", limit: 1, at: repo), ["tick"])
            // A commit without a subject still takes its place in the list.
            try run(["commit", "--quiet", "--allow-empty", "--allow-empty-message", "-m", ""], at: repo)
            try expectEqual(GitService.commitSubjects(from: deployed, to: "main", limit: 12, at: repo), ["(no subject)", "tick", "tick"])
        }

        test("GitService/commitCount_unknownCommit_isNilNotZero") {
            let repo = FileManager.default.temporaryDirectory
                .appendingPathComponent("uncommitted-count-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: repo) }
            try makeUpstream(at: repo)
            let unknown = String(repeating: "a", count: 40)
            try expectNil(GitService.commitCount(from: unknown, to: "main", at: repo))
            try expectNil(GitService.commitCount(from: "main", to: "origin/main", at: repo))
            // Never read as an option, even though `--all..main` would fail anyway.
            try expectNil(GitService.commitCount(from: "--all", to: "main", at: repo))
        }
    }

    // MARK: - Fixture helpers

    private static func makeUpstream(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try run(["init", "--quiet", "--initial-branch=main", "."], at: url)
        try run(["config", "user.email", "test@example.com"], at: url)
        try run(["config", "user.name", "Test"], at: url)
        try commit(at: url)
    }

    private static func commit(at url: URL) throws {
        let file = url.appendingPathComponent("log.txt")
        let line = "\(Date().timeIntervalSince1970)\n"
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try (existing + line).write(to: file, atomically: true, encoding: .utf8)
        try run(["add", "log.txt"], at: url)
        try run(["commit", "--quiet", "-m", "tick"], at: url)
    }

    private static func run(_ args: [String], at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
    }
}
