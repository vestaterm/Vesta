# cmux-style workspaces

Date: 2026-08-24
Status: approved

## Goal

Replace the two-level Project → Sessions model with cmux's flat model: each
sidebar row is a **workspace** (one terminal session rooted at a cwd, with
splits/tabs inside), optionally collected into **visual-only groups**. The
titlebar `+` creates a workspace immediately — no folder picker. After a
reboot, workspaces come back clean under the same name in the same directory.

Reference: cmux (github.com/manaflow-ai/cmux) — no project concept; sidebar =
workspaces; Workspace Groups are name/icon/color + collapse only; restore
survives reboot by rebuilding layout + cwds + best-effort scrollback with
fresh shells.

## Hard constraints (user-set)

- **Plugins keep working as-is.** Lua API and events are not changed; where a
  verb or event named "project" exists, it keeps functioning (remapped, see
  Compat).
- **Sidebar transparency/color customization stays** exactly as it is today.
- **Sidebar order is user-defined and persisted.** Drag-reorder of workspaces
  and groups survives app relaunch. Migration preserves the existing order.
- **Quitting the GUI does not end workspaces.** vestad keeps shells alive as
  today; only a reboot (dead ptys) triggers the cold-restore path.

## 1. Model (Tabs.swift)

- Remove `struct Proj`. `SessionStore` holds:
  - `workspaces: [Workspace]` — `Workspace` = existing `PaneTree` (unchanged;
    still owns name, cwd, paneIDs, split layout, tabs) + `color: NSColor?` +
    `groupID: UUID?`.
  - `groups: [Group]` — `id, name, color, collapsed`. No cwd, no behavior.
- Array order of `workspaces`/`groups` IS the sidebar order (grouped
  workspaces render under their group header, in array order).

## 2. Sidebar + "+" (Chrome.swift, WindowContext.swift)

- Titlebar `+` (and ⌘N path): create a workspace immediately. Shell cwd =
  active workspace's cwd, else `$HOME`. Default name = cwd basename; rename
  as today.
- Remove: the `NSOpenPanel` "Add Project" flow, the per-project hover `+`,
  and the change-project-dir folder button.
- Sidebar renders the flat list; group headers are collapsible; drag a
  workspace into/out of a group; drag-reorder everywhere (order persisted).
- Context menu on a workspace: rename, color, new group from workspace, move
  to group, remove. On a group: rename, color, ungroup (children survive),
  remove (closes children after confirm).
- Visual styling (transparency, colors, fonts) untouched.

## 3. Persistence + migration

- `windows.json` version bump: per-window `groups[]` + `workspaces[]`
  (name/cwd/color/groupID/paneID/layout) + active ids + frame. Order in the
  file = sidebar order.
- `projects.json` is retired; its data folds into the migration.
- One-time migration of the old format, preserving order:
  - project with exactly 1 session → one workspace (project's name + color)
  - project with ≥2 sessions → a group (project's name + color) containing
    its sessions as workspaces
- `vesta-projects` config key: each path seeds one dormant workspace.

## 4. Reboot: clean cold restore

- Daemon `.hello` reply gains `resumed: Bool` — true when a live pty existed,
  false when the daemon forked a fresh shell. Today the GUI cannot tell the
  difference, which is what makes post-reboot restores feel corrupted.
- On `resumed == false` for a restored workspace: fresh shell starts in the
  saved cwd, saved split layout is rebuilt, on-disk scrollback ring is
  replayed as inert history followed by a divider line, workspace keeps its
  name and sidebar position.
- `vesta-persist-scrollback` default flips to **on** so cold restore works
  out of the box (existing explicit `false` still respected).
- App-quit/relaunch with the daemon alive is unchanged: reattach to live
  shells (`resumed == true`), no reset.

## 5. Compat (CLI / Lua / docs)

- `vesta project new` → new workspace; `project rename|color|remove` operate
  on the workspace or group under the given id/name. Existing plugin scripts
  keep working; new `vesta ws`/`vesta group` verbs are thin aliases.
- Docs updated, including live halo-site.

## 6. Out of scope (future)

- **Lite mode** (`vesta-lite`): ghostty-like chrome-free window — no
  sidebar/titlebar accessories/footer, skip sidebar-feeding background work,
  plugins still load. Hook points: early-out in `buildContent`/`makeSidebar`
  (Chrome.swift), suppress `snapshot()`/tails/materialize. Tracked in
  PARKED.md.
- Group icons (SF Symbols), pinning, PR/branch badges from cmux.

## Delivery (small PRs)

1. PR1 — flatten: model + sidebar + `+` behavior + persistence + migration.
2. PR2 — cold restore: `resumed` flag, clean reset, scrollback default-on.
3. PR3 — CLI aliases + docs (incl. halo-site) + PARKED.md note.
