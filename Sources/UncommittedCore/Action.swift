import Foundation
import AppKit
import os.log

private let log = Logger(subsystem: "nl.defrog.uncommitted", category: "actions")

public struct Action: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: ActionKind
    /// App name to derive the icon from. Used by command actions that
    /// wrap a specific app's CLI (e.g. "Tower" for `gittower {path}`).
    /// Ignored for `.app` and `.finder` kinds which derive their own.
    public var iconApp: String?
    /// Optional semantic role. Used by error-recovery UI to find the
    /// user's preferred git client without hardcoding a name. At most
    /// one action per role; enforcement lives in the settings UI.
    public var role: ActionRole?

    public init(id: UUID = UUID(), name: String, kind: ActionKind, iconApp: String? = nil, role: ActionRole? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.iconApp = iconApp
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, iconApp, role
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.kind = try c.decode(ActionKind.self, forKey: .kind)
        self.iconApp = try c.decodeIfPresent(String.self, forKey: .iconApp)
        self.role = try c.decodeIfPresent(ActionRole.self, forKey: .role)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(iconApp, forKey: .iconApp)
        try c.encodeIfPresent(role, forKey: .role)
    }
}

public enum ActionRole: String, Codable, Hashable {
    /// User's preferred GUI git client. Surfaced in push/pull error
    /// alerts as a recovery button.
    case gitClient
}

public enum ActionKind: Codable, Hashable {
    case finder
    case app(String)        // application name passed to `open -a`
    case command(String)    // shell command; `{path}` is replaced with the repo path
}

public enum ActionRunner {
    public static func run(repoURL: URL, action: Action) {
        log.info("action \(action.name, privacy: .public) (\(String(describing: action.kind), privacy: .public)) at \(repoURL.path, privacy: .public)")
        switch action.kind {
        case .finder:
            NSWorkspace.shared.open(repoURL)

        case .app(let appName):
            openInApp(name: appName, url: repoURL)

        case .command(let command):
            let expanded = expand(command: command, repoPath: repoURL.path)
            run(executable: "/bin/zsh", args: ["-l", "-c", expanded], environment: Self.shellEnvironment)
            // If the command wraps an app (iconApp set), activate it
            // after a short delay so macOS switches to its Space/desktop.
            // The command handles opening the folder; this just brings
            // the window forward. LSUIElement apps can't trigger desktop
            // switches on their own — NSRunningApplication.activate can.


        }
    }

    /// Expands a command template by substituting every `{path}` token with
    /// the repo path. Pure and side-effect-free so it can be unit-tested
    /// without launching a subprocess.
    public static func expand(command: String, repoPath: String) -> String {
        command.replacingOccurrences(of: "{path}", with: repoPath)
    }

