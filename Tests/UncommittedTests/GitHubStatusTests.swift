import Foundation
import UncommittedCore

enum GitHubStatusTests {
    static func register() {
        registerRemoteParserTests()
        registerBotAuthorTests()
        registerAggregateTests()
        registerPRClassifierTests()
        registerPRAttentionTests()
        registerSummariesFixtureTests()
        registerLegacyCacheTests()
        registerPRReasonLabelTests()
        registerPrimaryCloneTests()
    }

    // MARK: - GitHubRemoteParser

    private static func registerRemoteParserTests() {
        test("GitHubRemoteParser/scpStyle_withDotGit") {
            let remote = GitHubRemoteParser.parse("git@github.com:thimo/uncommitted.git")
            try expectEqual(remote?.owner, "thimo")
            try expectEqual(remote?.repo, "uncommitted")
        }

        test("GitHubRemoteParser/scpStyle_withoutDotGit") {
            let remote = GitHubRemoteParser.parse("git@github.com:thimo/uncommitted")
            try expectEqual(remote?.owner, "thimo")
            try expectEqual(remote?.repo, "uncommitted")
        }

        test("GitHubRemoteParser/https_withDotGit") {
            let remote = GitHubRemoteParser.parse("https://github.com/sportcity-nl/electrolyte.git")
            try expectEqual(remote?.owner, "sportcity-nl")
            try expectEqual(remote?.repo, "electrolyte")
        }

        test("GitHubRemoteParser/https_withoutDotGit") {
            let remote = GitHubRemoteParser.parse("https://github.com/sportcity-nl/electrolyte")
            try expectEqual(remote?.owner, "sportcity-nl")
            try expectEqual(remote?.repo, "electrolyte")
        }

        test("GitHubRemoteParser/sshURL") {
            let remote = GitHubRemoteParser.parse("ssh://git@github.com/foo/bar.git")
            try expectEqual(remote?.owner, "foo")
            try expectEqual(remote?.repo, "bar")
        }

        test("GitHubRemoteParser/gitlabReturnsNil") {
            try expect(GitHubRemoteParser.parse("git@gitlab.com:foo/bar.git") == nil)
        }

        test("GitHubRemoteParser/genericHostReturnsNil") {
            try expect(GitHubRemoteParser.parse("https://example.com/foo/bar.git") == nil)
        }

        test("GitHubRemoteParser/emptyReturnsNil") {
            try expect(GitHubRemoteParser.parse("") == nil)
            try expect(GitHubRemoteParser.parse("   \n  ") == nil)
        }

        test("GitHubRemoteParser/malformedReturnsNil") {
            // Slug missing the second segment.
            try expect(GitHubRemoteParser.parse("git@github.com:foo.git") == nil)
            // Three-segment path isn't owner/repo.
            try expect(GitHubRemoteParser.parse("https://github.com/foo/bar/baz") == nil)
        }

        test("GitHubRemoteParser/caseInsensitiveHost") {
            let remote = GitHubRemoteParser.parse("git@GitHub.com:foo/bar.git")
            try expectEqual(remote?.owner, "foo")
            try expectEqual(remote?.repo, "bar")
        }
    }

    // MARK: - Bot author detection

    private static func registerBotAuthorTests() {
        test("isBotAuthor/userTypeBotWins") {
            try expect(GitHubAPI.isBotAuthor(login: "anyone", type: "Bot"))
            try expect(GitHubAPI.isBotAuthor(login: "ANYONE", type: "bot"))
        }

        test("isBotAuthor/dependabotLogin") {
            try expect(GitHubAPI.isBotAuthor(login: "dependabot", type: "User"))
            try expect(GitHubAPI.isBotAuthor(login: "Dependabot", type: nil))
        }

        test("isBotAuthor/renovateLogin") {
            try expect(GitHubAPI.isBotAuthor(login: "renovate", type: nil))
            try expect(GitHubAPI.isBotAuthor(login: "renovate-bot", type: nil))
        }

        test("isBotAuthor/githubActionsLogin") {
            try expect(GitHubAPI.isBotAuthor(login: "github-actions", type: nil))
        }

        test("isBotAuthor/bracketBotSuffix") {
            try expect(GitHubAPI.isBotAuthor(login: "dependabot[bot]", type: nil))
            try expect(GitHubAPI.isBotAuthor(login: "myorg-bot[bot]", type: nil))
        }

        test("isBotAuthor/normalUserIsHuman") {
            try expect(!GitHubAPI.isBotAuthor(login: "thimo", type: "User"))
            try expect(!GitHubAPI.isBotAuthor(login: "octocat", type: nil))
        }

        test("isBotAuthor/nilLoginIsHuman") {
            try expect(!GitHubAPI.isBotAuthor(login: nil, type: nil))
        }
    }

