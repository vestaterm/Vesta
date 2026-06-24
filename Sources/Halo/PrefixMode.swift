import AppKit

/// A prefix-mode action. Every case maps 1:1 onto an action that ALREADY exists
/// in Workspace/PaneTree (dispatched in Task 1.4) — prefix mode adds no new pane
/// plumbing. `detach`/`kill`/`switcher` are wired into the keytable + dispatch
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
    case switcher           // s  → (stub until M2)
    case detach             // d  → (stub until M3)
    case kill               // x  → (stub until M3)
}

/// The default `(key) → PrefixAction` table, used when the config supplies no
/// `halo-prefix-bind` overrides. Keys are the SINGLE-character token a user
/// presses AFTER the prefix; arrows use the tokens "left"/"down"/"up"/"right".
/// tmux muscle memory: % / " split, h j k l + arrows navigate, z zoom, c new,
/// n/p next/prev, , rename, s switcher, d detach, x kill.
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
    "s": .switcher,
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
    case "switcher": return .switcher
    case "detach": return .detach
    case "kill": return .kill
    default: return nil
    }
}

/// Build the active keytable: start from `defaultPrefixKeytable`, then apply any
/// `halo-prefix-bind = <key>:<action>` overrides. `entries` is the raw list of
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

// MARK: - Self-check (pure logic: keytable parse + resolve)

func prefixKeytableSelfCheck() {
    // Default table covers all 14 actions (18 entries: 14 actions, 4 arrow aliases).
    let d = defaultPrefixKeytable
    assert(d.count == 18, "defaultPrefixKeytable should have 18 entries (14 actions, 4 arrow aliases)")
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
    assert(d["s"] == .switcher)
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
    assert(resolvePrefix("s", in: d) == .switcher, "s switcher")
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
