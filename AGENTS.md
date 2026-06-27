# AGENTS.md — rules for AI agents working in Vesta

Vesta is a native macOS terminal built on **libghostty** (linked as
`GhosttyKit.xcframework`, *not* a fork), with a project sidebar, tmux-style
splits, a persistent-session daemon, embedded Lua plugins, and a scriptable
`vesta` CLI. Swift/AppKit. Bundle id `io.github.notnaki.vesta`.

Read this before changing anything. Follow it.

## Golden rules

1. **Match the surrounding code.** Comment density, naming, and idioms vary by
   file — imitate the file you're editing. Don't reformat code you didn't change.
2. **Minimal diffs (ponytail).** Ship the smallest change that works. No
   speculative abstractions, no scaffolding "for later", delete before adding.
   Mark deliberate shortcuts with a `ponytail:` comment.
3. **Never hardcode the version.** It's stamped from the git tag by
   `make-app.sh`. Read `Updater.currentVersion` (or `CFBundleShortVersionString`)
   — see the past bug where About/sidebar showed a stale `0.1.0`.
4. **Verify against a RELEASE build, not just `swift run`.** Several bugs only
   appeared in the signed/notarized bundle (resource lookup, release-only
   `assert` elision). When in doubt, `./make-app.sh release` and run the bundle.

## Build / run / test

```sh
swift build                                   # fetches GhosttyKit automatically
swift run vesta selfcheck                     # pure-logic checks — MUST pass before commit
./make-app.sh [release|debug]                 # build Vesta.app (stamps version/build/commit)
open Vesta.app
```

- `selfcheck` is the test harness — add an assertion there for non-trivial logic.
  It also fails loudly if bundled resources (fonts) can't be found.
- **`assert(...)` is compiled out in release.** Never put a side-effecting call
  inside `assert(...)` — hoist the call out, assert on the result.

## Architecture (where things live, all under `Sources/`)

- `Vesta/main.swift` — `AppDelegate`, app lifecycle, ⌘ keybinds, Lua bridge,
  toasts/notifications, onboarding + update wiring.
- `Vesta/Chrome.swift` — window, titlebar accessories, sidebar (incl. the update
  badge + version footer).
- `Vesta/Control.swift` — the `vesta` CLI verbs + the Unix-socket server.
- `Vesta/Tabs.swift` — `SessionStore` (app-owned pool) + `Workspace` (per-window view).
- `Vesta/Updater.swift` — in-app self-update (download DMG → swap → relaunch).
- `Vesta/Notifier.swift`, `AboutWindow.swift`, `OnboardingOverlay.swift` — self-named.
- `vestad/` — the session daemon (one `forkpty`'d shell per pane + raw output ring).
- `vesta-attach/` — the per-pane relay ghostty spawns; dumb byte pump over a `0600` socket.
- `VestaMux/` — shared wire protocol (`MuxProtocol`) + paths (`MuxPaths`).

Sessions persist via `vestad` independently of the app — shells (and anything
running in them) survive quit/relaunch and reattach. Don't assume the app owns the PTY.

## Config & CLI

- User config is the ghostty config plus `vesta-*` keys (libghostty ignores them).
  Every `vesta-*` default matches the built-in look. Plugins are Lua folders under
  `~/.config/vesta/plugins/`.
- The `vesta` CLI drives the running app over `~/Library/Application Support/vesta/control.sock`.
  `vesta help` is authoritative; keep usage text + README in sync when adding a verb.

## Icon (read before touching it — this bit a previous agent)

The app icon is an **Icon Composer** document, `AppIcon.icon`. `actool` only
renders it on **macOS 26 / Xcode 26**, which the CI runner (macos-15) lacks — so
the rendered `AppIcon.icns` + `Assets.car` are **pre-rendered and committed under
`AppIcon-prebuilt/`**, and `make-app.sh` ships those directly. A pre-rounded
`.icns` alone makes Tahoe add a second squircle ("box plate"), so `Assets.car`
(with `CFBundleIconName`) must ship. After editing `AppIcon.icon`, re-render and
re-commit `AppIcon-prebuilt/` (command is in `make-app.sh`).

## Workflow

- Branch → PR → independent review → merge (squash). Don't commit feature work
  straight to `main`. Run `swift build` + `swift run vesta selfcheck` before
  committing.
- Releases: push a `vX.Y.Z` tag → `.github/workflows/release.yml` builds, signs
  (Developer ID), notarizes, smoke-tests the bundle, and publishes a DMG. Manual
  `workflow_dispatch` is a dry run (builds + signs + notarizes, no publish).
- Keep README / `docs/` accurate when behavior or the CLI/Lua API changes.
- End commit messages with the `Co-Authored-By` trailer.

## Don't

- Don't reintroduce a Ghostty fork — link the xcframework.
- Don't break the `vesta-*`-defaults-match-built-in invariant.
- Don't add dependencies for what a few lines of stdlib/AppKit can do.
- Don't disable the hardened-runtime entitlements (notarization needs them).
