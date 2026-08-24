import AppKit

// MARK: - Sidebar data types (consumed by Task B's Chrome rendering)

/// Card heat — paint only, never geometry: what a BACKGROUND session wants you to know.
enum SessionHeat { case none, ok, warn, need }

/// Compact split topology for the session card's schematic — the REAL layout (nested
/// splits + ratios + which pane is focused), not the old count-based grid.
// Not an `indirect enum` — that trips an opaque swiftc "circular reference" in this
// module; the children Array supplies the boxing instead, factories keep call sites terse.
struct PaneGlyph: Equatable {
    enum Kind: Equatable {
        case leaf(focused: Bool)
        case split(vertical: Bool, ratio: Double)
    }
    var kind: Kind
    var children: [PaneGlyph] = []   // exactly [a, b] for .split; empty for .leaf

    static func leaf(focused: Bool) -> PaneGlyph { .init(kind: .leaf(focused: focused)) }
    static func split(vertical: Bool, ratio: Double, a: PaneGlyph, b: PaneGlyph) -> PaneGlyph {
        .init(kind: .split(vertical: vertical, ratio: ratio), children: [a, b])
    }
}

// Equatable so the renderer can skip rebuilds when a 1Hz tick changed nothing (idle CPU).
/// One sidebar row = one workspace = one terminal session (flat model, cmux-style).
struct SidebarWorkspace: Equatable {
    let label: String
    let active: Bool
    var index: Int                    // flat index into store.workspaces — the click/drag key
    var ports: [Int] = []   // listening TCP ports of the workspace's foreground process tree
    var dirty: Int = 0      // uncommitted changes in the workspace's cwd (git status --porcelain)
    var attention: Bool = false  // bell/desktop-notification fired while ws was not active
    var heat: SessionHeat = .none
    var heatAge: String? = nil       // "3m" since the heat event (bell / command exit)
    var paneCount: Int = 1
    var focusedPaneID: String? = nil  // tail lookup key (filled by WindowContext)
    var tail: [String] = []           // last cleaned output lines (TailStore)
    var treeID: String = ""           // stable PaneTree.paneID — drag-reorder identity guard
    var layout: PaneGlyph? = nil      // real split topology (multi-pane workspaces only)
    var color: NSColor? = nil         // per-workspace tint (nil ⇒ accent)
    var branch: String? = nil         // git branch of the ws cwd (filled by WindowContext)
    var grouped: Bool = false         // render indented under a group header
}

/// A group header row: purely visual packaging over a contiguous run of workspaces.
struct SidebarGroup: Equatable {
    let name: String
    let collapsed: Bool
    var color: NSColor? = nil    // custom group tint (nil ⇒ accent)
    var id: String = ""          // stable Group.id — drag-reorder identity guard
    var groupIndex: Int = 0      // index into store.groups
    var members: [SidebarWorkspace]  // var so WindowContext can inject ports/dirty per member
}

/// The sidebar is a flat list of these — a bare workspace row, or a group with its members.
enum SidebarItem: Equatable {
    case workspace(SidebarWorkspace)
    case group(SidebarGroup)
}

// MARK: - Workspace/Group model

/// A visual-only grouping of workspaces. Deliberately has NO cwd and NO behavior: it
/// does not own sessions, it does not supply a default directory, it cannot be empty
/// (the ops delete a group the moment its last member leaves). Membership is recorded
/// on the workspace (`WS.groupID`); the group's members are the contiguous run of
/// workspaces carrying its id, so sidebar order stays a single flat array.
struct Group {
    var id: String               // "g:<uuid>", or a migrated old project id
    var name: String
    var color: NSColor? = nil    // custom tint, set via the sidebar context menu
    var collapsed: Bool = false
}

/// One sidebar row: a terminal session (PaneTree owns the live ghostty surfaces) plus
/// its presentation state. Flat — there is no project layer above it.
struct WS {
    var tree: PaneTree
    var color: NSColor? = nil    // custom tint, set via the sidebar context menu
    var groupID: String? = nil   // nil ⇒ top-level (ungrouped)
}

