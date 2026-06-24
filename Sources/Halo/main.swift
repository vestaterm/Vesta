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
    // Multi-window: each WindowContext owns a Workspace + chrome + per-window caches.
    // ⌘N opens another. `active` is the key window (last to become key), else the first.
    var windows: [WindowContext] = []
    weak var lastKey: WindowContext?
    var active: WindowContext? { lastKey ?? windows.first }
    var server: ControlServer!
    var theme = Theme()
    private var attnTimer: Timer?
    // Window-state persistence (windows.json). `restoring` suppresses saves while
    // we rebuild windows at launch; `savePending` coalesces rapid changes.
    private var restoring = false
    private var savePending = false

    /// Create, show, and track a new window. ⌘N / first launch.
    @discardableResult
    func newWindow() -> WindowContext {
        let prev = active?.controller.window ?? windows.last?.controller.window
        let ctx = WindowContext(theme: theme,
            onBecomeKey: { [weak self] c in self?.lastKey = c },
            onClose:     { [weak self] c in self?.windows.removeAll { $0 === c }
                                            if self?.lastKey === c { self?.lastKey = self?.windows.last }
                                            self?.scheduleSave() })   // a closed window shouldn't reappear
        ctx.onPersist = { [weak self] in self?.scheduleSave() }
        windows.append(ctx)
        lastKey = ctx
        // Only the first window restores/saves its frame; later ones cascade off it.
        if let prev, let win = ctx.controller.window {
            win.setFrameAutosaveName("")
            win.setFrameOrigin(NSPoint(x: prev.frame.minX + 26, y: prev.frame.minY - 26))
        }
        ctx.start()
        return ctx
    }

    @objc func newWindowMenu() { newWindow(); NSApp.activate(ignoringOtherApps: true) }

    // MARK: - Window-state persistence

    private static var windowsFile: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/halo"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/windows.json"
    }

    /// Rebuild last session's windows from windows.json, else one fresh window.
    private func restoreWindows() {
        restoring = true
        defer { restoring = false }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Self.windowsFile)),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !saved.isEmpty {
            for win in saved {
                let ctx = newWindow()          // builds a default window…
                ctx.workspace.hydrate(from: win)  // …then replaces its state with the saved one
                ctx.refresh()
            }
        } else {
            newWindow()
        }
    }

    /// Persist every window's projects + sessions-by-cwd. Coalesced so rapid
    /// changes (focus/git callbacks) don't write on every tick.
    private func scheduleSave() {
        guard !restoring, !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.savePending = false
            self?.saveWindows()
        }
    }

    func saveWindows() {
        let arr = windows.map { $0.workspace.serialize() }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.windowsFile), options: .atomic)
    }

    func applicationWillTerminate(_ note: Notification) { saveWindows() }

    func applicationDidFinishLaunching(_ note: Notification) {
        Fonts.register()                             // bundle Geist/Martian Mono before building UI
        let ghostty = GhosttyApp.shared             // inits libghostty (init/config/app) — native config sync
        theme = ghostty.theme                        // colors from the real ghostty config

        NSApp.mainMenu = makeMainMenu(target: self)   // bundle-less binary: build the menu bar
        restoreWindows()                              // saved windows (or one fresh window)

        server = ControlServer(workspaceProvider: { [weak self] in self?.active?.workspace })
        server.onReload = { [weak self] in self?.reloadConfig() }
        server.start()

        installKeybinds()
        // Poll background sessions (all windows) for command-finished → attention ring.
        attnTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows.forEach { $0.pollAttention() } }
        }
        NSApp.activate(ignoringOtherApps: true)

        // Finder Services provider ("New Halo Session Here"); drain any folders the
        // app was launched to open (open -a Halo <dir> / Open With).
        NSApp.servicesProvider = self
        if !pendingOpenDirs.isEmpty {
            let dirs = pendingOpenDirs; pendingOpenDirs = []
            for d in dirs { active?.workspace.newTab(cwd: d) }
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
        active?.controller.setSidebarWidth(CGFloat(HaloConfig.shared.sidebarWidth))   // live default
    }

    // Closing the window does NOT quit Halo — the app keeps running (menu bar
    // stays live); reopen via the Dock or ⌘N-style reactivation.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// Dock-click / reactivation with no visible window → bring a window back
    /// (or open a fresh one if they were all closed).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let win = windows.first?.controller.window { win.makeKeyAndOrderFront(nil) }
            else { newWindow() }
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
        windows.forEach { $0.applyTheme(t) }
    }

    /// Open the native settings panel (⌘,).
    @objc func openSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController(
                theme: theme,
                onSidebarWidth: { [weak self] w in self?.active?.controller.setSidebarWidth(w) },
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

    @objc func toggleSidebarMenu() { active?.controller.toggleSidebar() }

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
        guard let ws = active?.workspace else { pendingOpenDirs += dirs; return }
        for d in dirs { ws.newTab(cwd: d) }
    }

    // ponytail: hard-coded keybinds. make them config-driven when asked.
    private func installKeybinds() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.modifierFlags.contains(.command) else { return e }
            let shift = e.modifierFlags.contains(.shift)
            // ⌘N: new window (doesn't need a key window).
            if !shift, e.charactersIgnoringModifiers == "n" { self.newWindow(); return nil }
            // Everything else acts on the key window.
            guard let ctx = self.active else { return e }
            let ws = ctx.workspace
            switch e.charactersIgnoringModifiers {
            // Split panes (unchanged)
            case "d":  ws.activeTree.splitFocused(shift ? .horizontal : .vertical, cwd: ws.activeTree.focusedCwd); return nil
            // ⌘W: pane → session → window (cascade). ⌘⇧W: close session.
            case "w":
                if shift {
                    ws.closeSession(ws.activeP, ws.activeS)
                } else if ws.activeTree.paneCount > 1 {
                    ws.activeTree.closeFocused()                  // 1) close the pane
                } else if ws.totalSessions > 1 {
                    ws.closeSession(ws.activeP, ws.activeS)        // 2) close the session
                } else {
                    ctx.controller.window?.performClose(nil)      // 3) last one → close the window
                }
                return nil
            // ⌘F: in-terminal search (⌃⌘F is full screen — let that fall through)
            case "f" where !e.modifierFlags.contains(.control):
                ws.activeTree.focused?.startSearch(); return nil
            // ⌘B: toggle sidebar
            case "b":  ctx.controller.toggleSidebar(); return nil
            // ⌘]/⌘[: focus next/prev pane within the active session
            case "]":  ws.activeTree.focusNext(); return nil
            case "[":  ws.activeTree.focusPrev(); return nil
            // ⌘T: new session in the active project (cwd = ~)
            case "t":  ws.newSession(ws.activeP); return nil
            // ⌘}/⌘{: cycle sessions within the active project
            case "}":  ws.nextSession(); return nil
            case "{":  ws.prevSession(); return nil
            // ⌘1–9: select session n in the active project
            case "1","2","3","4","5","6","7","8","9":
                if let n = Int(e.charactersIgnoringModifiers ?? "") {
                    ws.selectSessionInActiveProject(n)
                }
                return nil
            // ⌘⇧Return: open browser at the focused session's first detected port, else about:blank
            case "\r" where shift:
                let tree = ws.activeTree
                let url = ctx.detectedPort(tree).map { URL(string: "http://localhost:\($0)")! } ?? URL(string: "about:blank")!
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
