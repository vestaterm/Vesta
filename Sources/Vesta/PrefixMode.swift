import AppKit

/// A prefix-mode action. Every case maps 1:1 onto an action that ALREADY exists
/// in Workspace/PaneTree (dispatched in Task 1.4) — prefix mode adds no new pane
/// plumbing. `detach`/`kill` are wired into the keytable + dispatch
/// now but stubbed (beep) until Milestones 2–3.
enum PrefixAction: Equatable {
    case splitVertical      // %  → ws.activeTree.splitFocused(.vertical, …)
    case splitHorizontal    // "  → ws.activeTree.splitFocused(.horizontal, …)
    case focusLeft          // h / ←
    case focusDown          // j / ↓
    case focusUp            // k / ↑
    case focusRight         // l / →
    case zoom               // z  → ws.activeTree.zoomFocused()
    case newSession         // c  → ws.newSession(ws.activeP)
    case nextSession        // n  → ws.nextSession()
    case prevSession        // p  → ws.prevSession()
    case rename             // ,  → rename the active session's project
    case detach             // d  → (stub until M3)
    case kill               // x  → (stub until M3)
}

/// The default `(key) → PrefixAction` table, used when the config supplies no
/// `vesta-prefix-bind` overrides. Keys are the SINGLE-character token a user
/// presses AFTER the prefix; arrows use the tokens "left"/"down"/"up"/"right".
/// tmux muscle memory: % / " split, h j k l + arrows navigate, z zoom, c new,
/// n/p next/prev, , rename, d detach, x kill.
let defaultPrefixKeytable: [String: PrefixAction] = [
    "%": .splitVertical,
    "\"": .splitHorizontal,
    "h": .focusLeft, "left": .focusLeft,
    "j": .focusDown, "down": .focusDown,
    "k": .focusUp, "up": .focusUp,
    "l": .focusRight, "right": .focusRight,
    "z": .zoom,
    "c": .newSession,
    "n": .nextSession,
    "p": .prevSession,
    ",": .rename,
    "d": .detach,
    "x": .kill,
]

/// Map an action NAME (config token) to a PrefixAction. Names match the
/// tmux-ish verbs; unknown names return nil (entry skipped).
private func prefixActionNamed(_ name: String) -> PrefixAction? {
    switch name {
    case "split-vertical", "split": return .splitVertical
    case "split-horizontal", "vsplit": return .splitHorizontal
    case "focus-left": return .focusLeft
    case "focus-down": return .focusDown
    case "focus-up": return .focusUp
    case "focus-right": return .focusRight
    case "zoom": return .zoom
    case "new-session": return .newSession
    case "next-session": return .nextSession
    case "prev-session": return .prevSession
    case "rename": return .rename
    case "detach": return .detach
    case "kill": return .kill
    default: return nil
    }
}

/// Build the active keytable: start from `defaultPrefixKeytable`, then apply any
/// `vesta-prefix-bind = <key>:<action>` overrides. `entries` is the raw list of
/// such values. A malformed entry (no `:`, empty key, unknown action) is skipped
/// so a typo never disarms the whole table. Case-insensitive on the action name;
/// the KEY token is taken verbatim (so `%`, `"`, `,` survive).
func parsePrefixKeytable(_ entries: [String]) -> [String: PrefixAction] {
    var table = defaultPrefixKeytable
    for raw in entries {
        guard let colon = raw.firstIndex(of: ":") else { continue }
        let key = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
        let name = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, let action = prefixActionNamed(name) else { continue }
        table[key] = action
    }
    return table
}

/// Resolve a pressed key token (a single character, or "left"/"down"/"up"/"right"
/// for arrows) to its action. Returns nil when the key isn't bound — the caller
/// cancels the pending state on a nil resolve.
func resolvePrefix(_ key: String, in table: [String: PrefixAction]) -> PrefixAction? {
    table[key]
}

