import Foundation
import VestaMux
#if canImport(Darwin)
import Darwin
#endif

// argv[1] = paneID. This relay is a dumb byte pump: ghostty's stdin → daemon,
// daemon output → ghostty's stdout. The daemon owns the shell; on EOF (pane
// closed) we detach and the shell keeps running under vestad.
let args = CommandLine.arguments

// stderr diagnostics via a raw write loop. FileHandle.standardError.write(_:) throws an
// uncaught NSException when the underlying fd (the ghostty PTY) returns EAGAIN/EPIPE,
// which aborts the relay (SIGABRT) and surfaces as "Ghostty failed to launch". Never
// touch FileHandle here — raw write() returns an error, it can't throw.
func writeErr(_ s: String) {
    let bytes = Array(s.utf8)
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var off = 0
        while off < raw.count {
            let n = write(STDERR_FILENO, base + off, raw.count - off)
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            break   // EAGAIN/EPIPE/other → give up quietly, never throw
        }
    }
}

// A pane that draws the daemon-spawn straw gets a transient SIGHUP during the spawn
// window (ghostty/login session churn at workspace restore); default SIGHUP = terminate,
// which silently killed the relay before it could connect → "Ghostty failed to launch".
// Ignore it: the real "pane closed" signal is PTY EOF on stdin, which the pump handles.
// SIGPIPE likewise must be ignored — we write to the daemon socket and check the return.
signal(SIGHUP, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
guard args.count >= 2 else { writeErr("usage: vesta-attach <paneID>\n"); exit(2) }
let paneID = args[1]

// ── lazy-spawn the daemon if its socket is absent ────────────────────────────
func socketAlive(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return false }
    defer { close(fd) }
    var addr = makeSockaddrUn(path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
    }
}
func spawnDaemon() {
    let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("vestad").path
        ?? (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/vestad"
    // Launch vestad detached via posix_spawn with POSIX_SPAWN_SETSID. We deliberately
    // avoid Process/`/bin/sh`/perl: Process.waitUntilExit() hangs when the backgrounded
    // grandchild inherits our pane's PTY fds, which stalled the winning pane forever.
    // SETSID puts vestad in its own session so it outlives this pane; the file actions
    // point its std fds at /dev/null so it never holds/steals the pane's terminal.
    // vestad's own flock makes the multi-pane spawn race resolve to one surviving daemon.
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_RDWR, 0)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    // SETSID: own session so vestad outlives this pane. CLOEXEC_DEFAULT: every fd not named in
    // file_actions (0/1/2 → /dev/null above) is closed at exec, so this relay's socket + PTY fds
    // never leak into the daemon — the daemon then never re-leaks them into the shells it forks.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var pid: pid_t = 0
    exe.withCString { c in
        var argv: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: c), nil]
        _ = posix_spawn(&pid, c, &fa, &attr, &argv, environ)
    }
    posix_spawn_file_actions_destroy(&fa)
    posix_spawnattr_destroy(&attr)
    // parent: wait (bounded) for the socket to come up, whether we won the race or not.
    for _ in 0..<100 { if socketAlive(MuxPaths.daemonSocket) { return }; usleep(20_000) }
}
if !socketAlive(MuxPaths.daemonSocket) { spawnDaemon() }

// Open a fresh blocking connection to the daemon socket. Returns the connected fd, or
// nil if the daemon isn't reachable. Used for the initial attach AND for reconnect.
func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var addr = makeSockaddrUn(MuxPaths.daemonSocket)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
    }
    if !ok { close(fd); return nil }
    return fd
}

// ── connect ──────────────────────────────────────────────────────────────────
// Mutable: a daemon restart/crash (or a transient socket blip) swaps in a fresh fd via
// reconnect() below, transparently resuming the relay without disturbing the ghostty PTY.
guard var sock = connectSocket() else { writeErr("vesta-attach: daemon unavailable\n"); exit(1) }

