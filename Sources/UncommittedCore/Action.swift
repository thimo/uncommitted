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
        switch action.kind {
        case .finder:
            NSWorkspace.shared.open(repoURL)

        case .app(let appName):
            run(executable: "/usr/bin/open", args: ["-a", appName, repoURL.path])

        case .command(let command):
            let expanded = command.replacingOccurrences(of: "{path}", with: repoURL.path)
            run(executable: "/bin/zsh", args: ["-l", "-c", expanded])
        }
    }

    private static func run(executable: String, args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        do {
            try process.run()
        } catch {
            log.error("Failed to launch \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

public enum AppIcons {
    /// Returns the icon for a macOS application looked up by display name.
    /// Checks common install locations plus one level of /Applications
    /// subdirectories (Setapp, Toolbox, etc.).
    public static func icon(forApp name: String) -> NSImage? {
        let fm = FileManager.default
        let primaryCandidates = [
            "/Applications/\(name).app",
            "/Applications/Setapp/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app",
        ]
        for path in primaryCandidates where fm.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        // Fall back to scanning /Applications one level deep for nested containers.
        if let children = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for child in children where !child.hasSuffix(".app") {
                let nested = "/Applications/\(child)/\(name).app"
                if fm.fileExists(atPath: nested) {
                    return NSWorkspace.shared.icon(forFile: nested)
                }
            }
        }
        return nil
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
