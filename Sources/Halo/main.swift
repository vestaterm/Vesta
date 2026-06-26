import AppKit
import HaloMux

let argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "selfcheck" {
    // Pure-logic checks only. PaneTree/Chrome spawn real ghostty surfaces,
    // which need a live app + run loop — exercised by actually launching the app.
    // workspaceSelfCheck tests the Proj/SidebarProject data model without ghostty.
    _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck(); portsSelfCheck(); workspaceSelfCheck(); worktreeSelfCheck(); browserSelfCheck(); prefixKeytableSelfCheck(); sessionNameSelfCheck(); muxProtocolSelfCheck(); muxPathsSelfCheck(); luaSandboxSelfCheck()
    // chromeSelfCheck creates AppKit objects (HaloWindowController → HaloConfig.shared →
    // GhosttyApp.shared). GhosttyApp.shared calls NSApp.isActive; NSApp is nil until
    // NSApplication.shared is first touched. Touch it here so GhosttyApp.shared doesn't crash.
    _ = NSApplication.shared
    MainActor.assumeIsolated { chromeSelfCheck(); prefixSpecSelfCheck() }
    print("all self-checks ok"); exit(0)
}
if let verb = argv.first, verb == "help" || verb == "--help" || verb == "-h" {
    printUsage(); exit(0)
}
if let verb = argv.first, controlVerbs.contains(verb) {
    exit(runControlCLI(argv))
}
// A non-empty first arg that isn't a known verb → show help (don't silently launch the GUI).
if let verb = argv.first {
    FileHandle.standardError.write(Data("halo: unknown command '\(verb)'\n\n".utf8))
    printUsage(); exit(2)
}
// Bare `halo` (no args): open a new window if an instance is already running, else
// fall through to launch the GUI.
if controlSocketAlive() {
    exit(runControlCLI(["new-window"]))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Shared sidebar: ONE app-owned session pool (projects + sessions) shared by every
    // window, so closing a window drops the view but never the sessions. Each window has
    // its OWN Workspace VIEW over this store (own active selection + display body), so
    // different windows can show different sessions, both live.
    let store = SessionStore()
    var windows: [WindowContext] = []
    weak var lastKey: WindowContext?
    var active: WindowContext? { lastKey ?? windows.first }
    var server: ControlServer!
    var theme = Theme()
    // Prefix mode (tmux-style). `prefix` is nil when halo-prefix is empty/disabled.
    private let prefixState = PrefixState()
    private var prefix: (mods: NSEvent.ModifierFlags, key: String)?
    private var prefixTable: [String: PrefixAction] = defaultPrefixKeytable
    private var attnTimer: Timer?
    // Window-state persistence (windows.json). `restoring` suppresses saves while
    // we rebuild windows at launch; `savePending` coalesces rapid changes.
    private var restoring = false
    private var savePending = false
    private var luaTimers: [Timer] = []   // halo.timer schedules; cleared on reload
    // halo.panel state is window-agnostic: specs are the source of truth; overlays are
    // rendered into windows per scope (active-only follows focus; all → every window).
    private struct PanelSpec { var lines: [PanelLine]; var opts: PanelOpts }
    private var luaPanelSpecs: [Int: PanelSpec] = [:]                  // id → spec (cleared on reload)
    private var panelViews: [Int: [ObjectIdentifier: PanelOverlay]] = [:]   // id → window → overlay
    private var luaPanelCounter = 0

    /// Create, show, and track a new window. ⌘N / first launch.
    @discardableResult
    func newWindow() -> WindowContext {
        let prev = active?.controller.window ?? windows.last?.controller.window
        // Wire the cross-window broadcast once: any pool change refreshes every window's
        // sidebar, reconciles which window shows each session live vs frozen, and persists.
        store.broadcast = { [weak self] in guard let self else { return }
                            self.windows.forEach { $0.refresh() }; self.reconcileDisplay(); self.scheduleSave() }
        let ctx = WindowContext(theme: theme, store: store,
            onBecomeKey: { [weak self] c in guard let self else { return }
                                            self.lastKey = c
                                            self.reconcileDisplay() },   // live follows focus
            onClose:     { [weak self] c in
                                            guard let self else { return }
                                            // Sessions live in the shared store, so closing a window
                                            // never loses them — just drop the view and persist.
                                            self.windows.removeAll { $0 === c }
                                            if self.lastKey === c { self.lastKey = self.windows.last }
                                            self.scheduleSave() })
        ctx.onPersist = { [weak self] in self?.scheduleSave() }
        windows.append(ctx)
        lastKey = ctx
        // Only the first window restores/saves its frame; later ones cascade off it.
        if let prev, let win = ctx.controller.window {
            win.setFrameAutosaveName("")
            win.setFrameOrigin(NSPoint(x: prev.frame.minX + 26, y: prev.frame.minY - 26))
        }
        ctx.start()
        renderPanels()   // a new window immediately shows "all"-scoped panels
        return ctx
    }

    // ⌘N opens a real second window. Both share the one session pool/sidebar; each
    // views its own active session (different sessions show live in each window).
    @objc func newWindowMenu() { newWindow(); NSApp.activate(ignoringOtherApps: true) }

    /// Decide, across all windows, which shows each session live vs. a frozen snapshot.
    /// A session's terminal is one NSView → one window. The KEY window always shows its
    /// session live; a window whose session is live in another window shows frozen; a
    /// window that's the sole viewer of an unowned session takes it live. So when two
    /// windows view the same session, live follows focus.
    func reconcileDisplay() {
        guard let key = active else { return }
        key.workspace.reconcile(preferLive: true)
        for w in windows where w !== key { w.workspace.reconcile(preferLive: false) }
        renderPanels()   // active-scoped panels follow focus; new windows pick up "all" panels
        PaneOutputTap.shared.reconcile(allLivePaneIDs())   // pane-output taps every live pane
    }

    /// Every live pane's mux id, across all projects/sessions (pane-output subscribes to all).
    func allLivePaneIDs() -> Set<String> {
        Set((active?.workspace.projs ?? []).flatMap { $0.sessions.flatMap { $0.paneIDs } })
    }

    /// Mount a picker overlay in the key window (or free `refs` and bail if one is already up).
    private func presentPicker(_ make: (NSView, @escaping () -> Void) -> PickerOverlay?, freeing refs: [Int32]) {
        guard let host = active?.controller.window?.contentView,
              !host.subviews.contains(where: { $0 is PickerOverlay }) else { refs.forEach { luaUnref($0) }; return }
        let dismiss: () -> Void = { [weak host] in host?.subviews.compactMap { $0 as? PickerOverlay }.forEach { $0.removeFromSuperview() } }
        guard let overlay = make(host, dismiss) else { return }
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
    }

    /// halo.pick: single-select (rich rows); call the ref with the chosen label.
    func showPick(_ items: [PickItem], _ ref: Int32) {
        presentPicker({ _, dismiss in
            PickerOverlay(theme: theme, richItems: items, multiSelect: false,
                onPick: { idx in dismiss(); if let i = idx.first { luaCall(ref: ref, stringArg: items[i].label) }; luaUnref(ref) },
                onCancel: { dismiss(); luaUnref(ref) })
        }, freeing: [ref])
    }

    /// halo.pickmulti: multi-select; call the ref with a table of chosen labels.
    func showPickMulti(_ items: [PickItem], _ ref: Int32) {
        presentPicker({ _, dismiss in
            PickerOverlay(theme: theme, richItems: items, multiSelect: true,
                onPick: { idx in dismiss(); luaCallStringList(ref: ref, idx.map { items[$0].label }); luaUnref(ref) },
                onCancel: { dismiss(); luaUnref(ref) })
        }, freeing: [ref])
    }

    /// halo.menu: single-select where each item carries its own action ref (-1 = none).
    func showMenu(_ items: [PickItem], _ refs: [Int32]) {
        let free = { refs.forEach { if $0 >= 0 { luaUnref($0) } } }
        presentPicker({ _, dismiss in
            PickerOverlay(theme: theme, richItems: items, multiSelect: false,
                onPick: { idx in dismiss(); if let i = idx.first, refs.indices.contains(i), refs[i] >= 0 { luaCall(ref: refs[i]) }; free() },
                onCancel: { dismiss(); free() })
        }, freeing: refs.filter { $0 >= 0 })
    }

    /// halo.panel: create (id 0) or update (existing id) a plugin panel. `window = "all"`
    /// renders it in every window; otherwise it lives in the active window and follows focus.
    /// Returns the panel id. Corner/scope are fixed at creation.
    func luaPanelSet(_ lines: [PanelLine], _ opts: PanelOpts) -> Int {
        let id: Int
        if opts.id > 0 { id = opts.id } else { luaPanelCounter += 1; id = luaPanelCounter }
        // Free the click refs of the spec we're replacing (the new lines carry fresh refs).
        let oldRefs = luaPanelSpecs[id]?.lines.compactMap(\.clickRef) ?? []
        var opts = opts; opts.id = id
        luaPanelSpecs[id] = PanelSpec(lines: lines, opts: opts)
        renderPanels()
        oldRefs.forEach { luaUnref($0) }   // after re-render, so live overlays no longer hold them
        return id
    }

    /// Reconcile panel overlays against the specs: each spec renders into its target windows
    /// (all, or just the active one), updating in place and removing overlays from windows it
    /// no longer targets (e.g. an active-scoped panel when focus moves). Also prunes overlays
    /// for closed windows. Called on panel set/update and whenever the active window changes.
    func renderPanels() {
        let live = Set(windows.map(ObjectIdentifier.init))
        for id in Array(panelViews.keys) {
            for (wid, ov) in panelViews[id] ?? [:] where !live.contains(wid) {
                ov.removeFromSuperview(); panelViews[id]?[wid] = nil
            }
        }
        for (id, spec) in luaPanelSpecs {
            let targets = spec.opts.allWindows ? windows : [active].compactMap { $0 }
            let targetIDs = Set(targets.map(ObjectIdentifier.init))
            for (wid, ov) in panelViews[id] ?? [:] where !targetIDs.contains(wid) {
                ov.removeFromSuperview(); panelViews[id]?[wid] = nil    // moved away (active panel)
            }
            for win in targets {
                let wid = ObjectIdentifier(win)
                guard let host = win.controller.window?.contentView else { continue }
                if let ov = panelViews[id]?[wid] {
                    _ = ov.update(title: spec.opts.title, lines: spec.lines)   // refs managed at spec level
                } else {
                    let ov = PanelOverlay(theme: theme, lines: spec.lines, opts: spec.opts)
                    host.addSubview(ov); ov.pin(into: host)
                    panelViews[id, default: [:]][wid] = ov
                }
            }
        }
    }

    /// halo.prompt: free-text input overlay; call the Lua ref with the typed text (or free
    /// the ref on cancel).
    func showPrompt(_ message: String, _ initial: String, _ ref: Int32) {
        guard let host = active?.controller.window?.contentView,
              !host.subviews.contains(where: { $0 is PickerOverlay }) else { luaUnref(ref); return }
        let dismiss = { [weak host] in host?.subviews.compactMap { $0 as? PickerOverlay }.forEach { $0.removeFromSuperview() } }
        let overlay = PickerOverlay(theme: theme, prompt: message, initial: initial,
            onSubmit: { text in dismiss(); luaCall(ref: ref, stringArg: text); luaUnref(ref) },
            onCancel: { dismiss(); luaUnref(ref) })
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
    }

    /// halo.confirm: yes/no overlay; call the Lua ref with a boolean (Esc/click-scrim → false).
    func showConfirm(_ message: String, _ ref: Int32) {
        guard let host = active?.controller.window?.contentView,
              !host.subviews.contains(where: { $0 is PickerOverlay }) else { luaUnref(ref); return }
        let dismiss = { [weak host] in host?.subviews.compactMap { $0 as? PickerOverlay }.forEach { $0.removeFromSuperview() } }
        let overlay = PickerOverlay(theme: theme, confirm: message,
            onChoose: { item in dismiss(); luaCallBool(ref: ref, item == "Yes"); luaUnref(ref) },
            onCancel: { dismiss(); luaCallBool(ref: ref, false); luaUnref(ref) })
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
    }

    /// Show `msg` as a transient toast banner in the key window (what `halo.notify` calls).
    /// In-app so it's visible even under `swift run` (macOS notifications need a signed
    /// bundle). Falls back to stderr when there's no window. Uses the theme accent — no
    /// hardcoded colors.
    func showToast(_ msg: String) {
        guard let host = active?.controller.window?.contentView else {
            FileHandle.standardError.write(Data("[halo.lua] \(msg)\n".utf8)); return
        }
        let label = NSTextField(labelWithString: msg)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.96, alpha: 1)
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.97).cgColor
        banner.layer?.cornerRadius = 9
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = theme.accent.withAlphaComponent(0.55).cgColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)
        host.addSubview(banner)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: banner.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -11),
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 15),
            label.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -15),
            banner.topAnchor.constraint(equalTo: host.topAnchor, constant: 46),
            banner.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.7),
        ])
        banner.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; banner.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.32; banner.animator().alphaValue = 0 },
                completionHandler: { banner.removeFromSuperview() })
        }
    }

    /// Full structured state for `halo state`: the shared project/session pool plus every
    /// window's view (active selection + whether it hosts the live terminal). Lets an agent
    /// see the whole tree the sidebar shows, not just the active window's panes.
    func fullState() -> [String: Any] {
        let projects = store.projs.enumerated().map { (pi, p) -> [String: Any] in
            let sessions = p.sessions.enumerated().map { (si, t) -> [String: Any] in
                var d: [String: Any] = ["index": si, "panes": t.paneIDs.count, "paneIDs": t.paneIDs]
                if let n = t.name { d["name"] = n }
                if let c = t.focusedCwd { d["cwd"] = c }
                return d
            }
            var d: [String: Any] = ["index": pi, "name": p.name, "path": p.path,
                                    "expanded": p.expanded, "sessions": sessions]
            if let c = p.color { d["color"] = hexString(c) }
            return d
        }
        let wins = windows.enumerated().map { (wi, w) -> [String: Any] in
            ["index": wi, "key": w === active, "activeProject": w.workspace.activeP,
             "activeSession": w.workspace.activeS, "hostsLive": w.workspace.hostsLive]
        }
        return ["ok": true, "projects": projects, "windows": wins]
    }


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
        let ctx = newWindow()                  // builds the shared workspace (sharedWS)
        // One shared workspace → restore from the first saved entry. (Legacy files may
        // hold several windows; we collapse to the single shared sidebar.)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Self.windowsFile)),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = saved.first {
            ctx.workspace.hydrate(from: first)
            ctx.refresh()
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

    /// Persist the shared session pool (one entry). Serialized via any live window's
    /// Workspace (they share the store's projs). If no window is open, the last save on
    /// window-close already wrote the file, so skipping here is safe.
    func saveWindows() {
        guard let ws = (active ?? windows.first)?.workspace,
              let data = try? JSONSerialization.data(withJSONObject: [ws.serialize()], options: [.prettyPrinted]) else { return }
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
        luaReloadHook = { [weak self] in self?.reloadConfig() }   // sandbox auto-disable → full reload
        server.onNewWindow = { [weak self] in self?.newWindow(); NSApp.activate(ignoringOtherApps: true) }
        server.stateProvider = { [weak self] in self?.fullState() ?? ["ok": false] }
        server.start()
        // Lua bridge handlers (halo.notify / active / send), then run init.lua.
        luaNotify = { [weak self] msg in self?.showToast(msg) }
        luaActiveInfo = { [weak self] in
            guard let t = self?.active?.workspace.activeTree else { return nil }
            return (t.focusedCwd ?? "", t.focusedTitle, t.focusedPaneID ?? "")
        }
        luaSendText = { [weak self] s in self?.active?.workspace.activeTree.focused?.sendKeys(s) }
        luaControl = { [weak self] cmd, args in self?.server.invoke(cmd, args) ?? [:] }
        luaScheduleTimer = { [weak self] secs, ref in
            let t = Timer.scheduledTimer(withTimeInterval: max(0.05, secs), repeats: true) { _ in
                MainActor.assumeIsolated { luaCall(ref: ref) }
            }
            self?.luaTimers.append(t)
        }
        luaClearTimers = { [weak self] in self?.luaTimers.forEach { $0.invalidate() }; self?.luaTimers.removeAll() }
        luaShowPick = { [weak self] items, ref in self?.showPick(items, ref) }
        luaShowPickMulti = { [weak self] items, ref in self?.showPickMulti(items, ref) }
        luaShowMenu = { [weak self] items, refs in self?.showMenu(items, refs) }
        luaSetStatus = { [weak self] s in self?.windows.forEach { $0.controller.setLuaStatus(s) } }
        luaPanel = { [weak self] lines, opts in self?.luaPanelSet(lines, opts) ?? 0 }
        luaClosePanel = { [weak self] id in
            guard let self else { return }
            self.luaPanelSpecs[id]?.lines.compactMap(\.clickRef).forEach { luaUnref($0) }
            self.luaPanelSpecs[id] = nil
            (self.panelViews[id] ?? [:]).values.forEach { $0.removeFromSuperview() }
            self.panelViews[id] = nil }
        luaClearPanels = { [weak self] in
            guard let self else { return }
            self.luaPanelSpecs.values.flatMap { $0.lines }.compactMap(\.clickRef).forEach { luaUnref($0) }
            self.luaPanelSpecs.removeAll()
            self.panelViews.values.flatMap { $0.values }.forEach { $0.removeFromSuperview() }
            self.panelViews.removeAll() }
        luaShowPrompt = { [weak self] msg, initial, ref in self?.showPrompt(msg, initial, ref) }
        luaShowConfirm = { [weak self] msg, ref in self?.showConfirm(msg, ref) }
        LuaRuntime.shared.start()   // run init.lua + plugins (builds plugin UI on the window)
        // config-in-Lua: fold halo.set() overrides in (Lua wins) + re-theme. The plugin UI built
        // above used the pre-Lua theme, so rebuild it against the applied theme — otherwise
        // load-time panels/buttons keep the old accent until a manual reload.
        if !luaConfigOverrides.isEmpty {
            theme = GhosttyApp.shared.reloadConfig()
            windows.forEach { $0.applyTheme(theme) }
            LuaRuntime.shared.start()   // rebuild plugin UI with the applied theme
        }

        installKeybinds()
        let settings = GhosttyApp.shared.settings
        prefix = parsePrefixSpec(settings["halo-prefix"] ?? "ctrl+b")
        let binds = (settings["halo-prefix-bind"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        prefixTable = parsePrefixKeytable(binds)
        prefixState.onArmedChange = { [weak self] armed in
            self?.active?.controller.setPrefixArmed(armed)
        }
        // Poll background sessions (all windows) for command-finished → attention ring.
        attnTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.windows.forEach { $0.pollAttention() }
                // Catches handler-set changes (reload) and new/closed panes; no-op if unchanged.
                PaneOutputTap.shared.reconcile(self.allLivePaneIDs())
            }
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
        a.informativeText = "Your sessions keep running in the background and reattach next launch."
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
        LuaRuntime.shared.start()                  // re-run init.lua first → repopulate halo.set overrides
        let t = GhosttyApp.shared.reloadConfig()   // re-read file + merge Lua overrides (Lua wins)
        theme = t
        windows.forEach { $0.applyTheme(t) }
        // Re-parse the prefix from the merged settings (Lua may have set halo-prefix).
        let s = GhosttyApp.shared.settings
        prefix = parsePrefixSpec(s["halo-prefix"] ?? "ctrl+b")
        let binds = (s["halo-prefix-bind"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        prefixTable = parsePrefixKeytable(binds)
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

    /// Explicit kill of the focused session's shell under halod (menu / no key
    /// equivalent — Cmd-W only detaches).
    @objc func killSessionMenu() { active?.workspace.activeTree.killFocusedSession() }

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
            guard let self else { return e }
            // ── Prefix mode (runs before the ⌘ keybinds) ──────────────────────
            if let prefix = self.prefix {
                let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
                let isEscape = (e.keyCode == 53)   // Escape
                if self.prefixState.armed {
                    // Resolve the NEXT key. Arrows → tokens; else the typed char.
                    let key = Self.prefixKeyToken(e)
                    if let action = self.prefixState.handle(key: key, isEscape: isEscape, table: self.prefixTable) {
                        self.dispatchPrefix(action)
                    }
                    return nil   // swallow the key whether it fired, cancelled, or was Escape
                }
                // Not yet armed: is THIS the prefix chord?
                if mods == prefix.mods, (e.charactersIgnoringModifiers ?? "").lowercased() == prefix.key {
                    self.prefixState.arm()
                    return nil
                }
            }
            // ── Lua keybinds (halo.bind) — before built-in ⌘ binds, so a script can claim
            // any chord (e.g. ctrl+g, cmd+shift+p) ───────────────────────────────────────
            if !luaBinds.isEmpty {
                let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
                let key = (e.charactersIgnoringModifiers ?? "").lowercased()
                for b in luaBinds where parsePrefixSpec(b.spec).map({ $0.mods == mods && $0.key == key }) == true {
                    luaCall(ref: b.ref); return nil
                }
            }
            guard e.modifierFlags.contains(.command) else { return e }
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
            // With halo-persist on (M3), closing a pane/session only tears down the ghostty
            // surface → the halo-attach relay EOFs and detaches; the shell keeps running
            // under halod. Explicit kill is prefix-x / `halo kill`, never Cmd-W.
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

    /// The keytable token for a pressed key: arrow keys → direction words, else
    /// the lowercased character (so % " , map through verbatim).
    private static func prefixKeyToken(_ e: NSEvent) -> String {
        switch e.keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return (e.charactersIgnoringModifiers ?? "").lowercased()
        }
    }

    /// Run a resolved prefix action against the active window's workspace, using
    /// only methods that already exist. detach/kill/switcher are stubbed (beep)
    /// until Milestones 2–3 land their real behavior.
    private func dispatchPrefix(_ action: PrefixAction) {
        guard let ctx = active else { return }
        let ws = ctx.workspace
        switch action {
        case .splitVertical:   _ = ws.activeTree.splitFocused(.vertical, cwd: ws.activeTree.focusedCwd)
        case .splitHorizontal: _ = ws.activeTree.splitFocused(.horizontal, cwd: ws.activeTree.focusedCwd)
        case .focusLeft, .focusUp:    ws.activeTree.focusPrev()
        case .focusRight, .focusDown: ws.activeTree.focusNext()
        case .zoom:        ws.activeTree.zoomFocused()
        case .newSession:  ws.newSession(ws.activeP)
        case .nextSession: ws.nextSession()
        case .prevSession: ws.prevSession()
        case .rename:      promptRenameActiveSession()
        // Detach: close the pane → relay EOFs → shell lives on under halod.
        case .detach: ws.activeTree.closeFocused()
        // Kill: terminate the shell under halod, then close the pane locally.
        case .kill:   ws.activeTree.killFocusedSession()
        }
    }

    /// Prefix-`,` rename: rename the ACTIVE session (Workspace.renameSession, added in M2).
    private func promptRenameActiveSession() {
        guard let ws = active?.workspace else { return }
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "Leave blank to clear the name and use the folder name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            ws.renameSession(ws.activeP, ws.activeS, field.stringValue)
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