/// App-owned shared workspace pool: holds the workspaces (PaneTrees own the live ghostty
/// surfaces) + the visual groups, so they survive any window closing. Every window's
/// Workspace reads/writes `workspaces` here, and `broadcast` refreshes all open windows —
/// that's what makes the sidebar global. Per-window state (active selection, the
/// display body) stays in Workspace, so each window can view a DIFFERENT workspace.
@MainActor
final class SessionStore {
    /// Array order IS the sidebar order (user-defined, persisted). Group members are a
    /// contiguous run — the move ops maintain that invariant.
    var workspaces: [WS] = []
    var groups: [Group] = []
    var broadcast: () -> Void = {}
    /// Immediate sidebar render in every window, no debounce. Fired by handleChange —
    /// i.e. DISCRETE USER MUTATIONS only (toggle/select/close/new/rename/reorder).
    /// Deliberately NOT part of broadcast: onFocusChange also broadcasts, and that path
    /// fires on program-driven title/cwd escapes (OSC 0/2/7) at unbounded frequency —
    /// the per-session viewport capture in renderSidebar must stay behind the ≤1s
    /// debounce for those.
    var renderNow: () -> Void = {}
    // Last active workspace index — survives closing all windows, so reopening
    // returns to where you were instead of spawning a fresh workspace.
    var lastActive: Int = 0
}

/// Per-window view over the shared workspace pool: a flat, ordered list of workspaces
/// (one terminal session each) plus the visual groups drawn over it.
/// Container = body only — the active workspace's rootView, swapped on change.
/// No top tab strip.
@MainActor
final class Workspace {
    let store: SessionStore
    var wss: [WS] { get { store.workspaces } set { store.workspaces = newValue } }
    var groups: [Group] { get { store.groups } set { store.groups = newValue } }
    private(set) var activeW = 0

    // Workspace→worktree tag: keyed by PaneTree instance identity to avoid touching
    // PaneTree's init. The repo is captured at creation — a flat workspace has no
    // project above it to ask for one at close time.
    private var worktreeBranch: [ObjectIdentifier: (repo: String, branch: String)] = [:]

    // Workspaces that have rung the bell / fired a desktop notification while not active.
    private var attention: Set<ObjectIdentifier> = []
    private var attentionAt: [ObjectIdentifier: Date] = [:]   // when it rang (card heat age)
    private weak var lastShown: PaneTree?   // previously-active workspace (outgoing markSeen)

    /// True if `tree` has pending attention (bell/notification while backgrounded).
    /// Exposed for `sessions --json` / `pane status`.
    func hasAttention(_ tree: PaneTree) -> Bool { attention.contains(ObjectIdentifier(tree)) }

    /// The active workspace's tree. Clamped: the pool always holds ≥1 workspace (init
    /// seeds one, closeWorkspace replaces rather than empties), so this cannot miss.
    var activeTree: PaneTree { wss[min(max(activeW, 0), wss.count - 1)].tree }

    /// Same, but safe DURING init/hydrate, when the pool can still be momentarily empty.
    private var activeTreeIfAny: PaneTree? { wss.indices.contains(activeW) ? wss[activeW].tree : nil }

    let container = NSView()
    private let body = NSView()
    private var theme: Theme

    init(theme: Theme, store: SessionStore, hydrateFrom: [String: Any]? = nil) {
        self.store = store
        self.theme = theme
        container.wantsLayer = true
        // Terminal glass: an opaque backing here would block ghostty's background-opacity
        // from ever reaching the desktop — un-paint it when the terminal is translucent.
        container.layer?.backgroundColor = VestaConfig.shared.terminalOpacity < 1
            ? NSColor.clear.cgColor : theme.background.cgColor

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
        // populates wss (dormant) + calls showActive.
        if wss.isEmpty, let win = hydrateFrom,
           (win["workspaces"] as? [[String: Any]])?.isEmpty == false {
            hydrate(from: win)
            return
        }

        if wss.isEmpty {
            // First window for an empty pool: seed ONE workspace at ~. Config paths are
            // appended as extra dormant workspaces by the config seeding pass.
            wss.append(WS(tree: makeTree(cwd: NSHomeDirectory())))
            activeW = 0
        } else {
            // Reusing a live pool (e.g. reopened after closing all windows): return to the
            // last active workspace — clamped — never spawn a duplicate. Every workspace
            // always owns a tree, so there is nothing to lazy-create here.
            activeW = min(max(store.lastActive, 0), wss.count - 1)
        }
        showActive()
    }

