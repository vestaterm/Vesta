<p align="center">
  <img src="assets/vesta-icon.png" width="120" alt="Vesta icon">
</p>

<h1 align="center">Vesta</h1>

<p align="center">A native macOS terminal for running AI coding agents in parallel —<br>built on real <a href="https://ghostty.org">libghostty</a>, driven by a scriptable CLI.</p>

<p align="center">
  <a href="https://github.com/vestaterm/Vesta/releases/latest"><b>Download</b></a> ·
  <a href="https://vestaterm.github.io/vesta-site/">Website</a> ·
  <a href="https://vestaterm.github.io/vesta-site/docs.html">Docs</a> ·
  <a href="https://vestaterm.github.io/vesta-site/assets/vesta-demo.mp4">▶&nbsp;Watch&nbsp;the&nbsp;tour</a>
</p>

<p align="center">
  <img src="assets/hero.png" width="840" alt="Two Claude Code agents running side by side in Vesta, with the project sidebar showing 'halo · 2 panes'">
</p>

---

Vesta is a Swift/AppKit terminal that links **GhosttyKit.xcframework** (it is not
a Ghostty fork). It renders with Ghostty's Metal engine, reads your existing
`~/.config/ghostty/config` as-is, and adds a project sidebar, tmux-style splits,
and an agent-control CLI on top.

## Highlights

- **Real libghostty** — Ghostty's Metal renderer, your ghostty config and
  theme, zero reimplemented terminal logic.
- **Persistent sessions (tmux-style)** — shells survive Vesta quitting and
  reattach cleanly. A small daemon (`vestad`) holds the PTYs; panes connect
  through a relay (`vesta-attach`). Prefix-key mode for tmux muscle memory.
  Restore is lazy: at launch only the visible session reattaches; the rest
  stay listed in the sidebar and attach instantly on first click, so a big
  saved workspace opens fast. Until a restored session is first activated it
  won't ring the attention dot (its shell keeps running under the daemon
  regardless, and plugin `pane-output` taps still work).
- **Projects → sessions sidebar** — vertical, drag-resizable. Each project owns
  sessions; rename / recolor / remove from the right-click menu. Projects render
  as full-width dividers, with the session count and the **+** new-session
  control sharing one trailing slot.
- **Session cards** — each card shows an output tail (the last ~4 rendered
  lines of its focused pane, Claude Code-aware: anchored on the last `⏺` block,
  input-box chrome filtered), pane counts (`⊞N`, or a tiny split-schematic with
  `vesta-sidebar-panes`), and **heat**: an unseen failure flips the card amber
  with `✗` + how long ago, an unseen success gets a `✓` — driven by OSC 133
  marks, which Vesta injects into zsh out of the box (`vesta-shell-integration`);
  the bell/attention rail stays brightest. Actions like close reveal on hover —
  no always-visible close buttons.
- **Glass** — ephemeral chrome (command palette, confirms, toasts) always
  renders on native blur ("glass moments"). Opt in further with
  `vesta-glass-sidebar` (translucent sidebar, surface color as tint,
  `vesta-sidebar-opacity` for strength) and ghostty's own `background-opacity`
  for terminal translucency — two independent knobs, each with a matching
  titlebar band.
- **Native splits** — `⌘D` / `⌘⇧D`, click-to-focus, zoom, drag dividers.
- **Command palette** — `⌘⇧P` opens a searchable list of every action (splits,
  sessions, browser pane, settings…) plus your plugins' `vesta.command` entries,
  auto-scaling as you filter.
- **Default terminal** — **Vesta ▸ Make Vesta the Default Terminal** registers
  it as the Shell-role handler for unix executables (the same mechanism as
  Ghostty/iTerm2).
- **Drag & drop** — drop files onto a pane and their paths insert shell-escaped,
  space-separated (Terminal.app behavior); dropped text inserts as-is.
- **Scriptable** — the `vesta` CLI drives and reads the live UI over a Unix
  socket, so agents can orchestrate it.
- **Notifications** — `vesta.notify` from a plugin shows a stacking in-app toast,
  records it in a titlebar **bell** (history persists across restarts), and posts
  a macOS Notification Center banner when Vesta is backgrounded (or when forced).
- **Self-updating** — when a newer release exists, a badge appears at the sidebar
  bottom; click it to download, install (in place), and relaunch — no manual DMG.
- **Pick your app icon** — **Settings ▸ App Icon** swaps between a clean white
  flame, a pink one, and ten progressively "corrupted" stages (or click the icon
  in the About panel to cycle them). The choice is written onto the `.app` bundle,
  so it sticks in Finder/Dock across quits and survives in-place updates.
- **Everything from your config** — colors, fonts, sidebar width, divider width
  are all `vesta-*` keys in the same ghostty config file. Empty config = sane
  defaults.

## Build & run

No setup needed — `swift build` fetches the prebuilt GhosttyKit framework
(libghostty) automatically via a checksum-verified release asset.

