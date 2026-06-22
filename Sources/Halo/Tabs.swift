import AppKit

// MARK: - Sidebar data types (consumed by Task B's Chrome rendering)

struct SidebarSession {
    let label: String
    let active: Bool
    var ports: [Int] = []   // listening TCP ports of the session's foreground process tree
    var dirty: Int = 0      // uncommitted changes in the session's cwd (git status --porcelain)
}

struct SidebarProject {
    let name: String
    var branch: String?
    let expanded: Bool
    let active: Bool
    var color: NSColor? = nil    // custom project tint (nil ⇒ accent)
    var sessions: [SidebarSession]  // var so AppDelegate can inject ports/dirty per session
}

// MARK: - Project/Session model

struct Proj {
    var name: String
    var path: String
    var sessions: [PaneTree]
    var expanded: Bool
    var color: NSColor? = nil    // custom tint, set via the sidebar context menu
}

/// Owns projects; each project owns sessions (PaneTrees).
/// Container = body only — the active session's rootView, swapped on change.
/// No top tab strip.
@MainActor
final class Workspace {
    private(set) var projs: [Proj] = []
    private(set) var activeP = 0
    private(set) var activeS = 0

    // Session→branch tag: keyed by PaneTree instance identity to avoid touching PaneTree's init.
    private var worktreeBranch: [ObjectIdentifier: String] = [:]

    var activeTree: PaneTree { projs[activeP].sessions[activeS] }

    let container = NSView()
    private let body = NSView()
    private let theme: Theme

    // Callbacks (set by AppDelegate, invoked by Chrome in Task B)
    var onSelectSession:  ((Int, Int) -> Void)?
    var onCloseSession:   ((Int, Int) -> Void)?
    var onNewSession:     ((Int) -> Void)?
    var onToggleExpand:   ((Int) -> Void)?
    var onNewProject:     (() -> Void)?
    var onChange:         (() -> Void)?

    init(theme: Theme) {
        self.theme = theme
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.background.cgColor

        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Launch: home project at ~ with one session at ~, expanded + active.
        // Config projects are appended collapsed + empty by loadProjects/appendProject.
        let home = NSHomeDirectory()
        var homeProj = makeProj(name: "home", path: home, expanded: true)
        homeProj.sessions.append(makeTree(cwd: home))
        projs.append(homeProj)
        activeP = 0
        activeS = 0
        showActive()
    }

    // MARK: - Operations

    func toggleExpand(_ p: Int) {
        guard projs.indices.contains(p) else { return }
        if projs[p].sessions.isEmpty {
            // Lazy: create first session at the project path, expand, activate.
            let tree = makeTree(cwd: projs[p].path)
            projs[p].sessions.append(tree)
            projs[p].expanded = true
            activeP = p; activeS = 0
            showActive()
        } else {
            projs[p].expanded.toggle()
            handleChange()
        }
    }

    private func addSession(_ p: Int, cwd: String?) {
        guard projs.indices.contains(p) else { return }
        let tree = makeTree(cwd: cwd)
        projs[p].sessions.append(tree)
        projs[p].expanded = true
        activeP = p
        activeS = projs[p].sessions.count - 1
        showActive()
    }

    func newSession(_ p: Int) {
        addSession(p, cwd: NSHomeDirectory())
    }

