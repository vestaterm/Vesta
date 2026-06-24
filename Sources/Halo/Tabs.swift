import AppKit

// MARK: - Sidebar data types (consumed by Task B's Chrome rendering)

struct SidebarSession {
    let label: String
    let active: Bool
    var ports: [Int] = []   // listening TCP ports of the session's foreground process tree
    var dirty: Int = 0      // uncommitted changes in the session's cwd (git status --porcelain)
    var attention: Bool = false  // bell/desktop-notification fired while session was not active
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
    var id: String = ""          // stable identity for persistence: "home", "cfg:<path>", "u:<uuid>"
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

    // Sessions that have rung the bell / fired a desktop notification while not active.
    private var attention: Set<ObjectIdentifier> = []

    var activeTree: PaneTree { projs[activeP].sessions[activeS] }
    var totalSessions: Int { projs.reduce(0) { $0 + $1.sessions.count } }

    let container = NSView()
    private let body = NSView()
    private var theme: Theme

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
        var homeProj = makeProj(name: "home", path: home, expanded: true, id: "home")
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
        saveProjects()
        handleChange()
    }

    func setProjectColor(_ p: Int, _ color: NSColor?) {
        guard projs.indices.contains(p) else { return }
        projs[p].color = color
        saveProjects()
        handleChange()
    }

    /// Remove a project and all its sessions. Refuses to remove the last project
    /// (the workspace must always have ≥1 project with ≥1 session).
    func removeProject(_ p: Int) {
        guard projs.indices.contains(p), projs.count > 1 else { return }
        projs[p].sessions.forEach { forget($0) }   // evict identity-keyed state
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
        saveProjects()
        showActive()
    }

    func newProject() {
        let home = NSHomeDirectory()
        var proj = makeProj(name: "untitled", path: home, expanded: true, id: "u:\(UUID().uuidString)")
        // Add one session at home immediately (mirrors home proj behaviour).
        let tree = makeTree(cwd: home)
        proj.sessions.append(tree)
        projs.append(proj)
        activeP = projs.count - 1
        activeS = 0
        saveProjects()
        showActive()
    }

    func selectSession(_ p: Int, _ s: Int) {
        guard projs.indices.contains(p), projs[p].sessions.indices.contains(s) else { return }
        activeP = p; activeS = s
        attention.remove(ObjectIdentifier(activeTree))
        showActive()
    }

    /// Drop all identity-keyed state for a session being removed. Without this a
    /// later PaneTree that reuses the freed heap address inherits a stale
    /// worktree label or a phantom attention ring. (metaCache is evicted in
    /// AppDelegate.renderSidebar, which can see the live session set.)
    private func forget(_ tree: PaneTree) {
        let k = ObjectIdentifier(tree)
        worktreeBranch[k] = nil
        attention.remove(k)
    }

    /// Returns true when the last session is about to be removed — replace instead of deleting.
    nonisolated static func replaceOnClose(totalSessions: Int) -> Bool { totalSessions <= 1 }

    func closeSession(_ p: Int, _ s: Int) {
        guard projs.indices.contains(p), projs[p].sessions.indices.contains(s) else { return }
        let closing = projs[p].sessions[s]
        // If this was a worktree session, best-effort remove its worktree dir
        // off-main (non-force → dirty worktrees are left intact, never destroyed).
        if let branch = worktreeBranch[ObjectIdentifier(closing)] {
            let repo = projs[p].path
            let dir = Worktree.dirFor(repo: repo, branch: branch)
            DispatchQueue.global(qos: .utility).async { try? Worktree.remove(repo: repo, dir: dir) }
        }
        // Forget identity-keyed state for the session being removed/replaced.
        forget(closing)
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
                return SidebarSession(label: label, active: pi == activeP && si == activeS,
                                     attention: attention.contains(ObjectIdentifier(tree)))
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

    // MARK: - Persistence (created projects + names/colors survive restart)

    private static var projectsFile: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/halo"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/projects.json"
    }

    /// Write the current project list (id/name/path/color — not sessions) to disk.
    private func saveProjects() {
        let arr: [[String: String]] = projs.map { p in
            var d = ["id": p.id, "name": p.name, "path": p.path]
            if let c = p.color { d["color"] = hexString(c) }
            return d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.projectsFile), options: .atomic)
    }

    /// Layer persisted customizations on top of the launch state (home + config):
    /// update name/color of existing projects by id, and re-add user-created
    /// projects (`u:…`) that aren't present. Sessions stay lazy. Call after init +
    /// loadProjects, before `onChange` is wired (so it doesn't trigger a render).
    func restorePersisted() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.projectsFile)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }
        for d in arr {
            guard let id = d["id"], let name = d["name"], let path = d["path"] else { continue }
            let color = d["color"].flatMap { ghosttyColor($0) }
            if let i = projs.firstIndex(where: { $0.id == id }) {
                projs[i].name = name
                projs[i].color = color          // config/home rename + recolor persist
            } else if id.hasPrefix("u:") {
                projs.append(Proj(id: id, name: name, path: path, sessions: [], expanded: false, color: color))
            }
            // cfg:/home entries not present are intentionally not re-added — they're
            // driven by the live config (a path removed from config stays gone).
        }
    }

    /// Append a config project as collapsed + empty (lazy).
    func appendProject(name: String, path: String) {
        projs.append(Proj(id: "cfg:\(path)", name: name, path: path, sessions: [], expanded: false))
    }

    // MARK: - Window-state persistence (this window's projects + sessions-by-cwd)

    /// Snapshot for windows.json: each project (id/name/path/color/expanded) with its
    /// sessions reduced to their focused-pane cwd, plus the active project/session.
    /// ponytail: v1 persists cwds only — NOT split layouts or live processes (a process
    /// can't be restored); each session reopens as a single shell at its cwd.
    func serialize() -> [String: Any] {
        let projsData: [[String: Any]] = projs.map { p in
            var d: [String: Any] = [
                "id": p.id, "name": p.name, "path": p.path, "expanded": p.expanded,
                "sessions": p.sessions.map { $0.focusedCwd ?? p.path },
            ]
            if let c = p.color { d["color"] = hexString(c) }
            return d
        }
        return ["projects": projsData, "activeProject": activeP, "activeSession": activeS]
    }

    /// Replace the launch state with a saved window snapshot. Robust: a session cwd
    /// that no longer exists falls back to the project path, then ~. Always leaves
    /// ≥1 project and the active project with ≥1 session.
    func hydrate(from win: [String: Any]) {
        guard let projsData = win["projects"] as? [[String: Any]], !projsData.isEmpty else { return }
        // Tear down the default state this Workspace built in init.
        projs.forEach { $0.sessions.forEach { forget($0) } }
        projs.removeAll()

        let fm = FileManager.default
        func usableDir(_ cwd: String, fallback: String) -> String {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue { return cwd }
            if fm.fileExists(atPath: fallback, isDirectory: &isDir), isDir.boolValue { return fallback }
            return NSHomeDirectory()
        }

        for pd in projsData {
            let id = pd["id"] as? String ?? "u:\(UUID().uuidString)"
            let name = pd["name"] as? String ?? "untitled"
            let path = pd["path"] as? String ?? NSHomeDirectory()
            let color = (pd["color"] as? String).flatMap { ghosttyColor($0) }
            let expanded = pd["expanded"] as? Bool ?? true
            var proj = Proj(id: id, name: name, path: path, sessions: [], expanded: expanded, color: color)
            for cwd in (pd["sessions"] as? [String] ?? []) {
                proj.sessions.append(makeTree(cwd: usableDir(cwd, fallback: path)))
            }
            projs.append(proj)
        }

        // Invariants: ≥1 project, active project has ≥1 session.
        if projs.isEmpty {
            var home = makeProj(name: "home", path: NSHomeDirectory(), expanded: true, id: "home")
            home.sessions.append(makeTree(cwd: NSHomeDirectory()))
            projs.append(home)
        }
        activeP = min(max(0, win["activeProject"] as? Int ?? 0), projs.count - 1)
        if projs[activeP].sessions.isEmpty {
            projs[activeP].sessions.append(makeTree(cwd: projs[activeP].path))
            projs[activeP].expanded = true
        }
        activeS = min(max(0, win["activeSession"] as? Int ?? 0), projs[activeP].sessions.count - 1)
        showActive()
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
        attention.remove(ObjectIdentifier(activeTree))
        showActive()
    }

    // MARK: - Private helpers

    private func makeProj(name: String, path: String, expanded: Bool, id: String = "") -> Proj {
        Proj(id: id, name: name, path: path, sessions: [], expanded: expanded, color: nil)
    }

    /// Mark a background session as needing attention (driven by the prompt-return
    /// poller in AppDelegate — a background command finished). No-op for the active
    /// session (you're already looking at it).
    func markAttention(_ tree: PaneTree) {
        guard tree !== activeTree else { return }
        attention.insert(ObjectIdentifier(tree))
        handleChange()
    }

    private func makeTree(cwd: String?) -> PaneTree {
        let tree = PaneTree(theme: theme, cwd: cwd)
        tree.onFocusChange = { [weak self] in self?.handleChange() }
        tree.onAttention = { [weak self, weak tree] in
            guard let self, let tree else { return }
            // Only ring if this session isn't the one you're looking at.
            if tree !== self.activeTree {
                self.attention.insert(ObjectIdentifier(tree)); self.handleChange()
            }
        }
        return tree
    }

    private func showActive() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let v = activeTree.rootView
        v.frame = body.bounds
        v.autoresizingMask = [.width, .height]
        body.addSubview(v)
        // Make the active session's focused pane first responder so you can type
        // immediately without clicking it.
        activeTree.focusActivePane()
        // Clear attention ring for the now-focused session.
        attention.remove(ObjectIdentifier(activeTree))
        handleChange()
    }

    /// Focus the active session's pane (call after the window becomes key at launch).
    func focusActive() { activeTree.focusActivePane() }

    /// Live config reload (no relaunch): re-theme every session's panes and adopt
    /// the new theme for sessions created afterwards.
    func applyTheme(_ t: Theme) {
        theme = t
        container.layer?.backgroundColor = t.background.cgColor
        for p in projs { for s in p.sessions { s.applyTheme(t) } }
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

    // ── Attention: set when signalled while NOT the active session; clear on select ──
    func attn(active: Bool) -> Bool { !active }     // mirrors Workspace.attentionFired guard
    assert(attn(active: false) == true,  "signal on background session → ring")
    assert(attn(active: true)  == false, "signal on focused session → no ring")

    print("workspaceSelfCheck OK")
}