```sh
swift build                                       # auto-fetches GhosttyKit on first build
.build/arm64-apple-macosx/debug/vesta            # run the app (dev)
swift run vesta selfcheck                          # pure-logic checks
./install.sh                                      # copy vesta + vestad + vesta-attach → /usr/local/bin (CLI)

./make-app.sh                                     # build Vesta.app (double-clickable, logo icon)
open Vesta.app                                     # launch the bundle
```

> The raw debug binary is bundle-less and dies if its launching shell exits (use
> `nohup .build/.../vesta & disown`). **`./make-app.sh`** packages a proper
> `Vesta.app` — logo dock icon, "Vesta" menu, double-click launch, detached
> lifetime. The binary is self-contained (ghostty is statically linked).

## The `vesta` CLI

Drives the running app over `~/Library/Application Support/vesta/control.sock`.
`vesta help` is authoritative; the common verbs:

```sh
vesta help                       # list every verb + config key
vesta open <path>                # new session at <path>
vesta split -v | -h              # split the focused pane (side-by-side / stacked)
vesta new-pane --cwd <path>      # new pane in a dir
vesta focus <id> | vesta focus next
vesta zoom                       # toggle zoom on the focused pane
vesta close                      # close the focused pane
vesta send-keys <target> <text>  # type into a pane + run it (target = pane id or "focused"; --no-enter to skip the Return)
vesta send-keys --all|--session <P.S>|--project <name> <text>   # broadcast: focused session's panes / session P.S / all of a project (reply: pane count)
vesta capture                    # dump the focused pane's screen
vesta pane status <paneID>       # JSON for one pane: cwd, title, alive, attention
vesta list                       # the focused session's panes (+ tab index/count)
vesta tab new|next|prev|close    # tab control
vesta sessions [--json] [--project <name>]   # list sessions; --json for structured records (id, name, cwd, panes, active/attention; --project implies --json)
vesta kill <id>                  # end a session's shell (by paneID)
vesta notify [--desktop] [--title <t>] <msg>   # toast + bell; desktop banner when backgrounded (--desktop forces)
```

## Multiplexer & sessions

Shells run under a small daemon (`vestad`), not the app, so they **survive Vesta
quitting** and **reattach cleanly**. The daemon owns one `forkpty`'d shell per
pane and keeps the last ~256 KB of its raw output; on attach it replays those
bytes and ghostty re-renders them — colors, cursor, full-screen apps and all
(no separate screen model, so nothing to garble). On by default; set
`vesta-persist = false` for plain non-persistent shells.

What you get:

- **Survive quit** — `⌘Q`, reopen Vesta: panes come back with their shells and
  recent output.
- **Close ends the shell** — `⌘W` closes the focused pane (a non-last pane
  detaches; the last pane closes **and kills** its session). `⌘⇧W` closes and
  kills the session. Shells survive only across window-close / `⌘Q` quit, and
  reattach on relaunch. To keep a shell but drop the pane, prefix-`d` (detach).
- **Prefix mode** — tmux muscle memory. Press the prefix (`ctrl+b` by default,
  `vesta-prefix`), then a key (table below). Empty `vesta-prefix` disables it.
- **Explicit kill** — prefix-`x`, or `vesta kill <id>` — when you actually mean
  to end the shell.

### Verify it works

```sh
# 1. survive quit
#    in a pane:   echo i-was-here && date
#    ⌘Q, reopen Vesta.app → the pane shows that output again.

# 2. detached sessions survive
#    close the window (not ⌘⇧W) → its shells keep running; relaunch → they reattach.
#    or prefix-d a pane to detach it (shell lives on under vestad).

# 3. from the CLI, watch the daemon hold sessions
vesta sessions            # lists live + detached sessions with attach counts
vesta kill <id>           # ends one for real
```

If a pane ever says "daemon protocol … update Vesta", an **old `vestad` from a
previous build** is still running (`pkill -f vestad`, then relaunch) — the
daemon is single-instance per user.

### Prefix keytable (after `ctrl+b`)

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `%` | split vertical | `c` | new session |
| `"` | split horizontal | `n` / `p` | next / prev session |
| `h j k l` / arrows | focus pane | `,` | rename session |
| `z` | zoom pane | `d` | detach pane |
| `x` | kill shell |  |  |

Override bindings with `vesta-prefix-bind = key:action, …` in your ghostty config.

## Configuration

Vesta reads `vesta-*` keys from your ghostty config (libghostty ignores them).
Standard ghostty keys (`theme`, `background`, `foreground`, `cursor-color`,
`palette = N=#hex`) apply live. Every `vesta-*` default matches the built-in
look, so an untouched config changes nothing.

