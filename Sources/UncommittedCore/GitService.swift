import Foundation
import os.log

private let log = Logger(subsystem: "nl.defrog.uncommitted", category: "git")

/// Classified representation of a git command failure. Cases are added
/// as we encounter real examples — unrecognised stderr falls through to
/// `.unknown` which preserves today's behaviour (raw stderr in the alert).
/// The point of classification is layered: a friendlier user-facing
/// message, an audit trail via os.log, and a hook for future smart
/// responses (auto-retry for transient failures, recovery buttons, etc).
public enum GitError: Equatable {
    /// `git pull --ff-only` refused because the local branch has commits
    /// the remote doesn't, and vice versa — not a fast-forward.
    case divergedFFOnly
    /// `git push` rejected because the local branch is behind the remote.
    case pushRejectedNonFastForward
    /// A `.git/*.lock` file blocked the operation — another git process
    /// is (or was) running. Transient in the common case; retried
    /// automatically before surfacing to the user.
    case lockFileExists
    /// Fallback: git exited non-zero but we didn't recognise the stderr
    /// pattern. The raw text is preserved so the alert can still show it.
    case unknown(stderr: String, exitStatus: Int32)

    /// Short, user-facing explanation suitable for an alert body. For
    /// `.unknown` the caller falls back to the raw stderr.
    public var userMessage: String? {
        switch self {
        case .divergedFFOnly:
            return "Your branch and the remote have both moved on independently. Git won't auto-merge or rebase them from the menu bar — resolve it in your editor or terminal and try again."
        case .pushRejectedNonFastForward:
            return "The remote has commits your branch doesn't. Pull first, resolve any conflicts, then push again."
        case .lockFileExists:
            return "Another git process is using this repo. If nothing else is running, the lock file may be stale — delete the .lock file inside .git/ to clear it."
        case .unknown:
            return nil
        }
    }

    /// Whether this error is transient and worth retrying automatically.
    public var isRetryable: Bool {
        switch self {
        case .lockFileExists: return true
        default: return false
        }
    }
}

public enum GitService {
    public struct ActionResult {
        public let success: Bool
        /// Captured stderr for use in error alerts. Nil on success.
        public let errorOutput: String?
        /// Classified failure kind. Nil on success.
        public let kind: GitError?

        public init(success: Bool, errorOutput: String?, kind: GitError? = nil) {
            self.success = success
            self.errorOutput = errorOutput
            self.kind = kind
        }
    }

    // MARK: - Entry points

