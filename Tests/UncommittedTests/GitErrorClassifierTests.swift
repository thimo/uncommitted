import Foundation
import UncommittedCore

enum GitErrorClassifierTests {
    static func register() {
        // MARK: - divergedFFOnly

        test("GitError/pullDiverged_notPossibleToFastForward") {
            let stderr = """
            hint: Diverging branches can't be fast-forwarded, you need to either:
            hint:
            hint:   git merge --no-ff
            hint:   or:
            hint:   git rebase
            hint:
            fatal: Not possible to fast-forward, aborting.
            """
            try expectEqual(
                GitService.classify(exitStatus: 128, stderr: stderr),
                .divergedFFOnly
            )
        }

        test("GitError/pullDiverged_divergingBranchesLiteral") {
            let stderr = "fatal: Diverging branches can't be fast-forwarded."
            try expectEqual(
                GitService.classify(exitStatus: 128, stderr: stderr),
                .divergedFFOnly
            )
        }

        // MARK: - pushRejectedNonFastForward

        test("GitError/pushRejected_nonFastForwardExplicit") {
            let stderr = """
            To https://github.com/example/repo.git
             ! [rejected]        develop -> develop (non-fast-forward)
            error: failed to push some refs to 'https://github.com/example/repo.git'
            hint: Updates were rejected because the tip of your current branch is behind
            """
            try expectEqual(
                GitService.classify(exitStatus: 1, stderr: stderr),
                .pushRejectedNonFastForward
            )
        }

        test("GitError/pushRejected_rejectedAndFailedToPush") {
            // Some git versions emit "[rejected]" without the "(non-fast-forward)"
            // suffix when config.push.default is "simple" — fall back to the
            // "failed to push some refs" combo.
            let stderr = """
             ! [rejected]        develop -> develop
            error: failed to push some refs to 'git@github.com:example/repo.git'
            """
            try expectEqual(
                GitService.classify(exitStatus: 1, stderr: stderr),
                .pushRejectedNonFastForward
            )
        }

        // MARK: - unknown fallback

        test("GitError/networkFailure_fallsThroughToUnknown") {
            // Network errors aren't classified yet — they should stay in
            // `.unknown` so the raw stderr still reaches the alert.
            let stderr = "fatal: unable to access 'https://example.com/repo.git/': Could not resolve host: example.com"
            let result = GitService.classify(exitStatus: 128, stderr: stderr)
            if case .unknown = result { } else {
                throw TestFailure(
                    message: "expected .unknown, got \(result)",
                    file: #file,
                    line: #line
                )
            }
        }

        test("GitError/emptyStderr_fallsThroughToUnknown") {
            let result = GitService.classify(exitStatus: 1, stderr: "")
            if case .unknown = result { } else {
                throw TestFailure(
                    message: "expected .unknown, got \(result)",
                    file: #file,
                    line: #line
                )
            }
        }
    }
}
