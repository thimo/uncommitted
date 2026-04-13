import Foundation

/// Per-repo bookkeeping for the auto-fetch feature. Persisted by
/// `FetchStateStore` keyed on the repo's standardized URL path (UUIDs
/// regenerate on each launch, paths don't).
public struct FetchState: Codable, Equatable {
    /// Most recent attempt timestamp, regardless of success.
    public var lastAttemptAt: Date?
    /// Most recent successful attempt.
    public var lastSuccessAt: Date?
    /// Number of consecutive failures since the last success. Drives
    /// the exponential back-off and the row glyph threshold.
    public var consecutiveFailures: Int
    /// True if the last attempt was triggered by the user (Option-click
    /// refresh or per-row "Fetch from remote"). Lowers the row glyph
    /// threshold to 1 so manual failures surface immediately.
    public var lastAttemptWasManual: Bool
    /// True if `git remote` returned empty for this repo. The scheduler
    /// skips these forever; re-checked once per app launch.
    public var noRemote: Bool

    public init(
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        consecutiveFailures: Int = 0,
        lastAttemptWasManual: Bool = false,
        noRemote: Bool = false
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.consecutiveFailures = consecutiveFailures
        self.lastAttemptWasManual = lastAttemptWasManual
        self.noRemote = noRemote
    }

    public static let initial = FetchState()
}
