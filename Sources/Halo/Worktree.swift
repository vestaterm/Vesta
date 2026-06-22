import Foundation

enum Worktree {
    /// Managed worktree root: ~/.halo/worktrees/<repo>/<safe-branch>
    static func dir(root: String, repo: String, branch: String) -> String {
        let r = (root as NSString).appendingPathComponent(repo)
        return (r as NSString).appendingPathComponent(safeSegment(branch))
    }

    /// Branch names contain `/` (feature/x) and spaces — make one path segment.
    static func safeSegment(_ branch: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\ :")
        return branch.components(separatedBy: bad).filter { !$0.isEmpty }.joined(separator: "-")
    }
}

extension Worktree {
    @discardableResult
    static func add(repo: String, branch: String, base: String?) throws -> String {
        let target = dirFor(repo: repo, branch: branch)
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var args = ["-C", repo, "worktree", "add", target, "-b", branch]
        if let base { args.append(base) }
        try run("git", args)        // run: throws on nonzero exit, see below
        return target
    }

    /// Managed root for all worktrees: ~/.halo/worktrees
    static var defaultRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".halo/worktrees")
    }
    /// The deterministic worktree dir for a repo + branch (recomputable at close).
    static func dirFor(repo: String, branch: String) -> String {
        dir(root: defaultRoot, repo: (repo as NSString).lastPathComponent, branch: branch)
    }

    /// Remove a worktree. ponytail: non-force by default — git refuses to remove a
    /// dirty/locked worktree, so uncommitted work is never destroyed (the dir is
    /// just left on disk). Pass force only when the caller has confirmed data loss.
    static func remove(repo: String, dir: String, force: Bool = false) throws {
        var args = ["-C", repo, "worktree", "remove", dir]
        if force { args.append("--force") }
        try run("git", args)
    }
    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "halo.worktree", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}

func worktreeSelfCheck() {
    assert(Worktree.safeSegment("feature/login") == "feature-login", "slash → dash")
    assert(Worktree.safeSegment("a b") == "a-b", "space → dash")
    let d = Worktree.dir(root: "/r", repo: "halo", branch: "feat/x")
    assert(d == "/r/halo/feat-x", "dir compose, got \(d)")
    print("worktreeSelfCheck OK")
}
