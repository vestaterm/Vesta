# Halo — cmux Parity Design

Date: 2026-06-22
Status: approved (verbal) → implementation plan next

## Goal

Close the feature gap between Halo and **cmux** (the native macOS libghostty
terminal built for running parallel AI coding agents). Halo already matches
cmux on: libghostty + GPU rendering, vertical project sidebar, native splits,
scriptable `halo` CLI + Unix socket, no prefix keys, no required config.

This spec covers the four parity features Halo lacks. OS-level notifications
are explicitly **deferred to a later, separate plan**.

Non-negotiable constraints (carried from project requirements):
- Every new piece of chrome pulls color from the ghostty config via
  `theme.accent` / `theme.background`. **Never hardcode colors** (no `#161719`).
- Each feature ships **one** runnable pure-logic self-check (ponytail). UI is
  verified hands-on with screenshots + synthetic clicks, never by blind review.
- Shortest working diff. No new dependencies — stdlib / AppKit / libghostty /
  shelling out to `git` and `lsof` only.

## Feature 1 — Worktree isolation (core)

**What:** A session can be backed by its own git worktree on its own branch, so
several agent sessions work the same repo without colliding.

**Model:** `PaneTree` (a session) gains optional metadata
`worktree: (path: String, branch: String)?`. Nil = ordinary session.

**Creation:**
- CLI: `halo worktree <branch> [--base <ref>] [--repo <path>]` — runs
  `git worktree add <dir> -b <branch> [<base>]`, then opens a session whose cwd
  is the new worktree dir.
- UI: project row context menu → "New worktree session…" prompts for a branch
  name (reuse the existing `promptRename` NSAlert pattern). Base = project HEAD.

**Location:** `~/.halo/worktrees/<repo-name>/<branch>` — one managed dir per
repo. (ponytail: single managed root → trivial enumeration + cleanup;
repo-adjacent worktree dirs litter the parent and confuse other tooling.
Upgrade path: make the root a `halo-worktree-root` config key.)

**Branch label:** worktree sessions show `⎇ <branch>` as their sidebar label
instead of the program title.

**Removal:** closing a worktree session best-effort removes its worktree dir
off-main via **non-force** `git worktree remove` (no modal). Git refuses to
remove a dirty/locked worktree, so uncommitted work is never destroyed — the
dir is simply left on disk. Clean worktrees self-clean. (This replaces the
originally-planned confirm dialog: non-force removal IS the data-loss guard and
avoids a blocking modal in the shared close path the CLI also uses.)

**Self-check:** `worktreeDir(root, repo, branch)` path computation + branch-name
sanitization (slashes in branch → safe dir segment).

## Feature 2 — Attention rings

**What:** Show when an unfocused session's agent wants the user.

**Signals (ponytail — no idle-prompt heuristic):**
- Terminal **bell** (BEL) from the surface.
- **OSC 9** and **OSC 777** desktop-notification escapes (emitted by Claude
  Code, Codex, and most agent CLIs). libghostty routes both as runtime actions.

**Primary signal — prompt-return poll (verified live 2026-06-22):** this
libghostty build does NOT emit `RING_BELL`/`DESKTOP_NOTIFICATION` (bell is gated
by ghostty's `bell-features` config, which the embed exposes no API to inject;
OSC 9/777 produced no action even to a background surface). So the actual signal
is a **1.5s poll of `ghostty_surface_foreground_pid`** (AppDelegate.pollAttention):
a fresh session baselines its shell pid, and when a **background** session's
foreground pid returns to that shell pid (a command/agent turn finished), it is
ringed. Cleared on focus. The bell/notification `onAttention` wiring is kept
(harmless, future-proof) for when a libghostty build forwards those actions.

**Behavior:** a signal in a pane that is **not** the focused pane marks that
session `attention = true`. The sidebar session row draws a small accent ring
(`theme.accent`). Focusing the session clears it.

**State lives on** `PaneTree` (`var needsAttention: Bool`), surfaced through the
`SidebarSession` snapshot (`attention: Bool`). Set from the surface's
bell/notification action callback; cleared in `selectSession` / focus change.

**Self-check:** the attention state machine — set on signal-while-unfocused,
no-op on signal-while-focused, clear on focus.

## Feature 3 — Richer sidebar per session

Adds three bits of per-session metadata to the sidebar, all computed off-main
and cached (same pattern as the existing git footer/branch cache).

- **Ports:** `lsof -nP -iTCP -sTCP:LISTEN -a -p <pids>` over the pane shell's
  descendant PIDs → listening ports. Rendered as a chip (e.g. `:3000`).
  (ponytail: descendant-PID walk via `pgrep -P` chain; ceiling = misses
  processes that re-parent to launchd. Upgrade path: use the surface's reported
  child pid + a proper process-tree query.)
- **Dirty state:** `git status --porcelain | wc -l` for the session cwd → `●N`
  dot when > 0.
- **Status text:** already available as `PaneTree.focusedTitle`.

`SidebarSession` gains `ports: [Int]` and `dirty: Int`. AppDelegate fills them
into a cache (keyed by session identity) on the same off-main refresh that does
git, then re-renders.

**Self-check:** `parseLsofPorts(_:)` (extract unique listen ports from `lsof`
output) and `parsePorcelainCount(_:)`.

## Feature 4 — Embedded browser

**What:** A browser pane for hitting `localhost:PORT`.

**Model:** `PaneTree` leaves become a small enum — terminal or browser. A
browser leaf hosts a `WKWebView` (WebKit, system framework — no dependency).

**Creation:** `halo browser <url>` + a keybind opens a browser leaf via the same
split machinery as a terminal pane. (ponytail: minimal chrome — load URL,
reload, native back/forward swipe. No tab strip, no bookmarks, no address-bar
autocomplete.) If the focused session has a detected listening port, the
"new browser" action defaults its URL to `http://localhost:<port>`.

**Color:** the thin browser top bar uses `theme.background` / `theme.accent`.

**Self-check:** `normalizeURL(_:)` — bare `localhost:3000` / `3000` /
`example.com` → a valid `URL` with scheme.

## Deferred — OS notifications (separate later plan)

`UNUserNotificationCenter` banner when a background-app agent fires an attention
signal (so you're alerted with Halo not focused). Out of scope here; its own
spec/plan when we get to it. Feature 2's attention signal is the hook it will
reuse.

## Build order

1. Worktree isolation (touches Workspace model + CLI + sidebar action)
2. Richer sidebar metadata (ports + dirty)
3. Attention rings (consumes the sidebar row work)
4. Embedded browser (most isolated; leaf-type change in PaneTree)

## Out of scope / YAGNI

- Database branching, port *remapping* (cmux has these; not requested).
- Browser tabs/history/bookmarks.
- Idle-prompt attention heuristics.
- Persisting worktree sessions across app restarts.
