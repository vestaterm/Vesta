import Foundation

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

public func muxPathsSelfCheck() {
    let b = MuxPaths.base
    assert(b.hasSuffix("/Library/Application Support/vesta"), "base path")
    assert(MuxPaths.daemonSocket == b + "/vestad.sock", "socket path")
    assert(MuxPaths.sessionLog("abc") == b + "/sessions/abc.log", "session log path")
    // sessionLog keeps the paneID verbatim (it's a UUID string; no escaping needed).
    assert(MuxPaths.sessionLog("11111111-2222").hasSuffix("/sessions/11111111-2222.log"), "log uses paneID verbatim")
    print("muxPathsSelfCheck ok")
}
