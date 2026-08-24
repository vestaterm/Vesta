# cmux-style Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flatten Vesta's Project→Sessions model into cmux-style flat workspaces with visual-only groups, make `+` create a terminal session instantly, and make post-reboot restore clean.

**Architecture:** The shared `SessionStore` holds a flat ordered `[WS]` (each wraps the existing `PaneTree`, which keeps splits/tabs inside a workspace) plus `[Group]` (visual only: name/color/collapsed, no cwd). Sidebar order = array order; a group renders at the position of its first member and members are kept contiguous. Persistence moves to windows.json v2 with a pure migration from v1/v0. Cold-restore (PR2) is daemon-side: a fresh shell whose scrollback ring was seeded from disk gets a reset+divider ingested into the ring, and `helloAck` grows an additive `resumed` flag.

**Tech Stack:** Swift 6 / AppKit, SwiftPM. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-24-cmux-workspaces-design.md`

## Global Constraints

- Plugins keep working: Lua events (`session-opened`, `session-closed`, `focus-changed`, `dir-changed`, `command-finished`) keep firing with the same names/payloads; `vesta project *` CLI verbs keep answering.
- Sidebar transparency/color customization untouched: do not change `glassSidebar`/`sidebarOpacity`/`vesta-surface`/theme plumbing in Chrome.swift.
- Sidebar order is user-defined: array order in the store IS the order; persisted via windows.json; migration preserves old order.
- Quitting the GUI never kills shells (vestad semantics unchanged); only `closeWorkspace`/`.kill` do.
- Build: `swift build` (must stay warning-clean enough to compile). Checks: `swift test` (MuxProtocolTests) and `.build/debug/vesta selfcheck` (runs all *SelfCheck functions — main.swift:8).
- Commits: no Claude attribution lines (user rule). One PR per section below; after each PR: build + selfcheck + commit + push (user's dev process).

---

# PR1 — Flatten: model + sidebar + `+` + persistence + migration

Branch: `workspaces-flatten`.

### Task 1: New model core in Tabs.swift

**Files:**
- Modify: `Sources/Vesta/Tabs.swift` (replaces `Proj`, `SessionStore`, `Workspace` internals, `snapshot()`, drag helpers; keep `PaneGlyph`, `SessionHeat`, `parseWindowsFile` seam)
- Test: same file — rewrite `workspaceSelfCheck()`

**Interfaces:**
- Consumes: existing `PaneTree` API: `paneID`, `paneIDs`, `name`, `setName(_:)`, `focusedCwd`, `focusedLabel`, `focusedPaneID`, `focusedPID`, `isDormant`, `materialize()`, `serializeLayout() -> [String: Any]`, `tailLines`, `applyTheme(_:)`, `rootView`, `focusActivePane()`, `closeFocused()`, `killFocusedSession()`; `MuxClient.kill(paneID:)`; `Worktree.add/remove/dirFor`; `TerminalPane.suppressExit(_:)`; `TailStore`.
- Produces (used by Tasks 2–8):

```swift
struct Group {                       // visual only — no cwd, no behavior
    var id: String                   // "g:<uuid>" or a migrated old project id
    var name: String
    var color: NSColor? = nil
    var collapsed: Bool = false
}

struct WS {                          // one sidebar row = one terminal session
    var tree: PaneTree
    var color: NSColor? = nil
    var groupID: String? = nil       // nil ⇒ top-level (ungrouped)
}

// Render DTOs (Equatable so the renderer can skip identical rebuilds):
struct SidebarWorkspace: Equatable {
    let label: String
    let active: Bool
    var index: Int                   // flat index into store.workspaces
    var ports: [Int] = []
    var dirty: Int = 0
    var attention: Bool = false
    var heat: SessionHeat = .none
    var heatAge: String? = nil
    var paneCount: Int = 1
    var focusedPaneID: String? = nil
    var tail: [String] = []
    var treeID: String = ""
    var layout: PaneGlyph? = nil
    var color: NSColor? = nil        // per-workspace tint (nil ⇒ accent)
    var branch: String? = nil        // git branch of the ws cwd (filled by WindowContext)
    var grouped: Bool = false        // render indented under a group header
}
struct SidebarGroup: Equatable {
    let name: String
    let collapsed: Bool
    var color: NSColor? = nil
    var id: String = ""
    var groupIndex: Int = 0          // index into store.groups
    var members: [SidebarWorkspace]
}
enum SidebarItem: Equatable {
    case workspace(SidebarWorkspace)
    case group(SidebarGroup)
}

@MainActor final class SessionStore {
    var workspaces: [WS] = []
    var groups: [Group] = []
    var broadcast: () -> Void = {}
    var renderNow: () -> Void = {}
    var lastActive: Int = 0
}

@MainActor final class Workspace {   // per-window view over the store
    let store: SessionStore
    var wss: [WS] { get set }        // proxies store.workspaces (like projs did)
    var groups: [Group] { get set }  // proxies store.groups
    private(set) var activeW: Int
    var activeTree: PaneTree         // wss[activeW].tree (clamped)

    init(theme: Theme, store: SessionStore, hydrateFrom: [String: Any]? = nil)

    // ops
    func newWorkspace(at cwd: String? = nil)      // nil ⇒ active ws focusedCwd ?? ~
    func selectWorkspace(_ i: Int)
    func closeWorkspace(_ i: Int)                 // kills daemon shells; last-one → replace with ~ ws
    func renameWorkspace(_ i: Int, _ name: String?)
    func setWorkspaceColor(_ i: Int, _ c: NSColor?)
    func newWorktreeWorkspace(from i: Int, branch: String, base: String? = nil)
    func nextWorkspace(); func prevWorkspace()
    func selectWorkspaceNumber(_ n: Int)          // 1-based (prefix digit keys)

