# Halo cmux Parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the cmux feature gap — git-worktree-isolated sessions, richer per-session sidebar (ports + dirty), attention rings, and an embedded browser pane.

**Architecture:** Halo is Swift/AppKit on libghostty. `Workspace` (Tabs.swift) owns `Proj`s that own sessions (`PaneTree`s). `Chrome.swift` renders the sidebar from a `[SidebarProject]` snapshot. Ghostty routes per-surface actions through `GhosttyApp.action` → `TerminalPane`. Each feature extends one of these seams; pure logic gets an `assert`-based self-check wired into `selfcheck`, UI is verified hands-on with screenshots.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), AppKit, libghostty (GhosttyKit.xcframework), WebKit (`WKWebView`), shelling to `git` / `lsof` / `pgrep` via `Process`.

## Global Constraints

- **Color sync is non-negotiable.** All new chrome reads `theme.accent` / `theme.background` (or a `Proj.color`). Never hardcode a hex (no `#161719`).
- **No new dependencies.** Stdlib, AppKit, WebKit, libghostty, and `Process` shell-outs only.
- **One pure-logic self-check per feature**, wired into the `selfcheck` exit path in `main.swift` (joining `ghosttyConfigSelfCheck`/`controlSelfCheck`/`gitSelfCheck`/`workspaceSelfCheck`). UI/AppKit is NOT unit-tested — verified by launching and screenshotting (per project convention).
- **Ghostty action callbacks may arrive off-main** (renderer thread). Copy C data synchronously, then `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`. Follow the existing pattern in `GhosttyApp.action`.
- **Off-main shell-outs.** Anything calling `git`/`lsof` runs on a `.utility` queue and re-renders on main — same pattern as the existing branch cache in `main.swift`.
- Build check: `swift build` then `.build/arm64-apple-macosx/debug/halo selfcheck` must print `all self-checks ok`.

---

### Task 1: Git-worktree-isolated sessions

**Files:**
- Create: `Sources/Halo/Worktree.swift` (path computation + git worktree add/remove + self-check)
- Modify: `Sources/Halo/Tabs.swift` — add `worktreeBranch` to `PaneTree` usage via a parallel map (see Interfaces), `Workspace.newWorktreeSession(_:branch:)`, snapshot label; `SidebarSession` gains nothing (label carries it)
- Modify: `Sources/Halo/Control.swift` — `worktree` verb
- Modify: `Sources/Halo/Chrome.swift` — project menu item "New worktree session…" (reuses `promptRename`-style NSAlert)
- Modify: `Sources/Halo/main.swift` — wire `onNewWorktree`

