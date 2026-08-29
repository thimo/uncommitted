import Foundation

/// Serialises the git commands that talk to a remote, per repository.
///
/// `git` writes `.git/FETCH_HEAD` without taking a lock on it. Two fetch-ish
/// commands running in the same repo at the same time — the background sweep's
/// `git fetch` and the internal fetch that `git pull` runs first — therefore
/// interleave their writes and leave a torn line in the file. `git pull
/// --rebase` reads that fragment as a second merge head and dies with
/// "fatal: Cannot rebase onto multiple branches"; a retry a second later
/// works, which is what made it look random. Cancelling the background
/// operation isn't enough: by the time the user clicks Pull the `git fetch`
/// subprocess is usually already running, and `Operation.cancel()` doesn't
/// reach into a running subprocess.
///
/// So every remote-touching command goes through here, keyed by repo path.
/// One at a time per repo; different repos still run in parallel. The waiting
/// side blocks a background thread for as long as the other command takes
/// (bounded by `GitService`'s low-speed guard), never the main thread.
///
/// This only covers *our* processes. A fetch from Tower, an IDE or a terminal
/// can still collide with ours — nothing in-process can prevent that.
public final class RepoGitLock {
    public static let shared = RepoGitLock()

    /// Guards `locks` itself. Held only for the dictionary lookup, never
    /// while a git command runs.
    private let registryLock = NSLock()
    /// One mutex per repo, keyed by standardized path. Entries are never
    /// removed: a repo the user has acted on once will very likely be acted
    /// on again, and an NSLock is a handful of bytes.
    private var locks: [String: NSLock] = [:]

    public init() {}

    /// Runs `body` with this repo's mutex held.
    public func withLock<T>(_ url: URL, _ body: () -> T) -> T {
        let lock = mutex(for: url)
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func mutex(for url: URL) -> NSLock {
        let key = url.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[key] { return existing }
        let created = NSLock()
        locks[key] = created
        return created
    }
}