/// Parse the `vesta-prefix` config value (e.g. "ctrl+b") into modifier flags + the
/// trigger key (lowercased single char). Empty/whitespace → nil (prefix disabled).
/// Recognized mod tokens: ctrl/control, alt/opt/option, shift, cmd/super/command.
/// Defaults to ctrl+b when the key is absent but mods are present is NOT done —
/// a malformed spec returns nil (prefix off) rather than guessing.
func parsePrefixSpec(_ raw: String?) -> (mods: NSEvent.ModifierFlags, key: String)? {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let tokens = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    guard !tokens.isEmpty else { return nil }
    var mods: NSEvent.ModifierFlags = []
    var key: String? = nil
    for tok in tokens {
        switch tok {
        case "ctrl", "control": mods.insert(.control)
        case "alt", "opt", "option": mods.insert(.option)
        case "shift": mods.insert(.shift)
        case "cmd", "super", "command": mods.insert(.command)
        default:
            // The single trigger key. Last non-mod token wins; must be 1 char.
            if tok.count == 1 { key = tok } else { key = nil }
        }
    }
    guard let k = key, !mods.isEmpty else { return nil }   // require a real chord
    return (mods, k)
}

/// The pending-state machine for prefix mode. Lives for the app's lifetime,
/// owned by AppDelegate (Task 1.4). Not itself a view: it calls `onArmedChange`
/// so the chrome can show/hide the indicator, and returns a resolved action from
/// `handle(...)` for the caller to dispatch. Timeout auto-cancels so a stray
/// prefix never traps the keyboard.
@MainActor
final class PrefixState {
    private(set) var armed = false
    private let timeout: TimeInterval
    private var timer: Timer?

    /// Called whenever `armed` flips, so chrome can show/hide the indicator.
    var onArmedChange: ((Bool) -> Void)?

    init(timeout: TimeInterval = 2.0) { self.timeout = timeout }

