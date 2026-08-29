import Foundation
import UncommittedCore

enum RepoGitLockTests {
    static func register() {
        // MARK: - Mutual exclusion

        test("RepoGitLock/sameRepo_commandsDoNotOverlap") {
            // The bug this exists for: two git commands writing FETCH_HEAD in
            // the same repo at the same time. Assert that no two blocks are
            // ever inside the lock together.
            let lock = RepoGitLock()
            let url = URL(fileURLWithPath: "/tmp/repo-a")
            let counter = Counter()
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "test.repogitlock.same", attributes: .concurrent)

            for _ in 0..<20 {
                queue.async(group: group) {
                    lock.withLock(url) {
                        counter.enter()
                        Thread.sleep(forTimeInterval: 0.002)
                        counter.leave()
                    }
                }
            }
            group.wait()

            try expectEqual(counter.maxConcurrent, 1)
            try expectEqual(counter.completed, 20)
        }

        test("RepoGitLock/differentRepos_runInParallel") {
            // Serializing everything would make a 20-repo sweep crawl. The
            // lock is per repo, so different paths must not block each other.
            let lock = RepoGitLock()
            let counter = Counter()
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "test.repogitlock.diff", attributes: .concurrent)
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)

            for index in 0..<2 {
                queue.async(group: group) {
                    lock.withLock(URL(fileURLWithPath: "/tmp/repo-\(index)")) {
                        counter.enter()
                        started.signal()
                        // Hold until both blocks are inside; a per-repo lock
                        // lets that happen, a global one would deadlock here
                        // (guarded by the timeout below).
                        _ = release.wait(timeout: .now() + 2)
                        counter.leave()
                    }
                }
            }

            _ = started.wait(timeout: .now() + 2)
            _ = started.wait(timeout: .now() + 2)
            let bothInside = counter.maxConcurrent == 2
            release.signal()
            release.signal()
            group.wait()

            try expect(bothInside, "expected both repos to hold their own lock at once")
        }

        test("RepoGitLock/pathIsStandardized") {
            // Repo URLs reach the lock from config, FSEvents and git output;
            // trailing slashes and `..` segments must not hand out a second
            // mutex for the same repo.
            let lock = RepoGitLock()
            let counter = Counter()
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "test.repogitlock.norm", attributes: .concurrent)
            let variants = [
                URL(fileURLWithPath: "/tmp/src/repo"),
                URL(fileURLWithPath: "/tmp/src/repo/"),
                URL(fileURLWithPath: "/tmp/src/other/../repo"),
            ]

            for url in variants {
                for _ in 0..<5 {
                    queue.async(group: group) {
                        lock.withLock(url) {
                            counter.enter()
                            Thread.sleep(forTimeInterval: 0.002)
                            counter.leave()
                        }
                    }
                }
            }
            group.wait()

            try expectEqual(counter.maxConcurrent, 1)
            try expectEqual(counter.completed, 15)
        }

        test("RepoGitLock/returnsBodyValue") {
            let lock = RepoGitLock()
            let out = lock.withLock(URL(fileURLWithPath: "/tmp/repo-value")) { "pulled" }
            try expectEqual(out, "pulled")
        }
    }

    /// Tracks how many blocks are inside the lock at once.
    private final class Counter {
        private let mutex = NSLock()
        private var current = 0
        private(set) var maxConcurrent = 0
        private(set) var completed = 0

        func enter() {
            mutex.lock()
            current += 1
            maxConcurrent = max(maxConcurrent, current)
            mutex.unlock()
        }

        func leave() {
            mutex.lock()
            current -= 1
            completed += 1
            mutex.unlock()
        }
    }
}
