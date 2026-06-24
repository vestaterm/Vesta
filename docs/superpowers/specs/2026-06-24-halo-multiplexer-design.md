# Halo — Multiplexer & Sessions Design ("better than tmux")

Date: 2026-06-24
Status: approved (verbal) → implementation plan next

## Goal

Turn Halo's in-app sessions into a real terminal multiplexer that **beats
tmux** on the things power users hit daily: shells survive Halo quitting,
reattach is clean (no garble) **and restores native scrollback**, detached
sessions are always visible (never silent zombies), one session can be
mirrored live in multiple places, and you can attach to a session on another
machine. Plus tmux-style prefix-key muscle memory and named sessions.

This is delivered as five independently-shippable milestones over one
architecture. A separate, later spec covers the plugin/Lua system — **not in
scope here.**

### Why we beat tmux (the scorecard this spec commits to)

| Area | tmux | Halo (this spec) |
|---|---|---|
| Reattach redraw | clean (server screen state) | clean — same mechanism |
| Scrollback after reattach | copy-mode only | restored into **native** scrollback |
| Inline images across detach | unsupported entirely | **replayed** from a placement cache |
| Scrollback limit | RAM-capped (`history-limit`) | big cap + **disk spill** |
| Daemon crash | loses everything | loses live procs, **recovers history from disk** |
| Detached sessions | invisible until `tmux ls` | always in the switcher |
| Mirroring | works, clunky | seamless (same id attached twice) |
| Remote | nested-tmux gymnastics | native `halo attach ssh://host`, self-deploys helper |

## Non-negotiable constraints (carried from project requirements)

- Every new piece of chrome pulls color from the ghostty config
  (`theme.accent` / `theme.background`). **Never hardcode colors** (no
  `#161719`). The daemon never touches rendering — ghostty stays the source of
  truth for all color.
- Control/daemon sockets are owner-only `0600`.
- Shortest working diff. The only new dependency is **vendored libvterm**
  (MIT) — we do not write a VT parser, and we add nothing else.
- Each feature ships **one** runnable pure-logic self-check (ponytail). UI is
  verified hands-on with screenshots + synthetic clicks, never blind review.

## Architecture

Three processes, the classic server/client split done right:

```
┌─ Halo.app (GUI) ───────────────┐        ┌─ halod (daemon, survives quit) ──────┐
│ TerminalPane (ghostty surface) │        │ per pane-id:                         │
│   spawns command:              │        │   forkpty'd shell + PTY master       │
│     halo-attach <pane-id> ─────┼─socket─▶│   libvterm  → authoritative screen   │
│ PaneTree / Tabs                │  bytes │   scrollback ring (+ disk spill)     │
│ prefix mode / switcher         │  +winsz│   image-placement cache              │
└────────────────────────────────┘        │ drains PTY even while detached       │
                                           └──────────────────────────────────────┘
```

### Components & responsibilities

**`halod` — the daemon** (new executable target).
- Owns one `forkpty`'d shell + PTY master per **pane-id** (a stable UUID).
- Feeds every byte of PTY output through a per-session **libvterm** instance →
  authoritative screen + scrollback state, kept current even when no client is
  attached (so a backgrounded `make` never blocks on a full pipe).
- Maintains, per session: a scrollback ring (configurable cap) that **spills
  older lines to disk** (`~/Library/Application Support/halo/sessions/<id>.log`),
  and an **image-placement cache** (Kitty graphics: image data keyed by image
  id + active placements) for replay on attach.
- Listens on a `0600` unix socket. Multiple clients may attach to one session
  (mirroring). On attach: send a clean **redraw of current screen + restored
  scrollback + cached image placements**, then stream live.
- Reaps a session only when its **shell process exits**. Idle-exits the whole
  daemon when it owns zero live shells.
