import Foundation
import VestaMux
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

enum MuxClient {
    /// Outcome of an in-place daemon upgrade request.
    enum UpgradeOutcome: Equatable {
        case success            // the daemon exec'd the new binary (socket EOF, no error frame)
        case failure(String)    // the daemon refused/failed and kept running (reason)
        case unreachable        // daemon down or unresponsive — nothing to upgrade
    }

    /// SHA-256 (hex) of a file's contents, or nil if unreadable. Used to compare the bundled
    /// vestad against the running daemon's own executable identity.
    static func sha256OfFile(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Ask the running daemon for its own executable SHA-256. Returns nil if the daemon is
    /// down OR doesn't answer `info` (an older daemon predating in-place upgrade — we then
    /// leave it alone). Bounded read so a wedged daemon can't stall launch.
    static func daemonExecutableSHA() -> String? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        guard send(fd, .info) else { return nil }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<8 {   // a couple of reads is plenty for one small reply frame
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buf.append(Data(tmp[0..<n]))
            // An EMPTY sha means the daemon couldn't hash its own image (its executable was
            // unlinked, or isn't readable to it). Treat that as "unknown", not as a real
            // identity — otherwise it never equals bundledSHA, so we'd request an upgrade on
            // every single launch. Each of those execs costs the panes their replay ring
            // whenever scrollback persistence is off.
            if let f = decodeServerFrame(from: &buf), case let .info(sha) = f {
                return sha.isEmpty ? nil : sha
            }
        }
        return nil
    }

    /// Request an in-place upgrade to the binary at `path`. Success is signalled by the daemon
    /// exec'ing → this socket EOFs with no error frame; a refusal/failure arrives as
    /// upgradeResult(ok:false). Bounded read (exec+adopt takes a moment) so a wedged daemon
    /// can't beachball the caller.
    static func upgradeDaemon(to path: String) -> UpgradeOutcome {
        guard let fd = connect() else { return .unreachable }
        defer { close(fd) }
        guard send(fd, .upgrade(path: path)) else { return .unreachable }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n == 0 { return .success }        // clean EOF, no error frame → the daemon exec'd
            if n < 0 { return .unreachable }      // timeout/error before any verdict
            buf.append(Data(tmp[0..<n]))
            while let f = decodeServerFrame(from: &buf) {
                if case let .upgradeResult(ok, msg) = f, !ok { return .failure(msg) }
            }
        }
    }

    /// paneID → login-shell pid for every alive daemon session, one round trip. nil when
    /// the daemon is down or predates the `pids` verb (unknown tag is silently consumed —
    /// no reply ever comes — so the bounded read just times out).
    static func shellPIDs() -> [String: pid_t]? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        guard send(fd, .pids) else { return nil }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<8 {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buf.append(Data(tmp[0..<n]))
            if let f = decodeServerFrame(from: &buf), case let .pids(map) = f {
                return map.mapValues { pid_t($0) }
            }
        }
        return nil
    }

    /// Connect to the daemon socket (no lazy-spawn — if the daemon is down there
    /// are no detached sessions). Returns the connected fd or nil.
    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return nil }
        var addr = makeSockaddrUn(MuxPaths.daemonSocket)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) == 0 }
        }
        if !ok { close(fd); return nil }
        return fd
    }

    /// Write one whole frame. Returns false on error/short write — the frame
    /// stream is desynced then, so the caller should give up on this fd.
    @discardableResult
    static func send(_ fd: Int32, _ f: ClientFrame) -> Bool {
        let d = encode(f)
        return d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Kill a specific session by paneID: attach (hello) then send kill.
    /// Best-effort; returns false if the daemon was unreachable or never acked.
    @discardableResult
    static func kill(paneID: String) -> Bool {
        guard let fd = connect() else { return false }
        defer { close(fd) }
        // wantReplay: false — this fd only exists to deliver the kill; the ring replay is
        // 256 KB of noise before it. (The drain loop below stays: an OLD daemon ignores
        // the flag and replays anyway, and draining is what lets its kill land.)
        guard send(fd, .hello(paneID: paneID, cols: 80, rows: 24, wantReplay: false)),
              send(fd, .kill) else { return false }
        // Bound the blocking read: kill runs on main (close/quit), so a wedged daemon must not
        // beachball the app. 2s is plenty for a local socket ack; on timeout read → -1 → false.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // Keep reading — do NOT stop after one read. `hello` makes the daemon replay the
        // session's whole scrollback ring (up to 256 KB) BEFORE it ever decodes the `kill`
        // frame sitting behind it in the same socket buffer. If we stop reading, the daemon's
        // replay send blocks, fails, and closeClient()s us — which throws away the still-
        // undecoded `kill`. The shell then survives the close, holding its port forever.
        // Draining is what actually lets the kill land.
        //
        // Stop at `exited`, NOT at EOF: reapDeadShells closes only clients whose send FAILED
        // plus subscribers, so a healthy draining client's fd is left open forever. Waiting
        // for EOF would therefore always burn the full SO_RCVTIMEO — and closeSession kills
        // panes serially on the main thread, so a 4-pane session would freeze the UI for ~8s.
        // `exited` is sent only after the replay flushed and the kill was decoded and reaped,
        // so it is the true ack and it arrives in milliseconds.
        //
        // Require helloAck BEFORE exited: when `hello` fails to create a session the daemon
        // sends a bare exited(status:1) and never binds clientSession, so the kill is a silent
        // no-op. Without this we would report that as success.
        let deadline = Date().addingTimeInterval(3)   // absolute cap; SO_RCVTIMEO resets per read
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 65536)
        var bound = false
        while Date() < deadline {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }                        // timeout, error, or daemon vanished
            buf.append(Data(tmp[0..<n]))
            while let f = decodeServerFrame(from: &buf) {
                switch f {
                case .helloAck: bound = true
                case .exited:   return bound           // reaped → the kill landed
                default:        break                  // replay output; keep draining
                }
            }
        }
        return false
    }
}
