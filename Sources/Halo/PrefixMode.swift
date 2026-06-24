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

/// Parse `halo-prefix-bind` config lines of the form `key action` into a keytable.
/// Unknown tokens are silently skipped. Entries override `defaultPrefixKeytable`
/// when merged in Task 1.2.
func parsePrefixKeytable(_ entries: [String]) -> [String: PrefixAction] {
    let nameToAction: [String: PrefixAction] = [
        "split-vertical": .splitVertical,
        "split-horizontal": .splitHorizontal,
        "focus-left": .focusLeft,
        "focus-down": .focusDown,
        "focus-up": .focusUp,
        "focus-right": .focusRight,
        "zoom": .zoom,
        "new-session": .newSession,
        "next-session": .nextSession,
        "prev-session": .prevSession,
        "rename": .rename,
        "switcher": .switcher,
        "detach": .detach,
        "kill": .kill,
    ]
    var table: [String: PrefixAction] = [:]
    for entry in entries {
        let parts = entry.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let action = nameToAction[parts[1]] else { continue }
        table[parts[0]] = action
    }
    return table
}

func prefixModeSelfCheck() {
    // defaultPrefixKeytable coverage: all 14 actions are reachable
    assert(defaultPrefixKeytable["%"] == .splitVertical)
    assert(defaultPrefixKeytable["\""] == .splitHorizontal)
    assert(defaultPrefixKeytable["h"] == .focusLeft)
    assert(defaultPrefixKeytable["left"] == .focusLeft)
    assert(defaultPrefixKeytable["j"] == .focusDown)
    assert(defaultPrefixKeytable["down"] == .focusDown)
    assert(defaultPrefixKeytable["k"] == .focusUp)
    assert(defaultPrefixKeytable["up"] == .focusUp)
    assert(defaultPrefixKeytable["l"] == .focusRight)
    assert(defaultPrefixKeytable["right"] == .focusRight)
    assert(defaultPrefixKeytable["z"] == .zoom)
    assert(defaultPrefixKeytable["c"] == .newSession)
    assert(defaultPrefixKeytable["n"] == .nextSession)
    assert(defaultPrefixKeytable["p"] == .prevSession)
    assert(defaultPrefixKeytable[","] == .rename)
    assert(defaultPrefixKeytable["s"] == .switcher)
    assert(defaultPrefixKeytable["d"] == .detach)
    assert(defaultPrefixKeytable["x"] == .kill)
    assert(defaultPrefixKeytable.count == 18)   // 14 actions, 4 arrow aliases

    // parsePrefixKeytable: valid entry parsed, unknown action skipped
    let parsed = parsePrefixKeytable(["a split-vertical", "b bogus"])
    assert(parsed["a"] == .splitVertical)
    assert(parsed["b"] == nil)
    assert(parsed.count == 1)

    // parsePrefixKeytable: empty input → empty table
    assert(parsePrefixKeytable([]).isEmpty)

    print("prefixModeSelfCheck ok")
}
