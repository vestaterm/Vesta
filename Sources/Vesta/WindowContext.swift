import AppKit

/// One Vesta window: its own Workspace (the flat workspace list) + chrome controller,
/// plus the per-window caches and refresh/attention logic. AppDelegate owns an
/// array of these for multi-window (⌘N). GhosttyApp stays a single shared
/// libghostty app across every window (one app, many surfaces).
@MainActor
final class WindowContext {
    let workspace: Workspace
    let controller: VestaWindowController

    private let onBecomeKey: (WindowContext) -> Void
    private let onClose: (WindowContext) -> Void
    /// Set by AppDelegate: persist all windows after this one changes (debounced).
    var onPersist: (() -> Void)?
    // nonisolated(unsafe): only mutated on main during init; deinit (nonisolated)
    // reads it once to deregister. NotificationCenter.removeObserver is thread-safe.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    // Keyed by cwd — flat model, every workspace carries its own directory.
    // ponytail: branch rarely changes within a session; no invalidation needed.
    private var branchCache: [String: String] = [:]
    // Only the active workspace's meta (ports + dirty) is refreshed per change.
    private var metaCache: [ObjectIdentifier: (ports: [Int], dirty: Int)] = [:]
    // Prompt-return attention: per-workspace (shell pid, busy ticks).
    private var sessionBusy: [ObjectIdentifier: (shell: pid_t, busyTicks: Int)] = [:]
    private var lastCwd: [ObjectIdentifier: String] = [:]   // for the dir-changed event
    private let attnMinTicks = 3

    // Debounce the full refresh: title/pwd spam from the focused pane fires refresh() many
    // times/sec, each rebuilding the sidebar + spawning ~10 processes. We coalesce to at most
    // one heavy refresh per second, keyed on the focused pane's (cwd, pid) — the only inputs
    // to the git/ports work. A key change (open/close/select/split/dir) forces an immediate
    // refresh; an unchanged key (attention/rename/title spam) rides a trailing refresh (≤1s).
    private var lastRefreshKey = ""
    private var lastRefreshAt = Date.distantPast
    private var refreshQueued = false
    private let refreshInterval: TimeInterval = 1.0

    /// Lite window: private store, bare shells, no sidebar — see AppDelegate.newWindow.
    var lite: Bool { workspace.lite }

