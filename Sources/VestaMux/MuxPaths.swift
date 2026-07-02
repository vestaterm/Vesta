import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum MuxPaths {
    public static var base: String {
        // VESTA_MUX_DIR isolates a secondary/test instance onto its own socket + state.
        if let dir = ProcessInfo.processInfo.environment["VESTA_MUX_DIR"], !dir.isEmpty { return dir }
        return NSHomeDirectory() + "/Library/Application Support/vesta"
    }
    public static var daemonSocket: String { base + "/vestad.sock" }
    public static func sessionLog(_ paneID: String) -> String { base + "/sessions/\(paneID).log" }
    public static func ensureDirs() {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? fm.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: attrs)
        try? fm.createDirectory(atPath: base + "/sessions", withIntermediateDirectories: true, attributes: attrs)
        // createDirectory's mode only applies to dirs it CREATES; re-assert on the
        // leaf in case `base` pre-existed at a looser mode.
        try? fm.setAttributes(attrs, ofItemAtPath: base)
        try? fm.setAttributes(attrs, ofItemAtPath: base + "/sessions")
    }
}

/// Build a sockaddr_un for a unix socket path (shared by every socket call site;
/// the path is copied into sun_path, truncated if needed, always NUL-terminated).
public func makeSockaddrUn(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for i in 0..<min(bytes.count, raw.count - 1) { raw[i] = bytes[i] }
    }
    return addr
}

public func muxPathsSelfCheck() {
    let b = MuxPaths.base
    assert(b.hasSuffix("/Library/Application Support/vesta"), "base path")
    assert(MuxPaths.daemonSocket == b + "/vestad.sock", "socket path")
    assert(MuxPaths.sessionLog("abc") == b + "/sessions/abc.log", "session log path")
    // sessionLog keeps the paneID verbatim (it's a UUID string; no escaping needed).
    assert(MuxPaths.sessionLog("11111111-2222").hasSuffix("/sessions/11111111-2222.log"), "log uses paneID verbatim")
    // sockaddr helper: family set, path copied verbatim + NUL-terminated, long paths truncated.
    let sa = makeSockaddrUn("/tmp/x.sock")
    assert(sa.sun_family == sa_family_t(AF_UNIX), "sockaddr family")
    withUnsafeBytes(of: sa.sun_path) { raw in
        let want = Array("/tmp/x.sock".utf8)
        for (i, b) in want.enumerated() { assert(raw[i] == b, "sun_path byte \(i)") }
        assert(raw[want.count] == 0, "sun_path NUL-terminated")
    }
    let long = makeSockaddrUn(String(repeating: "a", count: 300))
    withUnsafeBytes(of: long.sun_path) { raw in
        assert(raw[raw.count - 1] == 0, "oversized path truncated, trailing NUL kept")
    }
    print("muxPathsSelfCheck ok")
}
