import Foundation
import AppKit
import os.log

private let log = Logger(subsystem: "nl.thimo.uncommitted", category: "actions")

public struct Action: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: ActionKind

    public init(id: UUID = UUID(), name: String, kind: ActionKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
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
            let expanded = command.replacingOccurrences(of: "{path}", with: repoURL.path)
            run(executable: "/bin/zsh", args: ["-l", "-c", expanded], environment: Self.shellEnvironment)
        }
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

    /// Resolved once at first use by launching the user's login shell
    /// (`$SHELL -l -c printenv PATH`). This sources the full profile
    /// (fish config, .zprofile, .bash_profile — whatever the user has)
    /// and gives us the real PATH including Homebrew, rbenv, etc.
    /// Cached because PATH is stable within a process lifetime.
    /// Timeout for the login-shell PATH resolution. Fish with heavy
    /// plugins or a broken network mount can stall — don't let a static
    /// initializer hang the app forever.
    private static let shellPathTimeout: TimeInterval = 3.0

    private static let shellEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "/usr/bin/printenv PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else { return env }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + shellPathTimeout) == .timedOut {
            process.terminate()
            log.warning("$SHELL PATH resolution timed out after \(shellPathTimeout)s — using inherited PATH")
            return env
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty {
            env["PATH"] = output
        }
        return env
    }()

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