    /// Opens a URL in a named app using NSWorkspace's modern API. This
    /// properly activates the app (switching Spaces / raising fullscreen
    /// windows) instead of shelling out to `open -a` which can leave
    /// fullscreen apps in the background. Falls back to `open -a` if
    /// we can't find the .app bundle on disk.
    private static func openInApp(name: String, url: URL) {
        if let appURL = AppLocator.url(forApp: name) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                if let error {
                    log.error("NSWorkspace.open failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            // Fallback: can't find the .app, let `open -a` try.
            run(executable: "/usr/bin/open", args: ["-a", name, url.path])
        }
    }

    /// Timeout for the login-shell PATH resolution. Fish with heavy
    /// plugins or a broken network mount can stall — don't let a shell
    /// command action hang the app forever.
    private static let shellPathTimeout: TimeInterval = 3.0

    /// Directories a shell-command action must still be able to see when
    /// the login shell couldn't be asked. The PATH the app inherits from
    /// launchd is the bare system one, which finds neither Homebrew nor
    /// the `code` launcher in `~/.local/bin`.
    private static let fallbackPathDirectories = [
        "~/.local/bin", "~/bin", "/opt/homebrew/bin", "/usr/local/bin",
    ]

    /// How long a failed lookup is left alone before the next action asks
    /// the shell again. The lookup blocks the caller (a click on the main
    /// thread) for up to `shellPathTimeout`, so a persistently stalling
    /// shell must not turn every action into a 3s freeze.
    private static let shellPathRetryInterval: TimeInterval = 60

    private static let shellEnvironmentLock = NSLock()
    private static var cachedShellEnvironment: [String: String]?
    private static var lastFailedEnvironment: [String: String]?
    private static var retryShellPathAfter: Date = .distantPast

    /// The environment for shell-command actions: the process environment
    /// with PATH taken from the user's login shell (`$SHELL -l -c printenv
    /// PATH`), which sources the full profile (fish config, .zprofile,
    /// .bash_profile — whatever the user has) and so includes Homebrew,
    /// rbenv, etc. Cached once the shell answered. A timeout or launch
    /// failure is only held for `shellPathRetryInterval`, so one slow
    /// shell start doesn't leave the process on the fallback PATH for the
    /// rest of its lifetime (2026-09-26: a single 3s fish start after the
    /// macOS 27 upgrade made every later `code {path}` fail with
    /// "command not found").
    private static var shellEnvironment: [String: String] {
        shellEnvironmentLock.lock()
        defer { shellEnvironmentLock.unlock() }
        if let cached = cachedShellEnvironment { return cached }
        if let failed = lastFailedEnvironment, Date() < retryShellPathAfter { return failed }
        let (env, resolved) = resolveShellEnvironment()
        if resolved {
            cachedShellEnvironment = env
            lastFailedEnvironment = nil
        } else {
            lastFailedEnvironment = env
            retryShellPathAfter = Date().addingTimeInterval(shellPathRetryInterval)
        }
        return env
    }

    /// Returns the environment plus whether the login shell answered. When
    /// it didn't, PATH is the inherited one extended with the fallback
    /// directories.
    private static func resolveShellEnvironment() -> (environment: [String: String], resolved: Bool) {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var fallback = env
        fallback["PATH"] = pathWithFallbackDirectories(env["PATH"], home: home)

        let shell = env["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "/usr/bin/printenv PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.warning("$SHELL (\(shell, privacy: .public)) failed to launch: \(error.localizedDescription, privacy: .public) — using inherited PATH plus fallback directories")
            return (fallback, false)
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + shellPathTimeout) == .timedOut {
            process.terminate()
            log.warning("$SHELL PATH resolution timed out after \(shellPathTimeout)s — using inherited PATH plus fallback directories; will retry on the next action")
            return (fallback, false)
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else {
            log.warning("$SHELL printed an empty PATH — using inherited PATH plus fallback directories")
            return (fallback, false)
        }
        env["PATH"] = output
        return (env, true)
    }

    /// Appends the fallback directories (with `~` expanded to `home`) that
    /// `path` doesn't already contain. Pure, for the tests.
    public static func pathWithFallbackDirectories(_ path: String?, home: String) -> String {
        var entries = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for dir in fallbackPathDirectories {
            let expanded = dir.hasPrefix("~/") ? home + dir.dropFirst(1) : dir
            if !entries.contains(expanded) { entries.append(expanded) }
        }
        return entries.joined(separator: ":")
    }

    private static func run(executable: String, args: [String], environment: [String: String]? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        if let environment {
            process.environment = environment
        }
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            log.error("Failed to launch \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        // Fire-and-forget: capture stderr in the background so we can
        // log failures without blocking the UI.
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log.error("command exited \(process.terminationStatus): \(args.joined(separator: " "), privacy: .public) — \(output, privacy: .public)")
            }
        }
    }
}

/// Finds .app bundles by display name. Used by both ActionRunner (to
/// open apps via NSWorkspace) and AppIcons (to grab their icons).
public enum AppLocator {
    /// Returns the URL of a macOS application looked up by display name.
    /// Checks common install locations plus one level of /Applications
    /// subdirectories (Setapp, Toolbox, etc.).
    public static func url(forApp name: String) -> URL? {
        let fm = FileManager.default
        let primaryCandidates = [
            "/Applications/\(name).app",
            "/Applications/Setapp/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app",
        ]
        for path in primaryCandidates where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let children = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for child in children where !child.hasSuffix(".app") {
                let nested = "/Applications/\(child)/\(name).app"
                if fm.fileExists(atPath: nested) {
                    return URL(fileURLWithPath: nested)
                }
            }
        }
        return nil
    }
}

public enum AppIcons {
    public static func icon(forApp name: String) -> NSImage? {
        guard let url = AppLocator.url(forApp: name) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    public static func icon(for action: Action) -> NSImage? {
        if let iconApp = action.iconApp {
            return icon(forApp: iconApp)
        }
        switch action.kind {
        case .finder:
            return NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        case .app(let name):
            return icon(forApp: name)
        case .command:
            return nil
        }
    }
}
