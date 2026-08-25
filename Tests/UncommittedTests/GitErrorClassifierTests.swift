import Foundation
import UncommittedCore

enum GitErrorClassifierTests {
    static func register() {
        // MARK: - networkUnreachable

        test("GitError/network_curlCouldntConnect") {
            // Verbatim from the diagnostics log, 2026-08-14.
            let stderr = "fatal: unable to access 'https://github.com/sportcity-nl/electrolyte.git/': Failed to connect to github.com port 443 after 75004 ms: Couldn't connect to server"
            try expectEqual(GitService.classify(exitStatus: 128, stderr: stderr), .networkUnreachable)
        }

        test("GitError/network_curlCouldNotResolveHost") {
            let stderr = "fatal: unable to access 'https://github.com/foo/bar.git/': Could not resolve host: github.com"
            try expectEqual(GitService.classify(exitStatus: 128, stderr: stderr), .networkUnreachable)
        }

        test("GitError/network_sshUnreachable") {
            let stderr = """
            ssh: connect to host github.com port 22: Network is unreachable
            fatal: Could not read from remote repository.
            """
            try expectEqual(GitService.classify(exitStatus: 128, stderr: stderr), .networkUnreachable)
        }

        test("GitError/network_lowSpeedAbort") {
            let stderr = "fatal: unable to access 'https://github.com/foo/bar.git/': Operation too slow. Less than 1000 bytes/sec transferred the last 20 seconds"
            try expectEqual(GitService.classify(exitStatus: 128, stderr: stderr), .networkUnreachable)
        }

        test("GitError/network_authFailureStaysUnknown") {
            // "Could not read from remote repository" alone is also what a
            // bad ssh key produces — must not be mistaken for offline.
            let stderr = """
            git@github.com: Permission denied (publickey).
            fatal: Could not read from remote repository.
            """
            try expectEqual(GitService.classify(exitStatus: 128, stderr: stderr), .unknown(stderr: stderr, exitStatus: 128))
        }

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

        test("GitError/pushRejected_fullHintMentioningPull") {
            // Full git output includes "git pull" in the hint. Must NOT
            // match divergedFFOnly just because "pull" appears in the text.
            let stderr = """
            To https://github.com/example/repo.git
             ! [rejected]        develop -> develop (non-fast-forward)
            error: failed to push some refs to 'https://github.com/example/repo.git'
            hint: Updates were rejected because the tip of your current branch is behind
            hint: its remote counterpart. If you want to integrate the remote changes,
            hint: use 'git pull' before pushing again.
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

        // MARK: - lockFileExists

        test("GitError/lockFile_indexLock") {
            let stderr = """
            error: Unable to create '/Users/thimo/src/sportcity/electrolyte-calcium/.git/index.lock': File exists.

            Another git process seems to be running in this repository, e.g.
            an editor opened by 'git commit'. Please make sure all processes
            are terminated then and try again.
            """
            try expectEqual(
                GitService.classify(exitStatus: 128, stderr: stderr),
                .lockFileExists
            )
        }

        test("GitError/lockFile_refLock") {
            let stderr = "error: Unable to create '/path/to/repo/.git/refs/heads/main.lock': File exists."
            try expectEqual(
                GitService.classify(exitStatus: 128, stderr: stderr),
                .lockFileExists
            )
        }

        // MARK: - unknown fallback

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

        // MARK: - pullArguments

        test("GitService/pullArguments_ffOnly") {
            try expectEqual(GitService.pullArguments(strategy: .ffOnly), ["pull", "--ff-only"])
        }
        test("GitService/pullArguments_rebase") {
            try expectEqual(GitService.pullArguments(strategy: .rebase), ["pull", "--rebase"])
        }
        test("GitService/pullArguments_merge") {
            try expectEqual(GitService.pullArguments(strategy: .merge), ["pull", "--no-rebase"])
        }
    }
}
