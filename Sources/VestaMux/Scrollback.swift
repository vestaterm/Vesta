import Foundation

/// Pure lifecycle decisions for on-disk scrollback logs (`sessions/<paneID>.log`), kept here
/// so `vesta selfcheck` can exercise them without a live daemon or the filesystem. The daemon
/// (vestad) owns the actual I/O; this is only the arithmetic it branches on.
public enum ScrollbackSweep {
    /// Startup orphan bound: a session log untouched for this long is swept on daemon start.
    /// A grace-delayed delete lost to a daemon death (logout/reboot) can strand a log whose
    /// session never comes back; nothing else would ever remove it. 30 days is deliberately
    /// generous — scrollback survives weeks of not opening a pane, but not forever.
    // ponytail: mtime-only, fixed 30d ceiling. No per-session bookkeeping, no config knob —
    // add one only if stranded logs ever actually accumulate enough to matter.
    public static let maxAgeSeconds: TimeInterval = 30 * 24 * 60 * 60

    /// True when a log last modified at `mtime` is stale as of `now` (age ≥ maxAge). Uses ≥ so
    /// exactly-maxAge sweeps. A future mtime (clock skew) yields a negative age → never stale.
    public static func isStale(mtime: TimeInterval, now: TimeInterval,
                               maxAge: TimeInterval = maxAgeSeconds) -> Bool {
        now - mtime >= maxAge
    }
}

/// How many bytes to drop from the FRONT of `data` so the remainder is at most `cap` bytes
/// AND begins at a point where a terminal can safely resume parsing. 0 when nothing is over.
///
/// The replay ring is byte-bounded, so a plain `suffix(cap)` lands wherever it lands — often
/// inside an ANSI sequence. The remainder then replays with its `ESC[` prefix missing and the
/// terminal renders the leftovers as literal text: a pane reattaches showing `;2;215;119;87m`
/// instead of a color change. Measured on a real workspace, 2 of 6 panes cut mid-sequence.
/// (The parser resyncs at the next ESC — but characters already emitted stay on screen, which
/// is the only part the user sees.)
///
/// Two bytes are safe resume points: ESC (starts a fresh sequence — in a well-formed stream it
/// is only ever an introducer, including the ESC of a String Terminator) and newline (never
/// occurs inside a CSI). Seek to whichever comes first: resume AT an ESC, AFTER a newline.
///
/// Seeking only newlines is not enough, and that is why this is not a one-liner: a pane running
/// a full-screen TUI — editor, agent — repaints with absolute cursor moves and emits no newlines
/// whatever. All six 256 KB windows measured contained zero `\n`. ESC is what is dense there.
// ponytail: forward-seek, not an escape-sequence parser, and bounded to scanWindow. It cannot
// resume mid-CSI, which is the entire failure mode. Known gap: a raw newline inside an OSC/DCS
// payload (tmux passthrough, multi-line notification body) is treated as a resume point and
// replays that payload's remainder as text — strictly rarer than the bug being fixed.
public func ringDropCount(_ data: Data, cap: Int) -> Int {
    guard data.count > cap else { return 0 }
    let drop = data.count - cap
    // Bounded scan. Past this many bytes, give up and take the raw suffix: output carrying
    // neither ESC nor newline in 4 KB is plain text, which cannot be mid-sequence anyway.
    // The bound is also what keeps this cheap — an unbounded byte-by-byte walk of a marker-free
    // 256 KB window (`cat /dev/zero`, `base64 -w0`) measured 1.5 ms, and this runs inline in
    // vestad's single-threaded select loop on every read. memchr keeps it in the low µs.
    let scanWindow = min(cap, 4096)
    let extra: Int = data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return 0 }
        let from = base.advanced(by: drop)
        let esc = memchr(from, 0x1b, scanWindow)
        let nl = memchr(from, 0x0a, scanWindow)
        let escOff = esc.map { UnsafeRawPointer($0) - from }
        let nlOff = nl.map { UnsafeRawPointer($0) - from }
        switch (escOff, nlOff) {
        case let (e?, n?): return e < n ? e : n + 1      // whichever comes first
        case let (e?, nil): return e                      // resume AT the ESC
        case let (nil, n?): return n + 1                  // resume AFTER the newline
        case (nil, nil): return 0                         // no marker in range → raw suffix
        }
    }
    return drop + extra
}

/// `data` reduced to its safe-boundary suffix. Convenience over `ringDropCount` for callers
/// that want a fresh value; the hot trim path uses the count directly with `removeFirst`.
public func ringSuffixFromSafeBoundary(_ data: Data, cap: Int) -> Data {
    let d = ringDropCount(data, cap: cap)
    return d == 0 ? data : Data(data.dropFirst(d))
}

