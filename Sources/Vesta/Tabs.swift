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

/// App-owned shared session pool: holds the projects + their sessions (PaneTrees own
/// the live ghostty surfaces), so they survive any window closing. Every window's
/// Workspace reads/writes `projs` here, and `broadcast` refreshes all open windows —
/// that's what makes the sidebar global. Per-window state (active selection, the
/// display body) stays in Workspace, so each window can view a DIFFERENT session.
@MainActor
final class SessionStore {
    var projs: [Proj] = []
    var broadcast: () -> Void = {}
    // Last active (project, session) selection — survives closing all windows, so reopening
    // returns to where you were instead of spawning a fresh project.
    var lastActive: (p: Int, s: Int) = (0, 0)
}

/// Owns projects; each project owns sessions (PaneTrees).
/// Container = body only — the active session's rootView, swapped on change.
/// No top tab strip.
@MainActor
final class Workspace {
    let store: SessionStore
    var projs: [Proj] { get { store.projs } set { store.projs = newValue } }
    private(set) var activeP = 0
    private(set) var activeS = 0

    // Session→branch tag: keyed by PaneTree instance identity to avoid touching PaneTree's init.
    private var worktreeBranch: [ObjectIdentifier: String] = [:]

    // Sessions that have rung the bell / fired a desktop notification while not active.
    private var attention: Set<ObjectIdentifier> = []

    /// True if `tree` has pending attention (bell/notification while backgrounded).
    /// Exposed for `sessions --json` / `pane status`.
    func hasAttention(_ tree: PaneTree) -> Bool { attention.contains(ObjectIdentifier(tree)) }

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

    init(theme: Theme, store: SessionStore, hydrateFrom: [String: Any]? = nil) {
        self.store = store
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

        // Restore path: build straight from the saved window entry instead of seeding a
        // throwaway home session (a real surface + relay + daemon login shell that hydrate
        // would immediately discard, leaking the shell under vestad every launch). hydrate
        // populates projs (dormant) + calls showActive.
        if projs.isEmpty, let win = hydrateFrom,
           (win["projects"] as? [[String: Any]])?.isEmpty == false {
            hydrate(from: win)
            return
        }

        if projs.isEmpty {
            // First window for an empty pool: seed the home project at ~ with one session.
            // Config projects are appended collapsed + empty by loadProjects/appendProject.
            let home = NSHomeDirectory()
            var homeProj = makeProj(name: "home", path: home, expanded: true, id: "home")
            homeProj.sessions.append(makeTree(cwd: home))
            projs.append(homeProj)
            activeP = 0
            activeS = 0
        } else {
            // Reusing a live pool (e.g. reopened after closing all windows): return to the
            // last active project — clamped — never spawn a duplicate. Lazy-open a session if
            // that project was collapsed/empty.
            let p = min(max(store.lastActive.p, 0), projs.count - 1)
            activeP = p
            if projs[p].sessions.isEmpty {
                projs[p].sessions.append(makeTree(cwd: projs[p].path.isEmpty ? NSHomeDirectory() : projs[p].path))
                projs[p].expanded = true
            }
            activeS = min(max(store.lastActive.s, 0), projs[p].sessions.count - 1)
        }
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
        // Default to the project's directory when no explicit cwd is given, so new sessions
        // (project "+", ⌘T, `tab new`) open in the project's default dir.
        let dir = cwd ?? (projs[p].path.isEmpty ? NSHomeDirectory() : projs[p].path)
        let tree = makeTree(cwd: dir)
        projs[p].sessions.append(tree)
        projs[p].expanded = true
        activeP = p
        activeS = projs[p].sessions.count - 1
        showActive()
        luaFire("session-opened", tree.paneID)
    }

    func newSession(_ p: Int) {
        addSession(p, cwd: nil)   // addSession defaults to the project's dir
    }

