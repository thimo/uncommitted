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

        test("GitHubStatusScheduler/mergedLag_higherLocalCount_raisesAndListsTheCommits") {
            let lag = DeploymentLag(aheadBy: 0, deployedSHA: "abc", defaultBranch: "main")
            let merged = GitHubStatusScheduler.mergedLag(current: lag, localCount: 2, localSubjects: ["b", "a"], countedFrom: "abc")
            try expectEqual(merged, DeploymentLag(aheadBy: 2, deployedSHA: "abc", defaultBranch: "main", subjects: ["b", "a"]))
        }

        test("GitHubStatusScheduler/mergedLag_sameCount_addsTheSubjects") {
            // GitHub gave the count; the clone supplies what the commits are.
            let lag = DeploymentLag(aheadBy: 1, deployedSHA: "abc", defaultBranch: "main")
            let merged = GitHubStatusScheduler.mergedLag(current: lag, localCount: 1, localSubjects: ["a"], countedFrom: "abc")
            try expectEqual(merged?.subjects, ["a"])
            try expectEqual(merged?.aheadBy, 1)
        }

        test("GitHubStatusScheduler/mergedLag_neverLowers_andShowsNoPartialList") {
            // A clone that hasn't fetched counts fewer commits than GitHub
            // reported: the pill keeps its number, and a list of one under
            // "3 commits" would be wrong.
            let lag = DeploymentLag(aheadBy: 3, deployedSHA: "abc", defaultBranch: "main")
            try expectNil(GitHubStatusScheduler.mergedLag(current: lag, localCount: 1, localSubjects: ["a"], countedFrom: "abc"))
        }

        test("GitHubStatusScheduler/mergedLag_staleClone_keepsTheOtherClonesList") {
            let lag = DeploymentLag(aheadBy: 2, deployedSHA: "abc", defaultBranch: "main", subjects: ["b", "a"])
            try expectNil(GitHubStatusScheduler.mergedLag(current: lag, localCount: 1, localSubjects: ["a"], countedFrom: "abc"))
        }

        test("GitHubStatusScheduler/mergedLag_nothingNew_isNil") {
            let lag = DeploymentLag(aheadBy: 1, deployedSHA: "abc", defaultBranch: "main", subjects: ["a"])
            try expectNil(GitHubStatusScheduler.mergedLag(current: lag, localCount: 1, localSubjects: ["a"], countedFrom: "abc"))
            let deployed = DeploymentLag(aheadBy: 0, deployedSHA: "abc", defaultBranch: "main")
            try expectNil(GitHubStatusScheduler.mergedLag(current: deployed, localCount: 0, localSubjects: [], countedFrom: "abc"))
        }

        test("GitHubStatusScheduler/mergedLag_countFromAnOlderDeployment_ignored") {
            // A deploy was recorded while the count ran: the count started
            // from the previous deployment and says nothing anymore.
            let lag = DeploymentLag(aheadBy: 0, deployedSHA: "new", defaultBranch: "main")
            try expectNil(GitHubStatusScheduler.mergedLag(current: lag, localCount: 4, localSubjects: ["d", "c", "b", "a"], countedFrom: "old"))
        }

        test("DeploymentLag/decodesACacheWrittenBeforeSubjects") {
            let json = Data(#"{"aheadBy":2,"deployedSHA":"abc","defaultBranch":"main"}"#.utf8)
            let lag = try JSONDecoder().decode(DeploymentLag.self, from: json)
            try expectEqual(lag, DeploymentLag(aheadBy: 2, deployedSHA: "abc", defaultBranch: "main"))
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
