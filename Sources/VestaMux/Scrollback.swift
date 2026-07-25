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

/// Cut `data` down to at most `cap` bytes, starting at a LINE boundary.
///
/// The replay ring is byte-bounded, so a plain `suffix(cap)` lands wherever it lands — very
/// often inside an ANSI escape sequence. The remainder then replays with its `ESC[` prefix
/// missing, and a terminal renders the leftovers as literal text: a pane reattaches showing
/// `;2;215;119;87m` instead of a color change. Measured on a real workspace, 4 of 6 panes cut
/// mid-sequence. (The parser resyncs at the next ESC — but characters already emitted stay on
/// screen, which is what the user actually sees.)
///
/// Two bytes are safe places to resume: an ESC (starts a fresh sequence) and a newline (can
/// never occur inside a CSI). Skip forward to whichever comes first and begin there.
///
/// Seeking ONLY newlines is not enough, and that is the whole reason this is not a one-liner:
/// a pane running a full-screen TUI — an editor, an agent — repaints with absolute cursor moves
/// and emits no newlines at all. Measured on a real workspace, all six 256 KB windows contained
/// zero `\n`. ESC is what is actually dense in that output, so it is what makes the seek work.
// ponytail: forward-seek, not an escape-sequence parser. It cannot resume mid-CSI, which is the
// entire failure mode. The cost is dropping the bytes between the cut and the next ESC/newline
// — a handful, since whichever kind of output this is, one of the two is common in it.
public func ringSuffixFromSafeBoundary(_ data: Data, cap: Int) -> Data {
    // Under the cap nothing was cut, so there is no broken sequence to skip past — returning
    // early matters, otherwise we would eat content from every short scrollback.
    guard data.count > cap else { return data }
    let tail = Data(data.suffix(cap))
    var i = tail.startIndex
    while i < tail.endIndex {
        if tail[i] == 0x1b { return Data(tail[i...]) }              // ESC: resume here
        if tail[i] == 0x0a { return Data(tail[tail.index(after: i)...]) }  // newline: resume after
        i = tail.index(after: i)
    }
    return tail   // neither found (pure text, no escapes) — nothing could be mid-sequence
}

public func scrollbackRingSelfCheck() {
    let esc = UInt8(0x1b)
    /// A replay is broken when it opens with the tail of a CSI: params then a final byte @-~.
    func startsMidSequence(_ b: Data) -> Bool {
        var i = b.startIndex
        while i < b.endIndex, "0123456789;?".utf8.contains(b[i]) { i = b.index(after: i) }
        return i > b.startIndex && i < b.endIndex && (0x40...0x7e).contains(b[i])
    }

    // THE REAL SHAPE: a full-screen TUI repainting with cursor moves and colors — no newlines
    // anywhere, which is what defeated a newline-only seek.
    var tui = Data()
    for _ in 0..<6 {
        tui.append(contentsOf: [esc] + Array("[38;2;215;119;87m".utf8))
        tui.append(contentsOf: Array("working".utf8))
        tui.append(contentsOf: [esc] + Array("[39m".utf8))
    }
    assert(!tui.contains(0x0a), "precondition: TUI sample has no newlines at all")
    // Cut inside "[38;2;215;119;87m" so the ESC[38 prefix is lost. The block repeats every 30
    // bytes, so drop 35 — a multiple of 30 would land exactly on an ESC and prove nothing.
    let cut = tui.count - 35
    assert(startsMidSequence(Data(tui.suffix(cut))), "precondition: naive slice starts mid-CSI")
    let fixedTUI = ringSuffixFromSafeBoundary(tui, cap: cut)
    assert(!startsMidSequence(fixedTUI), "must not resume mid-CSI, got \(fixedTUI.prefix(12))")
    assert(fixedTUI.first == esc, "TUI output resumes at an ESC, got \(String(describing: fixedTUI.first))")

    // Line-oriented shell output: resume just after a newline.
    var shell = Data("line one\n".utf8)
    shell.append(contentsOf: [esc] + Array("[31mred\n".utf8))
    shell.append(contentsOf: Array("line three\n".utf8))
    let fixedShell = ringSuffixFromSafeBoundary(shell, cap: 14)
    assert(!startsMidSequence(fixedShell), "shell replay must not resume mid-CSI")

    // Under the cap → verbatim, nothing eaten.
    let small = Data("abc\ndef".utf8)
    assert(ringSuffixFromSafeBoundary(small, cap: 1024) == small, "under cap is untouched")
    assert(ringSuffixFromSafeBoundary(small, cap: small.count) == small, "at cap is untouched")
    // Neither ESC nor newline → nothing can be mid-sequence, keep the bytes.
    assert(ringSuffixFromSafeBoundary(Data("aaaaaaaaaa".utf8), cap: 4) == Data("aaaa".utf8),
           "plain text → raw suffix kept")
    // Cut lands after the only newline → empty replay, not a crash.
    assert(ringSuffixFromSafeBoundary(Data("xy\n".utf8), cap: 2).isEmpty, "cut after the last newline")
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
