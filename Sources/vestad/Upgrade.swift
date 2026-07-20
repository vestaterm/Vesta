import Foundation
import VestaMux
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

// I/O side of the self-exec upgrade (the pure serialize/parse core lives in
// VestaMux/UpgradeState.swift). Everything here touches the filesystem, the executable
// image, or process identity, so it can't be unit-checked without a real daemon — the
// end-to-end test in a sandboxed VESTA_MUX_DIR daemon covers it instead.

/// Absolute path to THIS running executable (for the identical-binary refuse check). Uses
/// `_NSGetExecutablePath`; falls back to argv[0]. Symlinks are fine — we hash file CONTENTS,
/// not the path.
func currentExecutablePath() -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buf, &size) == 0 { return String(cString: buf) }
    return CommandLine.arguments.first ?? "vestad"
}

/// SHA-256 of a file's contents, hex-encoded, or nil if unreadable. Used to (a) refuse a
/// no-op upgrade to a byte-identical binary and (b) answer the app's `info` identity probe.
func sha256OfFile(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Where the daemon parks its upgrade snapshot for the new image to pick up on `--resume`.
/// Under MuxPaths.base (honours VESTA_MUX_DIR isolation), 0600 — it holds terminal ring bytes.
var upgradeStatePath: String { MuxPaths.base + "/upgrade-state.bin" }

/// Write the snapshot atomically at 0600. Returns false on any I/O failure (→ abort upgrade,
/// keep running). Written with a temp fd that's CLOEXEC, so it never leaks across the exec.
func writeUpgradeState(_ state: UpgradeState) -> Bool {
    let data = serializeUpgradeState(state)
    let path = upgradeStatePath
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { return false }
    setCloseOnExec(fd)
    var ok = true
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var off = 0
        while off < raw.count {
            let n = write(fd, base.advanced(by: off), raw.count - off)
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            ok = false; break
        }
    }
    close(fd)
    if ok { chmod(path, 0o600) } else { unlink(path) }
    return ok
}

/// Read + parse the snapshot on `--resume`. nil on missing/corrupt/version-mismatch → the
/// caller falls back to a fresh start. Does NOT delete the file (the caller deletes it only
/// after successfully adopting, so a crash mid-adopt still leaves it for inspection/cleanup).
func readUpgradeState(_ path: String) -> UpgradeState? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return parseUpgradeState(data)
}
