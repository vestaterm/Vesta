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
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(MuxPaths.daemonSocket.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for i in 0..<min(bytes.count, raw.count - 1) { raw[i] = bytes[i] }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) == 0 }
        }
        if !ok { close(fd); return nil }
        return fd
    }

    static func send(_ fd: Int32, _ f: ClientFrame) {
        let d = encode(f)
        d.withUnsafeBytes { raw in var off = 0
            while off < raw.count { let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off); if n <= 0 { break }; off += n } }
    }

    /// Kill a specific session by paneID: attach (hello) then send kill.
    static func kill(paneID: String) {
        guard let fd = connect() else { return }
        defer { close(fd) }
        send(fd, .hello(paneID: paneID, cols: 80, rows: 24))   // bind this fd to the session
        send(fd, .kill)
        var tmp = [UInt8](repeating: 0, count: 4096); _ = read(fd, &tmp, tmp.count)   // let the daemon act
    }
}
