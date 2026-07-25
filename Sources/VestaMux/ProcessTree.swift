import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Direct children of `pid`, via libproc. No fork, no subprocess — safe to call from
/// vestad's single-threaded select loop (unlike the `pgrep` walk in Ports.swift, which is
/// fine on the GUI side but would stall the daemon).
///
/// The `> 0` filter is load-bearing, not hygiene: `proc_listchildpids(0)` reports pid 0 as
/// its own child, which would otherwise recurse forever.
public func childPIDs(of pid: pid_t) -> [pid_t] {
    // The probe reports the SYSTEM-WIDE process count, not this pid's child count (it ignores
    // the ppid filter entirely) — so it is only an upper bound for sizing, and it never
    // short-circuits. The `n > 0` check on the real call is what rejects a bogus pid.
    let probe = proc_listchildpids(pid, nil, 0)
    guard probe > 0 else { return [] }
    var buf = [pid_t](repeating: 0, count: Int(probe) + 16)
    let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    guard n > 0 else { return [] }
    return buf.prefix(Int(n)).filter { $0 > 0 }
}

/// `pid` plus every process descended from it, breadth-first (root first).
///
/// Refuses pid <= 1. That guard is the difference between killing one pane's job tree and
/// wiping the user's login session: `kill(0, …)` signals the caller's ENTIRE process group,
/// `kill(-1, …)` signals every process the user owns, and pid 1 is launchd. None of those is
/// ever a session shell, so no legitimate call needs them.
public func processTreePIDs(_ pid: pid_t) -> [pid_t] {
    guard pid > 1 else { return [] }
    var seen: Set<pid_t> = [pid]          // also guarantees termination if the table lies
    var out: [pid_t] = [pid]
    var frontier: [pid_t] = [pid]
    while !frontier.isEmpty {
        var next: [pid_t] = []
        for p in frontier {
            for c in childPIDs(of: p) where c > 1 && seen.insert(c).inserted { next.append(c) }
        }
        out += next
        frontier = next
    }
    return out
}

/// SIGKILL `pid` and its whole descendant tree.
///
/// Collect the entire tree BEFORE signalling anything: once the root dies its children are
/// re-parented to launchd and proc_listchildpids can no longer find them. Then kill
/// root-first, so a supervisor (nodemon, cargo-watch, watchexec, pm2) is already dead before
/// its workers are, and cannot respawn one we collected but have not yet reached.
///
/// `send` is injectable so the self-check can prove the pid guards without signalling
/// anything real.
// ponytail: still one libproc snapshot per level, so a process forked mid-walk is missed.
// SIGSTOP-on-visit would close that; not worth it until something actually escapes.
public func killProcessTree(_ pid: pid_t, send: (pid_t) -> Void = { kill($0, SIGKILL) }) {
    for p in processTreePIDs(pid) { send(p) }
}

public func processTreeSelfCheck() {
    // --- the pid guards: the highest-consequence input this code can take ---
    var signalled: [pid_t] = []
    for bad in [pid_t(0), -1, 1, -999] {
        assert(processTreePIDs(bad).isEmpty, "pid \(bad) must yield no tree")
        killProcessTree(bad) { signalled.append($0) }
    }
    assert(signalled.isEmpty, "pid <= 1 must never reach kill(); got \(signalled)")

    // --- the real walk ---
    // `;` after the sleep stops sh exec'ing it in place, so we get a genuine grandchild —
    // the shape that matters: a dev server is a CHILD of the shell, not the shell itself.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "/bin/sleep 30; :"]
    do { try p.run() } catch { print("processTreeSelfCheck skipped (spawn failed)"); return }
    let parent = p.processIdentifier
    // Never leave a stray `sleep 30` behind, on any exit path including an assert trap.
    defer { for k in childPIDs(of: parent) { kill(k, SIGKILL) }; kill(parent, SIGKILL) }

    var kids: [pid_t] = []
    for _ in 0..<100 {                 // sh needs a moment to fork
        kids = childPIDs(of: parent)
        if !kids.isEmpty { break }
        usleep(20_000)
    }
    // guard, not assert: asserts compile out under -O, and a bare kids[0] would then trap on
    // an empty array in the shipped binary (which still accepts `selfcheck`).
    guard let survivor = kids.first else {
        assert(false, "childPIDs must find the shell's forked `sleep` grandchild")
        return
    }
    assert(!kids.contains(parent), "childPIDs must not include the pid itself")
    assert(processTreePIDs(parent).contains(survivor), "the tree walk must reach the grandchild")

    // Killing only the parent must NOT reap the grandchild — this is exactly the leak that
    // let `npm run dev` outlive its pane and keep its port bound.
    kill(parent, SIGKILL)
    p.waitUntilExit()
    assert(kill(survivor, 0) == 0, "grandchild outlives a parent-only kill (the leak)")
    kill(survivor, SIGKILL)           // what killProcessTree does: the whole tree

    print("processTreeSelfCheck ok")
}
