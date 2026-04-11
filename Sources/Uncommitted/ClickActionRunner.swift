import Foundation
import AppKit

enum ClickActionRunner {
    static func open(repoURL: URL, action: ClickAction, customCommand: String) {
        switch action {
        case .finder:
            NSWorkspace.shared.open(repoURL)

        case .custom:
            let expanded = customCommand.replacingOccurrences(of: "{path}", with: repoURL.path)
            runShell(command: expanded)

        default:
            guard let appName = action.openAppName else { return }
            runOpen(args: ["-a", appName, repoURL.path])
        }
    }

    private static func runOpen(args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        try? process.run()
    }

    private static func runShell(command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        try? process.run()
    }
}