    // groups (visual only; ≥1 member invariant — empty groups are deleted)
    func newGroupFromWorkspace(_ i: Int)          // group named after the ws label
    func moveToGroup(_ i: Int, groupID: String?)  // nil ⇒ ungroup; keeps members contiguous
    func renameGroup(_ g: Int, _ name: String)
    func setGroupColor(_ g: Int, _ c: NSColor?)
    func toggleGroupCollapsed(_ g: Int)
    func removeGroup(_ g: Int)                    // closes member workspaces
    func ungroup(_ g: Int)                        // members become top-level, group deleted

    // reorder (see pure helpers below)
    func moveTopLevel(from: Int, gap: Int, id: String)   // id = ws paneID or group id
    func moveMember(_ g: Int, from: Int, gap: Int, id: String)

    // render + persistence
    func snapshot() -> [SidebarItem]
    func serialize() -> [String: Any]             // v2 entry (Task 2)
    func hydrate(from win: [String: Any])         // v2 entry (Task 2)

    // Control.swift compat (keep working: list/tab/select/etc.)
    var active: Int { activeW }
    var tabs: [PaneTree] { wss.map(\.tree) }
    func newTab(cwd: String?)                     // = newWorkspace(at: cwd)
    func closeTab(); func closeTab(at i: Int); func selectTab(_ i: Int)
    func nextTab(); func prevTab()

    func hasAttention(_ tree: PaneTree) -> Bool
    func markAttention(_ tree: PaneTree)
    func applyTheme(_ t: Theme)
    func reconcile(preferLive: Bool); func mountLive(); func showFrozen(); func focusActive()
    var hostsLive: Bool
    nonisolated static func dropGap(midYs: [CGFloat], cursorY: CGFloat) -> Int      // unchanged
    nonisolated static func movedOrder(count: Int, from: Int, gap: Int) -> [Int]    // unchanged
    nonisolated static func replaceOnClose(totalSessions: Int) -> Bool               // unchanged
    nonisolated static func topLevelUnits(groupIDs: [String?]) -> [[Int]]            // NEW, pure
}
```

- [ ] **Step 1: Write the failing selfcheck first.** Replace the `Proj`-era parts of `workspaceSelfCheck()` with checks for the new pure logic (keep the existing dropGap/movedOrder blocks verbatim):

```swift
func workspaceSelfCheck() {
    // ── topLevelUnits: consecutive same-group indices fuse into one unit ──
    // wss groupIDs: [nil, "g1", "g1", nil, "g2"] → units [[0],[1,2],[3],[4]]
    let units = Workspace.topLevelUnits(groupIDs: [nil, "g1", "g1", nil, "g2"])
    assert(units == [[0], [1, 2], [3], [4]], "group members fuse into one top-level unit")
    assert(Workspace.topLevelUnits(groupIDs: []) == [], "empty store → no units")
    assert(Workspace.topLevelUnits(groupIDs: [nil, nil]) == [[0], [1]], "ungrouped are singletons")
    // Non-contiguous same-group ids DO NOT fuse (contiguity is an invariant the
    // move ops maintain; units are computed positionally):
    assert(Workspace.topLevelUnits(groupIDs: ["g1", nil, "g1"]) == [[0], [1], [2]],
           "units are positional — contiguity is the ops' job")

    // ── top-level reorder = movedOrder over units, then flatten ──
    let flat = Workspace.movedOrder(count: 4, from: 1, gap: 0).flatMap { units[$0] }
    assert(flat == [1, 2, 0, 3, 4], "moving the group block to the top carries both members")

    // ── replaceOnClose / dropGap / movedOrder: keep the existing assertions ──
    assert(Workspace.replaceOnClose(totalSessions: 1) == true, "last ws replaced not removed")
    assert(Workspace.replaceOnClose(totalSessions: 2) == false, "two ws: safe to remove")
    // (retain the whole existing dropGap + movedOrder blocks from the old selfcheck)
    print("workspaceSelfCheck OK")
}
```

- [ ] **Step 2: Run `swift build` to verify it fails** (topLevelUnits undefined).

- [ ] **Step 3: Rewrite the model.** Mechanics, mapped from the current code (line refs are pre-change):

  - Delete `struct Proj` (Tabs.swift:54), `SidebarProject`/`SidebarSession` (27–50); add the types from Interfaces above.
  - `SessionStore`: `projs` → `workspaces` + `groups`; `lastActive` becomes `Int`.
  - `Workspace.init` (121–171): empty pool ⇒ seed ONE workspace at `~` (`wss.append(WS(tree: makeTree(cwd: home)))`), `activeW = 0`. Live-pool path: clamp `activeW = min(max(store.lastActive,0), wss.count-1)`; a dormant ws needs no lazy-create (every ws always has a tree). Hydrate path unchanged in shape (calls `hydrate`).
  - `newWorkspace(at:)` replaces `newProject`/`addSession`/`newSession`:

```swift
func newWorkspace(at cwd: String? = nil) {
    let dir = cwd ?? activeTreeIfAny?.focusedCwd ?? NSHomeDirectory()
    let tree = makeTree(cwd: dir)
    wss.append(WS(tree: tree))          // top-level, end of list
    activeW = wss.count - 1
    showActive()
    luaFire("session-opened", tree.paneID)
}
// activeTreeIfAny: wss.indices.contains(activeW) ? wss[activeW].tree : nil
```

  - `closeWorkspace(_ i:)` = `closeSession` (315–363) with flat index: kill panes via `MuxClient.kill`, fire `session-closed`, worktree cleanup keyed on `worktreeBranch` (repo = the tree's own `focusedCwd` parent — store the repo path alongside the branch when creating: change `worktreeBranch` to `[ObjectIdentifier: (repo: String, branch: String)]`), `forget()`, replace-on-close when it's the last ws, else remove + fix `activeW` + delete the group if it just emptied.
  - `newWorktreeWorkspace(from:branch:base:)` = `newWorktreeSession` (219–233) with `repo = wss[i].tree.focusedCwd ?? NSHomeDirectory()`; the new ws joins the source ws's group (`groupID` copied) and records `(repo, branch)`.
  - Group ops:

```swift
func newGroupFromWorkspace(_ i: Int) {
    guard wss.indices.contains(i), wss[i].groupID == nil else { return }
    let g = Group(id: "g:\(UUID().uuidString)",
                  name: wss[i].tree.name ?? wss[i].tree.focusedLabel)
    groups.append(g)
    wss[i].groupID = g.id
    handleChange()
}

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
// remapActive: if activeW == moved { activeW = to } else adjust for the remove/insert shift.
// dropGroupIfEmpty(_ id: String?): removes groups[?] when no wss carries that id.
```

  - `ungroup(_ g:)`: set members' `groupID = nil` (they keep their positions), remove the group. `removeGroup(_ g:)`: `closeWorkspace` each member (iterate by paneID, re-find index each time — indices shift), group is dropped by `dropGroupIfEmpty`.
  - Reorder:

```swift
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