/// Builds the restart divider stamped into a cold-restored session's ring: a mode reset, then a
/// dim rule naming the new shell's directory. The replayed history ends wherever the machine died
/// — often mid-TUI — so this must undo every STICKY mode a dead full-screen app could have left
/// on, not just colors. Leaving any of them set poisons the brand-new shell behind the divider:
///
///  - `?1049l`                  leave the alt screen (else history+prompt render into a
///                              buffer the user can't scroll back out of)
///  - `?1000l ?1002l ?1003l`    stop X10/button/any-motion mouse reporting, and
///    `?1006l`                  SGR extended coordinates — else every click and scroll
///                              injects escape junk onto the fresh command line
///  - `?7h`                     restore autowrap (a TUI that turned it off truncates lines)
///  - `[r`                      reset DECSTBM to the full screen (a leftover scroll region
///                              pins output to a few rows)
///  - `?25h`                    show the cursor again (DECTCEM — the most visible failure:
///                              a working shell that looks frozen because it has no cursor)
///  - `(B`                      G0 back to ASCII (a leftover line-drawing charset renders
///                              the prompt as box glyphs)
///  - `[0m`                     finally SGR, clearing color/bold left on mid-sequence
///
/// All emitted unconditionally: each is a no-op when the mode wasn't set, and explicit beats
/// trying to infer the dead shell's state from bytes we never parsed.
///
/// ORDER IS LOAD-BEARING, and it is why the newline comes after the resets rather than first.
/// Two of the resets move the cursor: `[r` (DECSTBM) homes it to row 1, and `?1049l` restores
/// the cursor saved when the dead TUI entered the alt screen. Emitting `\r\n` first therefore
/// wrote the blank line at whatever row the history left the cursor on, and the resets then
/// yanked the cursor back up — so the rule painted over the TOP of the restored screen and the
/// rows below it stayed on display as stale history under the fresh prompt.
///
/// So: resets first, then `[999;1H` to park the cursor on the LAST row, then `\r\n`, then the
/// rule. 999 is a deliberate clamp, not a magic size: CUP row arguments past the bottom are
/// clamped to the last row by the terminal (ECMA-48 / xterm behaviour), which is how we reach
/// "the bottom row" without knowing the pane's height — the ring is replayed into whatever
/// geometry the client attaches with, so no height is available here. From the last row the
/// `\r\n` scrolls the screen up one line, pushing the restored history up into scrollback and
/// opening a blank line at the bottom for the rule. The trailing `\r\n` leaves the fresh prompt
/// on its own line under it.
///
/// Pure (no daemon state) so the selfcheck can exercise it; `dir` is tilde-abbreviated, and `~`
/// when the cwd is unknown.
public func coldRestoreBanner(cwd: String?) -> Data {
    let dir = cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~"
    let s = "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?7h\u{1b}[r\u{1b}[?25h\u{1b}(B\u{1b}[0m\u{1b}[999;1H\r\n\u{1b}[2m── vesta: session restarted — new shell in \(dir) ──\u{1b}[0m\r\n"
    return Data(s.utf8)
}

public func coldRestoreBannerSelfCheck() {
    let text = String(decoding: coldRestoreBanner(cwd: "/tmp"), as: UTF8.self)

    // ORDER, not mere presence: every mode reset must precede the cursor park, which must
    // precede the newline, which must precede the rule. Getting this backwards is the bug this
    // check exists for — a containment assert passes on the broken banner too.
    assert(text.hasPrefix("\u{1b}[?1049l"), "banner must open with the alt-screen leave, got \(text)")
    let park = text.range(of: "\u{1b}[999;1H")
    let rule = text.range(of: "\u{1b}[2m── vesta: session restarted")
    guard let park, let rule else { assertionFailure("banner missing cursor park or rule"); return }
    for reset in ["\u{1b}[?1049l", "\u{1b}[?1000l", "\u{1b}[?1002l", "\u{1b}[?1003l",
                  "\u{1b}[?1006l", "\u{1b}[?7h", "\u{1b}[r", "\u{1b}[?25h", "\u{1b}(B", "\u{1b}[0m"] {
        guard let r = text.range(of: reset) else { assertionFailure("banner missing \(reset)"); return }
        assert(r.upperBound <= park.lowerBound, "reset \(reset) must come BEFORE the [999;1H park")
    }
    guard let nl = text.range(of: "\r\n") else { assertionFailure("banner has no newline"); return }
    assert(park.upperBound == nl.lowerBound, "the park must be immediately followed by the CRLF")
    assert(nl.upperBound == rule.lowerBound, "the rule must follow the CRLF, not precede it")
    assert(text.hasSuffix("\u{1b}[0m\r\n"), "banner must end SGR-clean on its own line")

    // Unknown cwd → a bare tilde, never "nil" or an empty gap in the sentence.
    let unknown = String(decoding: coldRestoreBanner(cwd: nil), as: UTF8.self)
    assert(unknown.contains("new shell in ~ ──"), "nil cwd renders as ~, got \(unknown)")

    // A $HOME-prefixed path is abbreviated, so the rule stays short enough to fit a pane.
    let home = NSHomeDirectory()
    let deep = String(decoding: coldRestoreBanner(cwd: home + "/Code/vesta"), as: UTF8.self)
    assert(deep.contains("new shell in ~/Code/vesta ──"), "home path must tilde-abbreviate, got \(deep)")
    assert(!deep.contains(home), "abbreviated path must not leak the literal home directory")
    print("coldRestoreBannerSelfCheck OK")
}

