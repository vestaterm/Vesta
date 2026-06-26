# Security & privacy

Vesta is a terminal emulator with an embedded plugin system. A few things are
worth understanding before you install plugins or enable optional features.

## Plugins run arbitrary code — install only what you trust

A Vesta plugin is Lua that runs **in-process with full access to the `vesta` API**.
Concretely, a plugin can:

- read your terminal output and working directories (`vesta.capture`, `vesta.state`),
- **inject keystrokes into your shell** (`vesta.send`) — i.e. run commands as you,
- run control verbs, open files/URLs, and more.

Plugins declared with `vesta.plugin("owner/repo")` are **cloned from a git URL and
their code runs on load**. There is no sandbox and no plugin signing. Treat
installing a plugin exactly like running an arbitrary script from that source:
**only install plugins you trust**, and pin a ref (`{ ref = "v1.0.0" }`) so an
upstream change can't silently alter what runs.

Callbacks are error-isolated (a throwing plugin can't crash Vesta, and a
runaway loop is aborted), and a plugin that errors repeatedly is auto-disabled —
but that is a stability guard, **not** a security boundary.

## Scrollback on disk is off by default

By default Vesta does **not** write terminal output to disk. If you set
`vesta-persist-scrollback = true`, the daemon mirrors each pane's scrollback to
`~/Library/Application Support/vesta/sessions/<paneID>.log` (mode `0600`, owner-only)
so history survives a daemon restart. Terminal output can contain passwords, API
tokens, and SSH keys — enable this only if you accept on-disk persistence of that
data. Logs are removed when a session ends cleanly; a daemon crash can leave the
last ~512 KB on disk until the next clean exit. The daemon reads this setting once
at startup, so toggling it applies on the next daemon start (quit Vesta and let
`vestad` exit, or `kill` it).

## Local IPC

The daemon and control sockets, the single-instance lock, and any session logs
are created owner-only (`0600`), under a `0700` directory in Application Support.
They carry keystrokes and terminal output, so anyone able to read them could
observe or inject into your sessions — standard single-user-machine assumptions
apply.

## Sandboxing

Vesta is **not** App-Sandboxed (a terminal must spawn arbitrary child processes).
Hardened Runtime is enabled for notarized builds.

## Reporting

Found a vulnerability? Please open a private security advisory on the GitHub
repository rather than a public issue.
