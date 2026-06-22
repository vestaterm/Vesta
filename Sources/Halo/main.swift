import AppKit

let argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "selfcheck" {
    // Pure-logic checks only. PaneTree/Chrome spawn real ghostty surfaces,
    // which need a live app + run loop — exercised by actually launching the app.
    // workspaceSelfCheck tests the Proj/SidebarProject data model without ghostty.
    _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck(); portsSelfCheck(); workspaceSelfCheck(); worktreeSelfCheck(); browserSelfCheck()
    // chromeSelfCheck creates AppKit objects (HaloWindowController → HaloConfig.shared →
    // GhosttyApp.shared). GhosttyApp.shared calls NSApp.isActive; NSApp is nil until
    // NSApplication.shared is first touched. Touch it here so GhosttyApp.shared doesn't crash.
    _ = NSApplication.shared
    MainActor.assumeIsolated { chromeSelfCheck() }
    print("all self-checks ok"); exit(0)
}
if let verb = argv.first, verb == "help" || verb == "--help" || verb == "-h" {
    printUsage(); exit(0)
}
if let verb = argv.first, controlVerbs.contains(verb) {
    exit(runControlCLI(argv))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: HaloWindowController!
    var workspace: Workspace!
    var server: ControlServer!
    var theme = Theme()

    // ponytail: branch rarely changes within a session; no invalidation needed.
    // "" means "checked, not a repo". Upgrade path: FS watcher.
    private var branchCache: [String: String] = [:]

    // ponytail: only the active session's meta (ports + dirty) is refreshed per
    // change; non-active sessions keep their last cached value until they become
    // active. Upgrade path: a timer that cycles through all sessions.
    private var metaCache: [ObjectIdentifier: (ports: [Int], dirty: Int)] = [:]

    // Prompt-return attention: per-session (shell pid, currently-busy). When a
    // BACKGROUND session's foreground pid returns to its shell (command finished),
    // ring it. ponytail: 1.5s poll; first sighting baselines the shell pid (a fresh
    // session sits at its prompt). Replaces ghostty's bell/notif action, which this
    // libghostty build doesn't emit.
    private var sessionBusy: [ObjectIdentifier: (shell: pid_t, busy: Bool)] = [:]
    private var attnTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        Fonts.register()                             // bundle Geist/Martian Mono before building UI
        let ghostty = GhosttyApp.shared             // inits libghostty (init/config/app) — native config sync
        theme = ghostty.theme                        // colors from the real ghostty config

        // Workspace starts with home project at ~; config projects appended below.
        workspace = Workspace(theme: theme)
        loadProjects(ghostty.settings, into: workspace)

        // Wire HaloWindowController with the five session-management closures.
        // Each op calls showActive()/handleChange() → workspace.onChange → refresh(),
        // so no explicit refresh() call is needed here — the onChange callback below handles it.
        controller = HaloWindowController(
            theme: theme, content: workspace.container,
            onSelectSession: { [weak self] p, s in
                self?.workspace.selectSession(p, s)
            },
            onCloseSession: { [weak self] p, s in
                self?.workspace.closeSession(p, s)
            },
            onNewSession: { [weak self] p in
                self?.workspace.newSession(p)
            },
            onToggleExpand: { [weak self] p in
                self?.workspace.toggleExpand(p)
            },
            onNewProject: { [weak self] in
                self?.workspace.newProject()
            },
            onRenameProject: { [weak self] p, name in
                self?.workspace.renameProject(p, name)
            },
            onSetProjectColor: { [weak self] p, color in
                self?.workspace.setProjectColor(p, color)
            },
            onRemoveProject: { [weak self] p in
                self?.workspace.removeProject(p)
            },
            onNewWorktree: { [weak self] p, branch in
                self?.workspace.newWorktreeSession(p, branch: branch)
            })

        workspace.onChange = { [weak self] in self?.refresh() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        server = ControlServer(workspace: workspace)
        server.start()

        installKeybinds()
        refresh()
        // Poll background sessions for command-finished (prompt-return) → attention ring.
        attnTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAttention() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Ring a background session when its foreground process returns to the shell
    /// (a command/agent turn finished). Cleared when the session is focused.
    private func pollAttention() {
        let activeID = ObjectIdentifier(workspace.activeTree)
        let sessions = workspace.projs.flatMap(\.sessions)
        let live = Set(sessions.map(ObjectIdentifier.init))
        sessionBusy = sessionBusy.filter { live.contains($0.key) }   // evict closed sessions
        for tree in sessions {
            let oid = ObjectIdentifier(tree)
            let pid = tree.focusedPID
            // Baseline (or re-baseline until a real shell pid is known): a fresh
            // session sits at its prompt, so the first pid we see is the shell.
            guard let prev = sessionBusy[oid], prev.shell != 0 else {
                sessionBusy[oid] = (shell: pid ?? 0, busy: false)
                continue
            }
            let isBusy = pid != nil && pid != prev.shell
            if prev.busy && !isBusy && oid != activeID {   // busy → idle on a background session
                workspace.markAttention(tree)
            }
            sessionBusy[oid] = (shell: prev.shell, busy: isBusy)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Rebuild the sidebar from the live snapshot, filling branch + meta from caches.
    /// Pure render — must NOT call refresh() (avoid a loop).
    private func renderSidebar() {
        // Evict meta for sessions that no longer exist, so a new PaneTree reusing
        // a freed heap address can't inherit a stale chip. (Workspace evicts its
        // own identity dicts; metaCache lives here, so prune it here.)
        let live = Set(workspace.projs.flatMap(\.sessions).map(ObjectIdentifier.init))
        metaCache = metaCache.filter { live.contains($0.key) }

        var projs = workspace.snapshot()
        for i in projs.indices {
            let path = workspace.projs[i].path
            let cached = branchCache[path]
            projs[i].branch = (cached == nil || cached!.isEmpty) ? nil : cached
            // Inject per-session ports + dirty from metaCache (keyed by PaneTree identity).
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
    private func refresh() {
        let cwd = workspace.activeTree.focusedCwd ?? FileManager.default.currentDirectoryPath
        // Ghostty-style titlebar: show the live program title when set, else the cwd.
        let liveTitle = workspace.activeTree.focusedTitle
        controller.setDir(liveTitle.isEmpty ? abbreviateHome(cwd) : liveTitle)
        // Rebuild sidebar with cached branch labels.
        renderSidebar()
        // Git footer: off-main to avoid blocking the UI.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let g = Git.status(cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.controller.setStatus("normal" + (g.map { " · \($0)" } ?? ""))
                }
            }
        }
        // Fill branch cache for any project paths not yet checked, then re-render.
        let unchecked = workspace.projs.map(\.path).filter { branchCache[$0] == nil }
        if !unchecked.isEmpty {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var fresh: [String: String] = [:]
                for path in unchecked {
                    fresh[path] = Git.branch(path) ?? ""
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.branchCache.merge(fresh) { old, _ in old }
                        self.renderSidebar()
                    }
                }
            }
        }

        // Compute ports + dirty for the active session off-main, store in metaCache, re-render.
        // ponytail: only the active session refreshes per change; others keep last value.
        // Upgrade path: a timer that cycles through all sessions.
        let activeTree = workspace.activeTree
        let activeTreeID = ObjectIdentifier(activeTree)
        // focusedCwd is nil when the focused leaf is a browser (no terminal) —
        // don't scan an unrelated dir for git/ports; show empty meta instead.
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

    // ponytail: hard-coded keybinds. make them config-driven when asked.
    private func installKeybinds() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.modifierFlags.contains(.command) else { return e }
            let shift = e.modifierFlags.contains(.shift)
            switch e.charactersIgnoringModifiers {
            // Split panes (unchanged)
            case "d":  self.workspace.activeTree.splitFocused(shift ? .horizontal : .vertical, cwd: self.workspace.activeTree.focusedCwd); return nil
            // ⌘W: close focused pane; ⌘⇧W: close active session
            case "w":
                if shift {
                    self.workspace.closeSession(self.workspace.activeP, self.workspace.activeS)
                } else {
                    self.workspace.activeTree.closeFocused()
                }
                return nil
            // ⌘B: toggle sidebar
            case "b":  self.controller.toggleSidebar(); return nil
            // ⌘]: focus next pane within the active session
            case "]":  self.workspace.activeTree.focusNext(); return nil
            // ⌘T: new session in the active project (cwd = ~)
            case "t":  self.workspace.newSession(self.workspace.activeP); return nil
            // ⌘}/⌘{: cycle sessions within the active project
            case "}":  self.workspace.nextSession(); return nil
            case "{":  self.workspace.prevSession(); return nil
            // ⌘1–9: select session n in the active project
            case "1","2","3","4","5","6","7","8","9":
                if let n = Int(e.charactersIgnoringModifiers ?? "") {
                    self.workspace.selectSessionInActiveProject(n)
                }
                return nil
            // ⌘⇧Return: open browser at the focused session's first detected port, else about:blank
            case "\r" where shift:
                let tree = self.workspace.activeTree
                let treeID = ObjectIdentifier(tree)
                let url: URL
                if let port = self.metaCache[treeID]?.ports.first {
                    url = URL(string: "http://localhost:\(port)")!
                } else {
                    url = URL(string: "about:blank")!
                }
                tree.openBrowser(url: url)
                return nil
            default:   return e
            }
        }
    }
}

/// Append config projects from `halo-projects = ~/a, ~/b` into the workspace.
/// The home project (index 0) is already created by Workspace.init; config
/// projects are appended as collapsed + empty (lazy).
@MainActor
func loadProjects(_ settings: [String: String], into workspace: Workspace) {
    let raw = settings["halo-projects"]?
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    let home = NSHomeDirectory()
    for raw in raw {
        let path = (raw as NSString).expandingTildeInPath
        guard path != home else { continue }   // don't duplicate the home project
        let name = (path as NSString).lastPathComponent
        workspace.appendProject(name: name, path: path)
    }
}


func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
