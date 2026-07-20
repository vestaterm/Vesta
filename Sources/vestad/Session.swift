import Foundation
import VestaMux
#if canImport(Darwin)
import Darwin
#endif

/// One live shell: a `forkpty`'d PTY master + a bounded **raw output ring**.
/// The daemon drains the PTY into the ring even with zero clients (no
/// backpressure). On attach the ring is replayed verbatim — ghostty does all
/// the VT parsing, so reattach is byte-exact (no screen model, no snapshot).
final class Session {
    let paneID: String
    let masterFD: Int32
    let pid: pid_t
    var cols: Int32
    var rows: Int32
    /// Attached client fds (for output fan-out / exit broadcast). Usually one;
    /// multiple = mirroring, which is deferred — fan-out is free, size is just
    /// last-resize-wins for now (no focus arbitration).
    private(set) var clients: [Int32] = []
    /// Passive output-only readers (GUI pane-output taps). Get the live output fan-out
    /// but no ring replay, and are excluded from attachedCount.
    private(set) var subscribers: [Int32] = []
    private(set) var alive = true
    var cwd: String?
    var name: String?

    /// Last N bytes of raw PTY output, replayed on attach. 256 KB ≈ a few
    /// screenfuls of scrollback + whatever a full-screen app last drew.
    // ponytail: byte-bounded ring, so a reattach can replay a partial escape
    // sequence at the very front (rare, ghostty resyncs past it). Add a
    // disk-backed/screen-aware buffer only if that artifact actually bites.
    private static let ringCap = 256 * 1024
    private(set) var ring = Data()

    /// On-disk mirror of the ring (`sessions/<paneID>.log`) so scrollback survives a
    /// daemon restart/reboot: a fresh Session seeds its replay ring from this file. Bounded
    /// to logCap; trimmed back to the in-memory ring when it grows past that. 0600 — it
    /// carries terminal output. Deleted when the session ends cleanly (see Daemon.deleteLog).
    private var logFD: Int32 = -1
    private var logBytes = 0
    private static let logCap = 512 * 1024

    /// Whether to persist scrollback to disk (off by default — terminal output can hold
    /// secrets; opt in via `vesta-persist-scrollback = true`). Read once by the daemon.
    private let logEnabled: Bool

