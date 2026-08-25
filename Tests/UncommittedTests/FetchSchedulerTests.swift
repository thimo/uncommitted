import Foundation
import UncommittedCore

enum FetchSchedulerTests {
    /// Temp repo-shaped directory with the two files the tier heuristic
    /// looks at, stamped to the given ages. Passing nil for either leaves
    /// that file absent. No real git needed — the check is pure filesystem.
    private static func makeTempRepo(
        headAge: TimeInterval?,
        reflogAge: TimeInterval?,
        gitIsDirectory: Bool = true
    ) throws -> URL {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory
            .appendingPathComponent("uncommitted-fetch-tier-\(UUID().uuidString)")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)

        // Worktrees and submodules point at a git dir elsewhere via a
        // `.git` file; make sure the heuristic follows that indirection.
        let gitDir: URL
        if gitIsDirectory {
            gitDir = repo.appendingPathComponent(".git")
        } else {
            gitDir = repo.appendingPathComponent("elsewhere-gitdir")
            try "gitdir: \(gitDir.path)\n".write(
                to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)

        func stamp(_ url: URL, age: TimeInterval) throws {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data())
            try fm.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        if let headAge {
            try stamp(gitDir.appendingPathComponent("HEAD"), age: headAge)
        }
        if let reflogAge {
            try stamp(gitDir.appendingPathComponent("logs/HEAD"), age: reflogAge)
        }
        return repo
    }

