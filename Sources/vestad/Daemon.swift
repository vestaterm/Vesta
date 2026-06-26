import Foundation
import VestaMux
#if canImport(Darwin)
import Darwin
#endif

final class Daemon {
    private var listenFD: Int32 = -1
    private var sessions: [String: Session] = [:]
    private var clientBufs: [Int32: Data] = [:]   // partial inbound frames per client fd
    // Per-connection state: fd → the paneID it attached to.
    private var clientSession: [Int32: String] = [:]
    // fd → paneID for passive output-only subscribers (GUI pane-output taps).
    private var subscriberSession: [Int32: String] = [:]
    // Subscribers that arrived before their session existed, waiting to be bound on .hello.
    private var pendingSubscribers: [String: [Int32]] = [:]
    // Persist scrollback to disk? Off by default; read once from config at startup.
    private let logEnabled = Daemon.scrollbackEnabled()

    /// Read `vesta-persist-scrollback` from the Vesta config (XDG-aware). Default false —
    /// terminal output can contain secrets, so on-disk persistence is strictly opt-in.
    private static func scrollbackEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let path = (env["XDG_CONFIG_HOME"].map { $0 + "/vesta/config" }) ?? (NSHomeDirectory() + "/.config/vesta/config")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }   // skip comment lines
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "vesta-persist-scrollback" else { continue }
            // value before any inline comment, lowercased; accept true/1/yes
            let v = kv[1].split(separator: "#")[0].trimmingCharacters(in: .whitespaces).lowercased()
            return v == "true" || v == "1" || v == "yes"
        }
        return false
    }

    func run() {
        MuxPaths.ensureDirs()
        // Single-instance: hold an exclusive lock so concurrent lazy-spawns (one per
        // pane at launch) don't race to unlink/clobber each other's live socket. A
        // redundant vestad exits cleanly; the relays then all connect to the winner.
        // lockFD intentionally stays open for the process lifetime (releases on exit).
        let lockFD = open(MuxPaths.base + "/vestad.lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
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
        let lr = listen(fd, 16)
        guard bound == 0, lr == 0 else { close(fd); return }
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
            if n < 0 {
                if errno == EINTR { continue }
                // EBADF: a closed fd slipped into the set. Don't take down every shell —
                // prune the dead fds and keep serving. (Root cause is fixed in readClient,
                // but one stray fd must never kill the daemon.)
                if errno == EBADF, pruneDeadFDs() { continue }
                break
            }
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

    /// Drop any client fd that's no longer a valid open descriptor. Called on a select()
    /// EBADF so a single stale fd can't kill the daemon (which would drop every shell).
    /// Returns true if it pruned at least one (so the caller can retry select); false
    /// means the bad fd wasn't a client — fall through to break rather than spin.
    private func pruneDeadFDs() -> Bool {
        var pruned = false
        for fd in Array(clientBufs.keys) where fcntl(fd, F_GETFD) < 0 { closeClient(fd); pruned = true }
        return pruned
    }

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
            for c in s.clients where !sendFrame(c, frame) { stuck.append(c) }
            for c in s.subscribers where !sendFrame(c, frame) { stuck.append(c) }
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
            for c in s.clients where !sendFrame(c, frame) { stuck.append(c) }
            let subs = s.subscribers            // their session is gone → close them too
            sessions[id] = nil
            Session.deleteLog(id)               // session ended cleanly → drop its on-disk scrollback
            for c in stuck { closeClient(c) }   // drop stuck clients after iterating + removing session
            for c in subs { closeClient(c) }
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
        while let frame = decodeClientFrame(from: &buf) {
            handle(frame, from: fd)
            // handle() may closeClient(fd) (.detach/.kill/send failure). Writing buf
            // back below would resurrect the closed fd as a clientBufs key → next
            // select() sees a dead fd → EBADF → daemon dies → all panes drop. Bail.
            if clientBufs[fd] == nil { return }
        }
        clientBufs[fd] = buf
    }

    private func closeClient(_ fd: Int32) {
        if let paneID = clientSession[fd] { sessions[paneID]?.removeClient(fd: fd) }
        if let paneID = subscriberSession[fd] {
            sessions[paneID]?.removeSubscriber(fd: fd)
            pendingSubscribers[paneID]?.removeAll { $0 == fd }   // may still be unbound
            if pendingSubscribers[paneID]?.isEmpty == true { pendingSubscribers[paneID] = nil }
        }
        clientSession[fd] = nil; subscriberSession[fd] = nil; clientBufs[fd] = nil; close(fd)
    }

    private func handle(_ frame: ClientFrame, from fd: Int32) {
        switch frame {
        case let .hello(paneID, cols, rows, cwd):
            // No server-side version gate: the server unconditionally advertises its
            // version via helloAck (below); the CLIENT (vesta-attach, Task 3.8) compares
            // helloAck.version to its own muxProtocolVersion and bails on mismatch. This
            // is what makes remote attach (M5) against a newer/older daemon safe.
            let s: Session
            if let existing = sessions[paneID] { s = existing }
            else {
                guard let fresh = Session(paneID: paneID, cols: Int32(cols), rows: Int32(rows), cwd: cwd, logEnabled: logEnabled) else {
                    if !sendFrame(fd, encode(ServerFrame.exited(status: 1))) { closeClient(fd) }
                    return
                }
                sessions[paneID] = fresh; s = fresh
            }
            // Bind any subscribers that arrived before this session existed (review finding B).
            if let waiting = pendingSubscribers.removeValue(forKey: paneID) {
                for w in waiting { s.addSubscriber(fd: w) }
            }
            s.addClient(fd: fd)
            clientSession[fd] = paneID
            if !sendFrame(fd, encode(ServerFrame.helloAck(version: muxProtocolVersion))) {
                closeClient(fd); return
            }
            // Clean reattach: replay the raw output ring verbatim. ghostty parses it,
            // so the screen comes back byte-exact (colors/cursor/alt-screen and all),
            // and recent lines land in native scrollback for free. Empty for a fresh shell.
            let replay = s.snapshot()
            if !replay.isEmpty, !sendFrame(fd, encode(ServerFrame.output(replay))) {
                closeClient(fd); return
            }
        case let .input(data):
            // Input-from-any: any client's keystrokes go to the single PTY master.
            if let paneID = clientSession[fd] { sessions[paneID]?.writeInput(data) }
        case let .resize(cols, rows):
            // One PTY, last-resize-wins. (Focus-based arbitration across mirrors is deferred.)
            if let paneID = clientSession[fd] {
                sessions[paneID]?.resize(cols: Int32(cols), rows: Int32(rows))
            }
        case .detach:
            closeClient(fd)   // removes this client (no PTY reap — shell lives on)
        case .kill:
            if let paneID = clientSession[fd], let s = sessions[paneID] { kill(s.pid, SIGKILL); s.markDead() }
        case .list:
            let infos = sessions.values.map { SessionInfo(id: $0.paneID, name: $0.name, cwd: $0.cwd,
                alive: $0.alive, attachedCount: $0.clients.count) }
            if !sendFrame(fd, encode(ServerFrame.sessions(infos))) { closeClient(fd) }
        case let .subscribe(paneID):
            // Passive output-only reader. Never creates a session (avoids racing
            // vesta-attach's spawn). No ring replay (we want new output, not history);
            // excluded from attachedCount (list uses .clients). If the session doesn't
            // exist yet, queue this fd and bind it when .hello creates the session, so a
            // subscribe that wins the race against spawn isn't stuck unbound (finding B).
            subscriberSession[fd] = paneID
            if let s = sessions[paneID] { s.addSubscriber(fd: fd) }
            else { pendingSubscribers[paneID, default: []].append(fd) }
            if !sendFrame(fd, encode(ServerFrame.helloAck(version: muxProtocolVersion))) { closeClient(fd) }
        }
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