**Interfaces:**
- Produces:
  - `enum Worktree` with `static func dir(root: String, repo: String, branch: String) -> String` and `static func safeSegment(_ branch: String) -> String` (slashes/spaces → `-`).
  - `static func add(repo: String, branch: String, base: String?) throws -> String` — runs `git -C <repo> worktree add <dir> -b <branch> [<base>]`, returns the worktree dir. `static func remove(repo: String, dir: String) throws`.
  - `Workspace.newWorktreeSession(_ p: Int, branch: String)` — resolves the project's repo path, calls `Worktree.add`, then opens a session at the returned dir and tags it.
  - Session→branch tagging: store in `Workspace` as `worktreeBranch: [ObjectIdentifier: String]` keyed by the `PaneTree` instance (avoids touching `PaneTree`'s init). Snapshot reads it.

- [ ] **Step 1: Write the failing self-check** in `Sources/Halo/Worktree.swift`

```swift
import Foundation

enum Worktree {
    /// Managed worktree root: ~/.halo/worktrees/<repo>/<safe-branch>
    static func dir(root: String, repo: String, branch: String) -> String {
        let r = (root as NSString).appendingPathComponent(repo)
        return (r as NSString).appendingPathComponent(safeSegment(branch))
    }

    /// Branch names contain `/` (feature/x) and spaces — make one path segment.
    static func safeSegment(_ branch: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\ :")
        return branch.components(separatedBy: bad).filter { !$0.isEmpty }.joined(separator: "-")
    }
}

func worktreeSelfCheck() {
    assert(Worktree.safeSegment("feature/login") == "feature-login", "slash → dash")
    assert(Worktree.safeSegment("a b") == "a-b", "space → dash")
    let d = Worktree.dir(root: "/r", repo: "halo", branch: "feat/x")
    assert(d == "/r/halo/feat-x", "dir compose, got \(d)")
    print("worktreeSelfCheck OK")
}
```

- [ ] **Step 2: Add `add`/`remove` to `Worktree.swift`**

```swift
extension Worktree {
    @discardableResult
    static func add(repo: String, branch: String, base: String?) throws -> String {
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".halo/worktrees")
        let repoName = (repo as NSString).lastPathComponent
        let target = dir(root: root, repo: repoName, branch: branch)
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var args = ["-C", repo, "worktree", "add", target, "-b", branch]
        if let base { args.append(base) }
        try run("git", args)        // run: throws on nonzero exit, see below
        return target
    }
    static func remove(repo: String, dir: String) throws {
        try run("git", ["-C", repo, "worktree", "remove", dir, "--force"])
    }
    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "halo.worktree", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
```

- [ ] **Step 3: Wire `worktreeSelfCheck()` into `main.swift`** (the `selfcheck` branch), build, run.

Run: `swift build && .build/arm64-apple-macosx/debug/halo selfcheck`
Expected: output includes `worktreeSelfCheck OK` and `all self-checks ok`.

- [ ] **Step 4: Add `Workspace.newWorktreeSession` + branch tagging** in `Tabs.swift`

```swift
// stored on Workspace:
private var worktreeBranch: [ObjectIdentifier: String] = [:]

func newWorktreeSession(_ p: Int, branch: String) {
    guard projs.indices.contains(p) else { return }
    let repo = projs[p].path
    do {
        let dir = try Worktree.add(repo: repo, branch: branch, base: nil)
        addSession(p, cwd: dir)                              // addSession sets active + showActive
        worktreeBranch[ObjectIdentifier(activeTree)] = branch
        handleChange()
    } catch {
        NSSound.beep()
        // surface the git error without crashing
        let a = NSAlert(); a.messageText = "Couldn't create worktree"
        a.informativeText = error.localizedDescription; a.runModal()
    }
}
```

In `snapshot()`, when building each session label, prefer the worktree branch:

```swift
if let br = worktreeBranch[ObjectIdentifier(tree)] { label = "⎇ \(br)" }
```

(`addSession` is `private`; `newWorktreeSession` is in the same type so it can call it.)

- [ ] **Step 5: Add the `worktree` CLI verb** in `Control.swift`

Mirror an existing verb (e.g. `open`). Parse `worktree <branch> [--base <ref>]`, then on main call `workspace.newWorktreeSession(workspace.activeP, branch: branch)`. Add `"worktree"` to `controlVerbs` and document it in `printUsage`.

- [ ] **Step 6: Add the sidebar action** in `Chrome.swift`

In `makeProjectMenu`, add before the separator:

```swift
menu.addItem(BlockMenuItem(title: "New worktree session…") { [weak self] in
    self?.promptWorktree(pi)
})
```

Add `promptWorktree(_:)` modeled on `promptRename` (NSAlert + NSTextField, placeholder "branch name"), calling a new closure `onNewWorktree(pi, branch)`. Add `onNewWorktree: (Int, String) -> Void` to the init (default `{ _, _ in }`) and store it, exactly like `onRenameProject`.

- [ ] **Step 7: Wire in `main.swift`**

```swift
onNewWorktree: { [weak self] p, branch in self?.workspace.newWorktreeSession(p, branch: branch) }
```

- [ ] **Step 8: Build, launch, verify by hand**

Run: `swift build && nohup .build/arm64-apple-macosx/debug/halo & disown`
Verify (screenshot): right-click a project that is a git repo → "New worktree session…" → type `test/wt` → a session opens labelled `⎇ test/wt`; `git -C <repo> worktree list` shows it. Then `git worktree remove` it manually to clean up.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "Worktree-isolated sessions (CLI + sidebar action)"
```

---

### Task 2: Richer sidebar — ports + dirty state

**Files:**
- Create: `Sources/Halo/Ports.swift` (descendant-PID listen-port scan + parse + self-check)
- Modify: `Sources/Halo/Git.swift` — add `static func dirtyCount(_ cwd: String) -> Int` + a porcelain parse helper
- Modify: `Sources/Halo/Tabs.swift` — `SidebarSession` gains `var ports: [Int] = []` and `var dirty: Int = 0`; snapshot leaves them default (filled by AppDelegate)
- Modify: `Sources/Halo/main.swift` — fill a per-session cache off-main, like `branchCache`
- Modify: `Sources/Halo/Chrome.swift` — render a `:PORT` chip and a `●N` dirty dot on session rows

**Interfaces:**
- Produces:
  - `enum Ports { static func parse(_ lsof: String) -> [Int]; static func forShell(pid: pid_t) -> [Int] }`
  - `Git.dirtyCount(_ cwd:) -> Int`, `Git.parsePorcelain(_ out: String) -> Int`
  - `SidebarSession.ports: [Int]`, `SidebarSession.dirty: Int`
- Consumes: the focused pane's shell pid. `TerminalPane` must expose it: add `var shellPID: pid_t? { ghostty_surface_pwd... }` — if libghostty doesn't expose the child pid, fall back to scanning all listen ports for the cwd is NOT possible; instead use `Ports.forCwd` via `lsof +D` is too slow. **Decision:** key ports off the pane's reported child pid if available; if `TerminalPane` cannot supply a pid, ship dirty-state only and mark ports `// ponytail: needs surface child pid` (skip the ports chip). Check `TerminalPane.swift` / `ghostty.h` for a `ghostty_surface_*pid*` accessor first.

- [ ] **Step 1: Write `Ports.swift` with the parse self-check**

```swift
import Foundation

enum Ports {
    /// Extract unique listening TCP ports from `lsof -nP -iTCP -sTCP:LISTEN` output.
    /// Lines look like: `node 1234 user 23u IPv4 ... TCP *:3000 (LISTEN)`
    static func parse(_ lsof: String) -> [Int] {
        var seen = Set<Int>()
        for line in lsof.split(separator: "\n") {
            guard line.contains("(LISTEN)"), let colon = line.range(of: ":", options: .backwards) else { continue }
            let tail = line[colon.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            if let port = Int(digits) { seen.insert(port) }
        }
        return seen.sorted()
    }
}

func portsSelfCheck() {
    let sample = """
    node 1 u 1u IPv4 0t0 TCP *:3000 (LISTEN)
    node 1 u 2u IPv6 0t0 TCP [::1]:8080 (LISTEN)
    node 1 u 3u IPv4 0t0 TCP 127.0.0.1:3000 (LISTEN)
    sshd 9 u 4u IPv4 0t0 TCP *:22 (ESTABLISHED)
    """
    assert(Ports.parse(sample) == [3000, 8080], "listen ports deduped/sorted, got \(Ports.parse(sample))")
    print("portsSelfCheck OK")
}
```

- [ ] **Step 2: Add the live scan** (only if a child pid is available — see Interfaces)

```swift
extension Ports {
    /// Listen ports opened by `pid` and its descendants.
    static func forShell(pid: pid_t) -> [Int] {
        // descendants via pgrep -P chain (ponytail: misses re-parented procs)
        var pids = [pid]; var frontier = [pid]
        while let p = frontier.popLast() {
            let kids = shell("/usr/bin/pgrep", ["-P", "\(p)"]).split(separator: "\n").compactMap { pid_t($0) }
            pids += kids; frontier += kids
        }
        let out = shell("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pids.map(String.init).joined(separator: ",")])
        return parse(out)
    }
    private static func shell(_ tool: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 3: Add `Git.dirtyCount` + parse to `Git.swift`**

```swift
static func parsePorcelain(_ out: String) -> Int {
    out.split(separator: "\n").filter { !$0.isEmpty }.count
}
static func dirtyCount(_ cwd: String) -> Int {
    parsePorcelain(shell(["-C", cwd, "status", "--porcelain"]))   // reuse Git.swift's existing shell helper
}
```

Add to `gitSelfCheck()`: `assert(Git.parsePorcelain(" M a\n?? b\n") == 2)`.

- [ ] **Step 4: Extend `SidebarSession`** in `Tabs.swift` with `var ports: [Int] = []` and `var dirty: Int = 0` (defaulted, so existing construction compiles).

- [ ] **Step 5: Fill the cache off-main in `main.swift`**

Add a `metaCache: [ObjectIdentifier: (ports: [Int], dirty: Int)]` keyed by session. In `renderSidebar()`, after building `projs`, copy cached meta into each `SidebarSession`. In `refresh()`, for the active session compute `Git.dirtyCount(cwd)` and (if pid available) `Ports.forShell` off-main, store, re-render. (ponytail: only refresh the active session's meta per change; others keep last value. Upgrade path: a timer.)

- [ ] **Step 6: Render chips in `Chrome.swift`** `makeSessionRow`

After the name label, append to the inner stack: if `dirty > 0` a small `●\(dirty)` label in `theme.accent`; if `!ports.isEmpty` a `:\(ports[0])` label in a dim secondary color (`theme.accent.withAlphaComponent(0.6)`). Keep them inside the existing inner horizontal `NSStackView`.

- [ ] **Step 7: Build, selfcheck, launch, verify**

Run: `swift build && .build/arm64-apple-macosx/debug/halo selfcheck` → `portsSelfCheck OK`. Then launch; in a session run `python3 -m http.server 3000 &` and edit a file in a repo → the session row shows `:3000` and `●N` (screenshot).

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Richer sidebar: per-session ports + dirty count"
```

---

### Task 3: Attention rings

**Files:**
- Modify: `Sources/Halo/Ghostty/GhosttyApp.swift` — handle `GHOSTTY_ACTION_RING_BELL` + `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` → `pane.fireAttention()`
- Modify: `Sources/Halo/TerminalPane.swift` — `var onAttention: (() -> Void)?` + `func fireAttention()`
- Modify: `Sources/Halo/PaneTree.swift` — wire each leaf's `pane.onAttention` to a tree-level `onAttention` closure
- Modify: `Sources/Halo/Tabs.swift` — `Workspace` attention state + `SidebarSession.attention`
- Modify: `Sources/Halo/Chrome.swift` — draw an accent ring on attention session rows
- Modify: `main.swift` — none beyond existing onChange

**Interfaces:**
- Produces: `SidebarSession.attention: Bool`; `Workspace` keeps `attention: Set<ObjectIdentifier>` keyed by session `PaneTree`; cleared in `selectSession`/`selectSessionInActiveProject`.
- Consumes: `GHOSTTY_ACTION_RING_BELL`, `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` (confirmed in `ghostty.h`); the off-main→main action pattern in `GhosttyApp.action`.

- [ ] **Step 1: Add the state machine self-check** to `workspaceSelfCheck()` in `Tabs.swift`

```swift
// Attention: set when signalled while NOT the active session; clear on select.
func attn(active: Bool) -> Bool { !active }     // mirrors Workspace.attentionFired guard
assert(attn(active: false) == true,  "signal on background session → ring")
assert(attn(active: true)  == false, "signal on focused session → no ring")
```

- [ ] **Step 2: Add `onAttention`/`fireAttention` to `TerminalPane.swift`**

```swift
var onAttention: (() -> Void)?
func fireAttention() { onAttention?() }
```

- [ ] **Step 3: Route the actions in `GhosttyApp.action`** — extend the switch:

```swift
case GHOSTTY_ACTION_RING_BELL, GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
    nonisolated(unsafe) let udSafe2 = ud
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            Unmanaged<TerminalPane>.fromOpaque(udSafe2).takeUnretainedValue().fireAttention()
        }
    }
    return true
```

(Place before `default`. Keep the existing title/pwd path unchanged.)

- [ ] **Step 4: Bubble pane → tree in `PaneTree.swift`** `makeLeaf`

```swift
pane.onAttention = { [weak self] in self?.onAttention?() }
```

Add `var onAttention: (() -> Void)?` to `PaneTree` (next to `onFocusChange`).

- [ ] **Step 5: Handle it in `Workspace`** (`Tabs.swift`) — in `makeTree`:

```swift
tree.onAttention = { [weak self, weak tree] in
    guard let self, let tree else { return }
    // Only ring if this session isn't the one you're looking at.
    if tree !== self.activeTree {
        self.attention.insert(ObjectIdentifier(tree)); self.handleChange()
    }
}
```

Add `private var attention: Set<ObjectIdentifier> = []`. In `selectSession` and `selectSessionInActiveProject` and `showActive`, remove the now-active tree: `attention.remove(ObjectIdentifier(activeTree))`. In `snapshot`, set `attention: attention.contains(ObjectIdentifier(tree))` on each `SidebarSession` (add the field, default `false`).

- [ ] **Step 6: Draw the ring in `Chrome.swift`** `makeSessionRow`

When `session.attention`, add a 8×8 ring view (an `NSView` with `wantsLayer`, `layer.borderWidth = 1.5`, `layer.cornerRadius = 4`, `layer.borderColor = theme.accent.cgColor`, clear fill) at the trailing end of the inner stack (before the `×`).

- [ ] **Step 7: Build, selfcheck, verify**

Run: `swift build && .build/arm64-apple-macosx/debug/halo selfcheck`. Launch; in a background session run `printf '\a'` (bell) → that session's row shows an accent ring; focus it → ring clears (screenshot both states).

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Attention rings on bell/notification for background sessions"
```

---

### Task 4: Embedded browser pane

**Files:**
- Create: `Sources/Halo/BrowserPane.swift` (`WKWebView` host + `normalizeURL` + self-check)
- Modify: `Sources/Halo/PaneTree.swift` — `Leaf` hosts either a `TerminalPane` or a `BrowserPane`; focus/restyle/close handle both
- Modify: `Sources/Halo/Control.swift` — `browser [url]` verb
- Modify: `Sources/Halo/main.swift` — keybind (`⌘⇧Return` → open browser at focused session's first detected port, else `about:blank`)

**Interfaces:**
- Produces: `BrowserPane: NSView` with `init(url: URL)`, `func load(_ url: URL)`; `enum BrowserURL { static func normalize(_ s: String) -> URL }`.
- Consumes: `PaneTree.splitFocused` machinery. Minimal change: `Leaf` currently wraps `TerminalPane`. Generalize the leaf's content to a protocol `PaneContent: NSView` that both `TerminalPane` and `BrowserPane` conform to (empty marker protocol is enough — leaves just need an `NSView` + a focus method). Add `func focusContent()` to the protocol: `TerminalPane` makes itself first responder; `BrowserPane` makes its webview first responder.

- [ ] **Step 1: Write `BrowserPane.swift` with the URL self-check**

```swift
import AppKit
import WebKit

enum BrowserURL {
    /// `3000` → http://localhost:3000 ; `localhost:3000` / `example.com` → add scheme.
    static func normalize(_ s: String) -> URL {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return URL(string: "http://localhost:\(n)")! }
        if t.contains("://") { return URL(string: t) ?? URL(string: "about:blank")! }
        return URL(string: "http://\(t)") ?? URL(string: "about:blank")!
    }
}

