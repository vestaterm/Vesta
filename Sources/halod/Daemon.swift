import Foundation
import HaloMux
import CVterm
#if canImport(Darwin)
import Darwin
#endif

final class Daemon {
    private var listenFD: Int32 = -1
    private var sessions: [String: Session] = [:]
    private var clientBufs: [Int32: Data] = [:]   // partial inbound frames per client fd
    private var clientSession: [Int32: String] = [:]

    // Per-session sb_pushline trampoline: libvterm hands us scrolled-off rows.
    // We can't capture Swift state in a C function pointer, so route via a global
    // keyed by the session's stable raw-pointer identity (`Session.screenKey`).
    // Single-threaded select loop owns all mutation (Task 3.7 threading invariant),
    // so this shared map needs no locking; `nonisolated(unsafe)` asserts that the
    // synchronization is external (the one daemon thread).
    nonisolated(unsafe) static var ringFor: [UnsafeMutableRawPointer: ScrollbackRing] = [:]

    func run() {
        MuxPaths.ensureDirs()
        let path = MuxPaths.daemonSocket
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for i in 0..<min(bytes.count, raw.count - 1) { raw[i] = bytes[i] }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)            // owner-only: this socket carries keystrokes + scrollback
        listenFD = fd
        loop()
    }

    private func loop() {
        while true {
            var rset = fd_set(); __darwin_fd_set(listenFD, &rset)
            var maxFD = listenFD
            for (_, s) in sessions { __darwin_fd_set(s.masterFD, &rset); maxFD = max(maxFD, s.masterFD) }
            for fd in clientBufs.keys { __darwin_fd_set(fd, &rset); maxFD = max(maxFD, fd) }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            let n = select(maxFD + 1, &rset, nil, nil, &tv)
            if n < 0 { if errno == EINTR { continue }; break }
            reapDeadShells()
            if sessions.isEmpty && clientBufs.isEmpty && idleExpired() { break }  // idle-exit
            if __darwin_fd_isset(listenFD, &rset) != 0 { acceptClient() }
            // Drain every PTY (even with zero clients → no backpressure).
            for (_, s) in sessions where __darwin_fd_isset(s.masterFD, &rset) != 0 { drainPTY(s) }
            // Read client frames.
            for fd in Array(clientBufs.keys) where __darwin_fd_isset(fd, &rset) != 0 { readClient(fd) }
        }
        if listenFD >= 0 { close(listenFD); unlink(MuxPaths.daemonSocket) }
    }

    private var lastActivity = Date()
    private func idleExpired() -> Bool { Date().timeIntervalSince(lastActivity) > 10 }

    private func acceptClient() {
        let c = accept(listenFD, nil, nil)
        if c < 0 { return }
        _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL, 0) | O_NONBLOCK)
        clientBufs[c] = Data()
        lastActivity = Date()
    }

    private func drainPTY(_ s: Session) {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = read(s.masterFD, &tmp, tmp.count)
        if n > 0 {
            let data = Data(tmp[0..<n])
            s.ingest(data)
            for c in s.attached { sendFrame(c, encode(ServerFrame.output(data))) }
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            s.markDead()
        }
    }

    private func reapDeadShells() {
        for (id, s) in sessions where !s.alive {
            let status = reapAndDecode(s.pid)   // blocks briefly: child's PTY is already EOF/killed
            for c in s.attached { sendFrame(c, encode(ServerFrame.exited(status: status))) }
            sessions[id] = nil
            Daemon.ringFor[s.screenKey] = nil
        }
    }

    /// Block until `pid` is reaped, then decode the shell-convention exit code.
    /// Safe from hanging the select loop: called ONLY after the master PTY returned
    /// EOF/error (all the child's slave fds are closed → it has exited or is exiting)
    /// or after an explicit SIGKILL, so the child is dead/dying and waitpid returns
    /// promptly. Swift exposes no W* macros, so decode via bit ops.
    private func reapAndDecode(_ pid: pid_t) -> Int32 {
        var st: Int32 = 0
        while waitpid(pid, &st, 0) < 0 && errno == EINTR {}   // retry on EINTR
        if (st & 0x7f) == 0 { return (st >> 8) & 0xff }        // WIFEXITED → WEXITSTATUS
        let sig = st & 0x7f                                     // WTERMSIG
        return 128 + sig                                        // signalled → 128+signal
    }

    private func readClient(_ fd: Int32) {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &tmp, tmp.count)
        if n <= 0 { closeClient(fd); return }
        clientBufs[fd, default: Data()].append(Data(tmp[0..<n]))
        lastActivity = Date()
        var buf = clientBufs[fd]!
        while let frame = decodeClientFrame(from: &buf) { handle(frame, from: fd) }
        clientBufs[fd] = buf
    }

    private func closeClient(_ fd: Int32) {
        if let sid = clientSession[fd] { sessions[sid]?.attached.removeAll { $0 == fd } }
        clientSession[fd] = nil; clientBufs[fd] = nil; close(fd)
    }

    private func handle(_ frame: ClientFrame, from fd: Int32) {
        switch frame {
        case let .hello(paneID, cols, rows):
            // No server-side version gate: the server unconditionally advertises its
            // version via helloAck (below); the CLIENT (halo-attach, Task 3.8) compares
            // helloAck.version to its own muxProtocolVersion and bails on mismatch. This
            // is what makes remote attach (M5) against a newer/older daemon safe.
            let s: Session
            if let existing = sessions[paneID] { s = existing; s.resize(cols: Int32(cols), rows: Int32(rows)) }
            else {
                guard let fresh = Session(paneID: paneID, cols: Int32(cols), rows: Int32(rows)) else {
                    sendFrame(fd, encode(ServerFrame.exited(status: 1))); return
                }
                installScrollback(fresh)
                sessions[paneID] = fresh; s = fresh
            }
            s.attached.append(fd); clientSession[fd] = paneID
            sendFrame(fd, encode(ServerFrame.helloAck(version: muxProtocolVersion)))
            // Clean redraw: current screen + restored scrollback + cached images.
            // Scrollback shown = on-disk spilled history + the in-memory ring tail.
            // After a daemon crash this fresh session has an empty ring but the prior
            // <paneID>.log survives on disk, so reading it here is exactly the #6
            // history-recovery mitigation — recovered and live-spilled history use one path.
            var scrollback = (try? Data(contentsOf: URL(fileURLWithPath: MuxPaths.sessionLog(s.paneID)))) ?? Data()
            if !scrollback.isEmpty, scrollback.last != 0x0a { scrollback.append(0x0a) }
            scrollback.append(Data(s.ring.lines().joined(separator: [0x0a])))
            sendFrame(fd, encode(ServerFrame.snapshot(
                screen: s.screenSnapshot(), scrollback: scrollback, images: s.images.replayBytes())))
        case let .input(data):
            if let sid = clientSession[fd] { sessions[sid]?.writeInput(data) }
        case let .resize(cols, rows):
            if let sid = clientSession[fd] { sessions[sid]?.resize(cols: Int32(cols), rows: Int32(rows)) }
        case .detach:
            closeClient(fd)
        case .kill:
            if let sid = clientSession[fd], let s = sessions[sid] { kill(s.pid, SIGKILL); s.markDead() }
        case .list:
            let infos = sessions.values.map { SessionInfo(id: $0.paneID, name: $0.name, cwd: $0.cwd,
                alive: $0.alive, attachedCount: $0.attached.count) }
            sendFrame(fd, encode(ServerFrame.sessions(infos)))
        }
    }

    // Wire libvterm's scrollback push to this session's ring (scrolled-off rows → disk spill).
    private func installScrollback(_ s: Session) {
        Daemon.ringFor[s.screenKey] = s.ring
        var cbs = VTermScreenCallbacks()
        cbs.sb_pushline = { cols, cellsPtr, user in
            guard let user, let ring = Daemon.ringFor[user] else { return 0 }
            var line = Data()
            if let cells = cellsPtr {
                for i in 0..<Int(cols) {
                    let ch = cells[i].chars.0
                    if ch != 0, let u = Unicode.Scalar(ch) { line.append(contentsOf: Array(String(u).utf8)) }
                    else { line.append(0x20) }
                }
            }
            ring.push(line); return 1
        }
        s.installScreenCallbacks(cbs, user: s.screenKey)
    }

    private func sendFrame(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(fd, base.advanced(by: off), raw.count - off)
                if n <= 0 { break }; off += n
            }
        }
    }

    // ── Lazy launch: setsid so the daemon outlives the app ────────────────────
    static func spawnIfNeeded() {
        // Already up? A connect to the socket succeeds → nothing to do.
        if socketAlive(MuxPaths.daemonSocket) { return }
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("halod").path
            ?? (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/halod"
        // setsid via a tiny shell wrapper so the daemon detaches from our session.
        let wrapper = Process()
        wrapper.executableURL = URL(fileURLWithPath: "/bin/sh")
        wrapper.arguments = ["-c", "setsid \"\(exe)\" >/dev/null 2>&1 &"]
        try? wrapper.run(); wrapper.waitUntilExit()
        // Wait briefly for the socket to appear.
        for _ in 0..<50 { if socketAlive(MuxPaths.daemonSocket) { return }; usleep(20_000) }
    }

    static func socketAlive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return false }
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for i in 0..<min(bytes.count, raw.count - 1) { raw[i] = bytes[i] }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }
}