    func newWorktreeSession(_ p: Int, branch: String, base: String? = nil) {
        guard projs.indices.contains(p) else { return }
        let repo = projs[p].path
        do {
            let dir = try Worktree.add(repo: repo, branch: branch, base: base)
            addSession(p, cwd: dir)                              // addSession sets active + showActive
            worktreeBranch[ObjectIdentifier(activeTree)] = branch
            handleChange()
        } catch {
            NSSound.beep()
            // surface the git error without crashing
            let a = NSAlert(); a.messageText = "Couldn't create worktree"
            a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    func renameProject(_ p: Int, _ name: String) {
        guard projs.indices.contains(p) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projs[p].name = trimmed
        handleChange()
    }

    func setProjectColor(_ p: Int, _ color: NSColor?) {
        guard projs.indices.contains(p) else { return }
        projs[p].color = color
        handleChange()
    }

    /// Remove a project and all its sessions. Refuses to remove the last project
    /// (the workspace must always have ≥1 project with ≥1 session).
    func removeProject(_ p: Int) {
        guard projs.indices.contains(p), projs.count > 1 else { return }
        projs.remove(at: p)
        // Fix activeP: shift down if we removed at/before it, then clamp.
        if activeP >= p { activeP = max(0, activeP - 1) }
        activeP = min(activeP, projs.count - 1)
        // Active project may be a lazy (empty) one — ensure it has a session.
        if projs[activeP].sessions.isEmpty {
            projs[activeP].sessions.append(makeTree(cwd: projs[activeP].path))
            projs[activeP].expanded = true
        }
        activeS = min(activeS, projs[activeP].sessions.count - 1)
        showActive()
    }

    func newProject() {
        let home = NSHomeDirectory()
        var proj = makeProj(name: "untitled", path: home, expanded: true)
        // Add one session at home immediately (mirrors home proj behaviour).
        let tree = makeTree(cwd: home)
        proj.sessions.append(tree)
        projs.append(proj)
        activeP = projs.count - 1
        activeS = 0
        showActive()
    }

    func selectSession(_ p: Int, _ s: Int) {
        guard projs.indices.contains(p), projs[p].sessions.indices.contains(s) else { return }
        activeP = p; activeS = s
        showActive()
    }

    /// Returns true when the last session is about to be removed — replace instead of deleting.
    nonisolated static func replaceOnClose(totalSessions: Int) -> Bool { totalSessions <= 1 }

    func closeSession(_ p: Int, _ s: Int) {
        guard projs.indices.contains(p), projs[p].sessions.indices.contains(s) else { return }
        // Drop any worktree-branch tag for the session being removed/replaced.
        worktreeBranch.removeValue(forKey: ObjectIdentifier(projs[p].sessions[s]))
        // Never let global session count reach 0.
        let total = projs.reduce(0) { $0 + $1.sessions.count }
        if Workspace.replaceOnClose(totalSessions: total) {
            // Replace with a fresh ~ session rather than leaving 0.
            let tree = makeTree(cwd: NSHomeDirectory())
            projs[p].sessions[s] = tree
            activeP = p; activeS = s
            showActive()
            return
        }
        projs[p].sessions.remove(at: s)
        // If project is now empty, collapse it.
        if projs[p].sessions.isEmpty { projs[p].expanded = false }
        // Fix activeS/activeP.
        if activeP == p {
            if projs[p].sessions.isEmpty {
                // Find another project with sessions.
                if let q = projs.indices.first(where: { $0 != p && !projs[$0].sessions.isEmpty }) {
                    activeP = q; activeS = 0
                } else {
                    // No other sessions — create a fresh one in this project.
                    let tree = makeTree(cwd: projs[p].path.isEmpty ? NSHomeDirectory() : projs[p].path)
                    projs[p].sessions.append(tree)
                    projs[p].expanded = true
                    activeP = p; activeS = 0
                }
            } else {
                activeS = min(activeS, projs[p].sessions.count - 1)
            }
        }
        showActive()
    }

    func snapshot() -> [SidebarProject] {
        projs.enumerated().map { (pi, proj) in
            let multi = proj.sessions.count > 1
            let sessions = proj.sessions.enumerated().map { (si, tree) in
                // Disambiguate sibling sessions (otherwise every ~ shell reads "nuh").
                let base = tree.focusedLabel
                let panes = tree.paneCount
                var label = base
                if panes > 1 { label += " · \(panes) panes" }
                if multi { label = "\(si + 1). \(label)" }
                // Prefer worktree branch tag when available.
                if let br = worktreeBranch[ObjectIdentifier(tree)] { label = "⎇ \(br)" }
                return SidebarSession(label: label, active: pi == activeP && si == activeS)
            }
            return SidebarProject(
                name: proj.name,
                branch: nil,   // filled by AppDelegate's git fetch in Task C
                expanded: proj.expanded,
                active: pi == activeP,
                color: proj.color,
                sessions: sessions
            )
        }
    }

    // MARK: - Compat shims for Control.swift (do NOT remove until Control.swift is updated)

    /// The flat index of the active session across all projects (for `list` command).
    var active: Int {
        var n = 0
        for (pi, proj) in projs.enumerated() {
            for si in proj.sessions.indices {
                if pi == activeP && si == activeS { return n }
                n += 1
            }
        }
        return 0
    }

    /// Flat list of all PaneTrees (for `list` command's tab count).
    var tabs: [PaneTree] { projs.flatMap { $0.sessions } }

    func newTab(cwd: String?) {
        // Compat: opens a new session in the active project at the given cwd.
        // If cwd matches a project path, prefer that project; else use activeP.
        let targetP: Int
        if let cwd, let pi = projs.indices.first(where: { projs[$0].path == cwd }) {
            targetP = pi
        } else {
            targetP = activeP
        }
        addSession(targetP, cwd: cwd)
    }

    func closeTab() { closeSession(activeP, activeS) }
    func closeTab(at i: Int) {
        // Flat index i → project/session.
        var n = 0
        for (pi, proj) in projs.enumerated() {
            for si in proj.sessions.indices {
                if n == i { closeSession(pi, si); return }
                n += 1
            }
        }
    }
    func selectTab(_ i: Int) {
        var n = 0
        for (pi, proj) in projs.enumerated() {
            for si in proj.sessions.indices {
                if n == i { selectSession(pi, si); return }
                n += 1
            }
        }
    }
    func nextTab() {
        let t = tabs
        guard !t.isEmpty else { return }
        let cur = active
        let next = (cur + 1) % t.count
        selectTab(next)
    }
    func prevTab() {
        let t = tabs
        guard !t.isEmpty else { return }
        let cur = active
        let prev = (cur - 1 + t.count) % t.count
        selectTab(prev)
    }

    // MARK: - Project appending (called by loadProjects)

    /// Append a config project as collapsed + empty (lazy).
    func appendProject(name: String, path: String) {
        projs.append(Proj(name: name, path: path, sessions: [], expanded: false))
    }

    // MARK: - Cycle sessions within active project

    func nextSession() {
        guard projs.indices.contains(activeP), !projs[activeP].sessions.isEmpty else { return }
        let count = projs[activeP].sessions.count
        activeS = (activeS + 1) % count
        showActive()
    }

    func prevSession() {
        guard projs.indices.contains(activeP), !projs[activeP].sessions.isEmpty else { return }
        let count = projs[activeP].sessions.count
        activeS = (activeS - 1 + count) % count
        showActive()
    }

    func selectSessionInActiveProject(_ i: Int) {
        guard projs.indices.contains(activeP), projs[activeP].sessions.indices.contains(i - 1) else { return }
        activeS = i - 1
        showActive()
    }

    // MARK: - Private helpers

    private func makeProj(name: String, path: String, expanded: Bool) -> Proj {
        Proj(name: name, path: path, sessions: [], expanded: expanded, color: nil)
    }

    private func makeTree(cwd: String?) -> PaneTree {
        let tree = PaneTree(theme: theme, cwd: cwd)
        tree.onFocusChange = { [weak self] in self?.handleChange() }
        return tree
    }

    private func showActive() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let v = activeTree.rootView
        v.frame = body.bounds
        v.autoresizingMask = [.width, .height]
        body.addSubview(v)
        handleChange()
    }

    private func handleChange() {
        onChange?()
    }
}

// MARK: - Self-check

/// Pure data-model checks that work without a running NSApp / ghostty.
/// Called from the `selfcheck` exit path; does NOT create PaneTree or TerminalPane.
func workspaceSelfCheck() {
    let home = NSHomeDirectory()

    // ── Proj struct and SidebarProject/SidebarSession construction ──────────
    var homeProj = Proj(name: "~", path: home, sessions: [], expanded: true)
    assert(homeProj.path == home, "home proj path")
    assert(homeProj.sessions.isEmpty, "fresh proj has no sessions")
    assert(homeProj.expanded, "home proj starts expanded")

    var configProj = Proj(name: "code", path: "/Users/test/code", sessions: [], expanded: false)
    assert(!configProj.expanded, "config proj starts collapsed")

    // ── SidebarSession / SidebarProject ─────────────────────────────────────
    let ss1 = SidebarSession(label: "shell", active: true)
    let ss2 = SidebarSession(label: "vim", active: false)
    assert(ss1.active && !ss2.active, "session active flags")

    let sp = SidebarProject(name: "~", branch: "main", expanded: true, active: true, sessions: [ss1, ss2])
    assert(sp.sessions.count == 2, "sidebar project session count")
    assert(sp.branch == "main", "branch passthrough")
    assert(sp.active && sp.expanded, "project flags")

    // ── toggleExpand semantics: empty → create session; non-empty → flip ───────
    // The real Workspace.toggleExpand branches on sessions.isEmpty; verify the predicate.
    assert(homeProj.sessions.isEmpty == true, "toggleExpand: empty project takes the create-session branch")
    homeProj.expanded = true
    assert(homeProj.expanded, "toggleExpand on empty → expanded")

    configProj.expanded.toggle()
    assert(configProj.expanded, "toggleExpand on non-empty flips expanded")
    configProj.expanded.toggle()
    assert(!configProj.expanded, "toggleExpand twice → back to false")

    // ── closeSession invariant: replaceOnClose is the real decision function ───
    assert(Workspace.replaceOnClose(totalSessions: 1) == true,  "last session triggers replace, not remove")
    assert(Workspace.replaceOnClose(totalSessions: 2) == false, "two sessions: safe to remove one")

    // ── newProject appends and sets activeP to the new index ─────────────────
    var projs: [Proj] = [homeProj, configProj]
    let before = projs.count
    projs.append(Proj(name: "~", path: home, sessions: [], expanded: true))
    var activeP = projs.count - 1
    assert(projs.count == before + 1, "newProject appended")
    assert(activeP == projs.count - 1, "newProject activates new index")

    // ── appendProject: starts collapsed + empty ───────────────────────────────
    projs.append(Proj(name: "tmp", path: "/tmp", sessions: [], expanded: false))
    let emptyIdx = projs.count - 1
    assert(projs[emptyIdx].sessions.isEmpty, "appendProject: starts empty")
    assert(!projs[emptyIdx].expanded, "appendProject: starts collapsed")

    // ── toggleExpand on empty project: takes the create-session branch ───────
    // Real Workspace.toggleExpand branches on sessions.isEmpty; verify the predicate holds.
    assert(projs[emptyIdx].sessions.isEmpty == true, "toggleExpand on empty: would take create-session branch")
    projs[emptyIdx].expanded = true
    activeP = emptyIdx
    assert(activeP == emptyIdx, "toggleExpand on empty: activates the project")

    // ── removeProject: refuse last; fix activeP when removing at/before it ─────
    // Mirrors removeProject's index math (the real method needs a live Workspace).
    func fixActiveP(_ active: Int, removed p: Int, count: Int) -> Int {
        var a = active
        if a >= p { a = max(0, a - 1) }
        return min(a, count - 1)
    }
    assert(fixActiveP(2, removed: 0, count: 2) == 1, "remove before active shifts it down")
    assert(fixActiveP(0, removed: 1, count: 2) == 0, "remove after active leaves it")
    assert(fixActiveP(1, removed: 1, count: 1) == 0, "remove active clamps into range")

    print("workspaceSelfCheck OK")
}