    // MARK: - aggregate(workflowRuns:)

    private static func registerAggregateTests() {
        test("aggregate/emptyArrayIsNone") {
            try expectEqual(GitHubAPI.aggregate(workflowRuns: []), .none)
        }

        test("aggregate/allSuccessIsSuccess") {
            let runs = [
                GitHubAPI.WorkflowRun(status: "completed", conclusion: "success"),
                GitHubAPI.WorkflowRun(status: "completed", conclusion: "neutral"),
                GitHubAPI.WorkflowRun(status: "completed", conclusion: "skipped"),
            ]
            try expectEqual(GitHubAPI.aggregate(workflowRuns: runs), .success)
        }

        test("aggregate/anyFailureIsFailure") {
            let runs = [
                GitHubAPI.WorkflowRun(status: "completed", conclusion: "success"),
                GitHubAPI.WorkflowRun(status: "completed", conclusion: "failure"),
            ]
            try expectEqual(GitHubAPI.aggregate(workflowRuns: runs), .failure)
        }

        test("aggregate/cancelledIsFailure") {
            let runs = [GitHubAPI.WorkflowRun(status: "completed", conclusion: "cancelled")]
            try expectEqual(GitHubAPI.aggregate(workflowRuns: runs), .failure)
        }

        test("aggregate/timedOutIsFailure") {
            let runs = [GitHubAPI.WorkflowRun(status: "completed", conclusion: "timed_out")]
            try expectEqual(GitHubAPI.aggregate(workflowRuns: runs), .failure)
        }

        test("aggregate/inProgressIsPending") {
            let runs = [
                GitHubAPI.WorkflowRun(status: "completed", conclusion: "success"),
                GitHubAPI.WorkflowRun(status: "in_progress", conclusion: nil),
            ]
            try expectEqual(GitHubAPI.aggregate(workflowRuns: runs), .pending)
        }

        test("aggregate/queuedIsPending") {
            let runs = [GitHubAPI.WorkflowRun(status: "queued", conclusion: nil)]
            try expectEqual(GitHubAPI.aggregate(workflowRuns: runs), .pending)
        }

        test("aggregate/failureBeatsPending") {
            let runs = [
                GitHubAPI.WorkflowRun(status: "in_progress", conclusion: nil),
                GitHubAPI.WorkflowRun(status: "completed", conclusion: "failure"),
            ]
            try expectEqual(GitHubAPI.aggregate(workflowRuns: runs), .failure)
        }

        test("aggregate/staleIsSuccess") {
            // Stale = re-run was skipped because nothing changed; treat
            // as success so we don't flag green builds as red.
            let runs = [GitHubAPI.WorkflowRun(status: "completed", conclusion: "stale")]
            try expectEqual(GitHubAPI.aggregate(workflowRuns: runs), .success)
        }

        test("latestPerWorkflow/keepsFirstPerId") {
            // API returns newest first; we should keep the newest entry
            // for each workflowId and drop earlier history.
            let runs = [
                GitHubAPI.WorkflowRun(name: "CI", status: "completed", conclusion: "success", workflowId: 1),
                GitHubAPI.WorkflowRun(name: "CI", status: "completed", conclusion: "failure", workflowId: 1),
                GitHubAPI.WorkflowRun(name: "Lint", status: "completed", conclusion: "success", workflowId: 2),
            ]
            let latest = GitHubAPI.latestPerWorkflow(runs)
            try expectEqual(latest.count, 2)
            try expectEqual(latest[0].conclusion, "success")
            try expectEqual(latest[1].name, "Lint")
        }
    }

    // MARK: - PRClassifier

    private static func registerPRClassifierTests() {
        test("PRClassifier/draftBeatsEverything") {
            // Even a change-requested-on-my-own-PR draft is still just a draft.
            let f = PRClassifier.Facts(authorLogin: "thimo", isDraft: true, reviewDecision: "CHANGES_REQUESTED")
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .draft)
        }

