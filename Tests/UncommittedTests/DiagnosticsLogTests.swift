import Foundation
import UncommittedCore

enum DiagnosticsLogTests {
    private static func makeTempLog(retentionDays: Int = 14) -> DiagnosticsLog {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncommitted-diagnostics-tests-\(UUID().uuidString)")
        return DiagnosticsLog(directory: dir, retentionDays: retentionDays)
    }

    /// 2026-06-15 12:00:00 UTC — fixed so filenames are deterministic.
    private static let fixedNow = Date(timeIntervalSince1970: 1_781_524_800)

    static func register() {
        // MARK: - writing

        test("DiagnosticsLog/write_createsDailyFileWithLevelCategoryMessage") {
            let log = makeTempLog()
            log.log(.error, "git", "boom happened", now: fixedNow)

            let contents = try String(contentsOf: log.fileURL(for: fixedNow), encoding: .utf8)
            try expect(contents.contains("[ERROR]"), "level marker missing: \(contents)")
            try expect(contents.contains("git —"), "category missing: \(contents)")
            try expect(contents.contains("boom happened"), "message missing: \(contents)")
        }

        test("DiagnosticsLog/write_appendsSubsequentLines") {
            let log = makeTempLog()
            log.log(.info, "app", "first", now: fixedNow)
            log.log(.warning, "fetch", "second", now: fixedNow.addingTimeInterval(60))

            let contents = try String(contentsOf: log.fileURL(for: fixedNow), encoding: .utf8)
            let lines = contents.split(separator: "\n")
            try expectEqual(lines.count, 2)
            try expect(lines[0].contains("first"))
            try expect(lines[1].contains("second"))
        }

        test("DiagnosticsLog/write_rollsOverToNewFileAcrossDays") {
            let log = makeTempLog()
            let nextDay = fixedNow.addingTimeInterval(86_400)
            log.log(.info, "app", "yesterday", now: fixedNow)
            log.log(.info, "app", "today", now: nextDay)

            let first = try String(contentsOf: log.fileURL(for: fixedNow), encoding: .utf8)
            let second = try String(contentsOf: log.fileURL(for: nextDay), encoding: .utf8)
            try expect(log.fileURL(for: fixedNow) != log.fileURL(for: nextDay))
            try expect(first.contains("yesterday") && !first.contains("today"))
            try expect(second.contains("today") && !second.contains("yesterday"))
        }

        test("DiagnosticsLog/fileURL_usesDatedName") {
            let log = makeTempLog()
            let name = log.fileURL(for: fixedNow).lastPathComponent
            try expect(name.hasPrefix("Uncommitted-"), "unexpected name \(name)")
            try expect(name.hasSuffix(".log"), "unexpected name \(name)")
            // yyyy-MM-dd between prefix and suffix.
            let day = name.dropFirst("Uncommitted-".count).dropLast(".log".count)
            try expectEqual(day.count, 10)
        }

        // MARK: - lastError

        test("DiagnosticsLog/error_updatesLastErrorSynchronouslyOnMain") {
            let log = makeTempLog()
            log.log(.error, "git", "status failed", now: fixedNow)
            let entry = try requireNotNil(log.lastError)
            try expectEqual(entry.message, "status failed")
            try expectEqual(entry.category, "git")
        }

        test("DiagnosticsLog/infoAndWarning_doNotTouchLastError") {
            let log = makeTempLog()
            log.log(.info, "app", "launched", now: fixedNow)
            log.log(.warning, "fetch", "offline", now: fixedNow)
            try expectNil(log.lastError)
        }

        // MARK: - retention

        test("DiagnosticsLog/prune_removesFilesPastRetention_keepsRecent") {
            let log = makeTempLog(retentionDays: 14)
            let old = fixedNow.addingTimeInterval(-30 * 86_400)
            log.log(.info, "app", "ancient", now: old)
            log.log(.info, "app", "current", now: fixedNow)

            log.pruneOldLogs(now: fixedNow)

            let fm = FileManager.default
            try expect(!fm.fileExists(atPath: log.fileURL(for: old).path), "old file survived prune")
            try expect(fm.fileExists(atPath: log.fileURL(for: fixedNow).path), "current file was pruned")
        }

        test("DiagnosticsLog/prune_ignoresForeignFiles") {
            let log = makeTempLog(retentionDays: 14)
            let foreign = log.directory.appendingPathComponent("notes.txt")
            try "keep me".write(to: foreign, atomically: true, encoding: .utf8)

            log.pruneOldLogs(now: fixedNow)

            try expect(FileManager.default.fileExists(atPath: foreign.path), "foreign file was deleted")
        }
    }
}
