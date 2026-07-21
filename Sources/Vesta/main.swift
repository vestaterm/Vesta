import AppKit
import VestaMux

// A write to a dead control/mux socket must surface as EPIPE, not kill the app.
signal(SIGPIPE, SIG_IGN)

let argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "selfcheck" {
    // Pure-logic checks only. PaneTree/Chrome spawn real ghostty surfaces,
    // which need a live app + run loop — exercised by actually launching the app.
    // workspaceSelfCheck tests the Proj/SidebarProject data model without ghostty.
    _ = ghosttyConfigSelfCheck()
    controlSelfCheck()
    gitSelfCheck()
    portsSelfCheck()
    windowRefreshSelfCheck()
    tailStoreSelfCheck()
    workspaceSelfCheck()
    windowsFormatSelfCheck()
    worktreeSelfCheck()
    browserSelfCheck()
    prefixKeytableSelfCheck()
    sessionNameSelfCheck()
    dormantLayoutSelfCheck()
    tailFocusSelfCheck()
    focusOwnerSelfCheck()
    muxProtocolSelfCheck()
    muxPathsSelfCheck()
    scrollbackSweepSelfCheck()
    upgradeStateSelfCheck()
    shellIntegrationSelfCheck()
    fdLimitSelfCheck()
    luaSandboxSelfCheck()
    // Resource smoke test (works in release — asserts compile out): the bundled fonts must be
    // locatable from THIS binary's bundle. Catches a mispackaged .app before notarize/publish.
    if Fonts.fontsDirectory() == nil {
        FileHandle.standardError.write(Data("selfcheck FAIL: bundled fonts not found\n".utf8))
        exit(1)
    }
    // chromeSelfCheck creates AppKit objects (VestaWindowController → VestaConfig.shared →
    // GhosttyApp.shared). GhosttyApp.shared calls NSApp.isActive; NSApp is nil until
    // NSApplication.shared is first touched. Touch it here so GhosttyApp.shared doesn't crash.
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        chromeSelfCheck()
        prefixSpecSelfCheck()
    }
    print("all self-checks ok")
    exit(0)
}
if let verb = argv.first, verb == "help" || verb == "--help" || verb == "-h" {
    printUsage()
    exit(0)
}
if let verb = argv.first, controlVerbs.contains(verb) {
    exit(runControlCLI(argv))
}
// A non-empty first arg that isn't a known verb → show help (don't silently launch the GUI).
if let verb = argv.first {
    FileHandle.standardError.write(Data("vesta: unknown command '\(verb)'\n\n".utf8))
    printUsage()
    exit(2)
}
// Bare `vesta` (no args): open a new window if an instance is already running, else
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
    // Prefix mode (tmux-style). `prefix` is nil when vesta-prefix is empty/disabled.
    private let prefixState = PrefixState()
    private var prefix: (mods: NSEvent.ModifierFlags, key: String)?
    private var prefixTable: [String: PrefixAction] = defaultPrefixKeytable
    private var attnTimer: Timer?
    private var updateTimer: Timer?
    // Window-state persistence (windows.json). `restoring` suppresses saves while
    // we rebuild windows at launch; `savePending` coalesces rapid changes.
    private var restoring = false
    private var savePending = false
    private var luaTimers: [Timer] = []  // vesta.timer schedules; cleared on reload
    // vesta.panel state is window-agnostic: specs are the source of truth; overlays are
    // rendered into windows per scope (active-only follows focus; all → every window).
    private struct PanelSpec {
        var lines: [PanelLine]
        var opts: PanelOpts
    }
    private var luaPanelSpecs: [Int: PanelSpec] = [:]  // id → spec (cleared on reload)
    private var panelViews: [Int: [ObjectIdentifier: PanelOverlay]] = [:]  // id → window → overlay
    private var luaPanelCounter = 0

    /// Create, show, and track a new window. ⌘N / first launch.
    @discardableResult
    func newWindow(hydrateFrom: [String: Any]? = nil) -> WindowContext {
        let prev = active?.controller.window ?? windows.last?.controller.window
        // Wire the cross-window broadcast once: any pool change refreshes every window's
        // sidebar, reconciles which window shows each session live vs frozen, and persists.
        store.broadcast = { [weak self] in
            guard let self else { return }
            self.windows.forEach { $0.refresh() }
            self.reconcileDisplay()
            self.scheduleSave()
        }
        // NOT folded into broadcast: onFocusChange broadcasts on program-driven title/cwd
        // escapes at unbounded frequency, and renderSidebar's per-session viewport capture
        // runs before the skip-identical gate — only handleChange (discrete user actions)
        // gets the undebounced render.
        store.renderNow = { [weak self] in self?.windows.forEach { $0.renderSidebarNow() } }
        let ctx = WindowContext(
            theme: theme, store: store, hydrateFrom: hydrateFrom,
            onBecomeKey: { [weak self] c in
                guard let self else { return }
                self.lastKey = c
                self.reconcileDisplay()
            },  // live follows focus
            onClose: { [weak self] c in
                guard let self else { return }
                // Sessions live in the shared store, so closing a window
                // never loses them — just drop the view and persist.
                self.windows.removeAll { $0 === c }
                if self.lastKey === c { self.lastKey = self.windows.last }
                self.scheduleSave()
            })
        ctx.onPersist = { [weak self] in self?.scheduleSave() }
        ctx.controller.onBell = { [weak self] in self?.showNotifications() }
        ctx.controller.setUnread(unread)
        ctx.controller.onUpdate = { Updater.shared.badgeClicked() }
        applyUpdatePhase(to: ctx.controller, Updater.shared.phase)   // reflect current state in the new window
        windows.append(ctx)
        lastKey = ctx
        // Only the first window autosaves its frame; later ones cascade off it by default
        // (restoreWindows overrides with the per-entry frame saved in windows.json).
        if let prev, let win = ctx.controller.window {
            win.setFrameAutosaveName("")
            win.setFrameOrigin(NSPoint(x: prev.frame.minX + 26, y: prev.frame.minY - 26))
        }
        ctx.start()
        renderPanels()  // a new window immediately shows "all"-scoped panels
        return ctx
    }

    // ⌘N opens a real second window. Both share the one session pool/sidebar; each
    // views its own active session (different sessions show live in each window).
    @objc func newWindowMenu() {
        newWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Decide, across all windows, which shows each session live vs. a frozen snapshot.
    /// A session's terminal is one NSView → one window. The KEY window always shows its
    /// session live; a window whose session is live in another window shows frozen; a
    /// window that's the sole viewer of an unowned session takes it live. So when two
    /// windows view the same session, live follows focus.
    func reconcileDisplay() {
        guard let key = active else { return }
        key.workspace.reconcile(preferLive: true)
        for w in windows where w !== key { w.workspace.reconcile(preferLive: false) }
        renderPanels()  // active-scoped panels follow focus; new windows pick up "all" panels
        PaneOutputTap.shared.reconcile(allLivePaneIDs())  // pane-output taps every live pane
    }

    /// Every live pane's mux id, across all projects/sessions (pane-output subscribes to all).
    func allLivePaneIDs() -> Set<String> {
        Set((active?.workspace.projs ?? []).flatMap { $0.sessions.flatMap { $0.paneIDs } })
    }

    // Transient glass overlays, each in a child window over the active one (see ChildOverlay).
    private let pickerHost = ChildOverlay()    // pickers + prompt share one slot
    private let confirmHost = ChildOverlay()
    private let notifHost = ChildOverlay()

    /// Mount a picker overlay over the key window (or free `refs` and bail if one is already up).
    private func presentPicker(
        _ make: (@escaping () -> Void) -> PickerOverlay?, freeing refs: [Int32]
    ) {
        guard !onboardingActive,
            let parent = active?.controller.window,
            !pickerHost.isOpen, !confirmHost.isOpen
        else {
            refs.forEach { luaUnref($0) }
            return
        }
        let dismiss: () -> Void = { [weak self] in self?.pickerHost.close() }
        guard let overlay = make(dismiss) else { return }
        // Parent resize/close tears the overlay down without a pick — free the Lua refs
        // so a waiting plugin flow doesn't leak (mirrors the cancel path's cleanup).
        pickerHost.present(overlay, over: parent, onAutoClose: { refs.forEach { luaUnref($0) } })
    }

    /// vesta.pick: single-select (rich rows); call the ref with the chosen label.
    func showPick(_ items: [PickItem], _ ref: Int32, _ opts: PickOpts) {
        presentPicker(
            { dismiss in
                PickerOverlay(
                    theme: theme, richItems: items, multiSelect: false, opts: opts,
                    onPick: { idx in
                        dismiss()
                        if let i = idx.first { luaCall(ref: ref, stringArg: items[i].label) }
                        luaUnref(ref)
                    },
                    onCancel: {
                        dismiss()
                        luaUnref(ref)
                    })
            }, freeing: [ref])
    }

    /// vesta.pickmulti: multi-select; call the ref with a table of chosen labels.
    func showPickMulti(_ items: [PickItem], _ ref: Int32, _ opts: PickOpts) {
        presentPicker(
            { dismiss in
                PickerOverlay(
                    theme: theme, richItems: items, multiSelect: true, opts: opts,
                    onPick: { idx in
                        dismiss()
                        luaCallStringList(ref: ref, idx.map { items[$0].label })
                        luaUnref(ref)
                    },
                    onCancel: {
                        dismiss()
                        luaUnref(ref)
                    })
            }, freeing: [ref])
    }

    /// vesta.menu: single-select where each item carries its own action ref (-1 = none).
    func showMenu(_ items: [PickItem], _ refs: [Int32], _ opts: PickOpts) {
        let free = { refs.forEach { if $0 >= 0 { luaUnref($0) } } }
        presentPicker(
            { dismiss in
                PickerOverlay(
                    theme: theme, richItems: items, multiSelect: false, opts: opts,
                    onPick: { idx in
                        dismiss()
                        if let i = idx.first, refs.indices.contains(i), refs[i] >= 0 {
                            luaCall(ref: refs[i])
                        }
                        free()
                    },
                    onCancel: {
                        dismiss()
                        free()
                    })
            }, freeing: refs.filter { $0 >= 0 })
    }

    /// ⌘⇧P command palette: a searchable overlay of every runnable action — built-in app
    /// commands (with their shortcuts) plus every Lua-registered `vesta.command`. Reuses the
    /// vesta.pick overlay (PickerOverlay); selecting a row runs its action. Filtering is the
    /// overlay's built-in case-insensitive substring match — no fuzzy matching. // ponytail: substring is fine.
    func showCommandPalette() {
        // (label, shortcut-for-desc-column, action). Built-ins mirror installKeybinds/
        // dispatchPrefix. Actions take the key window at PICK time — nothing window-scoped
        // is captured, so a window closed with the palette up isn't retained by the overlay.
        var entries: [(String, String, (WindowContext) -> Void)] = [
            ("Split Vertical", "⌘D", { let ws = $0.workspace; ws.activeTree.splitFocused(.vertical, cwd: ws.activeTree.focusedCwd) }),
            ("Split Horizontal", "⌘⇧D", { let ws = $0.workspace; ws.activeTree.splitFocused(.horizontal, cwd: ws.activeTree.focusedCwd) }),
            ("Zoom Pane", "", { $0.workspace.activeTree.zoomFocused() }),
            ("Close Pane", "⌘W", { $0.workspace.activeTree.closeFocused() }),
            ("Close Session", "⌘⇧W", { let ws = $0.workspace; ws.closeSession(ws.activeP, ws.activeS) }),
            ("New Session", "⌘T", { let ws = $0.workspace; ws.newSession(ws.activeP) }),
            ("New Window", "⌘N", { [weak self] _ in self?.newWindow() }),
            ("Toggle Sidebar", "⌘B", { $0.controller.toggleSidebar() }),
            ("Focus Next Pane", "⌘]", { $0.workspace.activeTree.focusNext() }),
            ("Focus Previous Pane", "⌘[", { $0.workspace.activeTree.focusPrev() }),
            ("Next Session", "⌘}", { $0.workspace.nextSession() }),
            ("Previous Session", "⌘{", { $0.workspace.prevSession() }),
            ("Find in Terminal", "⌘F", { $0.workspace.activeTree.focused?.startSearch() }),
            ("Rename Session", "", { [weak self] _ in self?.promptRenameActiveSession() }),
            ("Kill Session", "", { $0.workspace.activeTree.killFocusedSession() }),
            ("Open Browser Pane", "⌘⇧↵", { ctx in
                let tree = ctx.workspace.activeTree
                let url = ctx.detectedPort(tree).map { URL(string: "http://localhost:\($0)")! }
                    ?? URL(string: "about:blank")!
                tree.openBrowser(url: url)
            }),
            ("Notifications", "", { [weak self] _ in self?.showNotifications() }),
            ("Enter Full Screen", "⌃⌘F", { $0.controller.window?.toggleFullScreen(nil) }),
            ("Settings…", "⌘,", { [weak self] _ in self?.openSettings() }),
            ("Reload Config", "", { [weak self] _ in self?.reloadConfig() }),
            ("Check for Updates…", "", { [weak self] _ in self?.checkForUpdates() }),
            ("About Vesta", "", { [weak self] _ in self?.showAbout() }),
        ]
        // Lua plugin commands (vesta.command) appear alongside the built-ins. The closure
        // captures the NAME and re-resolves at pick time, so a reload can't leave stale refs.
        for name in luaCommands.keys.sorted() {
            entries.append((name, "plugin", { _ in luaRunCommand(name) }))
        }
        let items = entries.map { PickItem(label: $0.0, desc: $0.1.isEmpty ? nil : $0.1) }
        let actions = entries.map { $0.2 }
        presentPicker(
            { dismiss in
                PickerOverlay(
                    theme: self.theme, richItems: items, multiSelect: false, opts: PickOpts(),
                    onPick: { [weak self] idx in
                        dismiss()
                        guard let ctx = self?.active else { return }
                        if let i = idx.first, actions.indices.contains(i) { actions[i](ctx) }
                    },
                    onCancel: { dismiss() })
            }, freeing: [])
    }

    /// vesta.panel: create (id 0) or update (existing id) a plugin panel. `window = "all"`
    /// renders it in every window; otherwise it lives in the active window and follows focus.
    /// Returns the panel id. Corner/scope are fixed at creation.
    func luaPanelSet(_ lines: [PanelLine], _ opts: PanelOpts) -> Int {
        let id: Int
        if opts.id > 0 {
            id = opts.id
        } else {
            luaPanelCounter += 1
            id = luaPanelCounter
        }
        // Free the click refs of the spec we're replacing (the new lines carry fresh refs).
        let oldRefs = luaPanelSpecs[id]?.lines.compactMap(\.clickRef) ?? []
        var opts = opts
        opts.id = id
        luaPanelSpecs[id] = PanelSpec(lines: lines, opts: opts)
        renderPanels()
        oldRefs.forEach { luaUnref($0) }  // after re-render, so live overlays no longer hold them
        return id
    }

    /// Reconcile panel overlays against the specs: each spec renders into its target windows
    /// (all, or just the active one), updating in place and removing overlays from windows it
    /// no longer targets (e.g. an active-scoped panel when focus moves). Also prunes overlays
    /// for closed windows. Called on panel set/update and whenever the active window changes.
    func renderPanels() {
        if onboardingActive {  // suppress all plugin panels for the duration of onboarding
            panelViews.values.flatMap { $0.values }.forEach { $0.removeFromSuperview() }
            panelViews.removeAll()
            return
        }
        var created = false
        let live = Set(windows.map(ObjectIdentifier.init))
        for id in Array(panelViews.keys) {
            for (wid, ov) in panelViews[id] ?? [:] where !live.contains(wid) {
                ov.removeFromSuperview()
                panelViews[id]?[wid] = nil
            }
        }
        for (id, spec) in luaPanelSpecs {
            let targets = spec.opts.allWindows ? windows : [active].compactMap { $0 }
            let targetIDs = Set(targets.map(ObjectIdentifier.init))
            for (wid, ov) in panelViews[id] ?? [:] where !targetIDs.contains(wid) {
                ov.removeFromSuperview()
                panelViews[id]?[wid] = nil  // moved away (active panel)
            }
            for win in targets {
                let wid = ObjectIdentifier(win)
                guard let host = win.controller.window?.contentView else { continue }
                if let ov = panelViews[id]?[wid] {
                    _ = ov.update(title: spec.opts.title, lines: spec.lines)  // refs managed at spec level
                } else {
                    let ov = PanelOverlay(theme: theme, lines: spec.lines, opts: spec.opts)
                    host.addSubview(ov)
                    ov.place(into: host)
                    panelViews[id, default: [:]][wid] = ov
                    created = true
                }
            }
        }
        // Restore persisted stacking only when a panel was just created (not on every timer
        // re-render, which would churn the z-order): re-add each window's panels back-to-front
        // by their saved z, so the last-fronted card ends up on top across launches.
        if created {
            for win in windows {
                guard let host = win.controller.window?.contentView else { continue }
                let panels = host.subviews.compactMap { $0 as? PanelOverlay }
                for ov in panels.sorted(by: { ov1, ov2 in
                    (PanelStore.get(ov1.panelTitle)?.z ?? 0) < (PanelStore.get(ov2.panelTitle)?.z ?? 0)
                }) {
                    host.addSubview(ov, positioned: .above, relativeTo: nil)
                }
            }
        }
    }

    /// vesta.prompt: free-text input overlay; call the Lua ref with the typed text (or free
    /// the ref on cancel).
    func showPrompt(_ message: String, _ initial: String, _ ref: Int32) {
        guard !onboardingActive,
            let parent = active?.controller.window,
            !pickerHost.isOpen
        else {
            luaUnref(ref)
            return
        }
        let dismiss: () -> Void = { [weak self] in self?.pickerHost.close() }
        let overlay = PickerOverlay(
            theme: theme, prompt: message, initial: initial,
            onSubmit: { text in
                dismiss()
                luaCall(ref: ref, stringArg: text)
                luaUnref(ref)
            },
            onCancel: {
                dismiss()
                luaUnref(ref)
            })
        pickerHost.present(overlay, over: parent, onAutoClose: { luaUnref(ref) })
    }

    /// vesta.confirm: compact yes/no dialog; call the Lua ref with a boolean (Esc/scrim → false).
    func showConfirm(_ message: String, _ ref: Int32) {
        guard !onboardingActive,
            let parent = active?.controller.window,
            !pickerHost.isOpen, !confirmHost.isOpen
        else {
            luaUnref(ref)
            return
        }
        let dismiss: () -> Void = { [weak self] in self?.confirmHost.close() }
        let overlay = ConfirmOverlay(theme: theme, message: message) { yes in
            dismiss()
            luaCallBool(ref: ref, yes)
            luaUnref(ref)
        }
        // Torn down by a parent-window event → resolve as "no" (Esc semantics), don't hang.
        confirmHost.present(overlay, over: parent, onAutoClose: {
            luaCallBool(ref: ref, false)
            luaUnref(ref)
        })
    }

    // In-app notification history (behind the titlebar bell). Ephemeral — last 50, not persisted.
    private var notes: [VestaNote] = []
    private var unread = 0
    private var notesFile: String { (controlSocketPath() as NSString).deletingLastPathComponent + "/notifications.json" }

    /// Load the persisted notification history (bell list survives restarts).
    func loadNotes() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: notesFile)),
              let saved = try? JSONDecoder().decode([VestaNote].self, from: data) else { return }
        notes = saved   // history only — unread stays 0 (already seen in a prior session)
    }
    private func saveNotes() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: URL(fileURLWithPath: notesFile), options: .atomic)
    }

    /// The full notify path: record it in the in-app list (bell), show the transient toast,
    /// and post a desktop banner when backgrounded (or when the call forces it).
    func handleNotify(_ msg: String, title: String?, desktop: Bool) {
        if onboardingActive { return }  // suppressed like other plugin UI during onboarding
        notes.append(VestaNote(title: title, message: msg, date: Date()))
        if notes.count > 50 { notes.removeFirst(notes.count - 50) }
        saveNotes()
        showToast(msg)
        Notifier.post(title: title, body: msg, force: desktop)
        // If the dropdown is already open, drop the new note straight in (it's visible → read);
        // otherwise bump the unread badge on the bell.
        if notifHost.isOpen {
            unread = 0
            presentNotifications()
        } else {
            unread += 1
        }
        windows.forEach { $0.controller.setUnread(unread) }
    }

    /// Toggle the notifications dropdown under the bell. Opening marks everything read.
    func showNotifications() {
        if notifHost.isOpen { notifHost.close(); return }  // bell pressed while open → close
        unread = 0
        windows.forEach { $0.controller.setUnread(0) }
        presentNotifications()
    }

    /// (Re)render the panel over the active window — called on open and after delete/clear.
    private func presentNotifications() {
        guard let parent = active?.controller.window else { return }
        let panel = NotificationsPanel(
            theme: theme, notes: notes.reversed(),
            onDelete: { [weak self] id in
                self?.notes.removeAll { $0.id == id }
                self?.saveNotes()
                self?.presentNotifications()
            },
            onClear: { [weak self] in
                self?.notes.removeAll()
                self?.saveNotes()
                self?.presentNotifications()
            })
        panel.onDismiss = { [weak self] in self?.notifHost.close() }
        notifHost.present(panel, over: parent)
    }

    // Live transient toasts, newest first. They stack: the newest is on top showing its text,
    // older ones peek out behind it (no readable text — a full list would be unusable). Capped.
    private var toasts: [NSView] = []
    private var toastTop: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private let toastPeek: CGFloat = 4
    private let toastMax = 3

    /// Show `msg` as a transient toast banner in the key window (what `vesta.notify` calls).
    /// In-app so it's visible even under `swift run` (macOS notifications need a signed
    /// bundle). Falls back to stderr when there's no window. Uses the theme accent — no
    /// hardcoded colors. Simultaneous toasts stack (newest on top) rather than replacing.
    func showToast(_ msg: String) {
        if onboardingActive { return }  // no plugin toasts over onboarding
        guard let host = active?.controller.window?.contentView else {
            FileHandle.standardError.write(Data("[vesta.lua] \(msg)\n".utf8))
            return
        }
        let label = NSTextField(labelWithString: msg)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.96, alpha: 1)
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        let banner = NSView()
        banner.wantsLayer = true
        installGlass(banner, tint: NSColor(white: 0.10, alpha: 1))   // glass moment: blur + dark tint
        banner.layer?.cornerRadius = 9
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = theme.accent.withAlphaComponent(0.55).cgColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)
        host.addSubview(banner, positioned: .above, relativeTo: nil)  // newest on top of the stack
        let top = banner.topAnchor.constraint(equalTo: host.topAnchor, constant: 46)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: banner.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -11),
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 15),
            label.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -15),
            banner.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.7),
            top,
        ])
        toasts.insert(banner, at: 0)
        toastTop[ObjectIdentifier(banner)] = top
        while toasts.count > toastMax {  // drop the oldest beyond the cap
            let old = toasts.removeLast()
            toastTop[ObjectIdentifier(old)] = nil
            old.removeFromSuperview()
        }
        banner.alphaValue = 0
        // Pass 1 (instant): place ONLY the new card at its final slot, leaving the others where
        // they are — so it appears in place (not sliding from the (0,0) layout origin) and the
        // existing cards don't snap.
        top.constant = 46 + CGFloat(toasts.count - 1) * toastPeek
        host.layoutSubtreeIfNeeded()
        // Pass 2 (animated): restack the existing cards into their new slots + dim, and fade the
        // newest in. The new card's constant is already final, so it only fades — no jump.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            layoutToasts(host)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            self?.dismissToast(banner)
        }
    }

    /// Position the toast stack: the newest is the front card (full text), sitting lowest;
    /// each older one is nudged UP behind it so only its top edge peeks out, and dimmed.
    private func layoutToasts(_ host: NSView) {
        let last = toasts.count - 1
        for (i, b) in toasts.enumerated() {
            toastTop[ObjectIdentifier(b)]?.constant = 46 + CGFloat(last - i) * toastPeek
        }
        host.layoutSubtreeIfNeeded()
        for (i, b) in toasts.enumerated() {
            b.alphaValue = (i == 0) ? 1 : max(0.25, 0.9 - CGFloat(i) * 0.16)
        }
    }

    private func dismissToast(_ banner: NSView) {
        guard toasts.contains(where: { $0 === banner }) else { return }  // already removed
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.32
                banner.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self else { return }
                banner.removeFromSuperview()
                self.toasts.removeAll { $0 === banner }
                self.toastTop[ObjectIdentifier(banner)] = nil
                if let host = self.toasts.first?.superview {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.18
                        ctx.allowsImplicitAnimation = true
                        self.layoutToasts(host)
                    }
                }
            })
    }

    /// Full structured state for `vesta state`: the shared project/session pool plus every
    /// window's view (active selection + whether it hosts the live terminal). Lets an agent
    /// see the whole tree the sidebar shows, not just the active window's panes.
    func fullState() -> [String: Any] {
        let projects = store.projs.enumerated().map { (pi, p) -> [String: Any] in
            let sessions = p.sessions.enumerated().map { (si, t) -> [String: Any] in
                var d: [String: Any] = [
                    "index": si, "panes": t.paneIDs.count, "paneIDs": t.paneIDs,
                ]
                if let n = t.name { d["name"] = n }
                if let c = t.focusedCwd { d["cwd"] = c }
                return d
            }
            var d: [String: Any] = [
                "index": pi, "name": p.name, "path": p.path,
                "expanded": p.expanded, "sessions": sessions,
            ]
            if let c = p.color { d["color"] = hexString(c) }
            return d
        }
        let wins = windows.enumerated().map { (wi, w) -> [String: Any] in
            [
                "index": wi, "key": w === active, "activeProject": w.workspace.activeP,
                "activeSession": w.workspace.activeS, "hostsLive": w.workspace.hostsLive,
            ]
        }
        return ["ok": true, "projects": projects, "windows": wins]
    }

    // MARK: - Window-state persistence

    private static var windowsFile: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/vesta"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/windows.json"
    }

    /// Rebuild last session's windows from windows.json, else one fresh window.
    private func restoreWindows() {
        restoring = true
        defer { restoring = false }
        // Parse windows.json BEFORE creating the first window, so the saved state can be
        // handed into the Workspace at init — otherwise the first window seeds a throwaway
        // home session (real surface + daemon login shell) that hydrate discards, leaking
        // the shell under vestad every launch.
        let data = try? Data(contentsOf: URL(fileURLWithPath: Self.windowsFile))
        let parsed = data.map { parseWindowsFile($0) }
        let first = parsed?.windows.first
        let ctx = newWindow(hydrateFrom: first)  // hydrates inside init when `first` is present
        guard let data, let parsed, let first else { return }
        let (version, saved) = parsed
        // Upgrade courtesy: keep the legacy (pre-versioning) file once, so a downgraded
        // build — which reads the v1 dict as "no saved windows" and overwrites it — can
        // be recovered manually from windows.json.v0.
        if version == 0 {
            try? data.write(to: URL(fileURLWithPath: Self.windowsFile + ".v0"), options: .atomic)
        }
        // Entry 0 (the key window at save time) is authoritative for the shared pool — already
        // hydrated inside newWindow(hydrateFrom:) above.
        if let fd = first["frame"] as? String { ctx.controller.window?.setFrame(from: fd) }
        ctx.refresh()
        // v1+: recreate the other windows as views over the SAME pool — only their
        // selection + frame are per-window (sessions live once, in the shared store).
        // Legacy (version 0) files collapse to one window, as before.
        guard version >= 1 else { return }
        for entry in saved.dropFirst() {
            let extra = newWindow()
            extra.workspace.selectSession(entry["activeProject"] as? Int ?? 0,
                                          entry["activeSession"] as? Int ?? 0)
            if let fd = entry["frame"] as? String { extra.controller.window?.setFrame(from: fd) }
            extra.refresh()
        }
        if windows.count > 1 {
            ctx.controller.window?.makeKeyAndOrderFront(nil)  // entry 0 was frontmost at save
            lastKey = ctx
            reconcileDisplay()
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

    /// Persist every window (versioned format), key window first so restore can re-front
    /// it. Each entry is that window's Workspace.serialize() + its frame. If no window is
    /// open, the last save on window-close already wrote the file, so skipping here is safe.
    func saveWindows() {
        guard !windows.isEmpty else { return }
        let key = active
        // ponytail: every entry repeats the shared project pool (Workspace.serialize
        // includes it; entry 0 is authoritative on restore). Split pool vs. per-window
        // state in a v2 format if the duplication ever matters.
        let ordered = [key].compactMap { $0 } + windows.filter { $0 !== key }
        let entries = ordered.map { w -> [String: Any] in
            var e = w.workspace.serialize()
            if let fd = w.controller.window?.frameDescriptor { e["frame"] = fd }
            return e
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["version": windowsFormatVersion, "windows": entries],
            options: [.prettyPrinted])
        else { return }
        try? data.write(to: URL(fileURLWithPath: Self.windowsFile), options: .atomic)
    }

    func applicationWillTerminate(_ note: Notification) {
        saveWindows()
        #if DEBUG
        // DEV builds only: kill the session daemon on quit. vestad is single-instance per
        // user, so a stale dev daemon (ad-hoc signed, often under a TCC-protected path like
        // ~/Desktop) would otherwise linger and serve a later RELEASE build — which makes
        // macOS re-prompt for Desktop access on every command. Release builds never do this:
        // there the daemon must outlive quit so sessions survive.
        // Edge: also kills a vestad a concurrent RELEASE app is using (single-instance) — fine for a dev build.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", "vestad"]
        try? p.run()
        #endif
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Fonts.register()  // bundle Geist/Martian Mono before building UI
        loadNotes()       // restore persisted notification history (bell list)
        // Re-stamp the user's chosen app-icon variant (Settings ▸ App Icon / About panel) onto
        // the bundle — this restores it after an in-place self-update (which ships a fresh
        // bundle with the default icon). Only for a non-default choice, and deferred off the
        // launch path so the bundle-write I/O doesn't block first paint.
        let savedIcon = UserDefaults.standard.string(forKey: AboutWindowController.iconKey)
        if let savedIcon, savedIcon != AboutWindowController.defaultVariant {
            DispatchQueue.main.async { AboutWindowController.applyIcon(named: savedIcon) }
        }
        let ghostty = GhosttyApp.shared  // inits libghostty (init/config/app) — native config sync
        theme = ghostty.theme  // colors from the real ghostty config

        NSApp.mainMenu = makeMainMenu(target: self)  // bundle-less binary: build the menu bar
        // Activate BEFORE building the first window: a translucent/glass window ordered
        // front while the app is still inactive gets an OPAQUE backing surface from the
        // WindowServer that never rebuilds (isOpaque reads false, but terminal see-through
        // and behind-window sidebar glass both render solid). ⌘N windows are fine because
        // the app is already active. Activating first makes the restored/first window's
        // backing establish with alpha, exactly like a ⌘N window.
        NSApp.activate(ignoringOtherApps: true)
        restoreWindows()  // saved windows (or one fresh window)
        // Output-tail ticks re-render the sidebar cards (refresh() self-debounces to ≤1/s).
        // Deliberately NOT store.broadcast — that path also persists windows.json.
        TailStore.shared.onChange = { [weak self] in self?.windows.forEach { $0.refresh() } }
        // Background-command attention, driven by shell-integration marks: the old
        // prompt-return pid heuristic is blind under vesta-persist (ghostty's pty runs
        // only the relay; commands live on the daemon's pty and never change the pid).
        TailStore.shared.onCommandDone = { [weak self] paneID, _, duration in
            guard let self, duration >= 3 else { return }   // quick commands don't ring
            for proj in self.store.projs {
                for tree in proj.sessions where !tree.isDormant && tree.paneIDs.contains(paneID) {
                    self.windows.forEach { $0.workspace.markAttention(tree) }   // no-op for the active one
                    return
                }
            }
        }

        server = ControlServer(workspaceProvider: { [weak self] in self?.active?.workspace })
        server.onReload = { [weak self] in self?.reloadConfig() }
        luaReloadHook = { [weak self] in self?.reloadConfig() }  // sandbox auto-disable → full reload
        server.onNewWindow = { [weak self] in
            self?.newWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
        server.stateProvider = { [weak self] in self?.fullState() ?? ["ok": false] }
        server.start()
        // Lua bridge handlers (vesta.notify / active / send), then run init.lua.
        luaNotifyRich = { [weak self] msg, title, desktop in
            self?.handleNotify(msg, title: title, desktop: desktop)
        }
        Notifier.requestAuth()
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
        luaClearTimers = { [weak self] in
            self?.luaTimers.forEach { $0.invalidate() }
            self?.luaTimers.removeAll()
        }
        luaShowPick = { [weak self] items, ref, opts in self?.showPick(items, ref, opts) }
        luaShowPickMulti = { [weak self] items, ref, opts in self?.showPickMulti(items, ref, opts) }
        luaShowMenu = { [weak self] items, refs, opts in self?.showMenu(items, refs, opts) }
        luaSetStatus = { [weak self] s in
            guard let self, !self.onboardingActive else { return }  // no plugin status during onboarding
            self.windows.forEach { $0.controller.setLuaStatus(s) }
        }
        luaPanel = { [weak self] lines, opts in self?.luaPanelSet(lines, opts) ?? 0 }
        luaClosePanel = { [weak self] id in
            guard let self else { return }
            self.luaPanelSpecs[id]?.lines.compactMap(\.clickRef).forEach { luaUnref($0) }
            self.luaPanelSpecs[id] = nil
            (self.panelViews[id] ?? [:]).values.forEach { $0.removeFromSuperview() }
            self.panelViews[id] = nil
        }
        luaClearPanels = { [weak self] in
            guard let self else { return }
            self.luaPanelSpecs.values.flatMap { $0.lines }.compactMap(\.clickRef).forEach {
                luaUnref($0)
            }
            self.luaPanelSpecs.removeAll()
            self.panelViews.values.flatMap { $0.values }.forEach { $0.removeFromSuperview() }
            self.panelViews.removeAll()
        }
        luaShowPrompt = { [weak self] msg, initial, ref in self?.showPrompt(msg, initial, ref) }
        luaShowConfirm = { [weak self] msg, ref in self?.showConfirm(msg, ref) }
        LuaRuntime.shared.start()  // run init.lua + plugins (builds plugin UI on the window)
        // config-in-Lua: fold vesta.set() overrides in (Lua wins) + re-theme. The plugin UI built
        // above used the pre-Lua theme, so rebuild it against the applied theme — otherwise
        // load-time panels/buttons keep the old accent until a manual reload.
        if !luaConfigOverrides.isEmpty {
            theme = GhosttyApp.shared.reloadConfig()
            windows.forEach { $0.applyTheme(theme) }
            LuaRuntime.shared.start()  // rebuild plugin UI with the applied theme
        }

        installKeybinds()
        let settings = GhosttyApp.shared.settings
        prefix = parsePrefixSpec(settings["vesta-prefix"] ?? "ctrl+b")
        let binds = (settings["vesta-prefix-bind"] ?? "")
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

        // Finder Services provider ("New Vesta Session Here"); drain any folders the
        // app was launched to open (open -a Vesta <dir> / Open With).
        NSApp.servicesProvider = self
        if !pendingOpenDirs.isEmpty {
            let dirs = pendingOpenDirs
            pendingOpenDirs = []
            for d in dirs { active?.workspace.newTab(cwd: d) }
        }

        Updater.shared.onPhase = { [weak self] phase in
            self?.windows.forEach { self?.applyUpdatePhase(to: $0.controller, phase) }
        }
        Updater.shared.check(silent: true)  // surface a newer release in the sidebar badge
        // Re-check hourly so the badge appears during a long-running session, not only at
        // launch. Silent — just updates the badge; skipped while downloading/staged.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check(silent: true) }
        }

        maybeShowOnboarding()
        scheduleBackgroundMaterialize()   // fill dormant sessions' sidebar tails after first paint
        // If an OLDER session daemon is still running (from a previous app version — release
        // builds keep it alive across quit so shells survive), swap it to our bundled vestad in
        // place so its shells migrate to the new code without dying. Deferred so a freshly
        // launched daemon (lazy-spawned by the first pane) has bound its socket first. Runs at
        // launch, which also covers the post-self-update relaunch (a relaunch is a fresh launch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.autoUpgradeDaemonIfNeeded()
        }
    }

    // Debounce: at most one auto-upgrade attempt per launch.
    private var daemonUpgradeChecked = false

    /// Compare the running daemon's own executable identity against our bundled vestad; on a
    /// mismatch, upgrade it in place (see MuxClient.upgradeDaemon) and toast the outcome.
    /// Skipped in DEBUG — dev daemons churn constantly and the DEBUG quit-pkill already handles
    /// dev hygiene, so an in-place upgrade there is noise (and would fight the churn).
    private func autoUpgradeDaemonIfNeeded() {
        #if DEBUG
        return
        #else
        guard !daemonUpgradeChecked else { return }
        daemonUpgradeChecked = true
        let bundled = Bundle.main.executableURL!.deletingLastPathComponent()
            .appendingPathComponent("vestad").path
        // File hash + socket round-trip off the main thread; toast back on main.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let bundledSHA = MuxClient.sha256OfFile(bundled) else { return }
            // Daemon down, or an older daemon that doesn't speak `info` → leave it alone. A
            // daemon spawned fresh from THIS bundle is already the new binary.
            guard let daemonSHA = MuxClient.daemonExecutableSHA() else { return }
            guard daemonSHA != bundledSHA else { return }   // already running our binary
            let outcome = MuxClient.upgradeDaemon(to: bundled)
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success:
                    self.showToast("session daemon updated in place — shells kept")
                case let .failure(reason):
                    // Non-scary: the shells are fine, we just didn't swap the daemon.
                    self.showToast("session daemon kept the previous version (\(reason))")
                case .unreachable:
                    break   // vanished mid-check; a fresh daemon will be the new binary
                }
            }
        }
        #endif
    }

    /// Background-materialize dormant restored sessions so their sidebar output tails
    /// (PaneTree.tailLines reads the LIVE ghostty viewport → empty while dormant) fill in
    /// without the user clicking each one. Staggered — one every ~200ms after a ~1.5s
    /// warm-up — so we don't fire a thundering herd of vesta-attach spawns + surface
    /// creations against first paint. Gated on vesta-sidebar-tails: the tails are the only
    /// consumer, so skip the cost entirely when they're off.
    ///
    /// Materializing an off-screen tree is safe: TerminalPane starts setSurfaceFocus(false),
    /// and materialize()'s restyle→focusContent() no-ops while root has no window — so no
    /// background pane steals first-responder or starts a blinking cursor. materialize() is
    /// guarded on dormantLayout, so a session the user clicks (or that already went live)
    /// mid-stagger just no-ops here.
    private func scheduleBackgroundMaterialize() {
        guard VestaConfig.shared.sidebarTails else { return }
        // Re-scan the shared pool each tick (covers all projects, incl. collapsed) and
        // materialize the next still-dormant tree; stop when none remain.
        func step() {
            guard let tree = store.projs.flatMap(\.sessions).first(where: { $0.isDormant }) else {
                windows.forEach { $0.refresh() }   // all live → tails/heat now render
                return
            }
            tree.materialize()   // also broadcasts (restyle→onFocusChange) → sidebar refresh
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: step)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: step)
    }

    var onboardingActive = false

    /// First-ever launch only: mount the onboarding overlay on the key window. Plugin UI
    /// (panels/status/toasts/pickers) is suppressed while it's up, then rebuilt on finish.
    /// Gated on a plain bool (not a version), so app updates never re-trigger it.
    private func maybeShowOnboarding() {
        guard !UserDefaults.standard.bool(forKey: "VestaDidOnboard"),
            let host = active?.controller.window?.contentView,
            !host.subviews.contains(where: { $0 is OnboardingOverlay })
        else { return }
        onboardingActive = true
        renderPanels()  // tears down any plugin panels already up
        windows.forEach {
            $0.controller.setLuaStatus("")
            $0.controller.setChromeHidden(true)
        }
        let overlay = OnboardingOverlay(
            theme: theme,
            addProject: { [weak self] path in self?.active?.workspace.newProject(at: path) },
            onFinish: { [weak self] in
                guard let self else { return }
                self.onboardingActive = false
                self.windows.forEach { $0.controller.setChromeHidden(false) }
                self.reloadConfig()
            })
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
    }

    @objc func checkForUpdates() { Updater.shared.check(silent: false) }

    /// Map an Updater phase → the sidebar update badge (text + whether it's clickable).
    private func applyUpdatePhase(to controller: VestaWindowController, _ phase: Updater.Phase?) {
        switch phase {
        case .available(let tag):     controller.setUpdateStatus("↑ update \(tag) — install", clickable: true)
        case .downloading(let p):     controller.setUpdateStatus("downloading… \(Int(p * 100))%", clickable: false)
        case .installing:             controller.setUpdateStatus("installing…", clickable: false)
        case .ready(let tag):         controller.setUpdateStatus("✓ \(tag) ready — relaunch", clickable: true)
        case .failed:                 controller.setUpdateStatus("update failed — retry", clickable: true)
        case nil:                     controller.setUpdateStatus(nil, clickable: false)
        }
    }

    /// Full reset: delete Vesta's config AND the settings persisted outside it
    /// (UserDefaults — sidebar width, window frame, quit-confirm), then reload so
    /// everything returns to defaults / the ghostty base.
    @objc func resetConfig() {
        try? FileManager.default.removeItem(atPath: vestaConfigPath())
        let d = UserDefaults.standard
        for k in ["VestaSidebarWidth", "VestaSkipQuitConfirm", "NSWindow Frame VestaMainWindow"] {
            d.removeObject(forKey: k)
        }
        reloadConfig()
        active?.controller.setSidebarWidth(CGFloat(VestaConfig.shared.sidebarWidth))  // live default
    }

    // Closing the window does NOT quit Vesta — the app keeps running (menu bar
    // stays live); reopen via the Dock or ⌘N-style reactivation.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// Dock-click / reactivation with no visible window → bring a window back
    /// (or open a fresh one if they were all closed).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        if !flag {
            if let win = windows.first?.controller.window {
                win.makeKeyAndOrderFront(nil)
            } else {
                newWindow()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Confirm before quitting (⌘Q) — running sessions would be killed — unless
    /// the user ticked "Don't ask again".
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UserDefaults.standard.bool(forKey: "VestaSkipQuitConfirm") { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Quit Vesta?"
        a.informativeText = "Your sessions keep running in the background and reattach next launch."
        a.alertStyle = .warning
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        a.addButton(withTitle: "Quit Vesta")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        if a.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "VestaSkipQuitConfirm")
        }
        return .terminateNow
    }

    // MARK: - Menu actions

    /// Register Vesta as the Shell-role handler for unix executables — macOS's notion of
    /// "default terminal" (same mechanism as Ghostty/iTerm2). Requires the installed .app
    /// (Info.plist declares the Shell role); the bare dev binary has no bundle, so the
    /// error toast is the expected outcome there.
    @objc func makeDefaultTerminal() {
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL, toOpen: .unixExecutable
        ) { [weak self] err in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.showToast(err == nil
                        ? "vesta is now the default terminal"
                        : "couldn't set default terminal: \(err!.localizedDescription)")
                }
            }
        }
    }

    private var aboutWC: AboutWindowController?
    @objc func showAbout() {
        if aboutWC == nil { aboutWC = AboutWindowController(theme: theme) }
        aboutWC?.showWindow(nil)
        aboutWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var settingsWC: SettingsWindowController?

    /// Re-read the config and re-apply colors/theme/terminal settings live — no
    /// relaunch. Pushes a fresh ghostty config to every surface and re-themes chrome.
    @objc func reloadConfig() {
        LuaRuntime.shared.start()  // re-run init.lua first → repopulate vesta.set overrides
        let t = GhosttyApp.shared.reloadConfig()  // re-read file + merge Lua overrides (Lua wins)
        theme = t
        windows.forEach { $0.applyTheme(t) }
        settingsWC?.refreshLocks()  // Lua-owned rows may have (un)locked (e.g. plugin toggled)
        // Re-parse the prefix from the merged settings (Lua may have set vesta-prefix).
        let s = GhosttyApp.shared.settings
        prefix = parsePrefixSpec(s["vesta-prefix"] ?? "ctrl+b")
        let binds = (s["vesta-prefix-bind"] ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
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

    /// Open the active config file in the user's editor: Vesta's own if imported,
    /// else the live ghostty config.
    @objc func openConfigFile() {
        let fm = FileManager.default
        let vesta = vestaConfigPath()
        if fm.fileExists(atPath: vesta) {
            NSWorkspace.shared.open(URL(fileURLWithPath: vesta))
            return
        }
        if let ghostty = ghosttyConfigPath() {
            NSWorkspace.shared.open(URL(fileURLWithPath: ghostty))
            return
        }
        // Neither exists — create a starter Vesta config and open it.
        try? fm.createDirectory(
            atPath: (vesta as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let starter =
            "# Vesta config — ghostty keys + vesta-* keys.\n"
            + "# e.g. theme = ..., vesta-accent = #7dcfb6, vesta-sidebar-width = 240\n"
        try? starter.write(toFile: vesta, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(URL(fileURLWithPath: vesta))
    }

    /// Copy the live ghostty config into Vesta's own config so it can be customized
    /// independently. After this, Vesta loads its own config (ghostty's stays put).
    @objc func importGhosttyConfig() {
        let fm = FileManager.default
        guard let src = ghosttyConfigPath(),
            let text = try? String(contentsOfFile: src, encoding: .utf8)
        else {
            let a = NSAlert()
            a.messageText = "No ghostty config found"
            a.informativeText = "Couldn't find ~/.config/ghostty/config to import from."
            a.runModal()
            return
        }
        let dst = vestaConfigPath()
        if fm.fileExists(atPath: dst) {
            let a = NSAlert()
            a.messageText = "Replace Vesta config?"
            a.informativeText = "This overwrites \(dst) with your ghostty config."
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        try? fm.createDirectory(
            atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Import only the SETTINGS: parse the key=value pairs and rewrite them under
        // a Vesta header, dropping ghostty's template comments/boilerplate. So the
        // file reads as Vesta's own, not a ghostty config.
        let pairs = parseGhosttyConfig(text)
        let header =
            "# Vesta config — your own copy. Any ghostty key works, plus vesta-* keys.\n"
            + "# Imported from your ghostty settings; edit freely (ghostty's config is untouched).\n\n"
        let body = pairs.map { "\($0.0) = \($0.1)" }.joined(separator: "\n") + "\n"
        do {
            try (header + body).write(toFile: dst, atomically: true, encoding: .utf8)
            let a = NSAlert()
            a.messageText = "Imported \(pairs.count) settings"
            a.informativeText = "Saved to your Vesta config. Apply now?"
            a.addButton(withTitle: "Reload")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { reloadConfig() }
        } catch {
            let a = NSAlert()
            a.messageText = "Import failed"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc func showHelp() {
        let a = NSAlert()
        a.messageText = "Vesta Help"
        a.informativeText = """
            Keys
              ⌘D / ⌘⇧D   split vertical / horizontal
              ⌘W / ⌘⇧W   close pane / session
              ⌘T          new session        ⌘B  toggle sidebar
              ⌘]          focus next pane     ⌘{ / ⌘}  prev / next session
              ⌘1–9        select session      ⌘⇧↵  open browser pane

            Sidebar
              Right-click a project: rename, recolor, remove, new worktree session.
              Session cards show the last lines of output; hover a card for × (close),
              a divider for + (new session). Hover any glyph for its meaning.

            Card legend
              ⊞2          panes in the session      ●3   uncommitted git changes
              :4321       listening port
              accent rail  rang while backgrounded — click to open
              ✓ · 2m      last command succeeded (unseen)
              ✗ · 18m     last command failed (unseen) — amber rail

            CLI
              Run `vesta help` in any terminal for the agent-control API
              (split, send-keys, capture, worktree, browser, …).

            Settings live in your ghostty config — Vesta ▸ Settings… (⌘,).
            """
        a.runModal()
    }

    @objc func toggleSidebarMenu() { active?.controller.toggleSidebar() }

    /// Explicit kill of the focused session's shell under vestad (menu / no key
    /// equivalent — Cmd-W only detaches).
    @objc func killSessionMenu() { active?.workspace.activeTree.killFocusedSession() }

    // MARK: - "Default terminal" integration (open folders / Finder Services)

    private var pendingOpenDirs: [String] = []

    /// Finder "Open With Vesta", `open -a Vesta <dir>`, dropping a folder on the icon.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openPaths(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    /// Finder right-click ▸ Services ▸ "New Vesta Session Here" (registered via Info.plist).
    @objc func newSessionHere(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
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
        guard let ws = active?.workspace else {
            pendingOpenDirs += dirs
            return
        }
        for d in dirs { ws.newTab(cwd: d) }
    }

    // ponytail: hard-coded keybinds. make them config-driven when asked.
    private func installKeybinds() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            // ── Prefix mode (runs before the ⌘ keybinds) ──────────────────────
            if let prefix = self.prefix {
                let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
                let isEscape = (e.keyCode == 53)  // Escape
                if self.prefixState.armed {
                    // Resolve the NEXT key. Arrows → tokens; else the typed char.
                    let key = Self.prefixKeyToken(e)
                    if let action = self.prefixState.handle(
                        key: key, isEscape: isEscape, table: self.prefixTable)
                    {
                        self.dispatchPrefix(action)
                    }
                    return nil  // swallow the key whether it fired, cancelled, or was Escape
                }
                // Not yet armed: is THIS the prefix chord?
                if mods == prefix.mods,
                    (e.charactersIgnoringModifiers ?? "").lowercased() == prefix.key
                {
                    self.prefixState.arm()
                    return nil
                }
            }
            // ── Lua keybinds (vesta.bind) — before built-in ⌘ binds, so a script can claim
            // any chord (e.g. ctrl+g, cmd+shift+p) ───────────────────────────────────────
            if !luaBinds.isEmpty {
                let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
                let key = (e.charactersIgnoringModifiers ?? "").lowercased()
                for b in luaBinds
                where parsePrefixSpec(b.spec).map({ $0.mods == mods && $0.key == key }) == true {
                    luaCall(ref: b.ref)
                    return nil
                }
            }
            guard e.modifierFlags.contains(.command) else { return e }
            let shift = e.modifierFlags.contains(.shift)
            // ⌘N: new window (doesn't need a key window).
            if !shift, e.charactersIgnoringModifiers == "n" {
                self.newWindow()
                return nil
            }
            // Everything else acts on the key window.
            guard let ctx = self.active else { return e }
            let ws = ctx.workspace
            // Lowercase: charactersIgnoringModifiers keeps Shift applied, so ⌘⇧D yields "D"
            // (not "d") — without this, every ⌘⇧<letter> chord silently falls through.
            switch e.charactersIgnoringModifiers?.lowercased() {
            // Split panes (unchanged)
            case "d":
                ws.activeTree.splitFocused(
                    shift ? .horizontal : .vertical, cwd: ws.activeTree.focusedCwd)
                return nil
            // ⌘W: pane → session → window (cascade). ⌘⇧W: close session.
            // With vesta-persist on (M3), closing a pane/session only tears down the ghostty
            // surface → the vesta-attach relay EOFs and detaches; the shell keeps running
            // under vestad. Explicit kill is prefix-x / `vesta kill`, never Cmd-W.
            case "w":
                if shift {
                    ws.closeSession(ws.activeP, ws.activeS)
                } else if ws.activeTree.paneCount > 1 {
                    ws.activeTree.closeFocused()  // 1) close the pane
                } else if ws.totalSessions > 1 {
                    ws.closeSession(ws.activeP, ws.activeS)  // 2) close the session
                } else {
                    ctx.controller.window?.performClose(nil)  // 3) last one → close the window
                }
                return nil
            // ⌘F: in-terminal search (⌃⌘F is full screen — let that fall through)
            case "f" where !e.modifierFlags.contains(.control):
                ws.activeTree.focused?.startSearch()
                return nil
            // ⌘B: toggle sidebar
            case "b":
                ctx.controller.toggleSidebar()
                return nil
            // ⌘⇧P: command palette (searchable list of every built-in + Lua command)
            case "p" where shift:
                self.showCommandPalette()
                return nil
            // ⌘]/⌘[: focus next/prev pane within the active session
            case "]":
                ws.activeTree.focusNext()
                return nil
            case "[":
                ws.activeTree.focusPrev()
                return nil
            // ⌘T: new session in the active project (cwd = ~)
            case "t":
                ws.newSession(ws.activeP)
                return nil
            // ⌘}/⌘{: cycle sessions within the active project
            case "}":
                ws.nextSession()
                return nil
            case "{":
                ws.prevSession()
                return nil
            // ⌘1–9: select session n in the active project
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if let n = Int(e.charactersIgnoringModifiers ?? "") {
                    ws.selectSessionInActiveProject(n)
                }
                return nil
            // ⌘⇧Return: open browser at the focused session's first detected port, else about:blank
            case "\r" where shift:
                let tree = ws.activeTree
                let url =
                    ctx.detectedPort(tree).map { URL(string: "http://localhost:\($0)")! } ?? URL(
                        string: "about:blank")!
                tree.openBrowser(url: url)
                return nil
            default: return e
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
        case .splitVertical:
            _ = ws.activeTree.splitFocused(.vertical, cwd: ws.activeTree.focusedCwd)
        case .splitHorizontal:
            _ = ws.activeTree.splitFocused(.horizontal, cwd: ws.activeTree.focusedCwd)
        case .focusLeft, .focusUp: ws.activeTree.focusPrev()
        case .focusRight, .focusDown: ws.activeTree.focusNext()
        case .zoom: ws.activeTree.zoomFocused()
        case .newSession: ws.newSession(ws.activeP)
        case .nextSession: ws.nextSession()
        case .prevSession: ws.prevSession()
        case .rename: promptRenameActiveSession()
        // Detach: close the pane → relay EOFs → shell lives on under vestad.
        case .detach: ws.activeTree.closeFocused()
        // Kill: terminate the shell under vestad, then close the pane locally.
        case .kill: ws.activeTree.killFocusedSession()
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

/// Append config projects from `vesta-projects = ~/a, ~/b` into the workspace.
/// The home project (index 0) is already created by Workspace.init; config
/// projects are appended as collapsed + empty (lazy).
@MainActor
func loadProjects(_ settings: [String: String], into workspace: Workspace) {
    let raw =
        settings["vesta-projects"]?
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    let home = NSHomeDirectory()
    for raw in raw {
        let path = (raw as NSString).expandingTildeInPath
        guard path != home else { continue }  // don't duplicate the home project
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