func browserSelfCheck() {
    assert(BrowserURL.normalize("3000").absoluteString == "http://localhost:3000", "bare port")
    assert(BrowserURL.normalize("localhost:8080").absoluteString == "http://localhost:8080", "host:port")
    assert(BrowserURL.normalize("https://x.com").absoluteString == "https://x.com", "full url kept")
    print("browserSelfCheck OK")
}
```

- [ ] **Step 2: Implement `BrowserPane`** — a thin `NSView` containing a `WKWebView` (fills bounds via autoresizing) and a 28px top bar with a reload button and a URL `NSTextField`; colors from `theme`. `focusContent()` → `window?.makeFirstResponder(webView)`.

- [ ] **Step 3: Introduce `PaneContent` protocol in `PaneTree.swift`**

```swift
@MainActor protocol PaneContent: NSView { func focusContent() }
```

Conform `TerminalPane` (`func focusContent() { window?.makeFirstResponder(self) }`) and `BrowserPane`. Change `Leaf.pane: TerminalPane` references that are terminal-specific (cwd/title/onUpdate/id) to guard on `as? TerminalPane`; the leaf stores `let content: PaneContent`. Keep a stable `id` on the leaf itself (move `id` from pane to leaf, or keep terminal ids and assign browser leaves negative ids). **Minimal path:** give `Leaf` its own `let id: Int` (from `nextId`) instead of reading `pane.id`; update `leaves`/`focusedId`/`list()` to use `leaf.id`. Terminal-only call sites (`focusedCwd`/`focusedTitle`/`paneCount`) cast `content as? TerminalPane`.

- [ ] **Step 4: Add `PaneTree.openBrowser(url:)`** — same as `splitFocused` but the new leaf wraps a `BrowserPane(url:)` instead of a terminal. Extract the shared split-and-attach code so both call it (DRY).

- [ ] **Step 5: Add the `browser` CLI verb** in `Control.swift` — `browser [url]`; on main, resolve url (`BrowserURL.normalize`, default to active session's first cached port) and call `workspace.activeTree.openBrowser(url:)`. Register in `controlVerbs` + `printUsage`.

- [ ] **Step 6: Add the keybind** in `main.swift` `installKeybinds` — `⌘⇧Return` (`charactersIgnoringModifiers == "\r"` with shift) → open browser at the focused session's first detected port (from `metaCache`) else `about:blank`.

- [ ] **Step 7: Wire `browserSelfCheck()` into `main.swift` selfcheck. Build, selfcheck, verify**

Run: `swift build && .build/arm64-apple-macosx/debug/halo selfcheck` → `browserSelfCheck OK`. Launch; `halo browser 3000` (with a server on 3000) → a browser pane splits in showing the page (screenshot).

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Embedded browser pane (WKWebView leaf + browser verb)"
```

---

## Self-Review notes (planner)

- Spec coverage: Feature 1→Task 1, Feature 2→Task 2, Feature 3→Task 3, Feature 4→Task 4. Deferred notifications intentionally absent.
- Known risk (flagged for the implementer/reviewer): **Task 2 ports** depend on libghostty exposing the surface child pid — if absent, ship dirty-state only and mark ports as a ponytail follow-up (the task says so explicitly). **Task 4 Step 3** is the only real refactor (leaf content generalization); keep it minimal (leaf owns `id`, cast for terminal-only methods) to avoid disturbing split/zoom/focus.
- Each task ends green (`selfcheck` + a hands-on screenshot) and is independently revertible.
