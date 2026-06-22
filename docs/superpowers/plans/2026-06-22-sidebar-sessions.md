# Halo — sidebar sessions, resizable sidebar, ghostty-style titlebar, visible git

Fixes 8 complaints: (1) no top tabs — tabs live nested under projects in the
sidebar; (2) titlebar pwd no longer clipped by sidebar; (3) sidebar drag-resizable;
(4) can create new projects; (5) sessions/projects default to `~` (no folder dialog);
(6) titlebar shows the focused program's title like ghostty (e.g. "claude"); (7) git
status visible in the sidebar footer; (8) sessions closable.

## Global constraints (binding)
- Built on real libghostty; keep ghostty config color sync intact (theme.background /
  theme.accent everywhere — never re-hardcode #161719).
- Match the locked mockup aesthetic: uniform surface, white@0.07 hairlines, near-gray
  mint accent, slim rows. Mockup at `mockup.html` (projects + nested "sessions").
- ponytail ultra: laziest working solution, stdlib/native first, shortest diff. One
  runnable self-check per file with non-trivial logic (extend the existing
  `*SelfCheck()` funcs; `swift run halo selfcheck` must stay green).
- Swift 6 strict concurrency: UI types stay `@MainActor`.

## Model (Workspace owns projects; a project owns sessions)
A **session** = an existing `PaneTree` (today's "tab", unchanged internally).

```swift
struct Proj { var name: String; var path: String; var sessions: [PaneTree]; var expanded: Bool }
// Workspace:
private(set) var projs: [Proj]
private(set) var activeP = 0
private(set) var activeS = 0
var activeTree: PaneTree { projs[activeP].sessions[activeS] }
```

Behaviour:
- **Launch:** index 0 is always a home project `Proj(name:"~", path: home, sessions:[session@~], expanded:true)`, active. Config `halo-projects` are appended as collapsed projects with `sessions:[]` (lazy — created on first expand). This is the "open from ~ by default" fix.
- `toggleExpand(p)`: if `projs[p].sessions` is empty, create one session at `projs[p].path`, expand, make active; else flip `expanded`.
- `newSession(p)`: append a session with **cwd = home (`~`)** (user's explicit choice), expand, make it active.
- `newProject()`: append `Proj(name:"~", path: home, sessions:[session@~], expanded:true)`, make active.
- `selectSession(p,s)` / `closeSession(p,s)`: standard. Never let the global session count reach 0 — if the last remaining session anywhere is closed, immediately create a fresh `~` session in that project (mirror today's "never close the last tab").
- `container` = the body only. **Delete the top `TabBar`** (class + all wiring).

Snapshot the sidebar renders from (Workspace builds it; git branch filled by the AppDelegate, may be nil):
```swift
struct SidebarSession { let label: String; let active: Bool }
struct SidebarProject { let name: String; var branch: String?; let expanded: Bool; let active: Bool; let sessions: [SidebarSession] }
func snapshot() -> [SidebarProject]
```
Callbacks Workspace exposes (set by AppDelegate, invoked by Chrome): `onSelectSession`, `onCloseSession`, `onNewSession`, `onToggleExpand`, `onNewProject` — each `(Int,...)->Void`; plus existing `onChange`.

Keybinds (main.swift): ⌘T `newSession(activeP)`, ⌘W close active session, ⌘}/⌘{ cycle sessions within active project, ⌘1–9 select session in active project, ⌘D/⌘⇧D split, ⌘B toggle sidebar, ⌘] focus next pane (unchanged).

## Task A — Workspace project/session model + remove top tabs (Tabs.swift, main.swift)
Rewrite `Workspace` to the model above; delete `TabBar`/`ChipView`. Update
`main.swift`: `loadProjects` feeds config projects; launch session at `~`; rewire
keybinds to session ops; AppDelegate wires the five callbacks (stub bodies that call
Workspace + `refresh()` for now — Chrome rendering lands in Task B/C). Extend
`tabsSelfCheck()` → `workspaceSelfCheck()`: assert launch has home proj + 1 session at
home; `newSession` adds at home & activates; `closeSession` never drops to 0;
`newProject` appends & activates; `toggleExpand` on empty creates a session at the
project path. Must compile + selfcheck green.

## Task B — Sidebar: nested projects/sessions + resizable drag + titlebar (Chrome.swift)
- Replace the static projects stack with a render driven by `setProjects([SidebarProject])`
  (called on every `onChange`). Each project row: caret ▸/▾ (expanded), pdot, name,
  dim branch label (mockup). Click row → `onToggleExpand`/select. Per-project trailing
  `+` → `onNewSession(p)`. Nested session rows (indented ~14px): label + hover/active
  `×` → `onCloseSession(p,s)`; click → `onSelectSession(p,s)`. Active session = brighter
  text + the 2px accent left bar (reuse today's selected styling). `PROJECTS` header
  gets a trailing `+` → `onNewProject`.
- **Resizable sidebar:** make `sidebarWidth` constant draggable — a ~5px grab strip on
  the sidebar's right edge (an `NSView` with a resize cursor + mouseDragged adjusting
  the constraint). Clamp `[160, 420]`. In-memory only. Keep ⌘B toggle working with the
  current width.
- **Titlebar:** widen the accessory host so the dir/title no longer truncates at the
  sidebar edge (tabs are gone from the top strip → full width is free; cap near the
  window width, not `sbWidth-80`). Keep toggle+folder; `setDir` still renders the label.
- Wire all callbacks through the existing `init` (extend it with the five closures,
  defaulting to `{}`). Extend `chromeSelfCheck()` to build with a couple of
  `SidebarProject`s, call `setProjects`, toggle sidebar, assert no crash.

## Task C — ghostty-style titlebar title + visible git footer (main.swift, Git.swift)
- Titlebar shows the focused pane's **live program title** like ghostty: in
  `AppDelegate.refresh()`, set the titlebar to `focused.title` when non-empty (e.g.
  "claude"), else fall back to `name / cwd`. (TerminalPane already tracks `title` via the
  SET_TITLE action + `setLiveTitle`.) Add `controller.setTitle(_:)` or reuse `setDir`.
- Git footer: confirm `Git.status(cwd)` result is shown in the sidebar status line for
  the focused session's cwd, in mockup form (` <branch> ↑n · k dirty`). Make the footer
  always show the branch line when in a repo; show just `▌ normal` when not. Keep the
  off-main shell-out. (Root cause of "no git": prior default cwd wasn't a repo.)
- Build (`swift build`) + `swift run halo selfcheck` green; launch and screenshot-verify.
