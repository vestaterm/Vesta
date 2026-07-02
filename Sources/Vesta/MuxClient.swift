import Foundation
import VestaMux
#if canImport(Darwin)
import Darwin
#endif

enum MuxClient {
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
