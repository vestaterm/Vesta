import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Direct children of `pid`, via libproc. No fork, no subprocess — safe to call from
/// vestad's single-threaded select loop (unlike the `pgrep` walk in Ports.swift, which is
/// fine on the GUI side but would stall the daemon).
public func childPIDs(of pid: pid_t) -> [pid_t] {
    let probe = proc_listchildpids(pid, nil, 0)
    guard probe > 0 else { return [] }
    // Ask for headroom and re-read the returned count: the tree can grow between the sizing
    // call and the real one, and proc_listchildpids fills what fits rather than failing.
    var buf = [pid_t](repeating: 0, count: Int(probe) + 16)
    let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    guard n > 0 else { return [] }
    return buf.prefix(Int(n)).filter { $0 > 0 }
}

public func processTreeSelfCheck() {
    // `;` after the sleep stops sh from exec'ing it in place, so we get a real grandchild —
    // the shape that matters: a dev server is a CHILD of the shell, not the shell itself.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "/bin/sleep 30; :"]
    do { try p.run() } catch { print("processTreeSelfCheck skipped (spawn failed)"); return }
    let parent = p.processIdentifier

    var kids: [pid_t] = []
    for _ in 0..<100 {                 // sh needs a moment to fork
        kids = childPIDs(of: parent)
        if !kids.isEmpty { break }
        usleep(20_000)
    }
    assert(!kids.isEmpty, "childPIDs must find the shell's forked `sleep` grandchild")
    assert(!kids.contains(parent), "childPIDs must not include the pid itself")

    // Killing only the parent must NOT reap the grandchild — this is exactly the leak that
    // let `npm run dev` outlive its pane and keep its port bound.
    kill(parent, SIGKILL)
    p.waitUntilExit()
    let survivor = kids[0]
    assert(kill(survivor, 0) == 0, "grandchild outlives a parent-only kill (the leak)")
    kill(survivor, SIGKILL)           // what killTree does: children too

    assert(childPIDs(of: -1).isEmpty, "bogus pid yields no children, never a crash")
    print("processTreeSelfCheck ok")
}
