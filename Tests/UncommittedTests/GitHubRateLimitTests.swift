import Foundation
import UncommittedCore

enum GitHubRateLimitTests {
    static func register() {
        // MARK: - Recognising the refusal

        test("GitHubRateLimit/isRateLimitError_graphqlPrimary") {
            try expect(GitHubRateLimitGate.isRateLimitError("gh: API rate limit already exceeded for user ID 1."))
        }

        test("GitHubRateLimit/isRateLimitError_restPrimaryAndSecondary") {
            try expect(GitHubRateLimitGate.isRateLimitError("gh: API rate limit exceeded for user ID 1. (HTTP 403)"))
            try expect(GitHubRateLimitGate.isRateLimitError("gh: You have exceeded a secondary rate limit. (HTTP 403)"))
        }

        test("GitHubRateLimit/isRateLimitError_otherFailures_false") {
            try expect(!GitHubRateLimitGate.isRateLimitError("gh: Not Found (HTTP 404)"))
            try expect(!GitHubRateLimitGate.isRateLimitError("error connecting to api.github.com"))
        }

        // MARK: - The pause

        test("GitHubRateLimit/gate_pausesOnlyTheRefusedResource") {
            let gate = GitHubRateLimitGate()
            let now = Date()
            try expect(!gate.isAnyPaused(now: now))
            try expect(gate.noteFailure(.graphql, stderr: "API rate limit already exceeded", now: now))
            try expect(gate.isPaused(.graphql, now: now))
            try expect(!gate.isPaused(.rest, now: now))
            try expect(gate.isAnyPaused(now: now))
        }

        test("GitHubRateLimit/gate_liftsAfterThePause") {
            let gate = GitHubRateLimitGate()
            let now = Date()
            gate.noteFailure(.rest, stderr: "API rate limit exceeded", now: now)
            try expect(gate.isPaused(.rest, now: now.addingTimeInterval(GitHubRateLimitGate.pause - 1)))
            try expect(!gate.isPaused(.rest, now: now.addingTimeInterval(GitHubRateLimitGate.pause)))
        }

        test("GitHubRateLimit/gate_secondRefusalDuringPause_doesNotRestartIt") {
            // Concurrent calls all fail at once: only the first starts the
            // pause (and gets logged), the rest must not push it out.
            let gate = GitHubRateLimitGate()
            let now = Date()
            try expect(gate.noteFailure(.graphql, stderr: "rate limit", now: now))
            try expect(!gate.noteFailure(.graphql, stderr: "rate limit", now: now.addingTimeInterval(60)))
            try expect(!gate.isPaused(.graphql, now: now.addingTimeInterval(GitHubRateLimitGate.pause)))
        }

        test("GitHubRateLimit/gate_otherFailure_doesNotPause") {
            let gate = GitHubRateLimitGate()
            try expect(!gate.noteFailure(.graphql, stderr: "gh: Not Found (HTTP 404)"))
            try expect(!gate.isAnyPaused())
        }

        // MARK: - Undeployed commits counted locally

        test("GitHubStatusScheduler/raisedLag_higherLocalCount_raises") {
            let lag = DeploymentLag(aheadBy: 0, deployedSHA: "abc", defaultBranch: "main")
            let raised = GitHubStatusScheduler.raisedLag(current: lag, localCount: 2, countedFrom: "abc")
            try expectEqual(raised, DeploymentLag(aheadBy: 2, deployedSHA: "abc", defaultBranch: "main"))
        }

        test("GitHubStatusScheduler/raisedLag_neverLowers") {
            // A clone that hasn't fetched counts fewer commits than GitHub
            // reported; that must not shrink the pill.
            let lag = DeploymentLag(aheadBy: 3, deployedSHA: "abc", defaultBranch: "main")
            try expectNil(GitHubStatusScheduler.raisedLag(current: lag, localCount: 1, countedFrom: "abc"))
            try expectNil(GitHubStatusScheduler.raisedLag(current: lag, localCount: 3, countedFrom: "abc"))
        }

        test("GitHubStatusScheduler/raisedLag_countFromAnOlderDeployment_ignored") {
            // A deploy was recorded while the count ran: the count started
            // from the previous deployment and says nothing anymore.
            let lag = DeploymentLag(aheadBy: 0, deployedSHA: "new", defaultBranch: "main")
            try expectNil(GitHubStatusScheduler.raisedLag(current: lag, localCount: 4, countedFrom: "old"))
        }

        // MARK: - Popup-open throttle

        test("GitHubStatusScheduler/popupRefreshDue_neverRefreshed_true") {
            try expect(GitHubStatusScheduler.popupRefreshDue(last: nil, ciStatus: nil, localStateChanged: false, now: Date()))
        }

        test("GitHubStatusScheduler/popupRefreshDue_recentRefresh_false") {
            let now = Date()
            let last = now.addingTimeInterval(-(GitHubStatusScheduler.popupMinimumAge - 1))
            try expect(!GitHubStatusScheduler.popupRefreshDue(last: last, ciStatus: .success, localStateChanged: false, now: now))
        }

        test("GitHubStatusScheduler/popupRefreshDue_oldRefresh_true") {
            let now = Date()
            let last = now.addingTimeInterval(-GitHubStatusScheduler.popupMinimumAge)
            try expect(GitHubStatusScheduler.popupRefreshDue(last: last, ciStatus: CIStatus.none, localStateChanged: false, now: now))
        }

        test("GitHubStatusScheduler/popupRefreshDue_pendingOrFailingCI_usesTheFastCadence") {
            let now = Date()
            let last = now.addingTimeInterval(-GitHubStatusScheduler.pendingInterval)
            try expect(GitHubStatusScheduler.popupRefreshDue(last: last, ciStatus: .pending, localStateChanged: false, now: now))
            try expect(GitHubStatusScheduler.popupRefreshDue(last: last, ciStatus: .failure, localStateChanged: false, now: now))
            try expect(!GitHubStatusScheduler.popupRefreshDue(last: now.addingTimeInterval(-30), ciStatus: .pending, localStateChanged: false, now: now))
        }

        test("GitHubStatusScheduler/popupRefreshDue_pushSinceRefresh_trueDespiteRecentRefresh") {
            // Push, then open the popup to watch CI: the green badge from a
            // minute ago must not be held for the rest of the five minutes.
            let now = Date()
            let last = now.addingTimeInterval(-10)
            try expect(GitHubStatusScheduler.popupRefreshDue(last: last, ciStatus: .success, localStateChanged: true, now: now))
        }
    }
}