// ── raw mode on our controlling terminal (the ghostty PTY = our stdin/stdout) ─
// Without this the PTY slave stays in cooked mode: the kernel line discipline
// line-buffers, echoes, and swallows escape sequences, so arrow keys (history),
// Ctrl-C, and Tab never reach the daemon's shell line editor. A relay must pass
// every byte through untouched and let the real shell do the editing. OPOST-off
// is correct too — daemon output is already cooked terminal bytes. Restore on exit
// so the next program on this PTY isn't left stuck in raw mode.
var savedTermios = termios()
let ptyRaw = tcgetattr(STDIN_FILENO, &savedTermios) == 0
if ptyRaw { var raw = savedTermios; cfmakeraw(&raw); tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) }

// ── initial winsize from our controlling tty (ghostty's PTY) ─────────────────
func currentWinsize() -> (Int, Int) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
        return (Int(ws.ws_col), Int(ws.ws_row))
    }
    return (80, 24)
}
/// Write one whole frame to the daemon socket. Returns false on unrecoverable
/// write error — the frame stream is desynced then, so the caller must tear
/// down (same as daemon EOF) rather than keep pumping garbage.
@discardableResult
func send(_ f: ClientFrame) -> Bool {
    let d = encode(f)
    return d.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(sock, raw.baseAddress!.advanced(by: off), raw.count - off)
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {   // sock is non-blocking
                var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, 1, 5000)
                if pr > 0 { continue }                         // writable → retry write
                if pr < 0 && errno == EINTR { continue }       // signal (SIGWINCH) → retry
                return false                                   // daemon stuck → desynced
            }
            return false   // EPIPE/other → daemon gone
        }
        return true
    }
}

// stdout is the ghostty PTY. We set the fd non-blocking for stdin, and in a PTY the
// stdin/stdout share one open-file-description, so a full output buffer returns EAGAIN.
// FileHandle.write(_:) THROWS an uncaught NSException on EAGAIN/short writes — which
// crashes the relay (ghostty then reports "failed to launch"). Use a raw write loop
// that waits for writable on EAGAIN instead of crashing.
func writeOut(_ data: Data) {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var off = 0
        while off < raw.count {
            let n = write(STDOUT_FILENO, base + off, raw.count - off)
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var pfd = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, 1, 5000)
                if pr > 0 { continue }                         // writable → retry write
                if pr < 0 && errno == EINTR { continue }       // signal (SIGWINCH) → retry
                break                                   // stuck reader → drop this chunk
            }
            break   // EPIPE/other → reader gone; stop writing (shell stays under daemon)
        }
    }
}
let (cols0, rows0) = currentWinsize()
// Our cwd is what libghostty set via config.working_directory (the project/session dir).
// The daemon chdirs the shell here when it first creates this session.
let spawnCwd = FileManager.default.currentDirectoryPath
if !send(.hello(paneID: paneID, cols: cols0, rows: rows0, cwd: spawnCwd)) {
    if ptyRaw { tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios) }
    writeErr("vesta-attach: lost daemon connection during hello\n")
    close(sock); exit(1)
}

// ── SIGWINCH → resize ────────────────────────────────────────────────────────
// C signal handlers can't capture Swift state; stash the socket fd globally.
var gSock: Int32 = sock
signal(SIGWINCH) { _ in
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
        let d = encode(ClientFrame.resize(cols: Int(ws.ws_col), rows: Int(ws.ws_row)))
        d.withUnsafeBytes { raw in _ = write(gSock, raw.baseAddress, raw.count) }
    }
}

// ── reconnect ────────────────────────────────────────────────────────────────
// A daemon-socket EOF/error is NOT session death: the daemon may have restarted (in-place
// upgrade), crashed, or hit a transient blip while the shell it hosts is still alive. Retry
// connect + re-hello for ~10s (250ms backoff), transparently resuming the byte relay; only
// give up (return false → relay exits) if the retries exhaust.
//
// The PTY side stays undisturbed throughout: we never EOF ghostty. Keystrokes typed during
// the outage queue in the kernel PTY buffer and flush after we reattach. Re-hello uses the
// SAME paneID, so Daemon.hello REATTACHES to the live pane (never a new session) and replays
// its ring — the screen comes back byte-exact. If the daemon lost the session (hard crash
// with no persisted shell), hello spawns a fresh shell, the best possible recovery.
@MainActor func reconnect() -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        usleep(250_000)   // backoff first: the daemon needs a beat to rebind its socket
        // Heal a full daemon crash: respawn it if the socket is gone (spawnDaemon waits for it).
        if !socketAlive(MuxPaths.daemonSocket) { spawnDaemon() }
        guard let fd = connectSocket() else { continue }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        sock = fd; gSock = fd            // route send()/SIGWINCH at the new fd
        inbuf.removeAll(keepingCapacity: true)   // the old frame stream is gone; start clean
        let (c, r) = currentWinsize()
        if send(.hello(paneID: paneID, cols: c, rows: r, cwd: spawnCwd)) { return true }
        close(fd); sock = -1
    }
    return false
}