    init(theme: Theme,
         store: SessionStore,
         hydrateFrom: [String: Any]? = nil,
         lite: Bool = false,
         cwd: String? = nil,
         onBecomeKey: @escaping (WindowContext) -> Void,
         onClose: @escaping (WindowContext) -> Void) {
        self.onBecomeKey = onBecomeKey
        self.onClose = onClose

        // Each window gets its OWN Workspace (own active selection + display body) over
        // the shared SessionStore. So window A can view untitled→2 while window B views
        // untitled→1 — both live, different sessions. The store is app-owned, so closing
        // a window drops the view, never the sessions. An empty pool is populated by
        // Workspace.init (restore, else one ~ workspace) plus the config seeding below.
        let ws = Workspace(theme: theme, store: store, hydrateFrom: hydrateFrom, lite: lite, cwd: cwd)
        // Unconditional: the seeding pass dedupes by cwd, so config paths added since the
        // last save appear even when the pool was restored non-empty. Lite windows skip it —
        // their private store holds exactly one throwaway workspace.
        if !lite { seedConfigWorkspaces(GhosttyApp.shared.settings, into: ws) }
        self.workspace = ws

        // Same workspace-management closures as the single-window build, bound to
        // THIS workspace (capture ws, not self — self isn't fully init yet).
        // + is instant: a workspace inherits the active one's cwd, so there is no folder
        // picker anywhere in this path — you get a shell first and rename/move it later.
        controller = VestaWindowController(
            theme: theme, content: ws.container, lite: lite,
            onSelectWorkspace: { [weak ws] i in ws?.selectWorkspace(i) },
            onCloseWorkspace:  { [weak ws] i, id in ws?.closeWorkspace(i, id: id) },
            onNewWorkspace:    { [weak ws] in ws?.newWorkspace() },
            onToggleGroup:     { [weak ws] g in ws?.toggleGroupCollapsed(g) },
            // Chrome's rename prompt sends the raw field text ("" when the user cleared it).
            // Blank CLEARS the custom name — the label falls back to the cwd basename.
            onRenameWorkspace: { [weak ws] i, name in
                                            let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                            ws?.renameWorkspace(i, t.isEmpty ? nil : t) },
            onRenameGroup:     { [weak ws] g, name in ws?.renameGroup(g, name) },
            onSetWorkspaceColor: { [weak ws] i, color in ws?.setWorkspaceColor(i, color) },
            onSetGroupColor:     { [weak ws] g, color in ws?.setGroupColor(g, color) },
            onRemoveGroup:     { [weak ws] g in ws?.removeGroup(g) },
            onUngroup:         { [weak ws] g in ws?.ungroup(g) },
            onGroupFromWorkspace: { [weak ws] i in ws?.newGroupFromWorkspace(i) },
            onMoveToGroup:     { [weak ws] i, gid in ws?.moveToGroup(i, groupID: gid) },
            onNewWorktree:     { [weak ws] i, branch, id in
                                            ws?.newWorktreeWorkspace(from: i, branch: branch, id: id) },
            onReorderTopLevel: { [weak ws] from, gap, id in ws?.moveTopLevel(from: from, gap: gap, id: id) },
            onReorderMember:   { [weak ws] g, from, gap, id in ws?.moveMember(g, from: from, gap: gap, id: id) })

        // self is fully initialized past this point. Cross-window refresh + persistence
        // flow through store.broadcast (wired by AppDelegate), not a per-window onChange.
        let nc = NotificationCenter.default
        let win = controller.window
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.onBecomeKey(self) }
        })
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.onClose(self) }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Show + focus the window and do the initial render.
    func start() {
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        refresh()
        workspace.mountLive()   // show this window's active session right away
    }

    func applyTheme(_ t: Theme) {
        workspace.applyTheme(t)
        controller.applyTheme(t)
        refresh()
    }

    /// First detected port of a session (for the ⌘⇧Return browser keybind).
    func detectedPort(_ tree: PaneTree) -> Int? { metaCache[ObjectIdentifier(tree)]?.ports.first }

    /// Ring a background session when its foreground process returns to the shell
    /// (a command/agent turn finished). Cleared when the session is focused.
    func pollAttention() {
        let activeID = ObjectIdentifier(workspace.activeTree)
        let trees = workspace.wss.map(\.tree)
        let live = Set(trees.map(ObjectIdentifier.init))
        sessionBusy = sessionBusy.filter { live.contains($0.key) }   // evict closed workspaces
        for tree in trees {
            if tree.isDormant { continue }   // no live panes to poll; materializes on activation
            let oid = ObjectIdentifier(tree)
            // dir-changed: the focused pane's cwd moved (cd, etc.).
            let cwd = tree.focusedCwd ?? ""
            if let last = lastCwd[oid], last != cwd { luaFire("dir-changed", tree.focusedPaneID) }
            lastCwd[oid] = cwd
            let pid = tree.focusedPID
            guard let prev = sessionBusy[oid], prev.shell != 0 else {
                sessionBusy[oid] = (shell: pid ?? 0, busyTicks: 0)
                continue
            }
            let isBusy = pid != nil && pid != prev.shell
            if isBusy {
                sessionBusy[oid] = (shell: prev.shell, busyTicks: prev.busyTicks + 1)
            } else {
                if prev.busyTicks >= attnMinTicks {
                    if oid != activeID { workspace.markAttention(tree) }
                    luaFire("command-finished", tree.focusedPaneID)   // a command / agent turn finished
                }
                sessionBusy[oid] = (shell: prev.shell, busyTicks: 0)
            }
        }
    }

    /// Rebuild the sidebar from the live snapshot, filling branch + meta from caches.
    /// Pure render — must NOT call refresh() (avoid a loop).
    private func renderSidebar() {
        guard !lite else { return }   // no sidebar — skip the viewport captures too
        let live = Set(workspace.wss.map { ObjectIdentifier($0.tree) })
        metaCache = metaCache.filter { live.contains($0.key) }

        let tails = VestaConfig.shared.sidebarTails
        // Branch/ports/dirty/tail live in this window's caches, not the shared model, so the
        // snapshot arrives without them. A row is a row whether it sits top-level or under a
        // group header — one filler, applied down both arms of the enum.
        func fill(_ w: inout SidebarWorkspace) {
            guard workspace.wss.indices.contains(w.index) else { return }
            let tree = workspace.wss[w.index].tree
            if let meta = metaCache[ObjectIdentifier(tree)] {
                w.ports = meta.ports
                w.dirty = meta.dirty
            }
            if tails { w.tail = tree.tailLines }
            // Branch is keyed by cwd now (flat model: every workspace has its own).
            // An empty cached value means "checked, not a repo" — render nothing.
            let cached = tree.focusedCwd.flatMap { branchCache[$0] }
            w.branch = (cached?.isEmpty ?? true) ? nil : cached
        }

        var items = workspace.snapshot()
        for i in items.indices {
            switch items[i] {
            case .workspace(var w):
                fill(&w)
                items[i] = .workspace(w)
            case .group(var g):
                for m in g.members.indices { fill(&g.members[m]) }
                items[i] = .group(g)
            }
        }
        controller.setSidebar(items)
    }

    /// Update titlebar dir + sidebar footer (git) for the focused pane. The titlebar is always
    /// updated cheaply (title/pwd spam only needs this); the heavy sidebar rebuild + git/ports
    /// spawns are debounced to ≤1×/s and short-circuited when the focused (cwd, pid) is unchanged.
    func refresh() {
        // Cheap path first: keep the titlebar current on every call (this is what title/pwd
        // spam actually needs). No spawns, no sidebar teardown.
        let cwd = workspace.activeTree.focusedCwd ?? FileManager.default.currentDirectoryPath
        let liveTitle = workspace.activeTree.focusedTitle
        controller.setDir(liveTitle.isEmpty ? abbreviateHome(cwd) : liveTitle)

        // Lite: the titlebar path above is the whole render — no sidebar/footer exists,
        // so the git/ports spawns and the sidebar rebuild would feed nothing.
        if lite { return }

        let key = Self.refreshKey(cwd: workspace.activeTree.focusedCwd, pid: workspace.activeTree.focusedPID)
        let now = Date()
        if !Self.shouldFullRefresh(key: key, lastKey: lastRefreshKey, lastAt: lastRefreshAt, now: now, interval: refreshInterval) {
            // Same focus, refreshed recently → coalesce. Still schedule one trailing refresh so a
            // pending content change (attention/rename) lands within the window (≤1s).
            if !refreshQueued {
                refreshQueued = true
                let delay = refreshInterval - now.timeIntervalSince(lastRefreshAt)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
                    guard let self else { return }
                    self.refreshQueued = false
                    self.fullRefresh()
                }
            }
            return
        }
        fullRefresh()
    }

    /// Shell pid per pane from the daemon, cached — a session's login-shell pid never
    /// changes, and paneIDs are UUIDs (no reuse), so one `pids` round trip per unknown
    /// pane suffices. nonisolated + lock: called from the utility-queue port scan.
    /// Panes not in the daemon (vesta-persist off) miss here and fall back to ghostty's pid.
    private nonisolated(unsafe) static var shellPIDCache: [String: pid_t] = [:]
    private nonisolated(unsafe) static var lastPIDQuery = Date.distantPast
    private nonisolated static let shellPIDLock = NSLock()
    nonisolated static func daemonShellPID(_ paneID: String) -> pid_t? {
        shellPIDLock.lock()
        if let hit = shellPIDCache[paneID] { shellPIDLock.unlock(); return hit }
        // Miss: throttle daemon round trips to one per 5s — a non-daemon pane would
        // otherwise query every refresh tick forever, and a wedged daemon would eat its
        // 2s timeout per tick. NOT a permanent negative cache: a just-spawned pane can
        // race its daemon registration, and must resolve on a later query.
        guard Date().timeIntervalSince(lastPIDQuery) >= 5 else { shellPIDLock.unlock(); return nil }
        lastPIDQuery = Date()
        shellPIDLock.unlock()
        guard let all = MuxClient.shellPIDs() else { return nil }
        shellPIDLock.lock()
        shellPIDCache.merge(all) { _, new in new }
        let v = shellPIDCache[paneID]
        shellPIDLock.unlock()
        return v
    }

    /// Focus key for the debounce short-circuit: the git/ports work depends only on the focused
    /// pane's cwd + pid, so an unchanged key means an unchanged heavy result.
    nonisolated static func refreshKey(cwd: String?, pid: pid_t?) -> String { "\(cwd ?? "")|\(pid ?? 0)" }

    /// Pure debounce decision (unit-tested in windowRefreshSelfCheck): run the heavy refresh when
    /// the focus key changed, or when the last one is older than `interval`.
    nonisolated static func shouldFullRefresh(key: String, lastKey: String, lastAt: Date, now: Date, interval: TimeInterval) -> Bool {
        key != lastKey || now.timeIntervalSince(lastAt) >= interval
    }

    /// Undebounced sidebar render — store.broadcast uses it so user actions (toggle/
    /// select/close/reorder) land visually this frame instead of on the next ≤1s tick.
    /// Cheap when nothing changed (the renderer skips identical snapshots).
    func renderSidebarNow() { renderSidebar() }

    /// The heavy refresh: rebuild the sidebar and (off-main) recompute git status + ports.
    private func fullRefresh() {
        lastRefreshKey = Self.refreshKey(cwd: workspace.activeTree.focusedCwd, pid: workspace.activeTree.focusedPID)
        lastRefreshAt = Date()
        renderSidebar()
        // One branch lookup per distinct workspace cwd. Dormant rows are skipped — their
        // shells haven't been paid for yet, and neither should a git spawn be.
        let unchecked = Set(workspace.wss.compactMap { $0.tree.isDormant ? nil : $0.tree.focusedCwd })
            .filter { branchCache[$0] == nil }
        if !unchecked.isEmpty {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var fresh: [String: String] = [:]
                for path in unchecked { fresh[path] = Git.branch(path) ?? "" }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.branchCache.merge(fresh) { old, _ in old }
                        self.renderSidebar()
                    }
                }
            }
        }
        let activeTreeID = ObjectIdentifier(workspace.activeTree)
        let activeCwd = workspace.activeTree.focusedCwd
        let activePID = workspace.activeTree.focusedPID
        let activePaneID = workspace.activeTree.focused?.paneID
        let statusCwd = activeCwd ?? FileManager.default.currentDirectoryPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // One git spawn set (status --porcelain runs once, yields both the footer text AND
            // the dirty count) plus one ports lookup, instead of two parallel git dispatches.
            let (text, dirty) = Git.statusAndDirty(statusCwd)
            // Under vesta-persist, ghostty's foreground pid is only the vesta-attach relay
            // (a childless process) — scanning from it made the :port chip permanently blank.
            // The real login shell lives under vestad; scan from ITS pid when available.
            let scanPID = activePaneID.flatMap { Self.daemonShellPID($0) } ?? activePID
            let ports = scanPID.map { Ports.forShell(pid: $0) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.controller.setStatus("normal" + (text.map { " · \($0)" } ?? ""))
                    self.metaCache[activeTreeID] = (ports: ports, dirty: activeCwd == nil ? 0 : dirty)
                    self.renderSidebar()
                }
            }
        }
    }
}

/// Pure-logic check of the refresh debounce/short-circuit (no NSApp/ghostty needed).
func windowRefreshSelfCheck() {
    let t0 = Date()
    let k = WindowContext.refreshKey(cwd: "/tmp", pid: 42)
    // Changed focus → always refresh, even immediately.
    assert(WindowContext.shouldFullRefresh(key: "other", lastKey: k, lastAt: t0, now: t0, interval: 1.0),
           "changed focus key must refresh")
    // Same focus, refreshed just now → coalesce.
    assert(!WindowContext.shouldFullRefresh(key: k, lastKey: k, lastAt: t0, now: t0.addingTimeInterval(0.2), interval: 1.0),
           "same key within interval must coalesce")
    // Same focus, interval elapsed → trailing refresh runs.
    assert(WindowContext.shouldFullRefresh(key: k, lastKey: k, lastAt: t0, now: t0.addingTimeInterval(1.1), interval: 1.0),
           "same key past interval must refresh")
    print("windowRefreshSelfCheck OK")
}
