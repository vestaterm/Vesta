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
            if let f = decodeServerFrame(from: &buf), case let .info(sha) = f { return sha }
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
        guard send(fd, .hello(paneID: paneID, cols: 80, rows: 24)),   // bind this fd to the session
              send(fd, .kill) else { return false }
        // Bound the blocking read: kill runs on main (close/quit), so a wedged daemon must not
        // beachball the app. 2s is plenty for a local socket ack; on timeout read → -1 → false.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // Wait for the daemon to act; 0/-1 (incl. timeout) means it vanished without acking.
        var tmp = [UInt8](repeating: 0, count: 4096)
        return read(fd, &tmp, tmp.count) > 0
    }
}