    /// Arm the prefix (the user pressed the prefix chord). Starts the timeout.
    func arm() {
        armed = true
        onArmedChange?(true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    /// Cancel the pending state (timeout, Escape, or an unbound key).
    func cancel() {
        guard armed else { return }
        armed = false
        timer?.invalidate(); timer = nil
        onArmedChange?(false)
    }

    /// While armed, consume the next key: resolve it (and disarm), or cancel on a
    /// nil resolve. `isEscape` short-circuits to a plain cancel. Returns the action
    /// to dispatch, or nil if the key cancelled/was swallowed. Always disarms.
    func handle(key: String, isEscape: Bool, table: [String: PrefixAction]) -> PrefixAction? {
        guard armed else { return nil }
        defer { cancel() }            // any consumed key disarms (cancel() flips indicator off)
        if isEscape { return nil }
        return resolvePrefix(key, in: table)
    }
}

// MARK: - Self-check (pure logic: keytable parse + resolve)

func prefixKeytableSelfCheck() {
    // Default table covers all 13 actions (17 entries: 13 actions, 4 arrow aliases).
    let d = defaultPrefixKeytable
    assert(d.count == 17, "defaultPrefixKeytable should have 17 entries (13 actions, 4 arrow aliases)")
    assert(d["%"] == .splitVertical)
    assert(d["\""] == .splitHorizontal)
    assert(d["h"] == .focusLeft)
    assert(d["left"] == .focusLeft)
    assert(d["j"] == .focusDown)
    assert(d["down"] == .focusDown)
    assert(d["k"] == .focusUp)
    assert(d["up"] == .focusUp)
    assert(d["l"] == .focusRight)
    assert(d["right"] == .focusRight)
    assert(d["z"] == .zoom)
    assert(d["c"] == .newSession)
    assert(d["n"] == .nextSession)
    assert(d["p"] == .prevSession)
    assert(d[","] == .rename)
    assert(d["d"] == .detach)
    assert(d["x"] == .kill)
    // Default table resolves the canonical tmux bindings.
    assert(resolvePrefix("%", in: d) == .splitVertical, "% splits vertical")
    assert(resolvePrefix("\"", in: d) == .splitHorizontal, "\" splits horizontal")
    assert(resolvePrefix("h", in: d) == .focusLeft, "h focuses left")
    assert(resolvePrefix("left", in: d) == .focusLeft, "← focuses left")
    assert(resolvePrefix("l", in: d) == .focusRight, "l focuses right")
    assert(resolvePrefix("z", in: d) == .zoom, "z zooms")
    assert(resolvePrefix("c", in: d) == .newSession, "c new session")
    assert(resolvePrefix("n", in: d) == .nextSession, "n next")
    assert(resolvePrefix("p", in: d) == .prevSession, "p prev")
    assert(resolvePrefix(",", in: d) == .rename, ", renames")
    assert(resolvePrefix("d", in: d) == .detach, "d detach")
    assert(resolvePrefix("x", in: d) == .kill, "x kill")
    // Unbound key → nil (caller cancels).
    assert(resolvePrefix("Q", in: d) == nil, "unbound key resolves nil")

    // Overrides: rebind a key, add a new one, leave the rest untouched.
    let t = parsePrefixKeytable(["v:split-vertical", "x:zoom"])
    assert(resolvePrefix("v", in: t) == .splitVertical, "override adds v→splitVertical")
    assert(resolvePrefix("x", in: t) == .zoom, "override rebinds x→zoom")
    assert(resolvePrefix("h", in: t) == .focusLeft, "non-overridden keys keep defaults")

    // Malformed entries are skipped, never crash, never disarm the table.
    let m = parsePrefixKeytable(["", "nope", ":zoom", "q:bogus-action", "q:kill"])
    assert(resolvePrefix("q", in: m) == .kill, "last valid entry for a key wins; junk skipped")
    assert(resolvePrefix("%", in: m) == .splitVertical, "malformed input leaves defaults intact")

    print("prefixKeytableSelfCheck OK")
}

// MARK: - Self-check (parsePrefixSpec + PrefixState transitions)

@MainActor
func prefixSpecSelfCheck() {
    // nil / whitespace → disabled
    assert(parsePrefixSpec(nil) == nil, "nil spec → disabled")
    assert(parsePrefixSpec("  ") == nil, "whitespace spec → disabled")

    // Valid chords parse to the right flags + key
    let ctrlB = parsePrefixSpec("ctrl+b")
    assert(ctrlB != nil, "ctrl+b should parse")
    assert(ctrlB!.mods.contains(.control), "ctrl+b mods contains .control")
    assert(ctrlB!.key == "b", "ctrl+b key == b")

    let cmdA = parsePrefixSpec("cmd+a")
    assert(cmdA != nil, "cmd+a should parse")
    assert(cmdA!.mods.contains(.command), "cmd+a mods contains .command")
    assert(cmdA!.key == "a", "cmd+a key == a")

    // Malformed specs return nil
    assert(parsePrefixSpec("b") == nil, "no-mod spec → nil")
    assert(parsePrefixSpec("ctrl+esc") == nil, "multi-char key → nil")

    // PrefixState transitions (synchronous — no timeout firing)
    let ps = PrefixState()
    assert(!ps.armed, "fresh PrefixState not armed")

    ps.arm()
    assert(ps.armed, "after arm() → armed == true")

    // handle a bound key → resolves, then disarms
    let action = ps.handle(key: "%", isEscape: false, table: defaultPrefixKeytable)
    assert(action == .splitVertical, "% → splitVertical")
    assert(!ps.armed, "after handle() → disarmed")

    // Escape cancels, returns nil
    ps.arm()
    assert(ps.armed, "re-armed")
    let escaped = ps.handle(key: "q", isEscape: true, table: defaultPrefixKeytable)
    assert(escaped == nil, "escape → nil")
    assert(!ps.armed, "after escape → disarmed")

    // Unbound key cancels, returns nil
    ps.arm()
    assert(ps.armed, "re-armed for unbound test")
    let unbound = ps.handle(key: "Z", isEscape: false, table: defaultPrefixKeytable)
    assert(unbound == nil, "unbound key → nil")
    assert(!ps.armed, "after unbound → disarmed")

    print("prefixSpecSelfCheck ok")
}
