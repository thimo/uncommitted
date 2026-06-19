import Foundation
import UncommittedCore

enum StalenessTests {
    static func register() {
        // MARK: - age (compact + full render off one computed unit)

        test("Staleness/age_minutesAndHours") {
            let now = Date(timeIntervalSince1970: 1_000_000_000)
            try expectEqual(Staleness.age(since: now.addingTimeInterval(-90 * 60), now: now).compact, "1h")
            try expectEqual(Staleness.age(since: now.addingTimeInterval(-30 * 60), now: now).compact, "30m")
        }

        test("Staleness/age_daysStayDaysUntilFortnight") {
            let now = Date(timeIntervalSince1970: 1_000_000_000)
            let day = 86_400.0
            // 7 days is the default threshold — must read "7d", not "1w".
            try expectEqual(Staleness.age(since: now.addingTimeInterval(-7 * day), now: now).compact, "7d")
            try expectEqual(Staleness.age(since: now.addingTimeInterval(-13 * day), now: now).compact, "13d")
            try expectEqual(Staleness.age(since: now.addingTimeInterval(-14 * day), now: now).compact, "2w")
        }

        test("Staleness/age_monthsAndYears") {
            let now = Date(timeIntervalSince1970: 1_000_000_000)
            let day = 86_400.0
            try expectEqual(Staleness.age(since: now.addingTimeInterval(-45 * day), now: now).compact, "1mo")
            try expectEqual(Staleness.age(since: now.addingTimeInterval(-400 * day), now: now).compact, "1y")
        }

        test("Staleness/age_subMinuteAndFutureReadAsJustNow") {
            let now = Date(timeIntervalSince1970: 1_000_000_000)
            // Under a minute must never render "0m" / "0 minutes ago".
            let fresh = Staleness.age(since: now.addingTimeInterval(-30), now: now)
            try expectEqual(fresh.compact, "now")
            try expectEqual(fresh.full, "just now")
            try expectEqual(fresh.ago, "just now")
            // Clock skew (future date) clamps to zero → also "just now".
            try expectEqual(Staleness.age(since: now.addingTimeInterval(3_600), now: now).compact, "now")
        }

        test("Staleness/age_oneMinuteIsTheFloorForNumbers") {
            let now = Date(timeIntervalSince1970: 1_000_000_000)
            try expectEqual(Staleness.age(since: now.addingTimeInterval(-60), now: now).compact, "1m")
            try expectEqual(Staleness.age(since: now.addingTimeInterval(-59), now: now).compact, "now")
        }

        test("Staleness/age_compactAndFullAgreeOnUnit") {
            // The row ("10d") and the panel ("10 days") must never disagree —
            // both render off the same computed unit. 10 days = days, not "1 week".
            let now = Date(timeIntervalSince1970: 1_000_000_000)
            let ten = Staleness.age(since: now.addingTimeInterval(-10 * 86_400), now: now)
            try expectEqual(ten.compact, "10d")
            try expectEqual(ten.full, "10 days")
            // Singular has no trailing "s".
            let oneWeek = Staleness.age(since: now.addingTimeInterval(-14 * 86_400), now: now)
            try expectEqual(oneWeek.compact, "2w")
            try expectEqual(oneWeek.full, "2 weeks")
            let oneDay = Staleness.age(since: now.addingTimeInterval(-1 * 86_400), now: now)
            try expectEqual(oneDay.full, "1 day")
        }

        // MARK: - latestWorkingTreeModification

        test("Staleness/latestWorkingTreeModification_picksNewestMtime") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let old = Date(timeIntervalSince1970: 1_000_000_000)
            let recent = Date(timeIntervalSince1970: 1_700_000_000)
            try writeFile(dir, "a.txt", modified: recent)
            try writeFile(dir, "nested/b.txt", modified: old)

            let result = try requireNotNil(
                GitService.latestWorkingTreeModification(
                    paths: ["a.txt", "nested/b.txt"],
                    relativeTo: dir
                )
            )
            // Newest wins: a repo with one ancient file but a fresh edit reads
            // as recently active. Allow 2s slop for filesystem mtime granularity.
            try expect(abs(result.timeIntervalSince(recent)) < 2,
                       "expected newest mtime ~\(recent), got \(result)")
        }

        test("Staleness/latestWorkingTreeModification_skipsMissingFiles") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let present = Date(timeIntervalSince1970: 1_500_000_000)
            try writeFile(dir, "present.txt", modified: present)

            // "gone.txt" doesn't exist (e.g. a staged deletion) — it must be
            // skipped, not crash or poison the result.
            let result = try requireNotNil(
                GitService.latestWorkingTreeModification(
                    paths: ["gone.txt", "present.txt"],
                    relativeTo: dir
                )
            )
            try expect(abs(result.timeIntervalSince(present)) < 2)
        }

        test("Staleness/latestWorkingTreeModification_emptyPathsReturnsNil") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            try expectNil(GitService.latestWorkingTreeModification(paths: [], relativeTo: dir))
        }
    }

    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncommitted-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeFile(_ dir: URL, _ rel: String, modified: Date) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}