| Key | Default | Meaning |
|-----|---------|---------|
| `vesta-accent` | theme accent | accent color (rings, dots, focus ticks) |
| `vesta-surface` | theme background | base surface color |
| `vesta-sidebar-width` | 224 | sidebar open width (px) |
| `vesta-font-family` | GeistMono | chrome label font |
| `vesta-font-mono` | MartianMono | mono font |
| `vesta-font-size` | 13 | chrome font size |
| `vesta-divider-width` | 8 | split divider grab width (1px hairline drawn) |
| `vesta-projects` | — | comma-separated project paths to preload |
| `vesta-persist` | true | run shells under `vestad` (survive quit); `false` = plain shells |
| `vesta-persist-scrollback` | false | mirror scrollback to disk so it survives a daemon restart — or a reboot. **Off by default** — terminal output can contain secrets (see [SECURITY.md](SECURITY.md)) |
| `vesta-sidebar-tails` | true | session cards show the last ~4 rendered lines of their focused pane (content-aware for TUI agents: anchors on Claude Code's last `⏺` block, filters its input box). Also gates background materialization of restored sessions at launch |
| `vesta-sidebar-panes` | false | tiny split-schematic on multi-pane session cards; off = a dim `⊞N` count still shows |
| `vesta-glass-sidebar` | false | translucent sidebar — behind-window blur with the surface color as a tint; titlebar over the sidebar matches. Applies on relaunch |
| `vesta-sidebar-opacity` | 0.55 | sidebar tint strength in glass mode (0..1) |
| `vesta-shell-integration` | true | inject zsh OSC 133 marks into daemon-spawned shells so card heat (✓/✗) works out of the box; `false` = opt out |
| `background-opacity` | 1 | ghostty key (no `vesta-` prefix): terminal translucency, e.g. `0.9` — independent of the sidebar; the titlebar strip over the terminal matches the terminal's color and opacity |
| `vesta-prefix` | ctrl+b | prefix key for tmux-style mode; empty = disabled |
| `vesta-prefix-bind` | — | override prefix bindings: `key:action, …` |

## Keybindings

| Keys | Action |
|------|--------|
| `⌘D` / `⌘⇧D` | split vertical / horizontal |
| `⌘W` / `⌘⇧W` | close pane / close session |
| `⌘T` | new session in active project (cwd = project dir) |
| `⌘]` | focus next pane |
| `⌘{` / `⌘}` | previous / next session |
| `⌘1`–`⌘9` | select session N |
| `⌘B` | toggle sidebar |
| `⌘⇧P` | command palette (search + run any action or plugin command) |
| `ctrl+b` then a key | prefix mode (see Multiplexer & sessions) |

Click a pane to focus it; click a project to expand it; right-click a project
to rename / recolor / remove it. `⌘W` closes the focused pane; `⌘⇧W` closes
**and kills** its session — see Multiplexer & sessions.

## Architecture

- `Sources/Vesta/Ghostty/` — libghostty init, config sync, runtime callbacks.
- `TerminalPane.swift` — a ghostty surface (input / IME / mouse / resize / cwd / title).
- `PaneTree.swift` — tmux-style splits as nested `NSSplitView`s.
- `Tabs.swift` — the `Workspace` model: projects own sessions.
- `Chrome.swift` — window, titlebar, sidebar rendering.
- `TailStore.swift` — cleaned per-pane output tails (ANSI-stripped, OSC 133
  exit marks parsed) feeding the session cards.
- `Glass.swift` — native-blur base for ephemeral chrome ("glass moments") and
  the glass sidebar.
- `Control.swift` — the `vesta` CLI + socket server.
- `GhosttyConfig.swift` — `Theme` + `VestaConfig` (the `vesta-*` keys).
- `Git.swift` — branch / status, shelled out off-main.
- `PrefixMode.swift` — tmux-style prefix mode.
- `Sources/vestad/` — the session daemon: one `forkpty`'d shell per pane + a raw
  output ring, replayed on attach. No terminal parsing (ghostty does that).
- `Sources/vesta-attach/` — the per-pane relay ghostty spawns as its command;
  a dumb byte pump between the pane and the daemon over a `0600` unix socket.
- `Sources/VestaMux/` — shared wire protocol (`MuxProtocol`) + paths (`MuxPaths`)
  + `ShellIntegration.swift` (the zsh OSC 133 injection, via a ZDOTDIR swap).

## Roadmap

Designs live in `docs/superpowers/specs/`. Shipped: **persistent sessions**
(`2026-06-25-mux-rawring-rewrite.md`) — `vestad`/`vesta-attach` raw-ring
multiplexer, prefix mode. Deferred there: mirroring (one session in two panes),
remote attach (`vesta attach ssh://`), and inline-image replay across detach.
(Disk-spill scrollback later shipped as `vesta-persist-scrollback`.) Also shipped: **cmux parity**
(`2026-06-22-cmux-parity-design.md`) — worktree-isolated sessions (`vesta worktree`),
attention rings, the richer sidebar (cards with tails/heat), embedded browser pane.

## Self-checks

```sh
.build/arm64-apple-macosx/debug/vesta selfcheck   # config, control, git, workspace, chrome
```
