import Foundation

/// The environment every child process starts from: our own, minus the
/// variables a Claude Code session leaves behind. When the app is launched
/// from such a session (`open` after a rebuild) it inherits
/// `CLAUDE_CODE_CHILD_SESSION`, `CLAUDECODE`, `CLAUDE_PID` and friends. Passed
/// on, a `code {path}` action hands them to VS Code, and every Claude session
/// started in that window believes it is a child session and saves no
/// transcript (2026-11-23).
public enum ChildEnvironment {
    /// Read once: the process environment doesn't change after launch.
    public static let base: [String: String] = sanitized(ProcessInfo.processInfo.environment)

    /// Drops every variable whose name starts with `CLAUDE`. Pure, for the tests.
    public static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("CLAUDE") }
    }
}
