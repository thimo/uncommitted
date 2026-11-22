import Foundation
import UncommittedCore

enum DeployLauncherTests {
    static func register() {
        test("Deploy/command_nilWithoutDeployYml") {
            let dir = try makeRepoDir(deployYml: false, binKamal: false)
            defer { try? FileManager.default.removeItem(at: dir) }
            try expect(DeployLauncher.deployCommand(forRepoAt: dir) == nil)
        }

        test("Deploy/command_plainKamalWithoutBinstub") {
            let dir = try makeRepoDir(deployYml: true, binKamal: false)
            defer { try? FileManager.default.removeItem(at: dir) }
            try expectEqual(DeployLauncher.deployCommand(forRepoAt: dir), "kamal deploy")
        }

        test("Deploy/command_binstubWins") {
            let dir = try makeRepoDir(deployYml: true, binKamal: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try expectEqual(DeployLauncher.deployCommand(forRepoAt: dir), "bin/kamal deploy")
        }

        test("Deploy/terminal_ghosttyApp") {
            try expectEqual(DeployLauncher.terminalApp(in: [Action(name: "Ghostty", kind: .app("Ghostty"))]), "Ghostty")
        }

        test("Deploy/terminal_defaultsToTerminal") {
            let actions = [Action(name: "Finder", kind: .finder), Action(name: "Tower", kind: .command("gittower {path}"))]
            try expectEqual(DeployLauncher.terminalApp(in: actions), "Terminal")
        }

        test("Deploy/terminal_firstWins") {
            let actions = [Action(name: "Terminal", kind: .app("Terminal")), Action(name: "Ghostty", kind: .app("Ghostty"))]
            try expectEqual(DeployLauncher.terminalApp(in: actions), "Terminal")
        }

        test("Deploy/terminal_unverifiedTerminalFallsBack") {
            try expectEqual(DeployLauncher.terminalApp(in: [Action(name: "Warp", kind: .app("Warp"))]), "Terminal")
        }

        test("Deploy/blocker") {
            let clean = RepoStatus(branch: "main")
            try expect(DeployLauncher.blocker(status: clean, defaultBranch: "main") == nil)
            try expect(DeployLauncher.blocker(status: clean, defaultBranch: nil) == nil)
            // Unpushed or behind commits don't block.
            try expect(DeployLauncher.blocker(status: RepoStatus(branch: "main", ahead: 2, behind: 1), defaultBranch: "main") == nil)
            try expectEqual(DeployLauncher.blocker(status: nil, defaultBranch: "main"), "status unknown")
            try expectEqual(DeployLauncher.blocker(status: RepoStatus(branch: "main", untrackedPaths: ["a"]), defaultBranch: "main"), "commit changes first")
            try expectEqual(DeployLauncher.blocker(status: RepoStatus(branch: "main", operation: .rebase), defaultBranch: "main"), "finish the current git operation first")
            try expectEqual(DeployLauncher.blocker(status: RepoStatus(branch: "(detached)"), defaultBranch: nil), "HEAD is detached")
            try expectEqual(DeployLauncher.blocker(status: RepoStatus(branch: "feature"), defaultBranch: "main"), "switch to main first")
        }

        test("Deploy/terminal_skipsNonTerminalApps") {
            let actions = [Action(name: "Code", kind: .app("Visual Studio Code")), Action(name: "Ghostty", kind: .app("ghostty"))]
            try expectEqual(DeployLauncher.terminalApp(in: actions), "ghostty")
        }

        test("Deploy/script_quotesPathAndKeepsWindowOpen") {
            let script = DeployLauncher.commandScript(repoPath: "/Users/a/My Repos/it's", command: "bin/kamal deploy")
            try expect(script.hasPrefix("#!/bin/zsh\n"))
            try expect(script.contains("cd '/Users/a/My Repos/it'\\''s' || exit 1\n"), script)
            // Ends on success; only a failed deploy reaches the exec below.
            try expect(script.contains("\nbin/kamal deploy && exit 0\n"))
            try expect(script.contains("exec \"${SHELL:-/bin/zsh}\" -l"))
        }

        test("Deploy/ghostty_passesPathAndCommandAsArguments") {
            let args = DeployLauncher.ghosttyArguments(repoPath: "/r/it's here", command: "kamal deploy")
            // Closes the tab on success, leaves it open on failure.
            try expectEqual(Array(args.suffix(3)), ["/r/it's here", "kamal deploy && exit", "deploy: it's here"])
            let scriptText = args[1]
            try expect(!scriptText.contains("/r/it's here"))
            try expect(!scriptText.contains("kamal deploy"))
        }
    }

    private static func makeRepoDir(deployYml: Bool, binKamal: Bool) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deploy-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("config"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        if deployYml { fm.createFile(atPath: dir.appendingPathComponent("config/deploy.yml").path, contents: Data()) }
        if binKamal { fm.createFile(atPath: dir.appendingPathComponent("bin/kamal").path, contents: Data()) }
        return dir
    }
}