func moveTopLevel(from: Int, gap: Int, id: String) {
    let units = Self.topLevelUnits(groupIDs: wss.map(\.groupID))
    guard units.indices.contains(from) else { return }
    // identity guard: the unit's anchor is its first ws paneID, or the group id
    let anchor = units[from][0]
    let unitID = wss[anchor].groupID ?? wss[anchor].tree.paneID
    guard unitID == id else { return }
    let order = Self.movedOrder(count: units.count, from: from, gap: gap)
    guard order != Array(units.indices) else { return }
    let activeID = activeTreeIfAny?.paneID
    wss = order.flatMap { units[$0] }.map { wss[$0] }
    if let activeID { activeW = wss.firstIndex { $0.tree.paneID == activeID } ?? activeW }
    handleChange()
}

func moveMember(_ g: Int, from: Int, gap: Int, id: String) {
    guard groups.indices.contains(g) else { return }
    let span = wss.indices.filter { wss[$0].groupID == groups[g].id }  // contiguous
    guard span.indices.contains(from), wss[span[from]].tree.paneID == id else { return }
    let order = Self.movedOrder(count: span.count, from: from, gap: gap)
    guard order != Array(span.indices) else { return }
    let activeID = activeTreeIfAny?.paneID
    let reordered = order.map { wss[span[$0]] }
    for (k, idx) in span.enumerated() { wss[idx] = reordered[k] }
    if let activeID { activeW = wss.firstIndex { $0.tree.paneID == activeID } ?? activeW }
    handleChange()
}
```

  - `snapshot() -> [SidebarItem]`: walk `topLevelUnits`; a singleton ungrouped index → `.workspace(dto(i, grouped: false))`; a unit whose first index has a groupID → `.group(SidebarGroup(name:, collapsed:, color:, id:, groupIndex:, members: unit.map { dto($0, grouped: true) }))`. `dto(_:grouped:)` is the current per-session body of `snapshot()` (365–407) with: `label = tree.name ?? tree.focusedLabel` (no `si+1.` prefix — flat list, names disambiguate), worktree label `⎇ branch` kept, `index: i`, `color: wss[i].color`, `treeID = tree.paneID`. Collapsed groups still produce `members` (the renderer skips rendering them but count/heat aggregation may use them).
  - Keep `attention`/`attentionAt`/`forget`/`wire`/`showActive`/`mountLive`/`showFrozen`/`reconcile`/`applyTheme`/`handleChange` logic as-is, only re-pointed at `wss[...].tree` (e.g. `applyTheme` loops `for w in wss { w.tree.applyTheme(t) }`; `showActive` stores `store.lastActive = activeW`).
  - Compat shims (420–482): `active { activeW }`, `tabs { wss.map(\.tree) }`, `newTab(cwd:)` = `newWorkspace(at: cwd)`, `closeTab/selectTab/nextTab/prevTab` operate on the flat list directly (the old flat-index walk collapses to plain index arithmetic).
  - Delete: `toggleExpand`, `setProjectDir`, `renameProject` (→`renameGroup`), `setProjectColor` (→ two color ops), `removeProject` (→`removeGroup`), `newProject` (→`newWorkspace`), `newSession`, `addSession`, `moveProject`/`moveSession` (→ the two new move ops), `appendProject`, `saveProjects`/`restorePersisted`/`projectsFile` (projects.json retired — Task 2), `nextSession`/`prevSession`/`selectSessionInActiveProject` (→ `nextWorkspace`/`prevWorkspace`/`selectWorkspaceNumber`).

- [ ] **Step 4:** `swift build` — expect FAILURES ONLY in consumer files (Chrome/WindowContext/main/Control/PickerOverlay/OnboardingOverlay etc.), none in Tabs.swift. Do not fix consumers yet (Tasks 3–8). Verify Tabs.swift itself is clean: `swift build 2>&1 | grep "Tabs.swift" | grep -c error` → `0`.

- [ ] **Step 5: Commit** `feat: flat workspace + visual group model (consumers updated next)` — note: repo won't build until Task 8; keep all PR1 commits on the branch and only push/PR when green.

### Task 2: windows.json v2 + migration (projects.json retired)

**Files:**
- Modify: `Sources/Vesta/Tabs.swift` (`serialize`, `hydrate`, `windowsFormatVersion`, `parseWindowsFile`, new `migrateWindowEntry`), `Sources/Vesta/main.swift` (loadProjects — see step 3)
- Test: `windowsFormatSelfCheck()` in Tabs.swift

**Interfaces:**
- Produces: `windowsFormatVersion = 2`; entry shape:

```json
{
  "groups":     [{"id": "g:…", "name": "halo", "color": "#8ec7a8", "collapsed": false}],
  "workspaces": [{"paneID": "…", "cwd": "/x", "name": "build", "color": "#…",
                  "groupID": "g:…", "layout": {…PaneTree.serializeLayout…}}],
  "activeWorkspace": 0,
  "frame": "…"
}
```
- `func migrateWindowEntry(_ entry: [String: Any]) -> [String: Any]` — pure; v0/v1 project entry → v2 entry. `parseWindowsFile` returns entries already migrated to v2 shape.

- [ ] **Step 1: Write failing selfcheck cases** (append to `windowsFormatSelfCheck`):

```swift
// v1 → v2 migration: 1-session project → bare workspace; ≥2 → group + members.
let v1entry: [String: Any] = [
    "projects": [
        ["id": "home", "name": "home", "path": "/tmp",
         "sessions": [["cwd": "/tmp", "paneID": "P1", "name": "solo"]]],
        ["id": "u:x", "name": "halo", "path": "/h", "color": "#8ec7a8",
         "sessions": [["cwd": "/h", "paneID": "P2"], ["cwd": "/h/sub", "paneID": "P3"]]],
        ["id": "cfg:/lazy", "name": "lazy", "path": "/lazy", "sessions": []],
    ],
    "activeProject": 1, "activeSession": 1,
]
let m = migrateWindowEntry(v1entry)
let mws = m["workspaces"] as! [[String: Any]]
let mgs = m["groups"] as! [[String: Any]]
assert(mws.count == 4, "1 + 2 + 1 lazy = 4 workspaces")
assert(mgs.count == 1 && mgs[0]["name"] as? String == "halo", "only multi-session project → group")
assert(mws[0]["paneID"] as? String == "P1" && mws[0]["groupID"] == nil, "solo project → bare ws")
assert(mws[0]["name"] as? String == "solo", "session name survives")
assert(mws[1]["groupID"] as? String == mgs[0]["id"] as? String, "member carries group id")
assert(mws[2]["groupID"] as? String == mgs[0]["id"] as? String, "second member too")
assert(mws[1]["color"] as? String == "#8ec7a8", "project color lands on member workspaces")
assert(mws[3]["cwd"] as? String == "/lazy" && (mws[3]["layout"] as? [String: Any])?["cwd"] as? String == "/lazy",
       "lazy config project → one dormant ws at its path")
