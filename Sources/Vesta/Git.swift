import Foundation

/// Minimal real git status for the focused pane's cwd.
/// ponytail: shells out + polls on focus/cwd change. Add an FS watcher only if
/// the on-focus refresh proves too stale.
enum Git {
    /// "⎇ main ↑1 · 3 dirty" for a repo, or nil if `cwd` isn't one.
    static func status(_ cwd: String) -> String? {
        guard let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd), !branch.isEmpty
        else { return nil }

        var parts = ["⎇ \(branch)"]
        if let ab = run(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], cwd) {
            let n = ab.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Int($0) }
            if n.count == 2 {
                if n[1] > 0 { parts[0] += " ↑\(n[1])" }
                if n[0] > 0 { parts[0] += " ↓\(n[0])" }
            }
        }
        let dirty = run(["status", "--porcelain"], cwd)?
            .split(separator: "\n").count ?? 0
        if dirty > 0 { parts.append("\(dirty) dirty") }
        return parts.joined(separator: " · ")
    }

    /// Current branch name via `rev-parse --abbrev-ref HEAD`, or nil if not a repo / detached / empty.
    static func branch(_ cwd: String) -> String? {
        guard let b = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd), !b.isEmpty, b != "HEAD"
        else { return nil }
        return b
    }

    /// Count of uncommitted changes via `git status --porcelain`.
    /// Returns 0 if `cwd` is not a git repo.
    static func dirtyCount(_ cwd: String) -> Int {
        parsePorcelain(run(["status", "--porcelain"], cwd) ?? "")
    }

    /// Count non-empty lines in porcelain output (each line = one changed path).
    static func parsePorcelain(_ out: String) -> Int {
        out.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    private static func run(_ args: [String], _ cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd] + args
        let out = Pipe(); p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func gitSelfCheck() {
    assert(Git.status("/") == nil,  "/ is not a git repo")   // deterministic
    assert(Git.branch("/") == nil,  "/ has no git branch")   // deterministic
    assert(Git.parsePorcelain(" M a\n?? b\n") == 2, "parsePorcelain: 2 changed paths")
    print("gitSelfCheck OK")
}
