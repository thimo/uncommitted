import Foundation

/// Holds back GitHub calls for a while after GitHub refused one for the
/// rate limit. A refused call costs no budget, but the sweep around it
/// does: with the GraphQL budget spent, every REST call a sweep still made
/// ate into the other budget, and the log filled with one warning per call.
///
/// The pause is a fixed length rather than "until the reset": the reset
/// time is not in the error, and `gh api rate_limit` was seen reporting
/// 3947 GraphQL points left while GraphQL calls were being refused
/// (2026-11-22). After the pause one call goes through as a probe.
public final class GitHubRateLimitGate {
    public enum Resource: Hashable {
        case graphql
        case rest
    }

    public static let shared = GitHubRateLimitGate()
    public static let pause: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var pausedUntil: [Resource: Date] = [:]

    public init() {}

    /// Covers the primary limit of both APIs ("API rate limit exceeded",
    /// "API rate limit already exceeded") and the secondary one.
    public static func isRateLimitError(_ stderr: String) -> Bool {
        stderr.range(of: "rate limit", options: .caseInsensitive) != nil
    }

    public func isPaused(_ resource: Resource, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = pausedUntil[resource] else { return false }
        return now < until
    }

    public func isAnyPaused(now: Date = Date()) -> Bool {
        isPaused(.graphql, now: now) || isPaused(.rest, now: now)
    }

    /// Records a failed call. Returns true when it starts a pause, so the
    /// caller logs the pause once instead of once per concurrent call.
    @discardableResult
    public func noteFailure(_ resource: Resource, stderr: String, now: Date = Date()) -> Bool {
        guard Self.isRateLimitError(stderr) else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let until = pausedUntil[resource], now < until { return false }
        pausedUntil[resource] = now.addingTimeInterval(Self.pause)
        return true
    }
}
