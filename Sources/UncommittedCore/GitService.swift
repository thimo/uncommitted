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
    /// When the branch is ahead of or behind its upstream, follows up with
    /// `git log` to capture commit subjects for the tooltips.
    public static func status(at url: URL) -> RepoStatus? {
        let result = execute(["status", "--porcelain=v2", "--branch"], at: url)
        guard result.exitStatus == 0 else { return nil }
        guard let output = String(data: result.stdout, encoding: .utf8) else { return nil }
        guard var parsed = parse(output) else { return nil }

        if parsed.ahead > 0 {
            parsed.aheadCommits = commitSubjects(range: "@{u}..HEAD", at: url)
        }
        if parsed.behind > 0 {
            parsed.behindCommits = commitSubjects(range: "HEAD..@{u}", at: url)
        }
        return parsed
    }

    /// Runs `git log <range> --format=%s` and returns each commit's subject
    /// (first line only, which is what `%s` gives us). Empty on any error —
    /// callers treat this as a best-effort enrichment, never a failure.
    private static func commitSubjects(range: String, at url: URL) -> [String] {
        let result = execute(["log", range, "--format=%s"], at: url)
        guard result.exitStatus == 0,
              let output = String(data: result.stdout, encoding: .utf8) else {
            return []
        }
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public static func push(at url: URL) -> ActionResult {
        action(["push"], at: url)
    }

    /// Uses `--ff-only` so a diverged branch fails loudly rather than creating
    /// a merge commit or rebasing local work without user intent.
    public static func pull(at url: URL) -> ActionResult {
        action(["pull", "--ff-only"], at: url)
    }

    /// Background fetch from `origin`. `--quiet --no-tags --prune` keeps
    /// chatter low and removes server-side gone branches. Used by the
    /// `FetchScheduler`; goes through the same execute() pipeline as
    /// push/pull so SIGKILL-on-timeout still applies for stuck ssh helpers.
    public static func fetch(at url: URL) -> ActionResult {
        action(["fetch", "--quiet", "--no-tags", "--prune", "origin"], at: url)
    }

    /// Returns true if the repo has at least one remote configured. Used
    /// by the FetchScheduler to skip local-only repos forever (re-checked
    /// once per app launch). Empty stdout from `git remote` ⇒ no remotes.
    public static func hasRemote(at url: URL) -> Bool {
        let result = execute(["remote"], at: url)
        guard result.exitStatus == 0,
              let output = String(data: result.stdout, encoding: .utf8) else {
            // On error, assume yes — we'd rather attempt a fetch and let
            // it fail than silently disable a real repo because a single
            // `git remote` invocation hiccupped.
            return true
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

        // Drain via `read(upToCount:)` which is the Swift-throwing API.
        // `readDataToEndOfFile()` goes through Obj-C `readDataOfLength:`
        // and raises an NSException (not a Swift error) when the kernel
        // returns an error on the pending read — e.g. after we SIGKILL
        // the process group to clean up stuck ssh helpers. NSExceptions
        // can't be caught from Swift and propagate out as app crashes.
        func drain(_ handle: FileHandle) -> Data {
            var data = Data()
            do {
                while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                    data.append(chunk)
                }
            } catch {
                // Reader was force-closed or the remote end errored —
                // return whatever we managed to collect.
            }
            return data
        }

        group.enter()
        concurrentQueue.async {
            stdoutData = drain(stdoutPipe.fileHandleForReading)
            group.leave()
        }

        group.enter()
        concurrentQueue.async {
            stderrData = drain(stderrPipe.fileHandleForReading)
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
        var stagedPaths: [String] = []
        var unstagedPaths: [String] = []
        var untrackedPaths: [String] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let head = line.first else { continue }

            switch head {
            case "#":
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
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

            case "1":
                // `1 XY sub mH mI mW hH hI path` — path may contain spaces,
                // so cap the split at 8 so everything after the 8th space is
                // treated as one path field.
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count >= 9 else { continue }
                let xy = parts[1]
                let path = String(parts[8])
                recordEntry(xy: xy, path: path, stagedPaths: &stagedPaths, unstagedPaths: &unstagedPaths)

            case "2":
                // Renamed/copied: `2 XY sub mH mI mW hH hI Xscore path\torigPath`.
                // One extra field (the similarity score), then the path field
                // carries both paths separated by a tab — we only want `path`.
                let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count >= 10 else { continue }
                let xy = parts[1]
                let pathField = parts[9]
                let path = String(pathField.split(separator: "\t").first ?? pathField)
                recordEntry(xy: xy, path: path, stagedPaths: &stagedPaths, unstagedPaths: &unstagedPaths)

            case "?":
                // `? path` — everything after the space-after-? is the path.
                let afterMarker = line.index(line.startIndex, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                guard afterMarker < line.endIndex else { continue }
                untrackedPaths.append(String(line[afterMarker...]))

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
            stagedPaths: stagedPaths,
            unstagedPaths: unstagedPaths,
            untrackedPaths: untrackedPaths
        )
    }

    private static func recordEntry(
        xy: Substring,
        path: String,
        stagedPaths: inout [String],
        unstagedPaths: inout [String]
    ) {
        let chars = Array(xy)
        guard chars.count >= 2 else { return }
        if chars[0] != "." { stagedPaths.append(path) }
        if chars[1] != "." { unstagedPaths.append(path) }
    }
}