assert(m["activeWorkspace"] as? Int == 2, "active (p=1,s=1) → flat index 2")
// Already-v2 entries pass through migrateWindowEntry unchanged.
let v2entry: [String: Any] = ["groups": [], "workspaces": [["paneID": "Q", "cwd": "/q"]],
                              "activeWorkspace": 0]
assert((migrateWindowEntry(v2entry)["workspaces"] as? [[String: Any]])?.count == 1, "v2 idempotent")
// parseWindowsFile: v2 file round-trips; v1 file arrives migrated.
let v2file = try! JSONSerialization.data(withJSONObject: ["version": 2, "windows": [v2entry]])
assert(parseWindowsFile(v2file).version == 2, "v2 parses")
let v1file = try! JSONSerialization.data(withJSONObject: ["version": 1, "windows": [v1entry]])
let pm = parseWindowsFile(v1file)
assert((pm.windows.first?["workspaces"] as? [[String: Any]])?.count == 4, "v1 entries auto-migrate")
```
Keep every existing v0/v1/garbage assertion, adapting expectations: legacy entries now come out of `parseWindowsFile` in v2 shape (the "legacy cwd-only string sessions" case must yield workspaces with a synthesized paneID and the cwd).

- [ ] **Step 2:** `swift build` → fails (`migrateWindowEntry` undefined).

- [ ] **Step 3: Implement.**
  - `windowsFormatVersion = 2`. `parseWindowsFile`: after decoding, map every entry through `migrateWindowEntry` (which returns v2 entries untouched — detect by presence of a `workspaces` key).
  - `migrateWindowEntry`: for each old project: 0 sessions → one ws `["paneID": UUID, "cwd": path, "layout": ["paneID": <same>, "cwd": path], "name": <project name if != basename>… ]` (bare, no group; carry project `color`); 1 session → bare ws (session's paneID/cwd/layout/name, color from project); ≥2 → emit group `["id": <old project id>, "name":, "color":, "collapsed": !(expanded ?? true)]` and one member ws per session with `groupID`. Flatten `activeProject`/`activeSession` → `activeWorkspace` by counting.
  - `serialize()`: emit the v2 shape from `groups` + `wss` (per-ws: `paneID`, `cwd` (= `tree.focusedCwd ?? layout cwd`), optional `name`, optional `color` hex via `hexString`, optional `groupID`, `layout: tree.serializeLayout()`), `activeWorkspace: activeW`.
  - `hydrate(from:)`: read v2 shape. Reuse the existing `usableDir`/`fixDirs` helpers verbatim (fallback = the ws's own saved `cwd`, then `~`). Build every ws dormant via `makeDormant(layout:name:)`; restore `color` (`ghosttyColor`), `groupID` (drop ids with no matching group). Restore `groups` first (id/name/color/collapsed). Invariant: ≥1 ws (else seed a `~` ws); clamp `activeWorkspace`. Preserve array order exactly — this is the user's sidebar order.
  - Delete `saveProjects`/`restorePersisted`/`projectsFile` and all callers. `projects.json` on disk is left in place (harmless; its names/colors already live in windows.json v1 which the migration consumes).
  - main.swift `restoreWindows` (654–693): unchanged flow; per-extra-window selection becomes `extra.workspace.selectWorkspace(entry["activeWorkspace"] as? Int ?? 0)`. The `.v0` backup courtesy now also applies to v1: on `version < windowsFormatVersion`, write `windows.json.v\(version)` once.
  - `loadProjects(_:into:)` (main.swift:1472) → rename `seedConfigWorkspaces(_:into:)`: for each `vesta-projects` path, if no existing ws has that cwd (`ws.tree.focusedCwd ?? dormant layout cwd`), append a dormant top-level ws at that path (use `makeDormant(layout: ["paneID": UUID().uuidString, "cwd": path])` via a small `appendConfigWorkspace(path:)` on Workspace). Call it in WindowContext.init in place of `loadProjects` — but now ALWAYS (not only when the store was empty), guarded by the dedup check, so newly-added config paths appear after a restore. Remove the `restorePersisted()` call.

- [ ] **Step 4:** `swift build 2>&1 | grep -c "Tabs.swift.*error"` → 0. Consumers still broken — expected.

- [ ] **Step 5: Commit** `feat: windows.json v2 — flat workspaces + groups, with v0/v1 migration`.

### Task 3: Sidebar rendering (Chrome.swift)

**Files:**
- Modify: `Sources/Vesta/Chrome.swift`

**Interfaces:**
- Consumes: `[SidebarItem]`, `SidebarWorkspace`, `SidebarGroup` (Task 1).
- Produces: `func setSidebar(_ items: [SidebarItem])` (replaces `setProjects`); new closure signatures on `VestaWindowController.init`:

```swift
onSelectWorkspace:   (Int) -> Void          // flat ws index
onCloseWorkspace:    (Int) -> Void
onNewWorkspace:      () -> Void             // titlebar + (no panel)
onToggleGroup:       (Int) -> Void          // group index
onRenameWorkspace:   (Int, String?) -> Void
onRenameGroup:       (Int, String) -> Void
onSetWorkspaceColor: (Int, NSColor?) -> Void
onSetGroupColor:     (Int, NSColor?) -> Void
onRemoveGroup:       (Int) -> Void
onGroupFromWorkspace: (Int) -> Void
onMoveToGroup:       (Int, String?) -> Void  // ws index, group id (nil = ungroup)
onNewWorktree:       (Int, String) -> Void   // ws index, branch
onReorderTopLevel:   (Int, Int, String) -> Void   // from-unit, gap, unit id
onReorderMember:     (Int, Int, Int, String) -> Void  // group idx, from, gap, paneID
```

- [ ] **Step 1: Rework rendering.**
  - `setProjects` (341–386) → `setSidebar(_ items: [SidebarItem])`; `lastProjects`/`pendingProjects` become `[SidebarItem]`. Iterate items: `.group(g)` → `makeGroupRow(g)` then, when `!g.collapsed`, one `makeWorkspaceRow(w)` per member (trailing constant −8 as today); `.workspace(w)` → `makeWorkspaceRow(w)` at full width (trailing 0). Keep custom spacings (3 after header before members, 10 between top-level items).
  - Header: `sectionLabel("PROJECTS"…)` → `"WORKSPACES"`; `projCount` shows total workspace count (`items.reduce` over members + singles); tooltip "workspaces".
  - `makeGroupRow(_ g: SidebarGroup)` = current `makeProjectRow` (588–667) minus the hover `+`/count-swap slot (keep the always-visible member-count label), minus branch tooltip; `▾/▸` from `!g.collapsed`; click → `onToggleGroup(g.groupIndex)`; `row.tag1 = g.groupIndex`; `row.identity = g.id`; `row.isSessionRow = false`; context menu = `makeGroupMenu` (Task 5). Tint = `g.color ?? theme.accent`.
  - `makeWorkspaceRow(_ w: SidebarWorkspace)` = current `makeSessionRow` (673–833) with: single index (`row.tag1 = w.index`, `tag2` unused), click → `onSelectWorkspace(w.index)`, × → `onCloseWorkspace(w.index)`, double-click rename → `onRenameWorkspace(w.index, …)` (keep `promptRenameSession` but re-key it), heat/tail/meta/ports/dirty/schematic all unchanged, plus: when `w.color != nil` use it for the active-border/rail tint in place of `theme.accent` (spec: per-workspace color), and append a dim `⎇ branch` to the meta run when `w.branch != nil` and the ws is grouped==false (top-level ws shows its own branch; the old per-project branch tooltip is gone).
  - `row.identity = w.treeID`; `row.isSessionRow = true` for member rows AND top-level ws rows — rename the field `isMemberRow`? No: keep `isSessionRow` name but set it `w.grouped` (it selects the drag lane — Task 4). Top-level ws rows get `isSessionRow = false` so they reorder in the top-level lane.
  - "no projects" empty label (361) → "no workspaces" (only reachable transiently).

- [ ] **Step 2: Titlebar.** In `buildTitlebarAccessory` (1328–1454): delete the `folder` button + `folderLeading` + `onChangeProjectDir` wiring and the `dirLabel`'s dependence on it (`dirLabel` now leads from `plus.trailingAnchor + 10`); `plus` tooltip → "New workspace (⌘N)", action → `onNewWorkspace()`. Simplify `syncTitlebarLayout` (1459–1466): drop `folderLeading`. `setDir` unchanged.

- [ ] **Step 3:** `swift build 2>&1 | grep -c "Chrome.swift.*error"` → 0 (drag code still referencing old lanes will be fixed in Task 4 — if it errors, stub the lane changes now and finish there).

- [ ] **Step 4: Commit** `feat: sidebar renders flat workspaces with visual group headers`.

### Task 4: Drag lanes + drop-on-header grouping (Chrome.swift)

**Files:**
- Modify: `Sources/Vesta/Chrome.swift` (835–1068 drag block)

- [ ] **Step 1: Lanes.** `laneUnits(for:)` (866–890): the "project lane" branch already groups a divider row with the session rows that follow — that IS the top-level lane (group header + members = one unit; each top-level ws row = its own unit since `isSessionRow == false` rows start a unit). Verify: a top-level ws row must start AND terminate its own unit — the current code appends following `isSessionRow` rows to the last unit, which is correct because only group headers are followed by member rows. The member lane (`isSessionRow == true`) filters siblings by `tag1`… but member rows' `tag1` is now the flat ws index. Add `var groupIdx = -1` to `TaggedRow`; member rows set it from the enclosing `SidebarGroup.groupIndex`; the member lane filters `$0.groupIdx == row.groupIdx`.
  - `endDrag` commit dispatch (1035–1036): member rows → `onReorderMember(row.groupIdx, from, gap, row.identity)` where `from` = the member's position within its lane (compute as `sib.firstIndex { $0 === row }` — store it on the row at `beginDrag` as `dragUnitFrom`, already available); top-level rows → `onReorderTopLevel(dragUnitFrom, gap, row.identity)`.
- [ ] **Step 2: Drop-on-header = join group.** In `endDrag`'s commit path, before the reorder dispatch: if the dragged row is a TOP-LEVEL WORKSPACE row (`!row.isSessionRow && row.tag2 == 0` — give ws rows `tag2 = 1` and group headers `tag2 = 0`? No: add `var isGroupHeader = false` to `TaggedRow` instead) and the cursor's final window-point lies inside a group header row's frame (hit-test `projectsStack.arrangedSubviews` for a `TaggedRow` with `isGroupHeader == true` containing the point), call `onMoveToGroup(row.tag1, <that header's identity>)` instead of `onReorderTopLevel`. Dragging a group header onto another header does nothing special (plain reorder).
- [ ] **Step 3:** `swift build` → Chrome.swift clean. Manual verification deferred to Task 8.
- [ ] **Step 4: Commit** `feat: sidebar drag — top-level lane, member lane, drop-on-header joins group`.

### Task 5: Context menus (Chrome.swift)

**Files:**
- Modify: `Sources/Vesta/Chrome.swift` (1094–1192)

- [ ] **Step 1:** `makeProjectMenu` → two builders:
  - `makeWorkspaceMenu(_ w: SidebarWorkspace, groups: [(id: String, name: String)])` on every ws row: Rename… (`promptRenameSession` re-keyed → `onRenameWorkspace`), Color ▸ (presets + reset → `onSetWorkspaceColor(w.index, …)`), New worktree workspace… (`promptWorktree` → `onNewWorktree(w.index, branch)`), separator, New group from workspace → `onGroupFromWorkspace(w.index)` (only when ungrouped), Move to group ▸ (one item per existing group → `onMoveToGroup(w.index, id)`; plus "Remove from group" when grouped → `onMoveToGroup(w.index, nil)`), separator, Close Workspace → existing confirm alert (“closes running programs”) → `onCloseWorkspace(w.index)`.
  - `makeGroupMenu(_ g: SidebarGroup)`: Rename… → `onRenameGroup`, Color ▸ → `onSetGroupColor`, Ungroup (keep workspaces) → new closure `onUngroup: (Int) -> Void`, separator, Remove Group… → `confirmRemove` (text: “closes the group's N workspaces and any running programs in them”) → `onRemoveGroup(g.groupIndex)`.
  - `setSidebar` passes the group list (id+name pairs collected from items) into `makeWorkspaceMenu`.
- [ ] **Step 2:** `swift build` → clean file. **Commit** `feat: workspace + group context menus (group from / move to / ungroup)`.

### Task 6: WindowContext rewiring

**Files:**
- Modify: `Sources/Vesta/WindowContext.swift`

- [ ] **Step 1:** Re-wire the controller closures (61–104): map every new closure name to the Task 1 op (`onNewWorkspace: { [weak ws] in ws?.newWorkspace() }` — NO NSOpenPanel; delete both panel blocks). Delete `onChangeProjectDir`.
- [ ] **Step 2:** `pollAttention` (139–167): `workspace.projs.flatMap(\.sessions)` → `workspace.wss.map(\.tree)`.
- [ ] **Step 3:** `renderSidebar` (171–192): build `var items = workspace.snapshot()`; per-item, fill `ports/dirty` from `metaCache` and `tail` when `VestaConfig.shared.sidebarTails`, and `branch` from `branchCache[cwd-of-ws]` (branch now keyed by each top-level ws's `focusedCwd`, populated in `fullRefresh` for the ACTIVE ws only — same cache-miss batch pattern, collecting `workspace.wss.compactMap { $0.tree.isDormant ? nil : $0.tree.focusedCwd }`). Call `controller.setSidebar(items)`. (Mutating members inside the enum: map items through a small `fill(_ w: inout SidebarWorkspace)` helper applied in both enum cases.)
- [ ] **Step 4:** `swift build` → WindowContext clean. **Commit** `feat: + creates a workspace instantly — folder pickers removed`.

### Task 7: main.swift + Control.swift + remaining consumers

**Files:**
- Modify: `Sources/Vesta/main.swift`, `Sources/Vesta/Control.swift`, `Sources/Vesta/OnboardingOverlay.swift`, `Sources/Vesta/PickerOverlay.swift` (+ anything `swift build` still flags: Menu.swift, PrefixMode.swift, LuaRuntime.swift…)

- [ ] **Step 1: main.swift.** `fullState` (619–643): emit `"workspaces"` (flat: index/name/cwd/panes/paneIDs/group) + `"groups"`, AND keep a `"projects"` key for plugin compat: one pseudo-project per top-level unit (group → its members as `sessions`; bare ws → a project with itself as the only session, `name` = ws label, `path` = ws cwd). `onCommandDone` loop (781): iterate `store.workspaces.map(\.tree)`. `scheduleBackgroundMaterialize` (962): `store.workspaces.map(\.tree).first { $0.isDormant }`. Onboarding `addProject:` closure (990) → `ws.newWorkspace(at: path)`. Keybind cases (1440–1447): `.newSession` → `ws.newWorkspace()`, `.nextSession/.prevSession` → `next/prevWorkspace()`; `promptRenameActiveSession` → `ws.renameWorkspace(ws.activeW, field.stringValue)`. `pendingOpenDirs` drain (881) already uses `newTab(cwd:)` — works via the shim. Prefix digit-select (search `selectSessionInActiveProject` callers) → `selectWorkspaceNumber`.
- [ ] **Step 2: Control.swift.** Verb mapping (keep every verb answering — plugins):
  - `list`/`tab`/`capture`/`send-keys`/`pane` etc. flow through the kept shims (`tabs`, `active`, `selectTab`…) — fix compile errors mechanically (`ws.projs` walks → `ws.wss`).
  - `sessions [--json] [--project <name>]`: records gain `"group"` (group name or absent) and keep `"project"` as an alias of it (bare ws → its own label); `--project` filters by group name OR bare-ws label. `id` becomes the flat index as a string (`"3"`); accept the old `"p.s"` form in `select`-style inputs by mapping through groups (see next).
  - `select`: one int → `selectWorkspace(i)`. Two ints `(p, s)` (legacy) → resolve top-level unit `p`, member `s` within it, via `topLevelUnits`; out of range → error.
  - `project` verb: `new [PATH] [--name X]` → `newWorkspace(at: PATH ?? caller cwd)` then optional `renameWorkspace`; `rename <name>` → active ws grouped ? `renameGroup` : `renameWorkspace`; `color` → same split; `remove` → active ws grouped ? `removeGroup` : `closeWorkspace(activeW)`; `dir` → `["ok": false, "error": "project dir was removed — each workspace owns its cwd (cd in the shell)"]`. Update the help text block (528–545) accordingly.
- [ ] **Step 3: Sweep.** `swift build` and fix every remaining consumer the compiler flags (OnboardingOverlay's addProject label text → "add a workspace"; PickerOverlay session lists → flat workspace list; `luaFire` call sites unchanged). Iterate until `swift build` succeeds with zero errors.
- [ ] **Step 4: Run checks:** `swift test` → PASS; `.build/debug/vesta selfcheck` → all `OK` lines including the new workspace/migration assertions.
- [ ] **Step 5: Commit** `feat: flatten consumers — control verbs, state, keybinds, onboarding`.

### Task 8: Live verification + migration smoke test

- [ ] **Step 1:** Back up state: `cp ~/Library/Application\ Support/vesta/windows.json ~/Library/Application\ Support/vesta/windows.json.bak 2>/dev/null || true`.
- [ ] **Step 2:** `./make-app.sh debug` and launch the built app. Verify with the real windows.json: old projects appear as groups (multi-session) / bare workspaces (single), order preserved, sessions reattach to live shells.
- [ ] **Step 3:** Exercise: `+` creates a ws in the active cwd instantly; rename; color; group-from-workspace; move-to-group; drag reorder top-level and within a group; drop ws on group header; collapse group; close ws; quit + relaunch → order + grouping + selection restored; `vesta sessions --json`, `vesta select 2`, `vesta project new /tmp` all answer.
- [ ] **Step 4:** Restore backup if anything mangled state; fix and repeat.
- [ ] **Step 5: Commit** any fixes, push branch, open PR1 (`gh pr create`), run the user's review flow.

---

# PR2 — Cold restore: `resumed` flag + reboot divider + scrollback default-on

Branch: `workspaces-cold-restore` (after PR1 merges).

### Task 9: helloAck `resumed` flag (additive, no version bump)

**Files:**
- Modify: `Sources/VestaMux/MuxProtocol.swift`, `Sources/vestad/Daemon.swift`, `Sources/vesta-attach/main.swift`
- Test: `Tests/VestaTests/MuxProtocolTests.swift` + `muxProtocolSelfCheck`

**Interfaces:**
- Produces: `ServerFrame.helloAck(version: Int, resumed: Bool)`. Wire: one trailing byte after the version u32; decoders that read only the u32 (old clients) are unaffected — same additive pattern as hello's v4 `cwd`. Decode absent byte → `resumed: true` (old daemons only ever reattach-or-silently-fork; assume live).

- [ ] **Step 1: Failing test** (MuxProtocolTests + mirror in `muxProtocolSelfCheck`):

```swift
func testHelloAckResumedRoundTrip() {
    for resumed in [true, false] {
        var buf = encode(ServerFrame.helloAck(version: 5, resumed: resumed))
        XCTAssertEqual(decodeServerFrame(from: &buf), .helloAck(version: 5, resumed: resumed))
        XCTAssertTrue(buf.isEmpty)
    }
    // Old-daemon frame (version only, no trailing byte) decodes as resumed: true.
    var legacy = Data()
    var p = Data()
    // u32 BE version 5, framed under tag 0x11 — build via the public encoder minus the byte:
    // simplest: hand-frame [len=5][0x11][00 00 00 05]
    legacy.append(contentsOf: [0, 0, 0, 5, 0x11, 0, 0, 0, 5])
    XCTAssertEqual(decodeServerFrame(from: &legacy), .helloAck(version: 5, resumed: true))
    _ = p
}
```

- [ ] **Step 2:** `swift test` → FAIL (case signature).
- [ ] **Step 3: Implement.** MuxProtocol.swift: case `helloAck(version: Int, resumed: Bool = true)`; encode appends `p.append(resumed ? 1 : 0)` after the version; decode: `let v = Int(r.u32()); let res = r.remaining() > 0 ? r.byte() == 1 : true`. Daemon.swift: `.hello` sends `helloAck(version: muxProtocolVersion, resumed: existingSessionFound)` (compute `let resumed = sessions[paneID] != nil` before the create-branch); `.subscribe` ack sends `resumed: true`. vesta-attach: pattern `case let .helloAck(version, _)`.
- [ ] **Step 4:** `swift test` + `.build/debug/vesta selfcheck` → PASS. **Commit** `feat(mux): helloAck reports whether the pty was resumed or freshly forked`.

### Task 10: Reboot divider — seeded fresh shells announce the restart

**Files:**
- Modify: `Sources/vestad/Session.swift`, `Sources/vestad/Daemon.swift`

**Interfaces:**
- Produces: `Session.seededFromLog: Bool` (true when `seedRingAndOpenLog` loaded bytes); `Daemon.coldRestoreBanner(cwd: String?) -> Data`.

- [ ] **Step 1:** Session.swift: `private(set) var seededFromLog = false`; set `seededFromLog = true` inside `seedRingAndOpenLog` when the file had bytes (`ring` seeded).
- [ ] **Step 2:** Daemon.swift `.hello`, fresh-session branch (after `sessions[paneID] = fresh`): 

```swift
// Cold restore (machine rebooted / daemon died): the ring was reseeded from disk but
// the shell is brand new. Stamp a reset + divider INTO the ring so every future
// replay shows history, then a visible cut, then the fresh prompt — instead of
// half-drawn TUI state with no process behind it.
if fresh.seededFromLog {
    fresh.ingest(Daemon.coldRestoreBanner(cwd: cwd))
}
```

```swift
static func coldRestoreBanner(cwd: String?) -> Data {
    let dir = cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~"
    // ?1049l leaves a stale alt screen; SGR reset clears colors mid-sequence output left on.
    let s = "\r\n\u{1b}[?1049l\u{1b}[0m\u{1b}[2m── vesta: session restarted — new shell in \(dir) ──\u{1b}[0m\r\n"
    return Data(s.utf8)
}
```

- [ ] **Step 3: Verify manually** (no unit seam for forkpty): with `vesta-persist-scrollback = true`, open a session, generate output, `pkill -x vestad` **plus** kill the shell (`pkill -f "zsh -l"` scoped: get the pid via `vesta`'s pids or `ps`), reopen the pane → old scrollback, divider line, fresh prompt in the same cwd, no alt-screen garbage. Also verify a plain daemon-upgrade reattach (live shell) shows NO divider.
- [ ] **Step 4: Commit** `feat(vestad): cold-restored sessions replay history behind a restart divider`.

### Task 11: `vesta-persist-scrollback` defaults on

**Files:**
- Modify: `Sources/vestad/Daemon.swift:44`, `Sources/Vesta/Settings.swift:155-157`

- [ ] **Step 1:** Daemon: `boolConfig("vesta-persist-scrollback", default: true)` — and the value parser must now honor explicit `false`/`0` (it already returns the parsed value when the key exists; only the default flips). Update the comment (no longer "strictly opt-in"; note 0600 + explicit `= false` opt-out).
- [ ] **Step 2:** Settings.swift: `settingBool("vesta-persist-scrollback", default: true)`; tip → "Mirror scrollback to disk (0600) so sessions survive a reboot. Turn off if terminal output may hold secrets."
- [ ] **Step 3:** `swift build` + `swift test` + selfcheck → PASS. Manual: remove the key from config, restart daemon, confirm `~/Library/Application Support/vesta` (MuxPaths) `sessions/*.log` files appear; set `= false`, restart daemon, confirm they don't.
- [ ] **Step 4: Commit**, push, open PR2, review flow.

---

# PR3 — CLI aliases + docs + PARKED note

Branch: `workspaces-cli-docs` (after PR2 merges).

### Task 12: `ws` / `group` verbs

**Files:**
- Modify: `Sources/Vesta/Control.swift`

- [ ] **Step 1:** Add `"ws"` and `"group"` to `controlVerbs` (Control.swift:11). `ws new [PATH] [--name X] | rename <name> | color <#hex|none> | close` → thin calls to `newWorkspace/renameWorkspace/setWorkspaceColor/closeWorkspace` on the active ws. `group new <name> | rename <name> | color <…> | ungroup | remove` → active ws's group (error `"active workspace is not in a group"` when none; `group new` = `newGroupFromWorkspace(activeW)` then rename). Update the help text; mark `project` as a legacy alias there.
- [ ] **Step 2:** Verify: `vesta ws new /tmp --name scratch`, `vesta group new stuff`, `vesta group rename things`, `vesta ws close`. **Commit** `feat(cli): ws/group verbs — project kept as legacy alias`.

### Task 13: Docs + PARKED

**Files:**
- Modify: `README.md`, `docs/roadmap.md`, `docs/writing-plugins.md` (state shape note), `PARKED.md`
- Also: locate the live halo-site repo (check `~/Desktop/halo-workspace/` siblings) and update its matching pages (user's standing auto-update-docs rule — no need to ask).

- [ ] **Step 1:** Rewrite the projects/sidebar sections: workspaces + visual groups, `+` behavior, reboot restore semantics (divider, scrollback default-on + how to opt out), windows.json v2 note, `ws`/`group` CLI, `vesta-projects` now seeds workspaces. `writing-plugins.md`: document `vesta state`'s `workspaces`/`groups` keys and that `projects` is a compat view.
- [ ] **Step 2:** PARKED.md: add “Lite mode (`vesta-lite`)” entry: ghostty-like chrome-free window; hook points = early-out in `buildContent`/`makeSidebar` (Chrome.swift), suppress `snapshot()`/tails/`scheduleBackgroundMaterialize`; plugins still load.
- [ ] **Step 3: Commit**, push, open PR3, review flow.