    /// Reads repo status via `git status --porcelain=v2 --branch`. Returns
    /// nil if git fails or the output can't be parsed as a valid status.
    /// When the branch is ahead of or behind its upstream, follows up with
    /// `git log` to capture commit subjects for the tooltips.
    ///
    /// Uses `--no-optional-locks` so we never grab `index.lock`. Without
    /// this, every FSEvents-triggered status poll takes a brief lock that
    /// collides with concurrent git operations (other tools, CI, Claude
    /// Code instances running `git add`/`git commit` in the same repo).
    /// Uses `--untracked-files=all` so individual files inside untracked
    /// directories are counted, matching what other git tools show.
    public static func status(at url: URL) -> RepoStatus? {
        let result = execute(["--no-optional-locks", "status", "--porcelain=v2", "--branch", "--untracked-files=all"], at: url)
        guard result.exitStatus == 0 else {
            log.error("status failed at \(url.path, privacy: .public): exit \(result.exitStatus)")
            return nil
        }
        guard let output = String(data: result.stdout, encoding: .utf8) else {
            log.error("status: non-UTF8 stdout at \(url.path, privacy: .public)")
            return nil
        }
        guard var parsed = parse(output) else {
            log.error("status: parse returned nil at \(url.path, privacy: .public)")
            return nil
        }

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

    /// Prepended to any command that talks to a remote so a broken
    /// network fails fast instead of hanging on libcurl's default
    /// retry timeline. If the transfer drops below 1 KB/s for 20
    /// continuous seconds, git aborts with a "transfer closed" error.
    /// A healthy pull/push even on a weak wifi link stays well above
    /// this; a disconnected machine dies in ~20s.
    private static let lowSpeedGuard: [String] = [
        "-c", "http.lowSpeedLimit=1000",
        "-c", "http.lowSpeedTime=20",
    ]

    public static func push(at url: URL) -> ActionResult {
        action(Self.lowSpeedGuard + ["push"], at: url)
    }

    /// Uses `--ff-only` so a diverged branch fails loudly rather than creating
    /// a merge commit or rebasing local work without user intent.
    public static func pull(at url: URL) -> ActionResult {
        action(Self.lowSpeedGuard + ["pull", "--ff-only"], at: url)
    }

    /// Background fetch from `origin`. `--quiet --no-tags --prune` keeps
    /// chatter low and removes server-side gone branches. Used by the
    /// `FetchScheduler`; goes through the same execute() pipeline as
    /// push/pull so SIGKILL-on-timeout still applies for stuck ssh helpers.
    public static func fetch(at url: URL) -> ActionResult {
        action(Self.lowSpeedGuard + ["fetch", "--quiet", "--no-tags", "--prune", "origin"], at: url)
    }

    /// Returns the URL configured for the named remote (default: `origin`),
    /// or nil when the remote isn't configured or `git remote get-url`
    /// fails. Used by the GitHub status feature to discover the
    /// `owner/repo` slug — empty means "skip this repo for GitHub calls."
    public static func remoteURL(at url: URL, name: String = "origin") -> String? {
        let result = execute(["remote", "get-url", name], at: url)
        guard result.exitStatus == 0,
              let output = String(data: result.stdout, encoding: .utf8) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
    /// child subprocess (credential helper, etc) inherited our pipe FDs
    /// and stays alive past git's exit, EOF is blocked on that child, so
    /// we bail after this timeout and kill the process group. The real
    /// termination status still comes from git itself — the drain timeout
    /// just caps how long we wait to collect its stderr text.
    private static let pipeDrainTimeoutSeconds: Int = 2

    /// Baseline environment for every git invocation. Disables ssh
    /// ControlMaster multiplexing so that the ssh child git spawns for
    /// network ops (fetch/pull/push) exits cleanly with git instead of
    /// forking a long-lived master process that inherits — and holds
    /// open — our stdout/stderr pipes past git's own exit. Without this,
    /// the drain loop stalls until `pipeDrainTimeoutSeconds`, the process
    /// group gets SIGKILL'd, and a successful pull gets reported as a
    /// "background helper kept pipes open" failure.
    ///
    /// Honours an existing `GIT_SSH_COMMAND` if the user has one set —
    /// we only inject defaults when nothing is configured, so a custom
    /// ssh wrapper still wins.
    private static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o ControlMaster=no -o ControlPath=none"
        }
        return env
    }

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
        process.environment = buildEnvironment()

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
        let concurrentQueue = DispatchQueue(label: "nl.defrog.uncommitted.pipe-drain", attributes: .concurrent)

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
            // credential helpers or other subprocesses that inherited our
            // pipe FDs. ssh ControlMaster is disabled via GIT_SSH_COMMAND
            // so that specific offender shouldn't reach us any more.
            let pgid = getpgid(process.processIdentifier)
            if pgid > 0 {
                Foundation.kill(-pgid, SIGKILL)
            }

            // Force-close our read ends so the dangling readers see EOF
            // on their next read attempt and release their closure captures.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()

