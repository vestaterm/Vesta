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

    // Prompt-return attention: per-session (shell pid, # of 1.5s ticks the
    // foreground command has been running). When a BACKGROUND session's foreground
    // returns to its shell after running long enough, ring it. Replaces ghostty's
    // bell/notif action, which this libghostty build doesn't emit.
    private var sessionBusy: [ObjectIdentifier: (shell: pid_t, busyTicks: Int)] = [:]
    private var attnTimer: Timer?
    // Only ring when a command ran for at least this many ticks (~4.5s), so a quick
    // `ls`/`cd` in a background session doesn't nag — we want real agent-turn finishes.
    private let attnMinTicks = 3

    func applicationDidFinishLaunching(_ note: Notification) {
        Fonts.register()                             // bundle Geist/Martian Mono before building UI
        let ghostty = GhosttyApp.shared             // inits libghostty (init/config/app) — native config sync
        theme = ghostty.theme                        // colors from the real ghostty config

        // Workspace starts with home project at ~; config projects appended below.
        workspace = Workspace(theme: theme)
        loadProjects(ghostty.settings, into: workspace)
        workspace.restorePersisted()   // layer saved names/colors + user projects on top

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
        NSApp.mainMenu = makeMainMenu(target: self)   // bundle-less binary: build the menu bar

        server = ControlServer(workspace: workspace)
        server.onReload = { [weak self] in self?.reloadConfig() }
        server.start()

        installKeybinds()
        refresh()
        // Poll background sessions for command-finished (prompt-return) → attention ring.
        attnTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAttention() }
        }
        NSApp.activate(ignoringOtherApps: true)
        // Window is key now — focus the active pane so the user can type immediately.
        workspace.focusActive()

        // Finder Services provider ("New Halo Session Here"); drain any folders the
        // app was launched to open (open -a Halo <dir> / Open With).
        NSApp.servicesProvider = self
        if !pendingOpenDirs.isEmpty {
            let dirs = pendingOpenDirs; pendingOpenDirs = []
            for d in dirs { workspace.newTab(cwd: d) }
        }

        Updater.check(silent: true)   // notify if a newer GitHub release exists
    }

    @objc func checkForUpdates() { Updater.check(silent: false) }

    /// Full reset: delete Halo's config AND the settings persisted outside it
    /// (UserDefaults — sidebar width, window frame, quit-confirm), then reload so
    /// everything returns to defaults / the ghostty base.
    @objc func resetConfig() {
        try? FileManager.default.removeItem(atPath: haloConfigPath())
        let d = UserDefaults.standard
        for k in ["HaloSidebarWidth", "HaloSkipQuitConfirm", "NSWindow Frame HaloMainWindow"] {
            d.removeObject(forKey: k)
        }
        reloadConfig()
        controller.setSidebarWidth(CGFloat(HaloConfig.shared.sidebarWidth))   // live default
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
                sessionBusy[oid] = (shell: pid ?? 0, busyTicks: 0)
                continue
            }
            let isBusy = pid != nil && pid != prev.shell
            if isBusy {
                sessionBusy[oid] = (shell: prev.shell, busyTicks: prev.busyTicks + 1)
            } else {
                // busy → idle: ring only if the command ran long enough and it's not the active session.
                if prev.busyTicks >= attnMinTicks && oid != activeID {
                    workspace.markAttention(tree)
                }
                sessionBusy[oid] = (shell: prev.shell, busyTicks: 0)
            }
        }
    }

    // Closing the window does NOT quit Halo — the app keeps running (menu bar
    // stays live); reopen via the Dock or ⌘N-style reactivation.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// Dock-click / reactivation with no visible window → bring the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Confirm before quitting (⌘Q) — running sessions would be killed — unless
    /// the user ticked "Don't ask again".
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UserDefaults.standard.bool(forKey: "HaloSkipQuitConfirm") { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Quit Halo?"
        a.informativeText = "This closes all sessions and their running programs."
        a.alertStyle = .warning
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        a.addButton(withTitle: "Quit Halo")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        if a.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "HaloSkipQuitConfirm")
        }
        return .terminateNow
    }

    // MARK: - Menu actions

    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Halo",
            .applicationVersion: "0.1.0",
            .credits: NSAttributedString(
                string: "A native macOS terminal for running AI coding agents in parallel, built on libghostty.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }

    private var settingsWC: SettingsWindowController?

    /// Re-read the config and re-apply colors/theme/terminal settings live — no
    /// relaunch. Pushes a fresh ghostty config to every surface and re-themes chrome.
    @objc func reloadConfig() {
        let t = GhosttyApp.shared.reloadConfig()
        theme = t
        workspace.applyTheme(t)
        controller.applyTheme(t)
        refresh()
    }

    /// Open the native settings panel (⌘,).
    @objc func openSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController(
                theme: theme,
                onSidebarWidth: { [weak self] w in self?.controller.setSidebarWidth(w) },
                onImport: { [weak self] in self?.importGhosttyConfig() },
                onOpenConfig: { [weak self] in self?.openConfigFile() },
                onReload: { [weak self] in self?.reloadConfig() },
                onReset: { [weak self] in self?.resetConfig() })
        }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the active config file in the user's editor: Halo's own if imported,
    /// else the live ghostty config.
    @objc func openConfigFile() {
        let fm = FileManager.default
        let halo = haloConfigPath()
        if fm.fileExists(atPath: halo) {
            NSWorkspace.shared.open(URL(fileURLWithPath: halo)); return
        }
        if let ghostty = ghosttyConfigPath() {
            NSWorkspace.shared.open(URL(fileURLWithPath: ghostty)); return
        }
        // Neither exists — create a starter Halo config and open it.
        try? fm.createDirectory(atPath: (halo as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        let starter = "# Halo config — ghostty keys + halo-* keys.\n"
            + "# e.g. theme = ..., halo-accent = #7dcfb6, halo-sidebar-width = 240\n"
        try? starter.write(toFile: halo, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(URL(fileURLWithPath: halo))
    }

    /// Copy the live ghostty config into Halo's own config so it can be customized
    /// independently. After this, Halo loads its own config (ghostty's stays put).
    @objc func importGhosttyConfig() {
        let fm = FileManager.default
        guard let src = ghosttyConfigPath(), let text = try? String(contentsOfFile: src, encoding: .utf8) else {
            let a = NSAlert()
            a.messageText = "No ghostty config found"
            a.informativeText = "Couldn't find ~/.config/ghostty/config to import from."
            a.runModal(); return
        }
        let dst = haloConfigPath()
        if fm.fileExists(atPath: dst) {
            let a = NSAlert()
            a.messageText = "Replace Halo config?"
            a.informativeText = "This overwrites \(dst) with your ghostty config."
            a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Import only the SETTINGS: parse the key=value pairs and rewrite them under
        // a Halo header, dropping ghostty's template comments/boilerplate. So the
        // file reads as Halo's own, not a ghostty config.
        let pairs = parseGhosttyConfig(text)
        let header = "# Halo config — your own copy. Any ghostty key works, plus halo-* keys.\n"
            + "# Imported from your ghostty settings; edit freely (ghostty's config is untouched).\n\n"
        let body = pairs.map { "\($0.0) = \($0.1)" }.joined(separator: "\n") + "\n"
        do {
            try (header + body).write(toFile: dst, atomically: true, encoding: .utf8)
            let a = NSAlert()
            a.messageText = "Imported \(pairs.count) settings"
            a.informativeText = "Saved to your Halo config. Apply now?"
            a.addButton(withTitle: "Reload"); a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { reloadConfig() }
        } catch {
            let a = NSAlert(); a.messageText = "Import failed"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    @objc func showHelp() {
        let a = NSAlert()
        a.messageText = "Halo Help"
        a.informativeText = """
        Keys
          ⌘D / ⌘⇧D   split vertical / horizontal
          ⌘W / ⌘⇧W   close pane / session
          ⌘T          new session        ⌘B  toggle sidebar
          ⌘]          focus next pane     ⌘{ / ⌘}  prev / next session
          ⌘1–9        select session      ⌘⇧↵  open browser pane

        Sidebar
          Right-click a project: rename, recolor, remove, new worktree session.

        CLI
          Run `halo help` in any terminal for the agent-control API
          (split, send-keys, capture, worktree, browser, …).

        Settings live in your ghostty config — Halo ▸ Settings… (⌘,).
        """
        a.runModal()
    }

    @objc func toggleSidebarMenu() { controller.toggleSidebar() }

    // MARK: - "Default terminal" integration (open folders / Finder Services)

    private var pendingOpenDirs: [String] = []

    /// Finder "Open With Halo", `open -a Halo <dir>`, dropping a folder on the icon.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openPaths(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    /// Finder right-click ▸ Services ▸ "New Halo Session Here" (registered via Info.plist).
    @objc func newSessionHere(_ pboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        openPaths(urls.filter { $0.isFileURL }.map { $0.path })
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open a terminal session at each path (a file → its parent dir). Queues if the
    /// workspace isn't built yet (app launched by the open request).
    private func openPaths(_ paths: [String]) {
        let dirs = paths.map { p -> String in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            return isDir.boolValue ? p : (p as NSString).deletingLastPathComponent
        }
        guard workspace != nil else { pendingOpenDirs += dirs; return }
        for d in dirs { workspace.newTab(cwd: d) }
    }

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