public func scrollbackRingSelfCheck() {
    let esc = UInt8(0x1b)
    func d(_ s: String) -> Data { Data(s.utf8) }

    // THE REAL SHAPE: a full-screen TUI repainting with cursor moves and colors and NO newlines
    // anywhere — which is exactly what defeated a newline-only seek.
    var tui = Data()
    for _ in 0..<6 {
        tui.append(esc); tui.append(contentsOf: d("[38;2;215;119;87m"))
        tui.append(contentsOf: d("working"))
        tui.append(esc); tui.append(contentsOf: d("[39m"))
    }
    assert(!tui.contains(0x0a), "precondition: TUI sample has no newlines at all")
    // The block repeats every 30 bytes, so drop 35 — a multiple of 30 would land exactly on an
    // ESC and prove nothing. This slices inside "[38;2;215;119;87m", losing the ESC[38 prefix.
    let cut = tui.count - 35
    assert(Data(tui.suffix(cut)).first != esc, "precondition: naive slice starts mid-sequence")
    let fixedTUI = ringSuffixFromSafeBoundary(tui, cap: cut)
    assert(fixedTUI.first == esc, "TUI replay must resume exactly at an ESC")

    // Line-oriented shell output. Assert the EXACT result: a weaker "doesn't look broken" check
    // passes on the unfixed raw suffix too, so it would prove nothing.
    var shell = d("line one\n")
    shell.append(esc); shell.append(contentsOf: d("[31mred\n"))
    shell.append(contentsOf: d("plain three\n"))
    // Cut inside "[31m" so the ESC is lost and the next marker is the newline after "red".
    let shellCut = d("mred\nplain three\n").count
    assert(Data(shell.suffix(shellCut)) == d("mred\nplain three\n"), "precondition: cut mid-CSI")
    assert(ringSuffixFromSafeBoundary(shell, cap: shellCut) == d("plain three\n"),
           "shell replay resumes after the newline, got \(ringSuffixFromSafeBoundary(shell, cap: shellCut))")

    // An ESC found inside an OSC payload is the String Terminator's own ESC, so resuming there
    // yields a bare ST — dispatched and ignored by a VT parser, nothing printed.
    var osc = d("xx")
    osc.append(esc); osc.append(contentsOf: d("]0;title"))
    osc.append(esc); osc.append(contentsOf: d("\\after"))
    let oscOut = ringSuffixFromSafeBoundary(osc, cap: osc.count - 4)   // cut inside the payload
    assert(oscOut.first == esc, "OSC cut resumes at the ST's ESC, got \(oscOut)")

    // Under/at the cap → verbatim, nothing eaten.
    let small = d("abc\ndef")
    assert(ringDropCount(small, cap: 1024) == 0, "under cap drops nothing")
    assert(ringSuffixFromSafeBoundary(small, cap: small.count) == small, "at cap is untouched")

    // BOUNDED SEEK: a marker-free run longer than the scan window must NOT eat the whole ring.
    // Unbounded, this discarded everything up to the next marker (up to cap-1 bytes).
    var blob = Data(repeating: 0x61, count: 9000)      // no ESC, no newline
    blob.append(esc); blob.append(contentsOf: d("[0m"))
    let cap = 8192
    let out = ringSuffixFromSafeBoundary(blob, cap: cap)
    assert(out.count == cap, "marker-free run past the scan window keeps the raw suffix, got \(out.count)")

    // Plain text, no markers at all → raw suffix.
    assert(ringSuffixFromSafeBoundary(Data(repeating: 0x61, count: 10), cap: 4).count == 4,
           "plain text keeps the raw suffix")
    // Cut lands after the only newline → empty replay, not a trap.
    assert(ringSuffixFromSafeBoundary(d("xy\n"), cap: 2).isEmpty, "cut after the last newline")
    print("scrollbackRingSelfCheck OK")
}

public func scrollbackSweepSelfCheck() {
    let day: TimeInterval = 24 * 60 * 60
    let now: TimeInterval = 1_000_000_000
    assert(!ScrollbackSweep.isStale(mtime: now - day, now: now), "1-day-old log kept")
    assert(!ScrollbackSweep.isStale(mtime: now - 29 * day, now: now), "29-day-old log kept")
    assert(!ScrollbackSweep.isStale(mtime: now - 30 * day + 1, now: now), "just-under-30-days kept")
    assert(ScrollbackSweep.isStale(mtime: now - 30 * day, now: now), "exactly-30-days swept (>=)")
    assert(ScrollbackSweep.isStale(mtime: now - 31 * day, now: now), "31-day-old log swept")
    assert(!ScrollbackSweep.isStale(mtime: now + day, now: now), "future mtime (clock skew) kept")
    print("scrollbackSweepSelfCheck OK")
}
