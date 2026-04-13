import Foundation
import UncommittedCore

enum FetchSchedulerTests {
    static func register() {
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

        test("FetchScheduler/shouldSurfaceFailure_threeAuto_returnsTrue") {
            let state = FetchState(consecutiveFailures: 3, lastAttemptWasManual: false)
            try expect(FetchScheduler.shouldSurfaceFailure(state))
        }
    }
}