    init?(paneID: String, cols rawCols: Int32, rows rawRows: Int32, cwd: String? = nil, logEnabled: Bool = false, shellIntegration: Bool = false) {
        self.logEnabled = logEnabled
        // Clamp to a sane minimum. A pane created before its window lays out reports a
        // 0×0 size; a 0-sized PTY is rejected by some shells. The real size arrives via
        // the first resize.
        let cols = rawCols > 0 ? rawCols : 80
        let rows = rawRows > 0 ? rawRows : 24
        self.paneID = paneID; self.cols = cols; self.rows = rows; self.cwd = cwd
        // Resolve the shell + shell-integration env in the PARENT (the child inherits this
        // exact environment, so getenv here == getenv in the child). For zsh we point ZDOTDIR
        // at our generated integration dir so its `.zshenv` runs; VESTA_ORIG_ZDOTDIR carries
        // the user's real ZDOTDIR (only when they had one) so `.zshenv` can restore it. Other
        // shells are left untouched → graceful degradation (attention rail still works).
        let shell = getenv("SHELL").flatMap { String(cString: $0) } ?? "/bin/zsh"
        // FAIL OPEN: swap ZDOTDIR only if our .zshenv actually exists — pointing zsh at an
        // empty dir would skip the restore AND the user's entire config for every new shell.
        let zshenv = MuxPaths.shellIntegrationZsh + "/.zshenv"
        let zdotdir = (shellIntegration && VestaShellIntegration.isZsh(shell)
                       && FileManager.default.fileExists(atPath: zshenv))
            ? MuxPaths.shellIntegrationZsh : nil
        let origZDOTDIR = getenv("ZDOTDIR").flatMap { String(cString: $0) }
        // forkpty a login shell.
        var master: Int32 = 0
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&master, nil, nil, &ws)
        if child < 0 { return nil }
        if child == 0 {
            // Start the shell in the requested directory (the project/session dir). A bad
            // path just leaves the child in its inherited cwd — the shell still spawns.
            if let cwd, !cwd.isEmpty { cwd.withCString { _ = chdir($0) } }
            // Inject the ZDOTDIR swap for zsh. Pass VESTA_ORIG_ZDOTDIR only when the user had
            // a ZDOTDIR, mirroring zsh's own "unset ZDOTDIR == $HOME" semantics.
            if let zdotdir {
                if let orig = origZDOTDIR, !orig.isEmpty { setenv("VESTA_ORIG_ZDOTDIR", orig, 1) }
                setenv("ZDOTDIR", zdotdir, 1)
            }
            // execl is variadic (unavailable to Swift); build an explicit argv for execv.
            // Login shell: argv[0] = shell, argv[1] = "-l".
            shell.withCString { shellC in
                "-l".withCString { dashL in
                    var argv: [UnsafeMutablePointer<CChar>?] = [
                        strdup(shellC), strdup(dashL), nil,
                    ]
                    _ = execv(shellC, &argv)
                }
            }
            _exit(127)
        }
        self.pid = child; self.masterFD = master
        // Parent side only. The child's slave stdio (fds 0/1/2, dup2'd by forkpty) is a
        // separate process and is NOT touched — but this master MUST be close-on-exec so the
        // NEXT session's forked shell doesn't inherit it (the root cause of the fd blow-up:
        // every new shell was inheriting every existing session's master fd).
        setCloseOnExec(masterFD)
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL, 0) | O_NONBLOCK)
        seedRingAndOpenLog()
    }

    /// Seed the replay ring from the prior on-disk log (scrollback from before a daemon
    /// restart), then open the log for append. The new shell's output continues the file.
    private func seedRingAndOpenLog() {
        guard logEnabled else { return }   // opt-in: no on-disk scrollback by default
        let path = MuxPaths.sessionLog(paneID)
        if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
            ring = data.count > Session.ringCap ? Data(data.suffix(Session.ringCap)) : data
            logBytes = data.count
        }
        logFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        setCloseOnExec(logFD)   // scrollback log must not leak into forked shells
    }

    /// Append raw PTY output to the ring (and the on-disk log), trimming past the cap.
    func ingest(_ bytes: Data) {
        ring.append(bytes)
        if ring.count > Session.ringCap {
            ring.removeFirst(ring.count - Session.ringCap)   // O(n) trim; runs only when full
        }
        writeLog(bytes)
    }

    private func writeLog(_ bytes: Data) {
        guard logFD >= 0 else { return }
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = write(logFD, base, raw.count) }
        }
        logBytes += bytes.count
        if logBytes > Session.logCap { trimLog() }   // rewrite to the in-memory ring
    }

    /// Truncate the on-disk log back to the current ring (last ringCap bytes) so it stays
    /// bounded. Amortized: runs only when the file passes logCap (≈ every 256 KB of output).
    private func trimLog() {
        let path = MuxPaths.sessionLog(paneID)
        if logFD >= 0 { close(logFD); logFD = -1 }
        try? ring.write(to: URL(fileURLWithPath: path))
        chmod(path, 0o600)   // write(to:) may use default perms; re-assert owner-only
        logFD = open(path, O_WRONLY | O_APPEND, 0o600)
        setCloseOnExec(logFD)   // scrollback log must not leak into forked shells
        logBytes = ring.count
    }

    /// Remove a session's on-disk scrollback (called when the session ends cleanly).
    static func deleteLog(_ paneID: String) {
        try? FileManager.default.removeItem(atPath: MuxPaths.sessionLog(paneID))
    }

    /// The replay sent on attach: the whole current ring.
    func snapshot() -> Data { ring }

    func resize(cols rawCols: Int32, rows rawRows: Int32) {
        let cols = rawCols > 0 ? rawCols : 80
        let rows = rawRows > 0 ? rawRows : 24
        guard cols != self.cols || rows != self.rows else { return }   // no-op → no spurious SIGWINCH
        self.cols = cols; self.rows = rows
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func addClient(fd: Int32) { clients.append(fd) }
    func removeClient(fd: Int32) { clients.removeAll { $0 == fd } }
    func addSubscriber(fd: Int32) { subscribers.append(fd) }
    func removeSubscriber(fd: Int32) { subscribers.removeAll { $0 == fd } }

    func writeInput(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(masterFD, base.advanced(by: off), raw.count - off)
                if n <= 0 { break }; off += n
            }
        }
    }

    func markDead() { alive = false }

    deinit { close(masterFD); if logFD >= 0 { close(logFD) } }
}