    // MARK: - Workspace operations

    /// Open a new workspace at the end of the list, top-level (never inside a group —
    /// grouping is an explicit user act). Defaults to the active workspace's cwd, so
    /// ⌘N continues where you were standing.
    func newWorkspace(at cwd: String? = nil) {
        let dir = cwd ?? activeTreeIfAny?.focusedCwd ?? NSHomeDirectory()
        let tree = makeTree(cwd: dir)
        wss.append(WS(tree: tree))
        activeW = wss.count - 1
        showActive()
        luaFire("session-opened", tree.paneID)
    }

    func selectWorkspace(_ i: Int) {
        guard wss.indices.contains(i) else { return }
        activeW = i
        let k = ObjectIdentifier(activeTree)
        attention.remove(k); attentionAt[k] = nil
        showActive()
        luaFire("focus-changed", activeTree.paneID)
    }

    func renameWorkspace(_ i: Int, _ name: String?) {
        guard wss.indices.contains(i) else { return }
        wss[i].tree.setName(name)   // setName fires onFocusChange → save + render
        handleChange()
    }

    func setWorkspaceColor(_ i: Int, _ c: NSColor?) {
        guard wss.indices.contains(i) else { return }
        wss[i].color = c
        handleChange()
    }

    /// Branch off workspace `i`: a git worktree of ITS cwd, opened as a new workspace that
    /// joins `i`'s group (so a group stays the natural home for a feature's branches).
    func newWorktreeWorkspace(from i: Int, branch: String, base: String? = nil) {
        guard wss.indices.contains(i) else { return }
        let repo = wss[i].tree.focusedCwd ?? NSHomeDirectory()
        let gid = wss[i].groupID
        do {
            let dir = try Worktree.add(repo: repo, branch: branch, base: base)
            newWorkspace(at: dir)                                   // appends + activates + showActive
            worktreeBranch[ObjectIdentifier(activeTree)] = (repo, branch)
            // moveToGroup keeps members contiguous (append landed it at the very end).
            if gid != nil { moveToGroup(activeW, groupID: gid) } else { handleChange() }
        } catch {
            NSSound.beep()
            // surface the git error without crashing
            let a = NSAlert(); a.messageText = "Couldn't create worktree"
            a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    /// Drop all identity-keyed state for a workspace being removed. Without this a
    /// later PaneTree that reuses the freed heap address inherits a stale
    /// worktree label or a phantom attention ring. (metaCache is evicted in
    /// AppDelegate.renderSidebar, which can see the live workspace set.)
    private func forget(_ tree: PaneTree) {
        let k = ObjectIdentifier(tree)
        worktreeBranch[k] = nil
        attention.remove(k)
        attentionAt[k] = nil   // else an address-reusing tree inherits a stale heat age
    }

    /// Returns true when the last workspace is about to be removed — replace instead of deleting.
    nonisolated static func replaceOnClose(totalSessions: Int) -> Bool { totalSessions <= 1 }

    func closeWorkspace(_ i: Int) {
        guard wss.indices.contains(i) else { return }
        let closing = wss[i].tree
        // Closing a workspace KILLS its daemon shell — the sidebar is the single source of
        // truth, so there are no orphaned detached sessions. (Window-close still only
        // detaches, since it doesn't drop the PaneTree from the shared store.)
        closing.paneIDs.forEach { TerminalPane.suppressExit($0); MuxClient.kill(paneID: $0) }
        luaFire("session-closed", closing.paneID)
        // If this was a worktree workspace, best-effort remove its worktree dir
        // off-main (non-force → dirty worktrees are left intact, never destroyed).
        if let wt = worktreeBranch[ObjectIdentifier(closing)] {
            let repo = wt.repo
            let dir = Worktree.dirFor(repo: repo, branch: wt.branch)
            DispatchQueue.global(qos: .utility).async { try? Worktree.remove(repo: repo, dir: dir) }
        }
        // Forget identity-keyed state for the workspace being removed/replaced.
        forget(closing)
        let gone = wss[i].groupID
        // Never let the global workspace count reach 0.
        if Workspace.replaceOnClose(totalSessions: wss.count) {
            // Replace with a fresh top-level ~ workspace rather than leaving 0.
            wss[i] = WS(tree: makeTree(cwd: NSHomeDirectory()))
            activeW = i
            dropGroupIfEmpty(gone)
            showActive()
            return
        }
        wss.remove(at: i)
        // Removing at/before the active row shifts the selection down one; clamp after.
        if activeW >= i { activeW = max(0, activeW - 1) }
        activeW = min(activeW, wss.count - 1)
        dropGroupIfEmpty(gone)
        showActive()
    }

    // MARK: - Group operations (visual only — a group never owns a session)

    /// Wrap a top-level workspace in a new group named after it. Already-grouped
    /// workspaces are a no-op (move them with moveToGroup instead).
    func newGroupFromWorkspace(_ i: Int) {
        guard wss.indices.contains(i), wss[i].groupID == nil else { return }
        let g = Group(id: "g:\(UUID().uuidString)",
                      name: wss[i].tree.name ?? wss[i].tree.focusedLabel)
        groups.append(g)
        wss[i].groupID = g.id
        handleChange()
    }

    /// Move workspace `i` into `groupID` (nil ⇒ ungroup). Re-seats the row so a group's
    /// members stay CONTIGUOUS — that contiguity is what makes a group one sidebar block.
    func moveToGroup(_ i: Int, groupID: String?) {
        guard wss.indices.contains(i), wss[i].groupID != groupID else { return }
        let old = wss[i].groupID
        var ws = wss.remove(at: i)
        ws.groupID = groupID
        // Insert at the end of the target group's span, or at the end of the list.
        let at = groupID.flatMap { gid in wss.lastIndex(where: { $0.groupID == gid }).map { $0 + 1 } }
            ?? wss.count
        wss.insert(ws, at: at)
        remapActive(moved: i, to: at)
        dropGroupIfEmpty(old)
        handleChange()
    }

    func renameGroup(_ g: Int, _ name: String) {
        guard groups.indices.contains(g) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[g].name = trimmed
        handleChange()
    }

    func setGroupColor(_ g: Int, _ c: NSColor?) {
        guard groups.indices.contains(g) else { return }
        groups[g].color = c
        handleChange()
    }

    func toggleGroupCollapsed(_ g: Int) {
        guard groups.indices.contains(g) else { return }
        groups[g].collapsed.toggle()
        handleChange()
    }

    /// Close every workspace in the group; the group itself is dropped once empty.
    func removeGroup(_ g: Int) {
        guard groups.indices.contains(g) else { return }
        let gid = groups[g].id
        // Indices shift as each member closes (and the last close REPLACES rather than
        // removes) — re-find by paneID instead of walking a stale index list.
        for id in wss.filter({ $0.groupID == gid }).map(\.tree.paneID) {
            if let i = wss.firstIndex(where: { $0.tree.paneID == id }) { closeWorkspace(i) }
        }
        dropGroupIfEmpty(gid)   // covers a memberless group (shouldn't exist, but it's one line)
    }

    /// Dissolve the group: members become top-level where they stand, group deleted.
    func ungroup(_ g: Int) {
        guard groups.indices.contains(g) else { return }
        let gid = groups[g].id
        for i in wss.indices where wss[i].groupID == gid { wss[i].groupID = nil }
        groups.remove(at: g)
        handleChange()
    }

    /// Delete a group once no workspace carries its id — the ≥1-member invariant.
    private func dropGroupIfEmpty(_ id: String?) {
        guard let id, !wss.contains(where: { $0.groupID == id }) else { return }
        groups.removeAll { $0.id == id }
    }

    /// Keep the active selection on the SAME workspace across a remove+insert of `moved`.
    private func remapActive(moved from: Int, to: Int) {
        if activeW == from { activeW = to; return }
        var a = activeW
        if a > from { a -= 1 }   // the remove shifted it down
        if a >= to { a += 1 }    // the insert shifted it back up
        activeW = a
    }

    // MARK: - Render snapshot

    func snapshot() -> [SidebarItem] {
        Self.topLevelUnits(groupIDs: wss.map(\.groupID)).flatMap { unit -> [SidebarItem] in
            // A workspace whose groupID has no Group (shouldn't happen — hydrate drops
            // dangling ids) still renders, just as plain top-level rows.
            guard let gid = wss[unit[0]].groupID,
                  let gi = groups.firstIndex(where: { $0.id == gid }) else {
                return unit.map { .workspace(dto($0, grouped: false)) }
            }
            // Collapsed groups still carry their members: the renderer hides the rows, but
            // the header aggregates their count/heat.
            return [.group(SidebarGroup(name: groups[gi].name, collapsed: groups[gi].collapsed,
                                        color: groups[gi].color, id: gid, groupIndex: gi,
                                        members: unit.map { dto($0, grouped: true) }))]
        }
    }

    private func dto(_ i: Int, grouped: Bool) -> SidebarWorkspace {
        let tree = wss[i].tree
        // Flat list: names disambiguate, so no "1." sibling prefix. Worktree tag wins.
        var label = tree.name ?? tree.focusedLabel
        if let wt = worktreeBranch[ObjectIdentifier(tree)] { label = "⎇ \(wt.branch)" }
        let oid = ObjectIdentifier(tree)
        let isActive = i == activeW
        let attn = attention.contains(oid)
        // Heat: waiting-for-you (bell) beats last-command ✓/✗; the ACTIVE workspace
        // carries none (you're looking at it), and exits are cleared on select
        // (markSeen) so heat always means "unseen news".
        var heat: SessionHeat = .none
        var heatAt: Date? = nil
        if attn {
            heat = .need; heatAt = attentionAt[oid]
        } else if !isActive, !tree.isDormant, let pid = tree.focusedPaneID,
                  let ex = TailStore.shared.exitState(pid) {
            heat = ex.code == 0 ? .ok : .warn; heatAt = ex.at
        }
        let age: String? = heatAt.map {
            let m = Int(Date().timeIntervalSince($0) / 60)
            return m < 1 ? "now" : (m < 60 ? "\(m)m" : "\(m / 60)h")
        }
        let paneCount = tree.paneCount
        let serialized = paneCount > 1 ? tree.serializeLayout() : nil
        return SidebarWorkspace(label: label, active: isActive, index: i,
                                attention: attn, heat: heat, heatAge: age,
                                paneCount: paneCount,
                                focusedPaneID: tree.isDormant ? nil : tree.focusedPaneID,
                                treeID: tree.paneID,
                                // Real topology for the schematic. Dormant workspaces
                                // focus their first leaf on materialize — mirror that.
                                layout: serialized.map { PaneTree.layoutGlyph(
                                    $0,
                                    focusedPaneID: tree.isDormant
                                        ? PaneTree.firstLeafID($0)
                                        : tree.focusedPaneID) },
                                color: wss[i].color,
                                grouped: grouped)
    }

    // MARK: - Compat shims for Control.swift (do NOT remove until Control.swift is updated)

    /// The index of the active workspace (for `list` command).
    var active: Int { activeW }

    /// Flat list of all PaneTrees (for `list` command's tab count).
    var tabs: [PaneTree] { wss.map(\.tree) }

    func newTab(cwd: String?) { newWorkspace(at: cwd) }

    func closeTab() { closeWorkspace(activeW) }
    func closeTab(at i: Int) { closeWorkspace(i) }
    func selectTab(_ i: Int) { selectWorkspace(i) }
    func nextTab() { nextWorkspace() }
    func prevTab() { prevWorkspace() }

    // MARK: - Window-state persistence (this window's workspaces + groups)

    /// Snapshot for windows.json: the flat workspace list (each with its full split
    /// `layout` — topology + per-leaf paneID/cwd — so splits restore intact), the visual
    /// groups, and the active index. Live processes/scrollback can't be restored — each
    /// leaf reopens as a fresh shell at its cwd.
    /// ponytail: provisional v2 writer — Task 2 owns the versioned format + v0/v1 migration.
    func serialize() -> [String: Any] {
        let groupsData: [[String: Any]] = groups.map { g in
            var d: [String: Any] = ["id": g.id, "name": g.name, "collapsed": g.collapsed]
            if let c = g.color { d["color"] = hexString(c) }
            return d
        }
        let wsData: [[String: Any]] = wss.map { w in
            var d: [String: Any] = ["paneID": w.tree.paneID,
                                    "cwd": w.tree.focusedCwd ?? NSHomeDirectory(),
                                    "layout": w.tree.serializeLayout()]
            if let nm = w.tree.name { d["name"] = nm }
            if let c = w.color { d["color"] = hexString(c) }
            if let g = w.groupID { d["groupID"] = g }
            return d
        }
        return ["groups": groupsData, "workspaces": wsData, "activeWorkspace": activeW]
    }

    /// Replace the launch state with a saved window snapshot. Robust: a leaf cwd that no
    /// longer exists falls back to the workspace's own saved cwd, then ~. Always leaves
    /// ≥1 workspace. Array order is preserved verbatim — it IS the user's sidebar order.
    func hydrate(from win: [String: Any]) {
        guard let wsData = win["workspaces"] as? [[String: Any]], !wsData.isEmpty else { return }
        // Tear down the default state this Workspace built in init.
        wss.forEach { forget($0.tree) }
        wss.removeAll()
        groups.removeAll()

        for gd in (win["groups"] as? [[String: Any]] ?? []) {
            guard let id = gd["id"] as? String else { continue }
            groups.append(Group(id: id,
                                name: gd["name"] as? String ?? "group",
                                color: (gd["color"] as? String).flatMap { ghosttyColor($0) },
                                collapsed: gd["collapsed"] as? Bool ?? false))
        }

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

        for d in wsData {
            // Every restored workspace is built DORMANT (persisted layout only). The one
            // the window will display materializes at showActive() below; the rest stay
            // data until first activation — no surfaces, no daemon attach at launch.
            let cwd = d["cwd"] as? String ?? NSHomeDirectory()
            // Preferred: a saved split layout (topology + per-leaf paneID/cwd). Fallback:
            // flat cwd/paneID → a single-leaf layout (serializeLayout echoes it back).
            let layout: [String: Any]
            if let saved = d["layout"] as? [String: Any],
               saved["a"] != nil || saved["paneID"] != nil || saved["browser"] != nil {
                layout = saved
            } else {
                layout = ["paneID": d["paneID"] as? String ?? UUID().uuidString, "cwd": cwd]
            }
            // A groupID with no restored group would render an orphan header — drop it.
            let gid = (d["groupID"] as? String).flatMap { id in
                groups.contains { $0.id == id } ? id : nil
            }
            wss.append(WS(tree: makeDormant(layout: fixDirs(layout, fallback: cwd),
                                            name: d["name"] as? String),
                          color: (d["color"] as? String).flatMap { ghosttyColor($0) },
                          groupID: gid))
        }

        // Invariant: ≥1 workspace.
        if wss.isEmpty { wss.append(WS(tree: makeTree(cwd: NSHomeDirectory()))) }
        activeW = min(max(0, win["activeWorkspace"] as? Int ?? 0), wss.count - 1)
        showActive()
    }

    // MARK: - Cycle workspaces

    func nextWorkspace() {
        guard !wss.isEmpty else { return }
        selectWorkspace((activeW + 1) % wss.count)
    }

    func prevWorkspace() {
        guard !wss.isEmpty else { return }
        selectWorkspace((activeW - 1 + wss.count) % wss.count)
    }

    /// 1-based select (the prefix digit keys count sidebar rows from 1).
    func selectWorkspaceNumber(_ n: Int) { selectWorkspace(n - 1) }

    // MARK: - Drag-reorder (sidebar)

    /// Number of row midpoints sitting ABOVE the cursor (window coords, y-up) — the
    /// insertion "gap" index (0…count) the sidebar drag drops into. Pure; selfchecked.
    nonisolated static func dropGap(midYs: [CGFloat], cursorY: CGFloat) -> Int {
        midYs.filter { $0 > cursorY }.count
    }

    /// Reordered [oldIndex] list after lifting the element at `from` and dropping it at
    /// insertion gap `gap` (0…count, computed with the dragged row still present, so
    /// gap==from and gap==from+1 both collapse to a no-op). Pure; selfchecked.
    nonisolated static func movedOrder(count: Int, from: Int, gap: Int) -> [Int] {
        var order = Array(0..<count)
        guard order.indices.contains(from) else { return order }
        let insertAt = min(max(gap > from ? gap - 1 : gap, 0), order.count - 1)
        let m = order.remove(at: from)
        order.insert(m, at: insertAt)
        return order
    }

    /// The top-level rows: each ungrouped workspace is its own unit, and each CONTIGUOUS
    /// run of same-group workspaces fuses into one unit (a group drags as one block).
    /// Purely positional — keeping members contiguous is the move ops' job. Pure; selfchecked.
    nonisolated static func topLevelUnits(groupIDs: [String?]) -> [[Int]] {
        var units: [[Int]] = []
        for (i, gid) in groupIDs.enumerated() {
            if let gid, let last = units.last, let li = last.last, groupIDs[li] == gid {
                units[units.count - 1].append(i)
            } else {
                units.append([i])
            }
        }
        return units
    }

    /// Move a top-level row (a bare workspace, or a whole group block) from unit index
    /// `from` to drop-gap `gap`. Order is RESTORED from windows.json (hydrate keeps array
    /// order). `id` is the identity captured at drag start — the workspace's paneID, or the
    /// group's id: the store can mutate mid-drag (another window, `vesta kill`), so a
    /// shifted index aborts as a no-op.
    func moveTopLevel(from: Int, gap: Int, id: String) {
        let units = Self.topLevelUnits(groupIDs: wss.map(\.groupID))
        guard units.indices.contains(from) else { return }
        let anchor = units[from][0]
        let unitID = wss[anchor].groupID ?? wss[anchor].tree.paneID
        guard unitID == id else { return }
        let order = Self.movedOrder(count: units.count, from: from, gap: gap)
        guard order != Array(units.indices) else { return }   // no-op drop
        let activeID = activeTreeIfAny?.paneID
        wss = order.flatMap { units[$0] }.map { wss[$0] }
        // Indices moved wholesale — re-find the active row by identity.
        if let activeID { activeW = wss.firstIndex { $0.tree.paneID == activeID } ?? activeW }
        handleChange()   // renders immediately (handleChange → store.renderNow)
    }

    /// Reorder a workspace WITHIN group `g` from `from` to drop-gap `gap` (indices are
    /// positions in the group's span, not the flat list). `id` is the dragged tree's paneID
    /// captured at drag start — a store that shifted mid-drag no longer matches, no-op.
    func moveMember(_ g: Int, from: Int, gap: Int, id: String) {
        guard groups.indices.contains(g) else { return }
        let span = wss.indices.filter { wss[$0].groupID == groups[g].id }   // contiguous
        guard span.indices.contains(from), wss[span[from]].tree.paneID == id else { return }
        let order = Self.movedOrder(count: span.count, from: from, gap: gap)
        guard order != Array(span.indices) else { return }   // no-op drop
        let activeID = activeTreeIfAny?.paneID
        let reordered = order.map { wss[span[$0]] }
        for (k, idx) in span.enumerated() { wss[idx] = reordered[k] }
        if let activeID { activeW = wss.firstIndex { $0.tree.paneID == activeID } ?? activeW }
        handleChange()
    }

    // MARK: - Private helpers

    /// Mark a background workspace as needing attention (driven by the prompt-return
    /// poller in AppDelegate — a background command finished). No-op for the active
    /// workspace (you're already looking at it).
    func markAttention(_ tree: PaneTree) {
        guard tree !== activeTreeIfAny else { return }
        let k = ObjectIdentifier(tree)
        attentionAt[k] = attentionAt[k] ?? Date()
        // Only a state CHANGE re-renders — a process spamming bells doesn't get an
        // undebounced render per \a once its ring is already lit.
        if attention.insert(k).inserted { handleChange() }
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
            // Only ring if this workspace isn't the one you're looking at.
            if tree !== self.activeTreeIfAny {
                let k = ObjectIdentifier(tree)
                self.attentionAt[k] = self.attentionAt[k] ?? Date()
                // Bell spam is free after the first ring (see markAttention).
                if self.attention.insert(k).inserted { self.handleChange() }
            }
        }
        return tree
    }

    private func showActive() {
        store.lastActive = activeW   // remember for reopen-after-close
        // Outgoing session first: exits that finished while it was ACTIVE were watched —
        // they must not light up as "unseen" heat the moment you switch away.
        if let prev = lastShown, prev !== activeTree { TailStore.shared.markSeen(prev.paneIDs) }
        lastShown = activeTree
        mountLive()
        let cleared = ObjectIdentifier(activeTree)                // clear ring for the focused session
        attention.remove(cleared); attentionAt[cleared] = nil
        TailStore.shared.markSeen(activeTree.paneIDs)             // its ✓/✗ heat is seen now
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
        container.layer?.backgroundColor = VestaConfig.shared.terminalOpacity < 1
            ? NSColor.clear.cgColor : t.background.cgColor
        for w in wss { w.tree.applyTheme(t) }
    }

    private func handleChange() {
        // Shared pool changed → refresh every window's sidebar + persist (AppDelegate
        // wires store.broadcast). One path, so all windows stay in sync.
        store.broadcast()
        // handleChange only ever runs from a discrete user action — render the click's
        // result this frame instead of riding refresh()'s ≤1s debounce.
        store.renderNow()
    }
}

// MARK: - Self-check

/// Pure data-model checks that work without a running NSApp / ghostty.
/// Called from the `selfcheck` exit path; does NOT create PaneTree or TerminalPane.
func workspaceSelfCheck() {
    // ── topLevelUnits: consecutive same-group indices fuse into one unit ──────
    // wss groupIDs: [nil, "g1", "g1", nil, "g2"] → units [[0],[1,2],[3],[4]]
    let units = Workspace.topLevelUnits(groupIDs: [nil, "g1", "g1", nil, "g2"])
    assert(units == [[0], [1, 2], [3], [4]], "group members fuse into one top-level unit")
    assert(Workspace.topLevelUnits(groupIDs: []) == [], "empty store → no units")
    assert(Workspace.topLevelUnits(groupIDs: [nil, nil]) == [[0], [1]], "ungrouped are singletons")
    // Non-contiguous same-group ids DO NOT fuse (contiguity is an invariant the
    // move ops maintain; units are computed positionally):
    assert(Workspace.topLevelUnits(groupIDs: ["g1", nil, "g1"]) == [[0], [1], [2]],
           "units are positional — contiguity is the ops' job")

    // ── top-level reorder = movedOrder over units, then flatten ───────────────
    let flat = Workspace.movedOrder(count: 4, from: 1, gap: 0).flatMap { units[$0] }
    assert(flat == [1, 2, 0, 3, 4], "moving the group block to the top carries both members")

    // ── closeWorkspace invariant: replaceOnClose is the real decision function ─
    assert(Workspace.replaceOnClose(totalSessions: 1) == true, "last ws replaced not removed")
    assert(Workspace.replaceOnClose(totalSessions: 2) == false, "two ws: safe to remove")

    // ── Drag-reorder: dropGap counts midpoints above the cursor (window y-up) ──────
    // Three rows at y = 90 (top), 60, 30 (bottom).
    let midYs: [CGFloat] = [90, 60, 30]
    assert(Workspace.dropGap(midYs: midYs, cursorY: 100) == 0, "cursor above all → gap 0 (top)")
    assert(Workspace.dropGap(midYs: midYs, cursorY: 75)  == 1, "cursor between row0/row1 → gap 1")
    assert(Workspace.dropGap(midYs: midYs, cursorY: 45)  == 2, "cursor between row1/row2 → gap 2")
    assert(Workspace.dropGap(midYs: midYs, cursorY: 10)  == 3, "cursor below all → gap 3 (bottom)")

    // ── Drag-reorder: movedOrder — gap==from and gap==from+1 are both no-ops ───────
    assert(Workspace.movedOrder(count: 4, from: 1, gap: 1) == [0, 1, 2, 3], "self gap → no-op")
    assert(Workspace.movedOrder(count: 4, from: 1, gap: 2) == [0, 1, 2, 3], "self+1 gap → no-op")
    assert(Workspace.movedOrder(count: 4, from: 0, gap: 2) == [1, 0, 2, 3], "move top down one slot")
    assert(Workspace.movedOrder(count: 4, from: 0, gap: 4) == [1, 2, 3, 0], "move top to bottom")
    assert(Workspace.movedOrder(count: 4, from: 3, gap: 1) == [0, 3, 1, 2], "move bottom up")
    assert(Workspace.movedOrder(count: 4, from: 3, gap: 0) == [3, 0, 1, 2], "move bottom to top")
    assert(Workspace.movedOrder(count: 1, from: 0, gap: 0) == [0], "single element is inert")

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
