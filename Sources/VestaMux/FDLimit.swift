import Foundation
#if canImport(Darwin)
import Darwin
#endif

// RLIM_INFINITY is defined as a macro the Swift importer can't surface ("structure not
// supported"), so re-declare the identical value: the max representable rlim_t.
private let RLIM_INFINITY_VALUE = rlim_t((rlim_t(1) << 63) - 1)

/// The soft `RLIMIT_NOFILE` we want vestad (and every shell it forks, which inherit it) to run
/// with. Dozens of persisted PTY sessions each cost a master fd plus a client/subscriber fd or
/// two; the default macOS soft limit of 256 runs out around 40 sessions, which starved forked
/// shells of fds ("pipe failed: too many open files"). Target 8192 for ample headroom.
///
/// Pure so it can be selfchecked: never exceeds the hard cap, never *lowers* the current soft
/// limit, and treats an unlimited (RLIM_INFINITY) hard cap as "take the full target".
public func desiredFDSoftLimit(soft: rlim_t, hard: rlim_t) -> rlim_t {
    let target: rlim_t = 8192
    let capped = (hard == RLIM_INFINITY_VALUE) ? target : min(target, hard)
    return max(soft, capped)   // never lower an already-generous inherited limit
}

/// Raise this process's soft `RLIMIT_NOFILE` toward `desiredFDSoftLimit`. Best-effort: on
/// failure the process keeps its inherited limit (a low limit degrades to fewer sessions, not a
/// crash), so we note it on stderr but never abort. Silent on success.
public func raiseFDLimit() {
    var lim = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else {
        fputs("vestad: getrlimit(RLIMIT_NOFILE) failed: \(String(cString: strerror(errno)))\n", stderr)
        return
    }
    let want = desiredFDSoftLimit(soft: lim.rlim_cur, hard: lim.rlim_max)
    guard want != lim.rlim_cur else { return }
    lim.rlim_cur = want   // leave rlim_max untouched (macOS clamps NOFILE to kern.maxfilesperproc)
    if setrlimit(RLIMIT_NOFILE, &lim) != 0 {
        fputs("vestad: setrlimit(RLIMIT_NOFILE, \(want)) failed: \(String(cString: strerror(errno)))\n", stderr)
    }
}

/// Mark a daemon-held fd close-on-exec so the shells vestad forks inherit *nothing* beyond
/// their own PTY slave stdio (fds 0/1/2, which forkpty dup2s and which must NOT be cloexec).
/// Applied at every fd-creation site in the daemon: without it, each newly forked shell
/// inherited every open master/socket/log fd, exhausting both the fd table and the shell's
/// own limit. `execve` clears cloexec fds, so any Swift code between fork and exec is covered.
@discardableResult
public func setCloseOnExec(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFD)
    if flags < 0 { return false }
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0
}

public func fdLimitSelfCheck() {
    let INF = rlim_t((rlim_t(1) << 63) - 1)
    // Unlimited hard cap → take the full 8192 target.
    assert(desiredFDSoftLimit(soft: 256, hard: INF) == 8192, "infinite hard cap → target")
    // Default macOS soft limit is raised to the target.
    assert(desiredFDSoftLimit(soft: 256, hard: 10240) == 8192, "raise from default")
    // Hard cap below target clamps to the hard cap.
    assert(desiredFDSoftLimit(soft: 256, hard: 4096) == 4096, "clamp to hard cap")
    // Never lower an already-generous inherited soft limit.
    assert(desiredFDSoftLimit(soft: 1048576, hard: INF) == 1048576, "never lower soft")
    // Exactly at target is a no-op value.
    assert(desiredFDSoftLimit(soft: 8192, hard: INF) == 8192, "at target")
    print("fdLimitSelfCheck ok")
}
