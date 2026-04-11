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

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return parse(output)
    }

    private static func parse(_ output: String) -> RepoStatus {
        var branch = "(detached)"
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

        return RepoStatus(
            branch: branch,
            ahead: ahead,
            behind: behind,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked
        )
    }
}
