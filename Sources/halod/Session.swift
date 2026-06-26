import Foundation
import HaloMux
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

    init?(paneID: String, cols rawCols: Int32, rows rawRows: Int32, cwd: String? = nil) {
        // Clamp to a sane minimum. A pane created before its window lays out reports a
        // 0×0 size; a 0-sized PTY is rejected by some shells. The real size arrives via
        // the first resize.
        let cols = rawCols > 0 ? rawCols : 80
        let rows = rawRows > 0 ? rawRows : 24
        self.paneID = paneID; self.cols = cols; self.rows = rows; self.cwd = cwd
        // forkpty a login shell.
        var master: Int32 = 0
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&master, nil, nil, &ws)
        if child < 0 { return nil }
        if child == 0 {
            // Start the shell in the requested directory (the project/session dir). A bad
            // path just leaves the child in its inherited cwd — the shell still spawns.
            if let cwd, !cwd.isEmpty { cwd.withCString { _ = chdir($0) } }
            let shell = getenv("SHELL").flatMap { String(cString: $0) } ?? "/bin/zsh"
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
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL, 0) | O_NONBLOCK)
    }

    /// Append raw PTY output to the ring, trimming the oldest bytes past the cap.
    func ingest(_ bytes: Data) {
        ring.append(bytes)
        if ring.count > Session.ringCap {
            ring.removeFirst(ring.count - Session.ringCap)   // O(n) trim; runs only when full
        }
    }

    /// The replay sent on attach: the whole current ring.
    func snapshot() -> Data { ring }

    func resize(cols rawCols: Int32, rows rawRows: Int32) {
        let cols = rawCols > 0 ? rawCols : 80
        let rows = rawRows > 0 ? rawRows : 24
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

    deinit { close(masterFD) }
}