    static func register() {
        // MARK: - isActive (tier classification)

        test("FetchScheduler/isActive_recentReflog_staleHEAD_returnsTrue") {
            // The regression this heuristic was rewritten for: you commit
            // daily on one branch, so the reflog moves but `.git/HEAD` —
            // rewritten only on a branch switch — hasn't changed in weeks.
            // Reading HEAD alone demoted these to the 7-day idle tier.
            let repo = try makeTempRepo(headAge: 30 * 24 * 3600, reflogAge: 3600)
            try expect(FetchScheduler.isActive(repoURL: repo))
        }

        test("FetchScheduler/isActive_bothStale_returnsFalse") {
            let old = FetchScheduler.activeThreshold + 24 * 3600
            let repo = try makeTempRepo(headAge: old, reflogAge: old)
            try expect(!FetchScheduler.isActive(repoURL: repo))
        }

        test("FetchScheduler/isActive_noReflog_recentHEAD_returnsTrue") {
            // Fallback path: `core.logAllRefUpdates=false`, so there's no
            // reflog to read and HEAD is all we have.
            let repo = try makeTempRepo(headAge: 3600, reflogAge: nil)
            try expect(FetchScheduler.isActive(repoURL: repo))
        }

        test("FetchScheduler/isActive_noReflog_staleHEAD_returnsFalse") {
            let repo = try makeTempRepo(
                headAge: FetchScheduler.activeThreshold + 24 * 3600, reflogAge: nil)
            try expect(!FetchScheduler.isActive(repoURL: repo))
        }

        test("FetchScheduler/isActive_worktreeGitdirFile_followsIndirection") {
            let repo = try makeTempRepo(
                headAge: 30 * 24 * 3600, reflogAge: 3600, gitIsDirectory: false)
            try expect(FetchScheduler.isActive(repoURL: repo))
        }

        test("FetchScheduler/isActive_noGitDir_returnsFalse") {
            // Unreadable — err toward idle rather than extra network traffic.
            let repo = FileManager.default.temporaryDirectory
                .appendingPathComponent("uncommitted-fetch-tier-missing-\(UUID().uuidString)")
            try expect(!FetchScheduler.isActive(repoURL: repo))
        }

        test("FetchScheduler/isActive_respectsNowParameter") {
            // Same repo reads active today, idle when asked about a date
            // well past the activity window.
            let repo = try makeTempRepo(headAge: 3600, reflogAge: 3600)
            try expect(FetchScheduler.isActive(repoURL: repo))
            let later = Date().addingTimeInterval(FetchScheduler.activeThreshold + 24 * 3600)
            try expect(!FetchScheduler.isActive(repoURL: repo, now: later))
        }

        // MARK: - shouldFetch

        test("FetchScheduler/shouldFetch_neverAttempted_returnsTrue") {
            let state = FetchState()
            try expect(FetchScheduler.shouldFetch(active: true, state: state, now: Date()))
            try expect(FetchScheduler.shouldFetch(active: false, state: state, now: Date()))
        }

        test("FetchScheduler/shouldFetch_withinInterval_returnsFalse") {
            let now = Date()
            // Active repo, last attempt 1 hour ago — well under the 24h
            // active interval, so it should not fetch yet.
            let state = FetchState(lastAttemptAt: now.addingTimeInterval(-3600))
            try expect(!FetchScheduler.shouldFetch(active: true, state: state, now: now))
        }

        test("FetchScheduler/shouldFetch_afterInterval_returnsTrue") {
            let now = Date()
            // Active repo, last attempt > 24h ago.
            let state = FetchState(lastAttemptAt: now.addingTimeInterval(-25 * 3600))
            try expect(FetchScheduler.shouldFetch(active: true, state: state, now: now))
        }

        test("FetchScheduler/shouldFetch_idleRepo_within7d_returnsFalse") {
            let now = Date()
            // Idle repo last fetched 6 days ago — under the 7d idle cadence.
            let state = FetchState(lastAttemptAt: now.addingTimeInterval(-6 * 86400))
            try expect(!FetchScheduler.shouldFetch(active: false, state: state, now: now))
        }

        test("FetchScheduler/shouldFetch_idleRepo_after7d_returnsTrue") {
            let now = Date()
            let state = FetchState(lastAttemptAt: now.addingTimeInterval(-8 * 86400))
            try expect(FetchScheduler.shouldFetch(active: false, state: state, now: now))
        }

        // MARK: - nextInterval

        test("FetchScheduler/nextInterval_noFailures_usesBaseTier") {
            let state = FetchState()
            try expectEqual(
                FetchScheduler.nextInterval(active: true, state: state),
                FetchScheduler.activeInterval
            )
            try expectEqual(
                FetchScheduler.nextInterval(active: false, state: state),
                FetchScheduler.idleInterval
            )
        }

        test("FetchScheduler/nextInterval_oneFailure_doublesBase") {
            // After 1 failure: base * 2^0 = base. Spec rule: doubling
            // starts on the SECOND failure. Verifies that the formula
            // doesn't accidentally penalize the first failure.
            let state = FetchState(consecutiveFailures: 1)
            try expectEqual(
                FetchScheduler.nextInterval(active: true, state: state),
                FetchScheduler.activeInterval
            )
        }

        test("FetchScheduler/nextInterval_severalFailures_exponentialBackoff") {
            // After 3 failures: base * 2^2 = 4 × base.
            let state = FetchState(consecutiveFailures: 3)
            try expectEqual(
                FetchScheduler.nextInterval(active: true, state: state),
                FetchScheduler.activeInterval * 4
            )
        }

        test("FetchScheduler/nextInterval_capsAtMaxBackoff") {
            // 20 consecutive failures × idle base would be 20 * 2^19 days,
            // which must be clamped to maxBackoff (~30 days).
            let state = FetchState(consecutiveFailures: 20)
            try expectEqual(
                FetchScheduler.nextInterval(active: false, state: state),
                FetchScheduler.maxBackoff
            )
        }

        // MARK: - shouldEagerFetch (popup-open sweep)

        test("FetchScheduler/eager_neverAttempted_returnsTrue") {
            try expect(FetchScheduler.shouldEagerFetch(state: FetchState(), now: Date()))
        }

        test("FetchScheduler/eager_withinOpenInterval_returnsFalse") {
            // Opening the popup again a minute later must not re-fetch.
            let now = Date()
            let state = FetchState(lastAttemptAt: now.addingTimeInterval(-60))
            try expect(!FetchScheduler.shouldEagerFetch(state: state, now: now))
        }

        test("FetchScheduler/eager_afterOpenInterval_returnsTrue") {
            let now = Date()
            let state = FetchState(
                lastAttemptAt: now.addingTimeInterval(-FetchScheduler.openInterval - 60))
            try expect(FetchScheduler.shouldEagerFetch(state: state, now: now))
        }

        test("FetchScheduler/eager_beatsTierInterval") {
            // The whole point: an hour-old fetch is fresh by the 24h active
            // tier but stale for someone staring at the list right now.
            let now = Date()
            let state = FetchState(lastAttemptAt: now.addingTimeInterval(-3600))
            try expect(!FetchScheduler.shouldFetch(active: true, state: state, now: now))
            try expect(FetchScheduler.shouldEagerFetch(state: state, now: now))
        }

        test("FetchScheduler/eager_noRemote_returnsFalse") {
            let state = FetchState(noRemote: true)
            try expect(!FetchScheduler.shouldEagerFetch(state: state, now: Date()))
        }

        test("FetchScheduler/eager_inBackoff_returnsFalse") {
            // A repo that failed keeps its back-off penalty instead of being
            // retried every time the popup opens.
            let state = FetchState(
                lastAttemptAt: Date().addingTimeInterval(-24 * 3600), consecutiveFailures: 1)
            try expect(!FetchScheduler.shouldEagerFetch(state: state, now: Date()))
        }

        test("FetchScheduler/eager_disabled_returnsFalse") {
            let state = FetchState(consecutiveFailures: 5)
            try expect(!FetchScheduler.shouldEagerFetch(state: state, now: Date()))
        }

        // MARK: - isDisabled

        test("FetchScheduler/isDisabled_zeroFailures_returnsFalse") {
            try expect(!FetchScheduler.isDisabled(FetchState()))
        }

        test("FetchScheduler/isDisabled_smallFailureCount_returnsFalse") {
            // 2 failures × idle base = 14d, well under 30d cap.
            try expect(!FetchScheduler.isDisabled(FetchState(consecutiveFailures: 2)))
        }

        test("FetchScheduler/isDisabled_exceedsMaxBackoff_returnsTrue") {
            // 5 failures × 7d × 2^4 = 112d, way past the 30-day cap.
            try expect(FetchScheduler.isDisabled(FetchState(consecutiveFailures: 5)))
        }

        // MARK: - shouldSurfaceFailure

        test("FetchScheduler/shouldSurfaceFailure_zero_returnsFalse") {
            try expect(!FetchScheduler.shouldSurfaceFailure(FetchState()))
        }

        test("FetchScheduler/shouldSurfaceFailure_oneAuto_returnsFalse") {
            // Auto failures only surface at 3+, so 1 isn't enough.
            let state = FetchState(consecutiveFailures: 1, lastAttemptWasManual: false)
            try expect(!FetchScheduler.shouldSurfaceFailure(state))
        }

        test("FetchScheduler/shouldSurfaceFailure_oneManual_returnsTrue") {
            // The user just clicked — they should see the failure now.
            let state = FetchState(consecutiveFailures: 1, lastAttemptWasManual: true)
            try expect(FetchScheduler.shouldSurfaceFailure(state))
        }

        // MARK: - failureCountsAgainstRepo (back-off policy)

        test("FetchScheduler/failureCounts_networkUnreachable_doesNot") {
            try expect(!FetchScheduler.failureCountsAgainstRepo(.networkUnreachable))
        }

        test("FetchScheduler/failureCounts_unknownAndNil_do") {
            try expect(FetchScheduler.failureCountsAgainstRepo(.unknown(stderr: "x", exitStatus: 128)))
            try expect(FetchScheduler.failureCountsAgainstRepo(.lockFileExists))
            try expect(FetchScheduler.failureCountsAgainstRepo(nil))
        }

        test("FetchScheduler/shouldSurfaceFailure_threeAuto_returnsTrue") {
            let state = FetchState(consecutiveFailures: 3, lastAttemptWasManual: false)
            try expect(FetchScheduler.shouldSurfaceFailure(state))
        }
    }
}