- Lazy-spawned by the app (double-fork/`setsid` so it outlives the app); not a
  LaunchAgent in v1 (a live process can't survive reboot anyway).

**`halo-attach <pane-id>` — the client relay** (new executable target).
- What ghostty spawns as `config.command`. Connects to `halod`, sends initial
  window size, receives the redraw+scrollback+images, then is a byte pump:
  stdin → daemon → shell, shell → daemon → stdout; forwards SIGWINCH.
- On Halo quit / pane close it dies; the shell keeps running under `halod`.
- Reconnects if the daemon socket blips.

**GUI integration** (existing targets).
- `TerminalPane` gains a stable `paneID: UUID`, persisted in the PaneTree
  serialization. Its surface `config.command` becomes
  `halo-attach <paneID>` (was: bare shell).
- On relaunch, rebuilding the tree reattaches live shells by id; ids the
  daemon doesn't know → daemon spawns a fresh shell (and, if a disk log exists
  from a prior daemon crash, replays that history first).
- `PaneTree` gains `name: String?` (session name) — persisted.

### Wire protocol (sketch)

Length-prefixed binary frames over the unix socket. Minimal, versioned.

- Client→daemon: `Hello{protocolVersion, paneID, cols, rows}`, `Input{bytes}`,
  `Resize{cols, rows}`, `Detach`, `Kill`, `List`.
- Daemon→client: `HelloAck{protocolVersion}` (mismatch → `NeedsUpdate`),
  `Snapshot{screen, scrollback, images}` (sent on attach), `Output{bytes}`,
  `Exited{status}`, `Sessions[{id, name, cwd, alive, attachedCount}]`.

`protocolVersion` handshake makes local/remote binary skew a clean error, not
a corrupt session.

## The five milestones (each independently shippable)

### Milestone 1 — Prefix-key mode (pure Swift, no daemon)
Configurable prefix (`halo-prefix = ctrl+b` default; empty = off). Prefix →
pending state with a subtle top-bar indicator → next key maps through a
config keytable to **existing** `PaneTree`/`Tabs` actions:
`%`/`"` split, `h j k l`/arrows navigate, `z` zoom, `c` new session,
`n`/`p` next/prev, `,` rename, `s` switcher, `d` detach, `x` kill.
No new pane plumbing — it dispatches actions that already exist.
*Self-check:* keytable parse + resolve `(prefix, key) → action` is pure logic.