    /// Change a project's default directory (used for new sessions). Existing sessions keep
    /// their own cwd.
    func setProjectDir(_ p: Int, _ path: String) {
        guard projs.indices.contains(p) else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projs[p].path = trimmed
        saveProjects()
        handleChange()
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

    func renameSession(_ p: Int, _ s: Int, _ name: String?) {
        guard projs.indices.contains(p), projs[p].sessions.indices.contains(s) else { return }
        projs[p].sessions[s].setName(name)   // setName fires onFocusChange → save + render
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

    /// Create a project. With a path, the folder name becomes the project name and its
    /// first session opens there; without one, an "untitled" project at home (legacy default).
    func newProject(at path: String? = nil) {
        let dir = path ?? NSHomeDirectory()
        let name = path == nil ? "untitled" : ((dir as NSString).lastPathComponent.isEmpty ? dir : (dir as NSString).lastPathComponent)
        var proj = makeProj(name: name, path: dir, expanded: true, id: "u:\(UUID().uuidString)")
        // Add one session in the project dir immediately (mirrors home proj behaviour).
        let tree = makeTree(cwd: dir)
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
        luaFire("focus-changed", activeTree.paneID)
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
        // Closing a session KILLS its daemon shell — the sidebar is the single source of
        // truth, so there are no orphaned detached sessions. (Window-close still only
        // detaches, since it doesn't drop the PaneTree from the shared store.)
        closing.paneIDs.forEach { TerminalPane.suppressExit($0); MuxClient.kill(paneID: $0) }
        luaFire("session-closed", closing.paneID)
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
                let base = tree.name ?? tree.focusedLabel
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
        let dir = NSHomeDirectory() + "/Library/Application Support/vesta"
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
    /// sessions, plus the active project/session. Each session stores its full split
    /// `layout` (topology + per-leaf paneID/cwd) so splits restore intact; cwd/paneID
    /// stay top-level as a fallback for pre-layout snapshots. Live processes/scrollback
    /// can't be restored — each leaf reopens as a fresh shell at its cwd.
    func serialize() -> [String: Any] {
        let projsData: [[String: Any]] = projs.map { p in
            var d: [String: Any] = [
                "id": p.id, "name": p.name, "path": p.path, "expanded": p.expanded,
                "sessions": p.sessions.map { (t: PaneTree) -> [String: Any] in
                    var sd: [String: Any] = ["cwd": t.focusedCwd ?? p.path, "paneID": t.paneID,
                                             "layout": t.serializeLayout()]
                    if let nm = t.name { sd["name"] = nm }
                    return sd
                },
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
        // Replace each leaf's saved cwd with a usable one (recurse through splits).
        func fixDirs(_ node: [String: Any], fallback: String) -> [String: Any] {
            var n = node
            if let a = node["a"] as? [String: Any], let b = node["b"] as? [String: Any] {
                n["a"] = fixDirs(a, fallback: fallback); n["b"] = fixDirs(b, fallback: fallback)
            } else if let cwd = node["cwd"] as? String {
                n["cwd"] = usableDir(cwd, fallback: fallback)
            }
            return n
        }

        for pd in projsData {
            let id = pd["id"] as? String ?? "u:\(UUID().uuidString)"
            let name = pd["name"] as? String ?? "untitled"
            let path = pd["path"] as? String ?? NSHomeDirectory()
            let color = (pd["color"] as? String).flatMap { ghosttyColor($0) }
            let expanded = pd["expanded"] as? Bool ?? true
            var proj = Proj(id: id, name: name, path: path, sessions: [], expanded: expanded, color: color)
            for entry in (pd["sessions"] as? [Any] ?? []) {
                // Every restored session is built DORMANT (persisted layout only). The one
                // the window will display materializes at showActive() below; the rest stay
                // data until first activation — no surfaces, no daemon attach at launch.
                // Preferred: a saved split layout (topology + per-leaf paneID/cwd).
                if let d = entry as? [String: Any],
                   let layout = d["layout"] as? [String: Any],
                   layout["a"] != nil || layout["paneID"] != nil || layout["browser"] != nil {
                    proj.sessions.append(makeDormant(layout: fixDirs(layout, fallback: path),
                                                     name: d["name"] as? String))
                    continue
                }
                // Fallback: flat cwd/paneID (pre-layout snapshot) or legacy string entry →
                // a single-leaf dormant layout (serializeLayout echoes it back identically).
                let cwd: String, pid: String, nm: String?
                if let d = entry as? [String: Any] {
                    cwd = d["cwd"] as? String ?? path
                    pid = d["paneID"] as? String ?? UUID().uuidString
                    nm  = d["name"] as? String
                } else if let s = entry as? String {   // legacy windows.json (pre-M2)
                    cwd = s; pid = UUID().uuidString; nm = nil
                } else { continue }
                proj.sessions.append(makeDormant(
                    layout: ["paneID": pid, "cwd": usableDir(cwd, fallback: path)], name: nm))
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

    private func makeTree(cwd: String?, paneID: String = UUID().uuidString, name: String? = nil) -> PaneTree {
        wire(PaneTree(theme: theme, cwd: cwd, paneID: paneID, name: name))
    }

    /// A DORMANT session: keeps its persisted layout as data, builds ghostty surfaces only
    /// on first activation (mountLive → rootView → materialize). This is the launch-time win —
    /// hydrate makes every non-active session dormant.
    private func makeDormant(layout: [String: Any], name: String? = nil) -> PaneTree {
        wire(PaneTree(theme: theme, dormant: layout, name: name))
    }

    private func wire(_ tree: PaneTree) -> PaneTree {
        // Broadcast through the app-owned store, NOT this Workspace: trees live in the
        // shared pool and outlive the window that wired them (close the last window →
        // reopen from the Dock reuses the pool; close one window of several). A dead
        // workspace here silently swallowed every tree mutation — closing/splitting a
        // pane stopped refreshing the sidebar's "N panes" until a click re-rendered it.
        tree.onFocusChange = { [weak store = store] in store?.broadcast() }
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
        store.lastActive = (activeP, activeS)   // remember for reopen-after-close
        mountLive()
        attention.remove(ObjectIdentifier(activeTree))   // clear ring for the focused session
        handleChange()                                   // broadcast → other windows reconcile
    }

    // ── Multi-window live/frozen (a session's rootView is one NSView → one window) ──

    /// True if THIS window currently hosts the live terminal for its active session
    /// (vs. another window holding the rootView, in which case we show a frozen snapshot).
    /// NOTE: touches rootView, which MATERIALIZES a dormant tree — fine for the active
    /// session (it's about to display anyway); never call this in a loop over all sessions.
    var hostsLive: Bool { activeTree.rootView.superview === body }

    /// Put our active session's live rootView into our body (stealing it from any other
    /// window that had it). Does NOT broadcast — call from reconcile to avoid a loop.
    func mountLive() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let v = activeTree.rootView
        v.frame = body.bounds
        v.autoresizingMask = [.width, .height]
        body.addSubview(v)
        activeTree.focusActivePane()
    }

    /// Our active session is live in another window → show a muted frozen snapshot of its
    /// current screen here instead of a blank. ponytail: plain-text capture (libghostty's
    /// read strips colors); refreshes whenever this window reconciles.
    func showFrozen() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let snap = NSView(); snap.wantsLayer = true
        snap.layer?.backgroundColor = theme.background.cgColor
        snap.frame = body.bounds; snap.autoresizingMask = [.width, .height]
        let scroll = NSScrollView(frame: snap.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let tv = NSTextView(frame: scroll.bounds)
        tv.autoresizingMask = [.width]
        tv.isEditable = false; tv.isSelectable = false; tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = NSColor(white: 0.5, alpha: 1)              // muted
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.string = activeTree.focused?.capture(scrollback: false) ?? ""
        scroll.documentView = tv
        snap.addSubview(scroll)
        body.addSubview(snap)
    }

    /// Decide this window's display: the focused (preferLive) window — or the sole viewer
    /// of an unowned session — shows live; a window whose session is live elsewhere freezes.
    func reconcile(preferLive: Bool) {
        // ponytail: skip the remount when our live root is already mounted here — a
        // replay-storm of broadcasts (scrollback replay retitling every pane) would otherwise
        // remount + re-first-respond the terminal on every tick. Mirrors the hostsLive guard.
        if preferLive {
            if !hostsLive { mountLive() }
        } else if activeTree.rootView.superview == nil {
            mountLive()
        } else if !hostsLive {
            showFrozen()
        }
        // else: already hosting live here → leave it
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
        // Shared pool changed → refresh every window's sidebar + persist (AppDelegate
        // wires store.broadcast). One path, so all windows stay in sync.
        store.broadcast()
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

    // ── Per-session snapshot is {cwd, paneID, name}; hydrate accepts dict + legacy ──
    func snap(cwd: String, paneID: String, name: String?) -> [String: Any] {
        var d: [String: Any] = ["cwd": cwd, "paneID": paneID]
        if let name { d["name"] = name }
        return d
    }
    // New dict shape: read back all three fields.
    let s = snap(cwd: "/tmp", paneID: "PID-1", name: "build")
    assert(s["cwd"] as? String == "/tmp", "snapshot cwd round-trips")
    assert(s["paneID"] as? String == "PID-1", "snapshot paneID round-trips")
    assert(s["name"] as? String == "build", "snapshot name round-trips")
    // nil name is simply absent (not stored as NSNull).
    let s2 = snap(cwd: "/tmp", paneID: "PID-2", name: nil)
    assert(s2["name"] == nil, "nil name is omitted from the snapshot")

    // hydrate's reader: a session entry may be the new dict OR a legacy bare cwd string.
    func readSession(_ entry: Any) -> (cwd: String, paneID: String?, name: String?) {
        if let d = entry as? [String: Any] {
            return (d["cwd"] as? String ?? home, d["paneID"] as? String, d["name"] as? String)
        }
        if let cwd = entry as? String { return (cwd, nil, nil) }   // legacy windows.json
        return (home, nil, nil)
    }
    let r1 = readSession(s)
    assert(r1.cwd == "/tmp" && r1.paneID == "PID-1" && r1.name == "build", "reads new dict entry")
    let r2 = readSession("/legacy/path")   // pre-M2 format
    assert(r2.cwd == "/legacy/path" && r2.paneID == nil && r2.name == nil, "reads legacy string entry")

    print("workspaceSelfCheck OK")
}

// MARK: - windows.json format (versioned)

/// windows.json format version. v1 = `{"version": 1, "windows": [entry…]}` with the
/// key window's entry first; each entry is Workspace.serialize() + optional "frame"
/// (NSWindow frameDescriptor). Pre-versioning files are a bare top-level array.
let windowsFormatVersion = 1

/// Decode windows.json bytes into (version, window entries). Pure — no I/O — so the
/// selfcheck can exercise it. An unversioned top-level array is the legacy format →
/// version 0. Corrupt/garbage JSON → (0, []): the caller falls back to a fresh window.
/// Future format bumps branch HERE (migrate old shapes into the current one).
func parseWindowsFile(_ data: Data) -> (version: Int, windows: [[String: Any]]) {
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return (0, []) }
    if let legacy = json as? [[String: Any]] { return (0, legacy) }   // pre-versioning format
    guard let dict = json as? [String: Any],
          let wins = dict["windows"] as? [[String: Any]] else { return (0, []) }
    return (dict["version"] as? Int ?? windowsFormatVersion, wins)
}

/// Format-level checks for windows.json (hydrate itself needs live PaneTrees/ghostty,
/// so the selfcheck stops at the parse seam — see workspaceSelfCheck for entry reading).
func windowsFormatSelfCheck() {
    // Current (v1) format: version + entries round-trip, frame string survives.
    let entry: [String: Any] = [
        "projects": [["id": "home", "name": "home", "path": "/tmp",
                      "sessions": [["cwd": "/tmp", "paneID": "P1"]]]],
        "activeProject": 0, "activeSession": 0, "frame": "10 10 800 600 0 0 1920 1080 ",
    ]
    let v1 = try! JSONSerialization.data(
        withJSONObject: ["version": windowsFormatVersion, "windows": [entry, entry]])
    let r1 = parseWindowsFile(v1)
    assert(r1.version == windowsFormatVersion && r1.windows.count == 2, "v1 file parses")
    assert((r1.windows[0]["projects"] as? [[String: Any]])?.count == 1, "v1 entry content intact")
    assert(r1.windows[1]["frame"] as? String == "10 10 800 600 0 0 1920 1080 ", "frame survives")
    // Legacy: bare top-level array, cwd-only string sessions (pre-M2) → version 0.
    let legacy = Data(
        #"[{"projects": [{"id": "home", "name": "home", "path": "/tmp", "sessions": ["/tmp", "/x"]}]}]"#
            .utf8)
    let r0 = parseWindowsFile(legacy)
    assert(r0.version == 0 && r0.windows.count == 1, "legacy array → version 0")
    let sess = ((r0.windows[0]["projects"] as? [[String: Any]])?.first?["sessions"] as? [Any]) ?? []
    assert(sess.first as? String == "/tmp", "legacy cwd-only session entries preserved")
    // Corrupted / garbage input must not crash and must fall back to (0, []).
    assert(parseWindowsFile(Data("not json {{{".utf8)).windows.isEmpty, "garbage → empty")
    assert(parseWindowsFile(Data()).windows.isEmpty, "empty file → empty")
    assert(parseWindowsFile(Data("42".utf8)).windows.isEmpty, "scalar json → empty")
    assert(parseWindowsFile(Data(#"{"version": 1}"#.utf8)).windows.isEmpty, "no windows key → empty")
    assert(parseWindowsFile(Data(#"{"windows": [{}]}"#.utf8)).version == windowsFormatVersion,
           "missing version in dict form → treated as current")
    print("windowsFormatSelfCheck OK")
}
