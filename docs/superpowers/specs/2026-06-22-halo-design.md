# Halo — Design

A native macOS terminal emulator built on libghostty, aimed at power users and
AI coding agents. Slim instrument-panel aesthetic, native tmux-like split panes,
a vertical projects sidebar, full ghostty-config compatibility, deep
customization, and a control CLI that lets agents (Claude Code, scripts, etc.)
drive and read the terminal.

## Goals

- Native, fast, Mac-first. Owns its own window, chrome, and layout.
- **Agent layer:** a `halo` CLI + control socket that can *drive* (split, spawn,
  send keys, focus) **and** *read* (capture a pane's screen/scrollback).
- **tmux-like panes natively** — visual tiling splits, no external tmux.
- **Pulls from ghostty config** — an existing `~/.config/ghostty/config` works
  as-is; Halo layers its own keys into the same format.
- **Everything customizable** — every visual/behavioral value is a config key,
  live-reloaded.
- **Excellent git integration** — ambient + per-pane git awareness (v1), with a
  full in-app git surface planned (C, later).
- Slim, seamless look on a single uniform `#161719` surface.

## Non-goals (v1)

- Session persistence / detach-reattach (no background server holding panes).
  Visual splits only; deliberate v2.
- A full in-app git GUI (diff/stage/commit/log) — see "Git, phase C" below.
- Cross-platform. Mac only.
- An embedded LLM. Agents are *clients* of the CLI, not built into the app.

## Architecture

A single Swift/AppKit app, `Halo.app`, linking `libghostty` via
`GhosttyKit.xcframework`. **No background daemon** — the running app *is* the
control server; the `halo` CLI is a thin client. libghostty provides a *surface*
(PTY + VT parsing + GPU rendering bound to an NSView); Halo owns everything
around it: window, chrome, pane tiling, sidebar, config, git, control socket.

```
Halo.app (Swift/AppKit)
├─ GhosttyBridge   — the only file that touches libghostty C API:
│                    init, config load, surface create/destroy, text capture
├─ PaneTree        — binary split tree; each leaf = one ghostty surface (NSView)
├─ WindowChrome    — slim seamless titlebar, traffic lights, sidebar toggle
├─ Sidebar         — projects list, git status, sessions, status footer
├─ GitMonitor      — per-directory git state, watches for changes
├─ ConfigStore     — loads ghostty config + halo keys; live reload; tokens
└─ ControlServer   — Unix socket; maps JSON commands → app actions

halo (CLI, separate small binary)
└─ connects to the socket, sends one JSON request, prints reply, exits
```

### Components

- **GhosttyBridge** — single chokepoint for the unsafe FFI. Wraps surface
  lifecycle and the text-read API used by `capture`. Keeps libghostty's C
  surface out of the rest of the codebase.
- **PaneTree** — owns layout: split h/v, focus, navigate, resize, zoom, close.
  Leaves hold surfaces; internal nodes hold split direction + ratio. This is the
  "tmux-like panes." Pure in-memory; not persisted in v1.
- **WindowChrome** — 30px seamless titlebar (no bottom border), traffic lights,
  sidebar toggle vertically centered on the same row as the lights, a small
  dir/project label. No center title, no right-side clutter.
- **Sidebar** — collapsible vertical panel (toggle aligned to traffic lights).
  Projects with git status dots, a sessions section, and a status footer (mode,
  pane count, branch, dirty). Single right-edge hairline; rest is borderless.
- **GitMonitor** — see "Git integration."
- **ConfigStore** — see "Configuration."
- **ControlServer** — the only surface the CLI/agents touch. One well-defined
  protocol; everything an agent can do goes through it.

## Control protocol (the agent layer)

Newline-delimited JSON over a Unix domain socket
(`~/Library/Application Support/halo/control.sock`). The CLI sends one request,
reads one response, exits. If the app isn't running, the CLI errors clearly
(opt-in `--launch` to start it).

v1 command surface:

| Command | Action |
|---|---|
| `halo split [-h\|-v] [--cwd PATH] [-- CMD...]` | split the focused pane |
| `halo new-pane [--cwd PATH] [-- CMD...]` | new pane (default split) |
| `halo close [<id>]` | close a pane |
| `halo focus <id\|dir>` | focus a pane (by id or direction) |
| `halo zoom [<id>]` | toggle pane zoom |
| `halo send-keys <id> "<text>"` | type into a pane |
| `halo capture <id> [--scrollback]` | dump a pane's screen/scrollback (read) |
| `halo list` | full pane tree as JSON |
| `halo open <path>` | open/add a project, cd focused pane to it |

Driving example (your use case): Claude Code in pane 1 runs
`halo split -v -- claude` to spawn a second Claude beside it; later
`halo capture 2` to read what that agent's pane shows.

## Configuration & customization

**One config source.** Halo uses libghostty's own config parser, so an existing
ghostty config loads unchanged (fonts, colors, keybinds, etc.). Halo-specific
settings are extra keys in the **same file/format**, all `halo-` prefixed:

```
# ghostty keys — work as-is
font-family = Geist Mono
background  = 161719

# halo keys — extend the same file
halo-accent        = mint        # the single accent token
halo-sidebar       = true
halo-sidebar-width = 224
halo-pane-marker   = corners     # corners | ring | line | none
halo-project       = ~/dev/halo
```

Every visual/behavioral value seen in the mockup is a key: accent, surface
color, sidebar width/visibility, pane-marker style, fonts, keybinds. **Live
reload** — editing the config updates a running Halo without restart. The
mockup's single `--accent` token is the model: one knob, theme-swappable.

Precedence: ghostty config → halo keys in same file → (future) per-project
override. Unknown ghostty keys are honored by libghostty; unknown `halo-` keys
warn but don't fail the load.

## Git integration

### Phase B (v1) — ambient + per-pane awareness

- **GitMonitor** tracks git state per directory of interest (each project dir +
  each pane's cwd): branch, dirty count, ahead/behind. Backed by `git` CLI
  invocations, refreshed on an FS watch of the repo (debounced) + on pane focus.
- **Sidebar** shows each project's branch and a dirty/clean dot; the status
  footer reflects the focused pane's repo (`▌normal · 3 panes` / ` main ↑1 ·
  2 dirty`).
- **Per-pane:** each pane independently tracks the git state of *its own* cwd, so
  a split in a different repo shows its own context (surfaced subtly, no panel).
- No staging/committing UI in v1.

### Phase C (planned, later) — in-app git surface

A real git panel living in the app: staged/unstaged diff view, stage/unstage,
commit, branch switcher, log graph. Large feature; explicitly deferred. Interim
lazy answer for power users: a keybinding to spawn `lazygit` in a split. Phase C
is designed *around* GitMonitor so the data layer is reused, not rebuilt.

## Look & feel

Locked via `~/Desktop/halo/mockup.html` (browser prototype of the app window):

- **Surface:** every region exactly `#161719`. No brightness steps between
  titlebar, sidebar, and panes — hairlines and split-line gaps do all separating.
- **Top bar:** 30px, seamless (no bottom border), flows into the panes. Left to
  right: traffic lights · sidebar toggle (centered on the lights' row) · small
  folder icon + dir. Nothing centered or right-aligned.
- **Sidebar toggle aligns to the traffic lights** — shares their exact centerline.
- **Panes:** no head strips. Identity = split-line gaps + corner ticks on the
  focused pane. Size badge appears only mid-resize.
- **Accent:** mint/teal dialed down to a near-gray (`oklch(0.86 0.018 190)`),
  used rarely — active-pane corners, selected project, cursor. One token.
- **Status** lives in the sidebar footer, not a bottom bar.
- **Type:** Geist Mono (terminal body) + Martian Mono (small instrument labels).
- One orchestrated load animation; `prefers-reduced-motion` respected.

## Error handling

- **CLI ↔ app:** app not running → clear CLI error + exit code; `--launch` opt-in.
  Bad command / unknown pane id → JSON error response, non-zero exit.
- **libghostty:** surface creation failure surfaces as a visible pane error
  state, never a crash. All FFI confined to GhosttyBridge for auditability.
- **Config:** parse errors show a non-blocking banner and keep the last good
  config; unknown `halo-` keys warn only.
- **Git:** any `git` failure (not a repo, git missing) degrades silently to "no
  git info" for that directory — never blocks the terminal.

## Testing

- **PaneTree** — unit tests for split/close/focus/zoom/resize invariants (tree
  stays valid, focus always resolves). The core logic, fully testable headless.
- **ConfigStore** — tests that a real ghostty config parses and halo keys layer
  correctly; precedence and unknown-key handling.
- **ControlServer protocol** — round-trip tests: request JSON → action → response
  JSON, including error cases, against a stubbed PaneTree.
- **GitMonitor** — tests against temp git repos (clean/dirty/ahead-behind).
- GhosttyBridge FFI is exercised via the app, not unit-tested in isolation.

## Milestones

1. Window + one libghostty surface rendering in a Swift/AppKit shell.
2. PaneTree + visual splits (tmux-like) with keybindings.
3. ConfigStore: load ghostty config + halo keys, live reload.
4. WindowChrome + Sidebar matching the mockup (the look).
5. ControlServer + `halo` CLI (drive, then capture).
6. GitMonitor (phase B): sidebar + per-pane git awareness.
7. Polish, then plan phase C (in-app git surface) and v2 (session persistence).
