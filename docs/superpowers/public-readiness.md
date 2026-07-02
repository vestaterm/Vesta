# Halo — Public Release Readiness

> Synthesized from an 8-dimension council audit (licensing, security, distribution,
> stability, testing, accessibility, feature-completeness, docs). 57 findings.

## 1. Verdict

Halo is a genuinely working terminal — libghostty rendering, splits, sidebar, CLI
control plane, worktrees, and an embedded browser are all real, not stubbed. But it
is **not publicly shippable today**, and the gap is not feature depth — it is **the
legal, trust, and distribution scaffolding that turns working code into a downloadable
product**. The biggest theme: Halo behaves like a private tool that was never meant to
leave the author's machine. Fix the legal + signing + socket layer and Halo becomes
shippable; everything else is refinement.

## 2. Blockers — must fix before any public release

### Legal foundation (no right to distribute as-is)
- [x] ~~Add a root `LICENSE` file~~ — done: MIT `LICENSE` at repo root.
- [x] ~~Bundle a `NOTICE`/attribution file~~ — done: root `NOTICE` covers ghostty MIT
      (Copyright 2024 Mitchell Hashimoto, Ghostty contributors), libpng, wuffs, simdutf.
- [x] ~~Add OFL 1.1 attribution for Geist Mono + Martian Mono~~ — done: `NOTICE` carries
      OFL 1.1 attribution for Geist Mono, Martian Mono, and Redaction.
- [ ] Resolve the "Halo" name + bundle ID — `dev.halo.terminal` implies a domain you
      may not own, and "HALO" is a Microsoft trademark in the software class. Trademark
      clearance + a bundle ID you own (e.g. `com.yourdomain.halo`).

### Code signing & distribution (Gatekeeper blocks the app elsewhere)
- [ ] Developer ID signing + Hardened Runtime + notarization + staple. Replace
      `codesign --sign -` with a real identity. Without this users see "Halo is damaged."
- [ ] Document the GhosttyKit.xcframework acquisition path (download URL or `zig build`).
      It's gitignored; today an external `swift build` fails immediately.

### Security (the control socket is an unauthenticated local backdoor)
- [x] ~~`chmod(path, 0o600)` immediately after `bind()` in Control.swift~~ — done:
      Control.swift chmods the socket to 0o600 right after bind.

### Stability
- [x] ~~Fix the `closeSurface`/action-callback use-after-free~~ — done: every callback
      copies C strings synchronously, then checks a lock-guarded live-pane registry
      (`TerminalPane.isLive`) on the main actor before `takeUnretainedValue()`, so a
      pane freed by Cmd-W is never resolved after the async hop.
- [x] ~~Replace `fatalError()` on `ghostty_config_new`/`ghostty_app_new` failure~~ —
      done: config-load failure falls back to a bare default config (app still
      launches); if `ghostty_app_new` (or even an empty config) fails, a critical
      `NSAlert` explains the failure and the app terminates cleanly instead of crashing.

## 3. Important — before or shortly after launch

**Security/robustness:** socket read timeout; git flag-injection guard in `worktree`;
guard zero/negative pane sizes; timeouts on `Git.run`/`Ports.shell`; debounce `refresh()`;
auto-handle shell exit; `/usr/bin/env` → absolute git in Worktree.swift.

**Distribution:** universal binary (`--arch arm64 --arch x86_64` + `lipo`); single
version source; DMG + GitHub Releases pipeline; auto-update (Sparkle 2); fix `install.sh`
(copy, don't symlink into `.build/`); delete `install.sh.save`.

**Accessibility:** VoiceOver labels/roles for sidebar rows, tiny buttons, the terminal
view; WCAG AA contrast on faint text + count badge; Reduce Motion in sidebar toggle;
keyboard navigation for sidebar rows.

**Testing/docs:** wire `paneTreeSelfCheck()` into the selfcheck chain; CI (`swift build`
+ selfcheck on PRs) + a real testTarget; README screenshots, Gatekeeper note, a
Security/Privacy section on the socket trust model; CHANGELOG; CONTRIBUTING.

**Feature parity:** Cmd-F find; Cmd-N second window; native fullscreen; OSC 8 hyperlinks;
live config reload; session/split-layout persistence.

## 4. Nice-to-have

Strip iOS slices from the xcframework; drop unconsumed config keys from memory; evict
`sessionBusy` synchronously in `forget()`; replace force-casts; refactor the 904-line
`Chrome.swift`; system text-size scaling; sidebar drag-to-reorder; deeper Settings
(theme/font/keybind pickers); verify the real macOS 13 floor.

## 5. Phased roadmap

**Phase 1 — Ship at all (legal + security + signing):** LICENSE + NOTICE + OFL;
trademark/name/bundle ID; Developer ID signing + notarization + xcframework docs;
`chmod 0600` socket; fix callback use-after-free and `fatalError`-on-startup.

**Phase 2 — Trustworthy & usable:** universal binary, version source, DMG + Releases,
Sparkle, fixed installer; shell-out timeouts, refresh debounce, pane-size guard,
shell-exit handling; VoiceOver baseline, contrast, Reduce Motion; CI + selfcheck +
README/CHANGELOG/CONTRIBUTING.

**Phase 3 — Competitive parity:** Cmd-F, Cmd-N, fullscreen, OSC 8; live config reload +
session persistence; deeper Settings, sidebar reordering, full keyboard nav.

## Progress (this branch)
- ✅ Self-contained themes: ghostty resources vendored into `Resources/ghostty` and
  bundled into the app; `GHOSTTY_RESOURCES_DIR` set at launch so named-theme color sync
  works from Finder without an installed Ghostty. (Was Phase 3 "live config" sibling.)
- ✅ Full config editor in Settings (any ghostty key), plus a GitHub-release update check
  (lightweight; Sparkle is the Phase-2 upgrade once Developer ID signing lands).
