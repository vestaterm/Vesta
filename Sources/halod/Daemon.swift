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
    // Per-connection state: fd → (paneID it attached to, daemon-assigned clientID).
    private var clientSession: [Int32: (paneID: String, clientID: Int)] = [:]

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
            let frame = encode(ServerFrame.output(data))
            var stuck: [Int32] = []
            for c in s.clientFDs where !sendFrame(c, frame) { stuck.append(c) }
            for c in stuck { closeClient(c) }   // drop desynced/stuck clients after iterating
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            s.markDead()
        }
    }

    private func reapDeadShells() {
        for (id, s) in sessions where !s.alive {
            let status = reapAndDecode(s.pid)   // blocks briefly: child's PTY is already EOF/killed
            let frame = encode(ServerFrame.exited(status: status))
            var stuck: [Int32] = []
            for c in s.clientFDs where !sendFrame(c, frame) { stuck.append(c) }
            sessions[id] = nil
            Daemon.ringFor[s.screenKey] = nil
            for c in stuck { closeClient(c) }   // drop stuck clients after iterating + removing session
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
        if let st = clientSession[fd] { sessions[st.paneID]?.removeClient(id: st.clientID) }
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
            if let existing = sessions[paneID] { s = existing }
            else {
                guard let fresh = Session(paneID: paneID, cols: Int32(cols), rows: Int32(rows)) else {
                    if !sendFrame(fd, encode(ServerFrame.exited(status: 1))) { closeClient(fd) }
                    return
                }
                installScrollback(fresh)
                sessions[paneID] = fresh; s = fresh
            }
            // Register this client; addClient re-arbitrates the shared PTY grid from
            // all attached clients (a second mirror joining no longer blindly resizes).
            let cid = s.addClient(fd: fd, cols: Int(cols), rows: Int(rows))
            clientSession[fd] = (paneID: paneID, clientID: cid)
            if !sendFrame(fd, encode(ServerFrame.helloAck(version: muxProtocolVersion))) {
                closeClient(fd); return
            }
            // Clean redraw: current screen + restored scrollback + cached images.
            // Scrollback shown = on-disk spilled history + the in-memory ring tail.
            // After a daemon crash this fresh session has an empty ring but the prior
            // <paneID>.log survives on disk, so reading it here is exactly the #6
            // history-recovery mitigation — recovered and live-spilled history use one path.
            var scrollback = (try? Data(contentsOf: URL(fileURLWithPath: MuxPaths.sessionLog(s.paneID)))) ?? Data()
            if !scrollback.isEmpty, scrollback.last != 0x0a { scrollback.append(0x0a) }
            scrollback.append(Data(s.ring.lines().joined(separator: [0x0a])))
            if !sendFrame(fd, encode(ServerFrame.snapshot(
                screen: s.screenSnapshot(), scrollback: scrollback, images: s.images.replayBytes()))) {
                closeClient(fd); return
            }
        case let .input(data):
            // Input-from-any: any client's keystrokes go to the single PTY master.
            if let st = clientSession[fd] { sessions[st.paneID]?.writeInput(data) }
        case let .resize(cols, rows):
            // Per-client: update THIS client's reported grid; the shared PTY size
            // now follows arbitration (focused client wins), not the last resize.
            if let st = clientSession[fd] {
                sessions[st.paneID]?.setClientGrid(id: st.clientID, cols: Int(cols), rows: Int(rows))
            }
        case .detach:
            closeClient(fd)   // removes this client + re-arbitrates (no PTY reap)
        case .kill:
            if let st = clientSession[fd], let s = sessions[st.paneID] { kill(s.pid, SIGKILL); s.markDead() }
        case .list:
            let infos = sessions.values.map { SessionInfo(id: $0.paneID, name: $0.name, cwd: $0.cwd,
                alive: $0.alive, attachedCount: $0.clients.count) }
            if !sendFrame(fd, encode(ServerFrame.sessions(infos))) { closeClient(fd) }
        case let .focus(on):
            // Focused client drives the shared PTY grid via arbitration.
            if let st = clientSession[fd] {
                sessions[st.paneID]?.setClientFocus(id: st.clientID, focused: on)
            }
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

    /// Write a whole length-prefixed frame to `fd`. Returns true if every byte was
    /// written; false means the client is stuck/broken and MUST be dropped (a partial
    /// frame would permanently desync that client's decoder). Client fds are
    /// O_NONBLOCK, so a full send buffer yields EAGAIN: we wait (bounded poll) for the
    /// fd to drain rather than truncating, but bail after 5s so one stuck client can't
    /// stall the single-threaded daemon forever.
    @discardableResult
    private func sendFrame(_ fd: Int32, _ data: Data) -> Bool {
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            while off < raw.count {
                let n = write(fd, base.advanced(by: off), raw.count - off)
                if n > 0 { off += n; continue }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let pr = poll(&pfd, 1, 5000)   // wait up to 5s for writable
                        if pr > 0 { continue }          // drained → retry write
                        return false                    // timeout or poll error → drop
                    }
                }
                return false                            // 0, EPIPE, ECONNRESET, etc → drop
            }
            return true
        }
    }

}