        test("PRClassifier/myPR_changesRequested") {
            let f = PRClassifier.Facts(authorLogin: "thimo", reviewDecision: "CHANGES_REQUESTED")
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .mine(.changesRequestedOnMine))
        }

        test("PRClassifier/myPR_ciFailing") {
            let f = PRClassifier.Facts(authorLogin: "thimo", ciState: "FAILURE")
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .mine(.ciFailingOnMine))
            let f2 = PRClassifier.Facts(authorLogin: "thimo", ciState: "ERROR")
            try expectEqual(PRClassifier.classify(f2, viewer: "thimo"), .mine(.ciFailingOnMine))
        }

        test("PRClassifier/myPR_changesRequestedBeatsCIFailure") {
            let f = PRClassifier.Facts(authorLogin: "thimo", reviewDecision: "CHANGES_REQUESTED", ciState: "FAILURE")
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .mine(.changesRequestedOnMine))
        }

        test("PRClassifier/myPR_approved") {
            let f = PRClassifier.Facts(authorLogin: "thimo", reviewDecision: "APPROVED")
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .mine(.approvedReadyToMerge))
        }

        test("PRClassifier/myPR_awaitingReview") {
            let f = PRClassifier.Facts(authorLogin: "thimo", reviewDecision: "REVIEW_REQUIRED")
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .waiting(.awaitingReview))
        }

        test("PRClassifier/viewerCaseInsensitive_myPR") {
            let f = PRClassifier.Facts(authorLogin: "Thimo", reviewDecision: "APPROVED")
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .mine(.approvedReadyToMerge))
        }

        test("PRClassifier/reviewRequested") {
            let f = PRClassifier.Facts(authorLogin: "octocat", requestedUserLogins: ["thimo"])
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .mine(.reviewRequested))
        }

        test("PRClassifier/reviewRequested_viewerCaseInsensitive") {
            let f = PRClassifier.Facts(authorLogin: "octocat", requestedUserLogins: ["Thimo"])
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .mine(.reviewRequested))
        }

        test("PRClassifier/teamRequestCountsAsMine") {
            let f = PRClassifier.Facts(authorLogin: "octocat", teamReviewRequested: true)
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .mine(.reviewRequested))
        }

        test("PRClassifier/newCommitsAfterMyReview_isMine") {
            let reviewedAt = Date(timeIntervalSince1970: 1000)
            let commitAt = Date(timeIntervalSince1970: 2000)
            let f = PRClassifier.Facts(
                authorLogin: "octocat",
                myLatestReviewState: "APPROVED",
                myLatestReviewAt: reviewedAt,
                lastCommitAt: commitAt
            )
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .mine(.newCommitsSinceReview))
        }

        test("PRClassifier/myReviewAfterLastCommit_isWaiting") {
            let commitAt = Date(timeIntervalSince1970: 1000)
            let reviewedAt = Date(timeIntervalSince1970: 2000)
            let f = PRClassifier.Facts(
                authorLogin: "octocat",
                myLatestReviewState: "APPROVED",
                myLatestReviewAt: reviewedAt,
                lastCommitAt: commitAt
            )
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .waiting(.waitingOnAuthor))
        }

        test("PRClassifier/myReviewNoNewCommits_isWaiting") {
            let f = PRClassifier.Facts(
                authorLogin: "octocat",
                myLatestReviewState: "COMMENTED",
                myLatestReviewAt: Date(timeIntervalSince1970: 1000)
            )
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .waiting(.waitingOnAuthor))
        }

        test("PRClassifier/botAuthor_notReviewedByMe_isWaitingBot") {
            let f = PRClassifier.Facts(authorLogin: "dependabot[bot]", authorIsBot: true)
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .waiting(.bot))
        }

        test("PRClassifier/notInvolved") {
            let f = PRClassifier.Facts(authorLogin: "octocat")
            try expectEqual(PRClassifier.classify(f, viewer: "thimo"), .waiting(.notInvolved))
        }
    }

    // MARK: - PRAttention / PRCount

    private static func registerPRAttentionTests() {
        test("PRAttention/sortRankOrdering") {
            try expectEqual(PRAttention.mine(.reviewRequested).sortRank, 0)
            try expectEqual(PRAttention.waiting(.notInvolved).sortRank, 1)
            try expectEqual(PRAttention.waiting(.bot).sortRank, 2)
            try expectEqual(PRAttention.draft.sortRank, 3)
        }

        test("PRAttention/isMineAndIsDraft") {
            try expect(PRAttention.mine(.awaitingReview).isMine)
            try expect(!PRAttention.waiting(.notInvolved).isMine)
            try expect(PRAttention.draft.isDraft)
            try expect(!PRAttention.mine(.awaitingReview).isDraft)
            try expectEqual(PRAttention.draft.reason, .draft)
        }

        test("PRCount/derivedFromMixedSummaries_excludesDrafts") {
            let prs = [
                summary(number: 1, attention: .mine(.reviewRequested)),
                summary(number: 2, attention: .mine(.approvedReadyToMerge)),
                summary(number: 3, attention: .waiting(.notInvolved)),
                summary(number: 4, attention: .waiting(.bot)),
                summary(number: 5, attention: .draft, isDraft: true),
            ]
            let count = PRCount(prs: prs)
            try expectEqual(count.mine, 2)
            try expectEqual(count.waiting, 2)
            try expectEqual(count.total, 4)
        }
    }

    private static func summary(number: Int, attention: PRAttention, isDraft: Bool = false) -> PRSummary {
        PRSummary(
            number: number,
            title: "PR #\(number)",
            url: "https://github.com/o/r/pull/\(number)",
            authorLogin: "someone",
            isBotAuthor: false,
            isDraft: isDraft,
            attention: attention,
            updatedAt: Date(timeIntervalSince1970: Double(number))
        )
    }

    // MARK: - GitHubAPI.summaries(from:viewer:) fixture

    private static func registerSummariesFixtureTests() {
        test("GitHubAPI/summaries_fromFixture") {
            let json = """
            {"data":{"viewer":{"login":"thimo"},"repository":{"pullRequests":{"nodes":[
             {"number":14255,"title":"Fix flag parsing","url":"https://github.com/cli/cli/pull/14255","isDraft":false,
              "updatedAt":"2026-08-25T05:39:31Z","author":{"login":"BagToad","__typename":"User"},
              "reviewDecision":"REVIEW_REQUIRED",
              "reviewRequests":{"nodes":[{"requestedReviewer":null},{"requestedReviewer":{"__typename":"User","login":"sergiou87"}}]},
              "latestReviews":{"nodes":[{"author":{"login":"x"},"state":"COMMENTED","submittedAt":"2026-08-25T05:25:37Z"}]},
              "commits":{"nodes":[{"commit":{"committedDate":"2026-08-25T05:17:19Z","statusCheckRollup":{"state":"SUCCESS"}}}]}},
             {"number":100,"title":"Bump lodash","url":"https://github.com/o/r/pull/100","isDraft":false,
              "updatedAt":"2026-08-24T00:00:00Z","author":{"login":"dependabot[bot]","__typename":"Bot"},
              "reviewDecision":null,
              "reviewRequests":{"nodes":[]},
              "latestReviews":{"nodes":[]},
              "commits":{"nodes":[{"commit":{"committedDate":"2026-08-24T00:00:00Z","statusCheckRollup":null}}]}},
             {"number":101,"title":"Team-reviewed change","url":"https://github.com/o/r/pull/101","isDraft":false,
              "updatedAt":"2026-08-23T00:00:00Z","author":{"login":"octocat","__typename":"User"},
              "reviewDecision":null,
              "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","slug":"platform"}}]},
              "latestReviews":{"nodes":[]},
              "commits":{"nodes":[{"commit":{"committedDate":"2026-08-23T00:00:00Z","statusCheckRollup":null}}]}},
             {"number":102,"title":"PR from a deleted account","url":"https://github.com/o/r/pull/102","isDraft":false,
              "updatedAt":"2026-08-22T00:00:00Z","author":null,
              "reviewDecision":null,
              "reviewRequests":{"nodes":[]},
              "latestReviews":{"nodes":[]},
              "commits":{"nodes":[{"commit":{"committedDate":"2026-08-22T00:00:00Z","statusCheckRollup":null}}]}},
             {"number":103,"title":"Work in progress","url":"https://github.com/o/r/pull/103","isDraft":true,
              "updatedAt":"2026-08-21T00:00:00Z","author":{"login":"thimo","__typename":"User"},
              "reviewDecision":null,
              "reviewRequests":{"nodes":[]},
              "latestReviews":{"nodes":[]},
              "commits":{"nodes":[{"commit":{"committedDate":"2026-08-21T00:00:00Z","statusCheckRollup":null}}]}}
            ]}}}}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(GitHubAPI.PullRequestsResponse.self, from: Data(json.utf8))
            let summaries = GitHubAPI.summaries(from: response, viewer: "thimo")
            try expectEqual(summaries.count, 5)

            let byNumber = Dictionary(uniqueKeysWithValues: summaries.map { ($0.number, $0) })

            // Neither reviewed by nor requested of thimo — waiting, not involved.
            try expectEqual(byNumber[14255]?.attention, .waiting(.notInvolved))

            // Bot author, thimo not involved — waiting, bot.
            try expectEqual(byNumber[100]?.isBotAuthor, true)
            try expectEqual(byNumber[100]?.attention, .waiting(.bot))

            // Team review requested — counts as mine.
            try expectEqual(byNumber[101]?.attention, .mine(.reviewRequested))

            // Deleted author decodes to an empty login, not involved.
            try expectEqual(byNumber[102]?.authorLogin, "")
            try expectEqual(byNumber[102]?.attention, .waiting(.notInvolved))

            // My own draft — draft outranks everything else.
            try expectEqual(byNumber[103]?.attention, .draft)
        }
    }

    // MARK: - GitHubRepoStatus legacy cache decoding

    private static func registerLegacyCacheTests() {
        test("GitHubRepoStatus/decodesLegacyCacheWithoutPrs") {
            // Old cache files carried `prCount: {humans, bots}` and no `prs`
            // key. Decoding should ignore the stale key rather than fail.
            let json = """
            {"prCount":{"humans":1,"bots":2},"ciStatus":"success","fetchedAt":"2026-08-25T00:00:00Z"}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let status = try decoder.decode(GitHubRepoStatus.self, from: Data(json.utf8))
            try expectEqual(status.prs, [])
            try expect(status.prCount.isEmpty)
            try expect(status.slug == nil)
        }
    }

    // MARK: - Primary clone per slug

    private static func registerPrimaryCloneTests() {
        let a = URL(fileURLWithPath: "/r/electrolyte")
        let b = URL(fileURLWithPath: "/r/electrolyte-calcium")
        let c = URL(fileURLWithPath: "/r/electrolyte-natrium")
        let other = URL(fileURLWithPath: "/r/web")
        let unknown = URL(fileURLWithPath: "/r/local-only")

        test("PrimaryClonePicker/firstInOrderWinsPerSlug") {
            let slugs = [a: "org/el", b: "org/el", c: "org/el", other: "org/web"]
            let primary = PrimaryClonePicker.primaryURLs(orderedURLs: [b, a, c, other], slugs: slugs)
            try expectEqual(primary, [b, other])
        }

        test("PrimaryClonePicker/unknownSlugIsAlwaysPrimary") {
            let slugs = [a: "org/el", b: "org/el"]
            let primary = PrimaryClonePicker.primaryURLs(orderedURLs: [a, unknown, b], slugs: slugs)
            try expectEqual(primary, [a, unknown])
        }

        test("GitHubRepoStatus/withoutPRs_keepsCI") {
            let pr = PRSummary(
                number: 1, title: "t", url: "u", authorLogin: "x", isBotAuthor: false,
                isDraft: false, attention: .waiting(.notInvolved), updatedAt: Date()
            )
            let status = GitHubRepoStatus(prs: [pr], ciStatus: .failure, failingCheckNames: ["lint"], slug: "org/el")
            let stripped = status.withoutPRs
            try expectEqual(stripped.prs, [])
            try expectEqual(stripped.ciStatus, .failure)
            try expectEqual(stripped.failingCheckNames, ["lint"])
            try expectEqual(stripped.slug, "org/el")
        }
    }

    // MARK: - PRReason labels

    private static func registerPRReasonLabelTests() {
        test("PRReason/labels") {
            try expectEqual(PRReason.changesRequestedOnMine.label, "changes requested")
            try expectEqual(PRReason.ciFailingOnMine.label, "CI failing")
            try expectEqual(PRReason.approvedReadyToMerge.label, "approved · merge")
            try expectEqual(PRReason.reviewRequested.label, "your review requested")
            try expectEqual(PRReason.newCommitsSinceReview.label, "new commits since your review")
            try expectEqual(PRReason.awaitingReview.label, "waiting for review")
            try expectEqual(PRReason.waitingOnAuthor.label, "waiting on @<author>")
            try expectEqual(PRReason.notInvolved.label, "")
            try expectEqual(PRReason.bot.label, "bot")
            try expectEqual(PRReason.draft.label, "draft")
        }
    }
}
