import Foundation
import Combine
import os.log

/// File-backed diagnostics log at `~/Library/Logs/Uncommitted/`, one file
/// per day, pruned after `retentionDays`. Every entry is mirrored to
/// os.log (same subsystem/category scheme the app always used), so
/// Console.app keeps working — the file adds what os.log can't give
/// users: something they can open, read, and attach to a bug report.
///
/// Writes are synchronous under a lock rather than queued: the log exists
/// precisely for the moments the process is about to die (crash handlers,
/// `atexit`, `applicationWillTerminate`), where an async queue would lose
/// the line that matters most. Volume is low — errors and lifecycle
/// events, not per-refresh chatter — so blocking the caller is fine.
public final class DiagnosticsLog: ObservableObject {
    public enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public struct Entry: Equatable {
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    public static let shared = DiagnosticsLog()

    /// Most recent error-level entry this session. Drives the Settings →
    /// General "Diagnostics" section. Set on the main thread; when the
    /// caller is already on main it's assigned synchronously so the UI
    /// (and tests) observe it immediately.
    @Published public private(set) var lastError: Entry?

    public let directory: URL

    public static let defaultDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Uncommitted", isDirectory: true)

    private let retentionDays: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    /// The "yyyy-MM-dd" day the open handle writes to, so a session that
    /// crosses midnight rolls over to a fresh file.
    private var handleDay: String?

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init(directory: URL = DiagnosticsLog.defaultDirectory, retentionDays: Int = 14) {
        self.directory = directory
        self.retentionDays = retentionDays
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneOldLogs()
    }

    // MARK: - Logging

    public func info(_ category: String, _ message: String) {
        log(.info, category, message)
    }

    public func warning(_ category: String, _ message: String) {
        log(.warning, category, message)
    }

    public func error(_ category: String, _ message: String) {
        log(.error, category, message)
    }

    /// `now` is injectable for tests only — production callers use the
    /// convenience methods above.
    public func log(_ level: Level, _ category: String, _ message: String, now: Date = Date()) {
        lock.lock()
        ensureHandleLocked(for: now)
        let line = "\(timestampFormatter.string(from: now)) [\(level.rawValue)] \(category) — \(message)\n"
        if let data = line.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
        lock.unlock()

        let logger = Logger(subsystem: "nl.defrog.uncommitted", category: category)
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }

        if level == .error {
            let entry = Entry(date: now, level: level, category: category, message: message)
            if Thread.isMainThread {
                lastError = entry
            } else {
                DispatchQueue.main.async { self.lastError = entry }
            }
        }
    }

    /// The log file a given moment writes to. Public for tests and for
    /// the crash handler's raw descriptor.
    public func fileURL(for date: Date) -> URL {
        lock.lock()
        defer { lock.unlock() }
        return fileURLLocked(for: date)
    }

    /// Raw O_APPEND file descriptor to today's log, for the crash signal
    /// handler — the only writer that can't take a lock or touch
    /// Foundation. O_APPEND keeps its writes from interleaving mid-line
    /// with the FileHandle writer.
    public func openRawAppendDescriptor(now: Date = Date()) -> Int32 {
        lock.lock()
        ensureHandleLocked(for: now)
        let path = fileURLLocked(for: now).path
        lock.unlock()
        return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }

    // MARK: - Retention

    /// Deletes `Uncommitted-*.log` files older than `retentionDays`.
    /// Files that don't match the naming pattern are left alone.
    public func pruneOldLogs(now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("Uncommitted-"), name.hasSuffix(".log") else { continue }
            let dayString = String(name.dropFirst("Uncommitted-".count).dropLast(".log".count))
            lock.lock()
            let day = dayFormatter.date(from: dayString)
            lock.unlock()
            guard let day, day < cutoff else { continue }
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Private

    private func fileURLLocked(for date: Date) -> URL {
        directory.appendingPathComponent("Uncommitted-\(dayFormatter.string(from: date)).log")
    }

    private func ensureHandleLocked(for now: Date) {
        let day = dayFormatter.string(from: now)
        guard handle == nil || handleDay != day else { return }
        try? handle?.close()
        handle = nil
        handleDay = day

        let url = fileURLLocked(for: now)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}
