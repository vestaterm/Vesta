# Halo

Native macOS terminal emulator. Slim instrument-panel look on a uniform
`#161719`, tmux-like split panes, a projects sidebar, ghostty-config color sync,
and a control CLI agents can drive.

## Run

```sh
swift run halo            # launch the GUI
swift build && .build/debug/halo
```

## Control CLI (the agent layer)

With the app running, the same binary acts as a client over a Unix socket
(`~/Library/Application Support/halo/control.sock`):

```sh
halo split -v                 # split focused pane (side by side); -h = top/bottom
halo new-pane --cwd ~/dev     # new pane in a dir
halo send-keys focused "ls\n" # type into a pane
halo focus 2                  # focus pane by id
halo tab new|next|prev|close  # tabs (each tab has its own panes)
halo open ~/project           # open a dir in a new tab
halo list                     # panes (+ active tab) as JSON
halo capture 2                # read a pane (pending GhosttyKit, see below)
```

Keybinds: ⌘D split · ⌘⇧D split horizontal · ⌘W close pane · ⌘⇧W close tab ·
⌘T new tab · ⌘{ / ⌘} prev/next tab · ⌘1–9 select tab · ⌘B sidebar · ⌘] cycle pane.
Click a pane to focus it; click a project to open it in a new tab.

## Config

Reads your existing ghostty config (XDG / `~/.config/ghostty/config` /
App-Support), including `theme = name`, `background`, `foreground`,
`cursor-color`, and `palette = N=#hex` — colors apply live. Halo-specific keys
(`halo-*`) layer into the same file, e.g. `halo-projects = ~/dev/halo, ~/dev/api`
to populate the sidebar.

Live cwd + git: the sidebar footer shows the focused pane's branch / ahead-behind
/ dirty count (via the shell's OSC-7 cwd reports). Tab titles follow each pane's
directory.

## Status

v0 runs on **SwiftTerm** as the terminal surface so it works today. The terminal
swaps to a **libghostty / GhosttyKit** surface (the design target) once that
framework is built — which needs **zig 0.15.2** exactly (`brew` ships 0.16.0).
`ghostty.h` is saved for that bridge. Pane `capture` and GPU rendering land with
that swap.

Not yet: session persistence (v2), in-app git surface (phase C). See
`docs/superpowers/specs/2026-06-22-halo-design.md`.

## Self-checks

```sh
.build/debug/halo selfcheck   # parser, pane tree, control protocol, chrome
```