            // Trust git's own termination status — the drain timeout only
            // tells us "we couldn't collect all of stderr," not "the command
            // failed." Returning whatever stderr we did manage to buffer
            // before the timeout keeps any classified-error messages intact
            // on a genuine failure, and lets a successful exit flow straight
            // through to the success path on the caller side without a
            // spurious "Pull failed" dialog.
            return ExecuteResult(
                exitStatus: process.terminationStatus,
                stdout: stdoutData,
                stderr: stderrData,
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

    /// How long to watch a lock file before giving up.
    private static let lockWatchTimeout: TimeInterval = 5.0

    private static func action(_ args: [String], at url: URL) -> ActionResult {
        let firstResult = singleAttempt(args, at: url)
        guard !firstResult.success, case .lockFileExists = firstResult.kind else {
            return firstResult
        }

        // Try to watch the lock file for deletion rather than sleeping
        // blindly. Falls back to a short sleep if we can't parse the
        // path or open the file.
        let lockPath = Self.lockFilePath(from: firstResult.errorOutput ?? "")
        if let lockPath {
            let cleared = waitForLockRelease(path: lockPath, timeout: lockWatchTimeout)
            if cleared {
                log.info("lock file released, retrying at \(url.path, privacy: .public)")
            } else {
                log.info("lock file still present after \(lockWatchTimeout)s at \(url.path, privacy: .public)")
            }
        } else {
            // Couldn't parse lock path — short sleep as fallback.
            log.info("could not parse lock path, sleeping before retry at \(url.path, privacy: .public)")
            Thread.sleep(forTimeInterval: 1.0)
        }

        return singleAttempt(args, at: url)
    }

    /// Extracts the `.lock` file path from git's stderr.
    /// Pattern: `Unable to create '<path>.lock': File exists.`
    private static func lockFilePath(from stderr: String) -> String? {
        guard let range = stderr.range(of: "'[^']+\\.lock'", options: .regularExpression) else {
            return nil
        }
        return String(stderr[range].dropFirst().dropLast())
    }

    /// Watches a lock file using a GCD file-system source (`O_EVTONLY`)
    /// and returns `true` as soon as the file is deleted, or `false` if
    /// the timeout expires. If the file is already gone when we try to
    /// open it, returns `true` immediately.
    private static func waitForLockRelease(path: String, timeout: TimeInterval) -> Bool {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File already gone — retry right away.
            return true
        }
        defer { close(fd) }

        let semaphore = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .delete,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { semaphore.signal() }
        source.resume()

        let result = semaphore.wait(timeout: .now() + timeout)
        source.cancel()
        return result == .success
    }

    private static func singleAttempt(_ args: [String], at url: URL) -> ActionResult {
        let result = execute(args, at: url)

        if let launchFailure = result.launchFailure {
            log.error("launch failed at \(url.path, privacy: .public): \(launchFailure.localizedDescription, privacy: .public)")
            return ActionResult(
                success: false,
                errorOutput: launchFailure.localizedDescription,
                kind: nil
            )
        }

        if result.exitStatus == 0 {
            return ActionResult(success: true, errorOutput: nil, kind: nil)
        }

        let text = String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = !text.isEmpty ? text : "git exited with status \(result.exitStatus)"
        let kind = classify(exitStatus: result.exitStatus, stderr: text)
        log.error("git \(args.joined(separator: " "), privacy: .public) failed at \(url.path, privacy: .public): \(String(describing: kind), privacy: .public) — \(text, privacy: .public)")
        return ActionResult(success: false, errorOutput: message, kind: kind)
    }

    /// Pattern-match known failure modes from stderr. Conservative on
    /// purpose: anything unrecognised stays `.unknown` and the alert
    /// shows the raw output unchanged. Add new cases as we meet them.
    /// Public so tests can exercise the patterns directly.
    public static func classify(exitStatus: Int32, stderr: String) -> GitError {
        let lower = stderr.lowercased()

        // `git pull --ff-only` failure. Git phrases this two different
        // ways depending on version and locale, so we check both.
        if lower.contains("not possible to fast-forward")
            || lower.contains("diverging branches can't be fast-forwarded") {
            return .divergedFFOnly
        }

        // `git push` rejection. The canonical signal is a "[rejected]"
        // ref line followed by "(non-fast-forward)" in the same block,
        // plus "failed to push some refs to" as a secondary hint.
        if lower.contains("(non-fast-forward)")
            || (lower.contains("[rejected]") && lower.contains("failed to push some refs")) {
            return .pushRejectedNonFastForward
        }

        // Lock file collision: another git process holds a lock on the
        // index or a ref. Matches both `.git/index.lock` and ref-level
        // locks like `.git/refs/heads/main.lock`.
        if lower.contains("unable to create") && lower.contains(".lock") && lower.contains("file exists") {
            return .lockFileExists
        }

        return .unknown(stderr: stderr, exitStatus: exitStatus)
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
