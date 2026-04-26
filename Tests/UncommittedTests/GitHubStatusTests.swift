import Foundation
import UncommittedCore

enum GitHubStatusTests {
    static func register() {
        registerRemoteParserTests()
        registerBotAuthorTests()
        registerAggregateTests()
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
}
