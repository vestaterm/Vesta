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