### Milestone 2 — Named sessions + switcher (small)
`PaneTree.name` (persisted). Rename via prefix-`,` or sidebar double-click.
**Switcher:** a fuzzy-filter overlay (prefix-`s` / Cmd-K) over all sessions in
all windows/projects — type to filter, Enter to jump. Reuses the existing
search-overlay styling. This overlay is also where **detached** sessions
appear once Milestone 3 lands (so they're never invisible).
*Self-check:* fuzzy ranker is pure logic.

### Milestone 3 — `halod` + `halo-attach` + libvterm (the core "better")
The architecture above. Ships with the beats-tmux mitigations **baked in**:
- **Clean reattach** from libvterm screen state (no garble).
- **Native scrollback restore** on reattach (scroll up with normal gestures).
- **Disk-spill scrollback** beyond the RAM cap.
- **On-disk history recovery** if the daemon itself crashed/restarted.
- **Image-placement replay** (Kitty graphics) across detach.
- Detach UX: **close = detach** (Cmd-W and quit keep the shell alive); a
  session is reaped only when its shell exits; explicit **kill** action
  (prefix-`x`, menu) for "I mean it". `halo sessions` / `halo kill <id>` CLI.
*Self-check:* protocol frame encode/decode round-trip; scrollback ring
eviction + disk-spill boundary; image-cache replay ordering — all pure logic,
no PTY needed.

### Milestone 4 — Mirroring (live, multi-client)
Same `paneID` attached from two panes/windows → both live, both see identical
state. Size policy: **follow the focused client**, letterbox idle mirrors
(nicer than tmux's smallest-wins). Optional read-only mirror mode is a later
nicety, not v1.
*Self-check:* size-arbitration policy (`focused` vs `idle` clients → chosen
grid) is pure logic.

### Milestone 5 — Remote attach
`halo attach ssh://host[:port] [session]`. The wire protocol is
transport-agnostic, so remote = run `halod` on the host + stream the same
frames over an SSH-forwarded unix socket. `halo` **self-deploys** the
`halod`/`halo-attach` helper binaries over `scp` when missing/outdated;
version handshake gates skew. SSH-forwarded socket only — **no raw TCP
listener** (would need its own auth; out of scope).
*Self-check:* `ssh://` URL parse + remote-deploy decision (`present && version
ok` → skip) is pure logic.

## Data flow (attached, steady state)

1. Shell writes → PTY master (held by `halod`).
2. `halod` feeds bytes to libvterm (state) **and** forwards `Output{bytes}` to
   each attached client.
3. `halo-attach` writes those bytes to its stdout → ghostty parses + renders.
4. Keystroke in ghostty → `halo-attach` stdin → `Input{bytes}` → daemon →
   PTY master → shell.
5. Window resize → ghostty → `halo-attach` SIGWINCH → `Resize` → daemon
   applies size policy → PTY `TIOCSWINSZ` + libvterm resize.

## Error handling

- **Daemon socket gone / blip:** `halo-attach` shows a one-line "reconnecting"
  status and retries with backoff; if the daemon is truly dead, it surfaces
  "session lost" and the pane can recover history from the disk log.
- **Daemon crash:** live processes are lost (unavoidable); on next spawn the
  daemon replays the per-session disk log so **history** is recovered.
- **Protocol version skew (remote):** clean `NeedsUpdate` → `halo` offers to
  redeploy the helper; never a corrupt stream.
- **Shell exits:** daemon sends `Exited{status}`, frees the session, removes it
  from the switcher; disk log retained briefly then GC'd.
- **PTY backpressure:** daemon always drains the PTY into libvterm + ring even
  with zero clients, so shells never block on full pipes.

## Testing

Per ponytail, one runnable pure-logic self-check per milestone (listed inline
above): keytable resolve, fuzzy ranker, protocol round-trip + scrollback/disk
boundary + image replay ordering, size-arbitration policy, ssh-URL/deploy
decision. UI and live-PTY behavior verified hands-on (screenshots + synthetic
input), never by blind review. No test frameworks/fixtures beyond a
`demo()`/`__main__`-style assert check.

## Packaging / CI

- Two new executable targets (`halod`, `halo-attach`) in `Package.swift`,
  bundled in `Halo.app/Contents/MacOS`. `make-app.sh` copies them.
- CI sign + notarize must cover both new binaries.
- Vendored libvterm built as a SwiftPM C target.

## Out of scope (this spec)

- The plugin / embedded-Lua system — its own later spec.
- Raw-TCP remote listener with independent auth (SSH-forwarded only).
- Read-only mirror mode, session sharing across users/accounts.
- LaunchAgent-managed daemon / reboot survival (a live process can't survive
  reboot regardless).

## Known limitations (accepted; tmux shares all but #7)

1. Inline images: live = perfect; across detach = replayed from cache (better
   than tmux, which has none) but bounded to what the Kitty protocol exposes.
2. Mirror/reattach at differing sizes: one PTY = one grid; idle mirrors
   letterbox (tmux forces smallest-client — we're nicer, not magic).
3. Scrollback is capped (then disk-spilled); not literally infinite.
4. Detached env is frozen (no rc re-source); SIGWINCH only while attached —
   inherent to detached processes, identical to tmux.
5. Extra socket hop + double parse: local-unix microseconds, output coalesced;
   matches or beats tmux.
6. Daemon crash loses live processes (history recovered from disk).
7. This is the highest-risk, permanently-maintained code in Halo — contained
   by leaning on vendored libvterm for the hard VT work.
