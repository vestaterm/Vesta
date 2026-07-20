import AppKit

/// One Vesta window: its own Workspace (projects/sessions) + chrome controller,
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

    // ponytail: branch rarely changes within a session; no invalidation needed.
    private var branchCache: [String: String] = [:]
    // Only the active session's meta (ports + dirty) is refreshed per change.
    private var metaCache: [ObjectIdentifier: (ports: [Int], dirty: Int)] = [:]
    // Prompt-return attention: per-session (shell pid, busy ticks).
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

    init(theme: Theme,
         store: SessionStore,
         hydrateFrom: [String: Any]? = nil,
         onBecomeKey: @escaping (WindowContext) -> Void,
         onClose: @escaping (WindowContext) -> Void) {
        self.onBecomeKey = onBecomeKey
        self.onClose = onClose

        // Each window gets its OWN Workspace (own active selection + display body) over
        // the shared SessionStore. So window A can view untitled→2 while window B views
        // untitled→1 — both live, different sessions. The store is app-owned, so closing
        // a window drops the view, never the sessions. First window to see an empty pool
        // populates it (config projects + persisted state).
        let ws = Workspace(theme: theme, store: store, hydrateFrom: hydrateFrom)
        if store.projs.isEmpty {
            loadProjects(GhosttyApp.shared.settings, into: ws)
            ws.restorePersisted()
        }
        self.workspace = ws

        // Same session-management closures as the single-window build, bound to
        // THIS workspace (capture ws, not self — self isn't fully init yet).
        controller = VestaWindowController(
            theme: theme, content: ws.container,
            onSelectSession:   { [weak ws] p, s in ws?.selectSession(p, s) },
            onCloseSession:    { [weak ws] p, s in ws?.closeSession(p, s) },
            onNewSession:      { [weak ws] p in ws?.newSession(p) },
            onToggleExpand:    { [weak ws] p in ws?.toggleExpand(p) },
            onNewProject:      { [weak ws] in
                                            guard let ws else { return }
                                            let panel = NSOpenPanel()
                                            panel.canChooseDirectories = true
                                            panel.canChooseFiles = false
                                            panel.canCreateDirectories = true
                                            panel.allowsMultipleSelection = false
                                            panel.prompt = "Add Project"
                                            panel.message = "Choose a folder for the new project"
                                            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
                                            let pick = { (r: NSApplication.ModalResponse) in
                                                if r == .OK, let url = panel.url { ws.newProject(at: url.path) }
                                            }
                                            if let win = ws.container.window { panel.beginSheetModal(for: win, completionHandler: pick) }
                                            else { pick(panel.runModal()) } },
            onRenameProject:   { [weak ws] p, name in ws?.renameProject(p, name) },
            onRenameSession:   { [weak ws] p, s, name in ws?.renameSession(p, s, name) },
            onSetProjectColor: { [weak ws] p, color in ws?.setProjectColor(p, color) },
            onRemoveProject:   { [weak ws] p in ws?.removeProject(p) },
            onNewWorktree:     { [weak ws] p, branch in ws?.newWorktreeSession(p, branch: branch) },
            onChangeProjectDir: { [weak ws] in
                                            guard let ws else { return }
                                            let panel = NSOpenPanel()
                                            panel.canChooseDirectories = true
                                            panel.canChooseFiles = false
                                            panel.canCreateDirectories = true
                                            panel.allowsMultipleSelection = false
                                            panel.prompt = "Set Folder"
                                            panel.message = "Default folder for new sessions in this project"
                                            let cur = ws.projs.indices.contains(ws.activeP) ? ws.projs[ws.activeP].path : NSHomeDirectory()
                                            panel.directoryURL = URL(fileURLWithPath: cur)
                                            let pick = { (r: NSApplication.ModalResponse) in
                                                if r == .OK, let url = panel.url { ws.setProjectDir(ws.activeP, url.path) }
                                            }
                                            if let win = ws.container.window { panel.beginSheetModal(for: win, completionHandler: pick) }
                                            else { pick(panel.runModal()) } },
            onReorderProject:  { [weak ws] from, gap in ws?.moveProject(from: from, gap: gap) },
            onReorderSession:  { [weak ws] p, from, gap in ws?.moveSession(p, from: from, gap: gap) })

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
        let sessions = workspace.projs.flatMap(\.sessions)
        let live = Set(sessions.map(ObjectIdentifier.init))
        sessionBusy = sessionBusy.filter { live.contains($0.key) }   // evict closed sessions
        for tree in sessions {
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
        let live = Set(workspace.projs.flatMap(\.sessions).map(ObjectIdentifier.init))
        metaCache = metaCache.filter { live.contains($0.key) }

        var projs = workspace.snapshot()
        for i in projs.indices {
            let path = workspace.projs[i].path
            let cached = branchCache[path]
            projs[i].branch = (cached == nil || cached!.isEmpty) ? nil : cached
            for si in projs[i].sessions.indices {
                let tree = workspace.projs[i].sessions[si]
                if let meta = metaCache[ObjectIdentifier(tree)] {
                    projs[i].sessions[si].ports = meta.ports
                    projs[i].sessions[si].dirty = meta.dirty
                }
                if VestaConfig.shared.sidebarTails {
                    projs[i].sessions[si].tail = tree.tailLines
                }
            }
        }
        controller.setProjects(projs)
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

    /// Focus key for the debounce short-circuit: the git/ports work depends only on the focused
    /// pane's cwd + pid, so an unchanged key means an unchanged heavy result.
    nonisolated static func refreshKey(cwd: String?, pid: pid_t?) -> String { "\(cwd ?? "")|\(pid ?? 0)" }

    /// Pure debounce decision (unit-tested in windowRefreshSelfCheck): run the heavy refresh when
    /// the focus key changed, or when the last one is older than `interval`.
    nonisolated static func shouldFullRefresh(key: String, lastKey: String, lastAt: Date, now: Date, interval: TimeInterval) -> Bool {
        key != lastKey || now.timeIntervalSince(lastAt) >= interval
    }

    /// The heavy refresh: rebuild the sidebar and (off-main) recompute git status + ports.
    private func fullRefresh() {
        lastRefreshKey = Self.refreshKey(cwd: workspace.activeTree.focusedCwd, pid: workspace.activeTree.focusedPID)
        lastRefreshAt = Date()
        renderSidebar()
        let unchecked = workspace.projs.map(\.path).filter { branchCache[$0] == nil }
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
        let statusCwd = activeCwd ?? FileManager.default.currentDirectoryPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // One git spawn set (status --porcelain runs once, yields both the footer text AND
            // the dirty count) plus one ports lookup, instead of two parallel git dispatches.
            let (text, dirty) = Git.statusAndDirty(statusCwd)
            let ports = activePID.map { Ports.forShell(pid: $0) } ?? []
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
