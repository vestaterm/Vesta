# Halo roadmap

Working notes on what's being built and what's deliberately parked. Update as
things land. (Created on the `feat/plugin-events` branch.)

## Shipped on feat/plugin-events-2 (continuation)

Next increment across all four themes; builds on feat/plugin-events.

1. **All-panes pane-output** — pane-output now subscribes to every live pane
   (was: only the focused one). One mux subscriber per pane, reconciled against
   all sessions; output keyed by paneID so it's never mislabeled.
2. **Plugin sandboxing** — (a) auto-disable: a plugin whose callback errors 5×
   in a row is disabled + reloaded (origin-tracked via luaRefOwner; the user's
   own init.lua is never auto-disabled); (b) runaway-loop guard: a lua_sethook
   count hook aborts a callback exceeding ~50M instructions. Verified by
   luaSandboxSelfCheck.
3. **Scrollback to disk** — daemon mirrors each session's ring to
   `sessions/<paneID>.log` (0600, bounded); a fresh Session seeds its replay
   ring from it, so scrollback survives a daemon restart/reboot. Log deleted on
   clean session end, kept when the daemon itself dies. Verified across a
   simulated crash+restart.
4. **Richer UI primitives** — `halo.pick` with {label, desc} rows; `halo.menu`
   (per-item action callbacks); `halo.pickmulti` (Tab-to-mark, returns a table);
   editable panel fields (`{input=true, placeholder=, action=fn}`).

## Shipped on feat/plugin-events

All four below landed and build clean. `pane-output` was verified end-to-end via an
isolated daemon run (subscriber received live output incl. a marker, no ring replay).
A `HALO_MUX_DIR` env override (MuxPaths) isolates a secondary/test instance onto its
own socket — used for that test, kept because it's generally useful.

1. **`session-exited` event** — fires when a shell exits on its own (distinct
   from `session-closed`, which is user-initiated). Hook: `GhosttyApp.closeSurface`
   when `processAlive == false`. *(done)*

2. **UI primitive enrichment** — additive, non-breaking:
   - `halo.confirm(message, fn)` → `fn(true|false)`. Yes/no dialog (today only
     free-text `halo.prompt` exists).
   - `halo.prompt(message, default, fn)` — optional initial value.
   Both reuse `PickerOverlay`. Kept minimal on purpose; add more primitives when
   a concrete plugin needs one.

3. **Split-tree persistence** — `windows.json` currently saves only the focused
   pane's cwd per session, so a split session restores as one pane (flagged v1
   limit at `Tabs.swift:432`). Serialize the full split topology
   (`PaneTree` → nested `{leaf|split}`: per-leaf `paneID`+`cwd`+kind, per-split
   orientation+ratio), rebuild it on `hydrate`. Each leaf keeps its own `paneID`
   for correct daemon reattach. Exact divider ratios are best-effort; topology is
   guaranteed.

4. **`pane-output` event** — `halo.on("pane-output", fn(paneID, chunk))`. The one
   real architectural piece (terminal bytes flow daemon → halo-attach → libghostty,
   below the GUI). Design (from Plan agent):
   - **Tap:** GUI opens a read-only mux subscriber to the daemon (reuse
     `MuxClient`); the daemon already fans output to all clients.
   - **Protocol:** new `ClientFrame.subscribe(paneID)` tag `0x07`, bump
     `muxProtocolVersion` → 5. Subscriber is output-only: no ring replay, ignores
     input/resize, excluded from `attachedCount`, must NOT create a session.
   - **Dispatch:** new `luaFirePaneOutput(paneID, chunk)` using `lua_pushlstring`
     (byte-safe — output is binary, not UTF-8; the existing `lua_pushstring` path
     would truncate at NUL). Two args.
   - **Gating:** no subscriber socket opened unless `luaEvents["pane-output"]` is
     non-empty.
   - **Volume:** background read loop, coalesce per run-loop tick into one main
     dispatch, cap a delivery at 256KB and drop overflow (best-effort, may coalesce).
   - **Scope:** focused pane only for v1; retarget on `focus-changed` (`Tabs.swift:225`).
   - **persist-off:** documented no-op (no daemon → no bytes to tap).

## Deferred (don't forget)

- **Plugin registry / discovery** — `halo plugins search`, curated `registry.json`
  in a git repo (GitHub-as-backend, PR to submit). Install records via a side-file
  like `disabled-plugins` (keeps user config untouched). Decided design; parked
  until there's a second user. A plugin is just a git repo + `init.lua`; sharing a
  URL already works.
- **Onboarding** — starter plugin + "write your first plugin" doc page + sidebar
  empty states. Deliberately LAST: the docs/starter should reflect the new
  `pane-output` API and enriched primitives, so writing them earlier means redoing them.
- **Config per-key live updates** — libghostty has no per-key setter; we
  write-file-and-reload (`.lua-overrides.conf`). Revisit only if reload latency bites.
- **Two-window-restore behavior** — never verified what reopening with two windows
  does (only the first window fully restores; others cascade).
- **Live process restore across daemon death** — scrollback now survives (on-disk
  log), but a running process can't be serialized. Out of scope.

_Done in feat/plugin-events-2: all-panes pane-output, plugin auto-disable +
runaway-loop guard, scrollback-to-disk._
