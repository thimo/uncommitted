import Foundation
import AppKit

struct Action: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var kind: ActionKind

    init(id: UUID = UUID(), name: String, kind: ActionKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

enum ActionKind: Codable, Hashable {
    case finder
    case app(String)        // application name passed to `open -a`
    case command(String)    // shell command; `{path}` is replaced with the repo path
}

enum ActionRunner {
    static func run(repoURL: URL, action: Action) {
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
        try? process.run()
    }
}

enum AppIcons {
    /// Returns the icon for a macOS application looked up by display name.
    /// Checks common install locations plus one level of /Applications
    /// subdirectories (Setapp, Toolbox, etc.).
    static func icon(forApp name: String) -> NSImage? {
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

    static func icon(for action: Action) -> NSImage? {
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
