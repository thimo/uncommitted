import Foundation

public enum GitService {
    public struct ActionResult {
        public let success: Bool
        /// Captured stderr for use in error alerts. Nil on success.
        public let errorOutput: String?
    }

    // MARK: - Entry points

    /// Reads repo status via `git status --porcelain=v2 --branch`. Returns
    /// nil if git fails or the output can't be parsed as a valid status.
    public static func status(at url: URL) -> RepoStatus? {
        let result = execute(["status", "--porcelain=v2", "--branch"], at: url)
        guard result.exitStatus == 0 else { return nil }
        guard let output = String(data: result.stdout, encoding: .utf8) else { return nil }
        return parse(output)
    }

    public static func push(at url: URL) -> ActionResult {
        action(["push"], at: url)
    }

    /// Uses `--ff-only` so a diverged branch fails loudly rather than creating
    /// a merge commit or rebasing local work without user intent.
    public static func pull(at url: URL) -> ActionResult {
        action(["pull", "--ff-only"], at: url)
    }

    // MARK: - Shared process runner

    private struct ExecuteResult {
        let exitStatus: Int32
        let stdout: Data
        let stderr: Data
        let launchFailure: Error?
    }

    /// After git exits, how long we wait for the stdout/stderr pipes to
    /// drain to EOF. Should be near-instant in the normal case — git is
    /// the only writer, so EOF fires the moment the process dies. If a
    /// child subprocess (ssh ControlMaster, credential helper) inherited
    /// our pipe FDs and stays alive past git's exit, EOF is blocked on
    /// that child, so we bail after this timeout, kill the process group,
    /// and return a stale-state-refresh error.
    private static let pipeDrainTimeoutSeconds: Int = 2

    /// Runs `/usr/bin/git <args>` in `url` with stdout and stderr captured
    /// concurrently on background queues.
    ///
    /// The concurrent drain is necessary to avoid a ~64KB pipe-buffer
    /// deadlock: if we read one pipe sequentially, git can block writing
    /// the other one and deadlock.
    ///
    /// We wait for the process to exit *first* — this is unbounded on
    /// purpose, so a legitimately slow git operation (large fetch, slow
    /// network) has all the time it needs. Only *after* git has exited
    /// do we apply a short timeout to the pipe drain. In the happy path
    /// the pipes see EOF instantly when git dies and this is a no-op. In
    /// the pathological case where a child subprocess kept our pipe FDs
    /// open past git's exit, the short timeout detects that, kills the
    /// process group to sever the children, and force-closes our FDs.
    private static func execute(_ args: [String], at url: URL) -> ExecuteResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = url
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ExecuteResult(exitStatus: -1, stdout: Data(), stderr: Data(), launchFailure: error)
        }

        // Concurrent drain — neither pipe can starve the other.
        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "nl.thimo.uncommitted.pipe-drain", attributes: .concurrent)

        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        concurrentQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        concurrentQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Wait unbounded for git to actually finish its work.
        process.waitUntilExit()

        // Git is dead. Pipe drains SHOULD be done (or finishing right now)
        // because EOF fires when the last writer closes. If they're still
        // blocked, a child subprocess inherited our pipe FDs.
        let drained = group.wait(timeout: .now() + .seconds(pipeDrainTimeoutSeconds))

        if drained == .timedOut {
            // Sever any surviving children from the pipes by killing the
            // process group. git itself is already gone; this only targets
            // ssh helpers and the like.
            let pgid = getpgid(process.processIdentifier)
            if pgid > 0 {
                Foundation.kill(-pgid, SIGKILL)
            }

            // Force-close our read ends so the dangling readers see EOF
            // on their next read attempt and release their closure captures.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()

            return ExecuteResult(
                exitStatus: -1,
                stdout: Data(),
                stderr: "A background helper (ssh ControlMaster, credential cache) kept stdout/stderr open after git exited. Git probably succeeded — refresh to confirm.".data(using: .utf8) ?? Data(),
                launchFailure: nil
            )
        }

        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        return ExecuteResult(
            exitStatus: process.terminationStatus,
            stdout: stdoutData,
            stderr: stderrData,
            launchFailure: nil
        )
    }

    private static func action(_ args: [String], at url: URL) -> ActionResult {
        let result = execute(args, at: url)

        if let launchFailure = result.launchFailure {
            return ActionResult(success: false, errorOutput: launchFailure.localizedDescription)
        }

        if result.exitStatus == 0 {
            return ActionResult(success: true, errorOutput: nil)
        }

        let text = String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (text?.isEmpty == false ? text : nil)
            ?? "git exited with status \(result.exitStatus)"
        return ActionResult(success: false, errorOutput: message)
    }

    // MARK: - Parser

    /// Parses `git status --porcelain=v2 --branch` output. Returns nil if the
    /// output is missing the `branch.oid` header, which git always emits for a
    /// real repository — if it's absent, something is wrong and we'd rather
    /// preserve the previous status than record a bogus "clean" state.
    /// Public so the test runner can exercise it directly.
    public static func parse(_ output: String) -> RepoStatus? {
        var branch = "(detached)"
        var headOid: String?
        var ahead = 0
        var behind = 0
        var staged = 0
        var unstaged = 0
        var untracked = 0

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = parts.first else { continue }

            switch head {
            case "#":
                guard parts.count >= 2 else { continue }
                switch parts[1] {
                case "branch.oid":
                    if parts.count >= 3 { headOid = String(parts[2]) }
                case "branch.head":
                    if parts.count >= 3 { branch = String(parts[2]) }
                case "branch.ab":
                    if parts.count >= 4 {
                        ahead = Int(parts[2].dropFirst()) ?? 0
                        behind = Int(parts[3].dropFirst()) ?? 0
                    }
                default: break
                }

            case "1", "2":
                // Entry line: "1 XY ..." where X = index status, Y = worktree status.
                // "." means unchanged in that column.
                guard parts.count >= 2 else { continue }
                let xy = parts[1]
                let chars = Array(xy)
                if chars.count >= 2 {
                    if chars[0] != "." { staged += 1 }
                    if chars[1] != "." { unstaged += 1 }
                }

            case "?":
                untracked += 1

            default:
                break
            }
        }

        // Require at least a branch.oid — every healthy repo emits one.
        // Without it we can't trust that "no entry lines" actually means "clean".
        guard headOid != nil else { return nil }

        return RepoStatus(
            branch: branch,
            headOid: headOid,
            ahead: ahead,
            behind: behind,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked
        )
    }
}
