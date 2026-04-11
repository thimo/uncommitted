import Foundation
import UncommittedCore

enum RepoResolutionTests {
    private static let fm = FileManager.default

    static func register() {
        test("RepoResolve/depthZero_sourceIsRepo_includesIt") {
            try withTempRoot { root in
                try makeRepo(root, "alpha")
                let resolved = RepoStore.resolve(sources: [sourceAt(root, "alpha", depth: 0)])
                try expectEqual(resolved.map(\.lastPathComponent), ["alpha"])
            }
        }

        test("RepoResolve/depthZero_sourceIsNotRepo_returnsEmpty") {
            try withTempRoot { root in
                try makePlainDir(root, "container")
                try makeRepo(root, "container/alpha") // should NOT be picked up at depth 0
                let resolved = RepoStore.resolve(sources: [sourceAt(root, "container", depth: 0)])
                try expect(resolved.isEmpty)
            }
        }

        test("RepoResolve/depthOne_findsDirectChildren") {
            try withTempRoot { root in
                try makePlainDir(root, "src")
                try makeRepo(root, "src/alpha")
                try makeRepo(root, "src/beta")
                try makeRepo(root, "src/gamma")

                let resolved = RepoStore.resolve(sources: [sourceAt(root, "src", depth: 1)])
                try expectEqual(resolved.map(\.lastPathComponent).sorted(), ["alpha", "beta", "gamma"])
            }
        }

        test("RepoResolve/depthOne_stopsAtFirstRepoFound") {
            try withTempRoot { root in
                try makeRepo(root, "src")
                try makeRepo(root, "src/should-be-ignored")

                let resolved = RepoStore.resolve(sources: [sourceAt(root, "src", depth: 1)])
                try expectEqual(resolved.map(\.lastPathComponent), ["src"])
            }
        }

        test("RepoResolve/depthTwo_findsGrandchildren") {
            try withTempRoot { root in
                try makePlainDir(root, "workspaces")
                try makePlainDir(root, "workspaces/project-a")
                try makeRepo(root, "workspaces/project-a/frontend")
                try makeRepo(root, "workspaces/project-a/backend")
                try makePlainDir(root, "workspaces/project-b")
                try makeRepo(root, "workspaces/project-b/api")

                let resolved = RepoStore.resolve(sources: [sourceAt(root, "workspaces", depth: 2)])
                try expectEqual(
                    resolved.map(\.lastPathComponent).sorted(),
                    ["api", "backend", "frontend"]
                )
            }
        }

        test("RepoResolve/nonexistentSource_isSkipped") {
            try withTempRoot { root in
                let resolved = RepoStore.resolve(sources: [sourceAt(root, "does-not-exist", depth: 1)])
                try expect(resolved.isEmpty)
            }
        }

        test("RepoResolve/overlappingSources_dedup") {
            try withTempRoot { root in
                try makePlainDir(root, "src")
                try makeRepo(root, "src/alpha")

                let resolved = RepoStore.resolve(sources: [
                    sourceAt(root, "src", depth: 1),
                    sourceAt(root, "src/alpha", depth: 0),
                ])

                try expectEqual(resolved.count, 1)
                try expectEqual(resolved.first?.lastPathComponent, "alpha")
            }
        }

        test("RepoResolve/trailingSlashInSourcePath_dedupsWithoutSlash") {
            try withTempRoot { root in
                try makeRepo(root, "alpha")
                let resolved = RepoStore.resolve(sources: [
                    sourceAt(root, "alpha", depth: 0),
                    sourceAt(root, "alpha/", depth: 0),
                ])
                try expectEqual(resolved.count, 1)
            }
        }

        test("RepoResolve/hiddenSubdirectories_areSkipped") {
            try withTempRoot { root in
                try makePlainDir(root, "src")
                try makeRepo(root, "src/alpha")
                try makeRepo(root, "src/.upstream") // hidden — skipped by contentsOfDirectory

                let resolved = RepoStore.resolve(sources: [sourceAt(root, "src", depth: 1)])
                try expectEqual(resolved.map(\.lastPathComponent), ["alpha"])
            }
        }
    }

    // MARK: - Helpers

    private static func withTempRoot(_ body: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory
            .appendingPathComponent("uncommitted-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(root)
    }

    @discardableResult
    private static func makeRepo(_ root: URL, _ relativePath: String) throws -> URL {
        let repo = root.appendingPathComponent(relativePath)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        let gitMarker = repo.appendingPathComponent(".git")
        try Data().write(to: gitMarker)
        return repo
    }

    @discardableResult
    private static func makePlainDir(_ root: URL, _ relativePath: String) throws -> URL {
        let dir = root.appendingPathComponent(relativePath)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sourceAt(_ root: URL, _ relativePath: String, depth: Int) -> Source {
        Source(
            path: root.appendingPathComponent(relativePath).path,
            scanDepth: depth
        )
    }
}
