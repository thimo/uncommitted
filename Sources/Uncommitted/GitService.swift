import Foundation

enum GitService {
    static func status(at url: URL) -> RepoStatus? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = url
        process.arguments = ["status", "--porcelain=v2", "--branch"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read the pipes before waitUntilExit so we can't deadlock on output
        // that exceeds the 64KB pipe buffer. readDataToEndOfFile unblocks when
        // git closes its end of the pipe, which happens when it exits.
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()

        guard process.terminationStatus == 0 else { return nil }
        guard let output = String(data: stdoutData, encoding: .utf8) else { return nil }
        return parse(output)
    }

    /// Parses `git status --porcelain=v2 --branch` output. Returns nil if the
    /// output is missing the `branch.oid` header, which git always emits for a
    /// real repository — if it's absent, something is wrong and we'd rather
    /// preserve the previous status than record a bogus "clean" state.
    private static func parse(_ output: String) -> RepoStatus? {
        var branch = "(detached)"
        var headOid: String?
        var ahead = 0
        var behind = 0
        var staged = 0
        var unstaged = 0
        var untracked = 0

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = parts.first else { continue }

            switch head {
            case "#":
                guard parts.count >= 2 else { continue }
                switch parts[1] {
                case "branch.oid":
                    if parts.count >= 3 { headOid = String(parts[2]) }
                case "branch.head":
                    if parts.count >= 3 { branch = String(parts[2]) }
                case "branch.ab":
                    if parts.count >= 4 {
                        ahead = Int(parts[2].dropFirst()) ?? 0
                        behind = Int(parts[3].dropFirst()) ?? 0
                    }
                default: break
                }

            case "1", "2":
                // Entry line: "1 XY ..." where X = index status, Y = worktree status.
                // "." means unchanged in that column.
                guard parts.count >= 2 else { continue }
                let xy = parts[1]
                let chars = Array(xy)
                if chars.count >= 2 {
                    if chars[0] != "." { staged += 1 }
                    if chars[1] != "." { unstaged += 1 }
                }

            case "?":
                untracked += 1

            default:
                break
            }
        }

        // Require at least a branch.oid — every healthy repo emits one.
        // Without it we can't trust that "no entry lines" actually means "clean".
        guard headOid != nil else { return nil }

        return RepoStatus(
            branch: branch,
            headOid: headOid,
            ahead: ahead,
            behind: behind,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked
        )
    }
}