// ── pump loop: stdin → daemon(input), daemon(server frames) → stdout ─────────
_ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL, 0) | O_NONBLOCK)
_ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL, 0) | O_NONBLOCK)
var inbuf = Data()
outer: while true {
    var rset = fd_set(); __darwin_fd_set(STDIN_FILENO, &rset); __darwin_fd_set(sock, &rset)
    let maxFD = max(STDIN_FILENO, sock)
    var tv = timeval(tv_sec: 30, tv_usec: 0)
    let n = select(maxFD + 1, &rset, nil, nil, &tv)
    if n < 0 { if errno == EINTR { continue }; break }    // EINTR from SIGWINCH is fine
    // stdin → input frames.
    if __darwin_fd_isset(STDIN_FILENO, &rset) != 0 {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let k = read(STDIN_FILENO, &tmp, tmp.count)
        if k == 0 { break }           // EOF on stdin (pane closed) → detach
        // PTY revoked (app quit): read() returns -1/EIO permanently. Without this the
        // loop would re-select instantly forever, spinning at 100% CPU. Only EINTR and
        // EAGAIN/EWOULDBLOCK are transient; anything else (EIO) means detach cleanly.
        if k < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { break }
        if k > 0, !send(.input(Data(tmp[0..<k]))) {
            // Input write failed → the daemon socket broke. Reconnect and resend this chunk on
            // the new fd so the keystrokes aren't lost; only tear down if reconnect exhausts.
            if !reconnect() { writeErr("vesta-attach: daemon unreachable after retries — detaching\r\n"); break outer }
            _ = send(.input(Data(tmp[0..<k])))
        }
    }
    // daemon → stdout (decode server frames; write output bytes).
    if __darwin_fd_isset(sock, &rset) != 0 {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let k = read(sock, &tmp, tmp.count)
        // Daemon closed the socket (restart/crash/blip). Don't treat as session death:
        // reconnect + re-hello, resuming the relay. Only exit if the retries exhaust.
        if k == 0 {
            if reconnect() { continue }
            writeErr("vesta-attach: daemon unreachable after retries — detaching\r\n")
            break outer
        }
        // sock is non-blocking: a spurious EAGAIN/EWOULDBLOCK (or EINTR) is transient,
        // so don't treat it as EOF and don't process stale bytes. A real error → reconnect.
        if k < 0 {
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            if reconnect() { continue } else { break outer }
        }
        inbuf.append(Data(tmp[0..<k]))
        while let f = decodeServerFrame(from: &inbuf) {
            switch f {
            case let .output(bytes):
                // Live output AND the on-attach raw-ring replay arrive as this frame.
                writeOut(bytes)
            case .exited:
                break outer        // shell exited → relay ends
            case let .helloAck(version):
                // Version gate: refuse a skewed daemon rather than misparse its frames
                // (critical for remote attach). Never kill the old daemon — it only
                // lingers because it still owns live shells (it idle-exits otherwise).
                // \r\n because the PTY is in raw mode here (OPOST off).
                if version != muxProtocolVersion {
                    writeErr("vesta-attach: a Vesta update left your sessions running under an older daemon\r\n" +
                             "(daemon protocol v\(version), this Vesta speaks v\(muxProtocolVersion)).\r\n" +
                             "Those sessions are still alive and will reattach with the old daemon.\r\n" +
                             "End them (exit their shells, or `vesta kill <id>`) to let the new daemon take over.\r\n")
                    break outer
                }
            case .sessions, .upgradeResult:
                break              // not used by the pump (the relay never sends list/upgrade)
            }
        }
    }
}
// EOF/quit: restore the terminal we raw-moded, then send a detach so the daemon
// drops our fd promptly; the shell keeps running under vestad.
if ptyRaw { tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios) }
send(.detach)
close(sock)
exit(0)
