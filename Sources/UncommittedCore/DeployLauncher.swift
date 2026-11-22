import Foundation
import AppKit

/// Starts a Kamal deploy in a visible terminal window. The deploy needs an
/// interactive 1Password login, so it can't run as a background process.
public enum DeployLauncher {
    /// Terminals recognised among the configured "open in" actions — only
    /// the ones whose launch path below was seen to run the command. Any
    /// other terminal falls back to Terminal rather than to an app that may
    /// just show the script as a document.
    static let knownTerminals = ["Terminal", "Ghostty"]

    /// Why this checkout must not be deployed right now, as a short phrase
    /// for the menu entry, or nil when it may. Kamal ships the local HEAD,
    /// so anything but a settled default branch is refused; `defaultBranch`
    /// is nil when GitHub hasn't told us, and then the branch isn't judged.
    public static func blocker(status: RepoStatus?, defaultBranch: String?) -> String? {
        guard let status else { return "status unknown" }
        if status.operation != nil { return "finish the current git operation first" }
        // The user's post-deploy hook skips a deploy from a dirty tree.
        if status.totalUncommitted > 0 { return "commit changes first" }
        if status.isDetached { return "HEAD is detached" }
        if let defaultBranch, status.branch != defaultBranch { return "switch to \(defaultBranch) first" }
        return nil
    }

    /// The deploy command for a repo, or nil when it has no Kamal config.
    public static func deployCommand(forRepoAt url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("config/deploy.yml").path) else { return nil }
        return fm.fileExists(atPath: url.appendingPathComponent("bin/kamal").path) ? "bin/kamal deploy" : "kamal deploy"
    }

    /// The terminal the user already uses for "open in" actions, else Terminal.
    public static func terminalApp(in actions: [Action]) -> String {
        for action in actions {
            if case .app(let name) = action.kind,
               knownTerminals.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return name
            }
        }
        return "Terminal"
    }

    // MARK: - Pure builders

    /// The AppleScript for Ghostty. Path, input and title arrive as `argv`,
    /// never as script text, so no quoting can break out of the script.
    /// The deploy goes into a background tab of the front window — the tab
    /// that was selected stays selected and Ghostty isn't brought forward —
    /// so it doesn't take over the screen; a window only when none is open.
    static let ghosttyScript = """
    on run argv
      tell application "Ghostty"
        set cfg to new surface configuration
        set initial working directory of cfg to (item 1 of argv)
        set initial input of cfg to (item 2 of argv) & linefeed
        if (count of windows) is 0 then
          new window with configuration cfg
        else
          set win to front window
          set previousTab to selected tab of win
          set deployTab to new tab in win with configuration cfg
          set name override of deployTab to (item 3 of argv)
          select tab previousTab
        end if
      end tell
    end run
    """

    /// What gets typed into the shell: the tab closes itself after a
    /// successful deploy and stays open, in the repo, after a failed one.
    /// `&&` and `exit` read the same in zsh, bash and fish.
    static func shellInput(command: String) -> String {
        "\(command) && exit"
    }

    /// Full argument list for `/usr/bin/osascript`.
    public static func ghosttyArguments(repoPath: String, command: String) -> [String] {
        let title = "deploy: \(URL(fileURLWithPath: repoPath).lastPathComponent)"
        return ["-e", ghosttyScript, repoPath, shellInput(command: command), title]
    }

    /// The `.command` script for other terminals. Terminal.app starts these
    /// with cwd = home, hence the `cd`. A successful deploy ends the script;
    /// after a failed one the final `exec` leaves a shell open in the repo.
    public static func commandScript(repoPath: String, command: String) -> String {
        let quoted = "'" + repoPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/zsh
        cd \(quoted) || exit 1
        \(command) && exit 0
        echo
        exec "${SHELL:-/bin/zsh}" -l

        """
    }

    // MARK: - Launching

    public static func launch(repoURL: URL, command: String, terminal: String) {
        DiagnosticsLog.shared.info("deploy", "starting \(command) for \(repoURL.lastPathComponent) in \(terminal)")
        if terminal.caseInsensitiveCompare("Ghostty") == .orderedSame {
            run(executable: "/usr/bin/osascript", args: ghosttyArguments(repoPath: repoURL.path, command: command))
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Uncommitted", isDirectory: true)
        // Unique per launch: the terminal reads the file after we return, so
        // two clones with the same folder name must not share one script.
        let script = dir.appendingPathComponent("deploy-\(repoURL.lastPathComponent)-\(UUID().uuidString).command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try commandScript(repoPath: repoURL.path, command: command).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            DiagnosticsLog.shared.error("deploy", "could not write \(script.path): \(error.localizedDescription)")
            return
        }
        if let appURL = AppLocator.url(forApp: terminal) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: config) { _, error in
                if let error {
                    DiagnosticsLog.shared.error("deploy", "opening \(terminal) failed: \(error.localizedDescription)")
                }
            }
        } else {
            run(executable: "/usr/bin/open", args: ["-a", terminal, script.path])
        }
    }

    /// Fire-and-forget: the exit status is awaited off the main thread so a
    /// failure (e.g. denied Automation permission) still reaches the log.
    private static func run(executable: String, args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            DiagnosticsLog.shared.error("deploy", "failed to launch \(executable): \(error.localizedDescription)")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                DiagnosticsLog.shared.error("deploy", "\(executable) exited \(process.terminationStatus): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }
}
