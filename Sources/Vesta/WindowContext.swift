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

    init(theme: Theme,
         store: SessionStore,
         onBecomeKey: @escaping (WindowContext) -> Void,
         onClose: @escaping (WindowContext) -> Void) {
        self.onBecomeKey = onBecomeKey
        self.onClose = onClose

        // Each window gets its OWN Workspace (own active selection + display body) over
        // the shared SessionStore. So window A can view untitled→2 while window B views
        // untitled→1 — both live, different sessions. The store is app-owned, so closing
        // a window drops the view, never the sessions. First window to see an empty pool
        // populates it (config projects + persisted state).
        let ws = Workspace(theme: theme, store: store)
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
                                            else { pick(panel.runModal()) } })

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
            }
        }
        controller.setProjects(projs)
    }

    /// Update titlebar dir + sidebar footer (git) for the focused pane. Git runs
    /// off-main so the shell-outs never block the UI.
    func refresh() {
        let cwd = workspace.activeTree.focusedCwd ?? FileManager.default.currentDirectoryPath
        let liveTitle = workspace.activeTree.focusedTitle
        controller.setDir(liveTitle.isEmpty ? abbreviateHome(cwd) : liveTitle)
        renderSidebar()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let g = Git.status(cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.controller.setStatus("normal" + (g.map { " · \($0)" } ?? "")) }
            }
        }
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ports = activePID.map { Ports.forShell(pid: $0) } ?? []
            let dirty = activeCwd.map { Git.dirtyCount($0) } ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.metaCache[activeTreeID] = (ports: ports, dirty: dirty)
                    self.renderSidebar()
                }
            }
        }
    }
}
