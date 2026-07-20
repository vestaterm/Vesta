import Foundation

// ── zero-downtime upgrade: state-file (de)serialization ──────────────────────
//
// When vestad upgrades itself in place (execv of a new binary), it can't hand live PTY
// masters + child PIDs to the new image through memory — exec wipes the address space. So
// it (a) clears CLOEXEC on each master fd (and the single-instance lock fd) so they survive
// the exec by fd number, and (b) writes a small 0600 state file describing every session:
// its paneID, the inherited master fd number, the child pid, size, cwd/name, and the raw
// output ring. The new binary parses this on `--resume`, adopts the fds into fresh Session
// objects seeded from the rings, and resumes — the hosted shells never notice.
//
// This file is the PURE, I/O-free core (serialize ↔ parse), so `vesta selfcheck` can
// round-trip it (fd numbers, ring bytes, optionals) without touching a real daemon. All the
// actual fd/exec/file work lives in vestad (Sources/vestad/Upgrade.swift).

/// Bump when the on-disk layout changes. A resume that reads a different version → the new
/// binary falls back to a fresh start (shells lost, but never a hung daemon) rather than
/// misparsing. parseUpgradeState enforces this.
public let upgradeStateVersion: UInt32 = 1

/// 4-byte magic prefix ("VUP1") — a corrupt/foreign file fails the magic check → nil → fresh start.
private let upgradeMagic: [UInt8] = [0x56, 0x55, 0x50, 0x31]   // "VUP1"

/// One session's worth of adoptable state.
public struct SessionState: Equatable {
    public let paneID: String
    public let masterFD: Int32   // the PTY master fd number, inherited across execv (CLOEXEC cleared)
    public let pid: Int32        // the child shell's pid — preserved across exec (still our child)
    public let cols: Int32
    public let rows: Int32
    public let cwd: String?
    public let name: String?
    public let ring: Data        // raw output ring, replayed to reattaching clients
    public init(paneID: String, masterFD: Int32, pid: Int32, cols: Int32, rows: Int32,
                cwd: String?, name: String?, ring: Data) {
        self.paneID = paneID; self.masterFD = masterFD; self.pid = pid
        self.cols = cols; self.rows = rows; self.cwd = cwd; self.name = name; self.ring = ring
    }
}

/// The whole snapshot handed across the self-exec.
public struct UpgradeState: Equatable {
    public let version: UInt32
    public let lockFD: Int32      // single-instance lock fd, kept held across exec (CLOEXEC cleared)
    public let sessions: [SessionState]
    public init(version: UInt32 = upgradeStateVersion, lockFD: Int32, sessions: [SessionState]) {
        self.version = version; self.lockFD = lockFD; self.sessions = sessions
    }
}

// ── byte helpers (self-contained; big-endian u32 + length-prefixed fields) ────
private func putU32(_ v: UInt32, into d: inout Data) {
    d.append(UInt8(v >> 24 & 0xff)); d.append(UInt8(v >> 16 & 0xff))
    d.append(UInt8(v >> 8 & 0xff));  d.append(UInt8(v & 0xff))
}
private func putField(_ bytes: Data, into d: inout Data) { putU32(UInt32(bytes.count), into: &d); d.append(bytes) }
private func putStr(_ s: String, into d: inout Data) { putField(Data(s.utf8), into: &d) }
private func putOptStr(_ s: String?, into d: inout Data) {
    if let s { d.append(1); putStr(s, into: &d) } else { d.append(0) }
}

/// Serialize a snapshot to bytes. Layout: magic, version, lockFD, count, then per session
/// [paneID][masterFD][pid][cols][rows][cwd?][name?][ring].
public func serializeUpgradeState(_ s: UpgradeState) -> Data {
    var d = Data()
    d.append(contentsOf: upgradeMagic)
    putU32(s.version, into: &d)
    putU32(UInt32(bitPattern: s.lockFD), into: &d)
    putU32(UInt32(s.sessions.count), into: &d)
    for ss in s.sessions {
        putStr(ss.paneID, into: &d)
        putU32(UInt32(bitPattern: ss.masterFD), into: &d)
        putU32(UInt32(bitPattern: ss.pid), into: &d)
        putU32(UInt32(bitPattern: ss.cols), into: &d)
        putU32(UInt32(bitPattern: ss.rows), into: &d)
        putOptStr(ss.cwd, into: &d)
        putOptStr(ss.name, into: &d)
        putField(ss.ring, into: &d)
    }
    return d
}

/// Bounds-checked cursor. Every read validates it stays inside the buffer; a short/corrupt
/// file yields nil from parse rather than a crash or a misread.
private struct SafeReader {
    let d: Data; var i: Int = 0
    init(_ d: Data) { self.d = d }
    mutating func u32() -> UInt32? {
        guard i + 4 <= d.count else { return nil }
        let b = d.startIndex + i
        let v = (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
        i += 4; return v
    }
    mutating func field() -> Data? {
        guard let n = u32(), i + Int(n) <= d.count else { return nil }
        let s = d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + Int(n))); i += Int(n); return s
    }
    mutating func str() -> String? { field().map { String(decoding: $0, as: UTF8.self) } }
    mutating func byte() -> UInt8? { guard i < d.count else { return nil }; let v = d[d.startIndex + i]; i += 1; return v }
    mutating func optStr() -> (has: Bool, val: String?)? {
        guard let b = byte() else { return nil }
        if b == 0 { return (true, nil) }
        guard let s = str() else { return nil }
        return (true, s)
    }
}

/// Parse a snapshot. Returns nil on a bad magic, a version mismatch, or ANY truncation —
/// the caller (vestad --resume) then falls back to a fresh start instead of adopting garbage.
public func parseUpgradeState(_ data: Data) -> UpgradeState? {
    guard data.count >= 4 else { return nil }
    for (k, m) in upgradeMagic.enumerated() where data[data.startIndex + k] != m { return nil }
    var r = SafeReader(data); r.i = 4
    guard let version = r.u32(), version == upgradeStateVersion else { return nil }
    guard let lockRaw = r.u32(), let count = r.u32() else { return nil }
    guard count <= 100_000 else { return nil }   // sanity cap — a corrupt count must not preallocate wildly
    var sessions: [SessionState] = []
    for _ in 0..<count {
        guard let paneID = r.str(),
              let masterFD = r.u32(), let pid = r.u32(),
              let cols = r.u32(), let rows = r.u32(),
              let cwd = r.optStr(), let name = r.optStr(),
              let ring = r.field()
        else { return nil }
        sessions.append(SessionState(
            paneID: paneID, masterFD: Int32(bitPattern: masterFD), pid: Int32(bitPattern: pid),
            cols: Int32(bitPattern: cols), rows: Int32(bitPattern: rows),
            cwd: cwd.val, name: name.val, ring: ring))
    }
    return UpgradeState(version: version, lockFD: Int32(bitPattern: lockRaw), sessions: sessions)
}

public func upgradeStateSelfCheck() {
    // Round-trip: fd numbers, sizes, optionals present + absent, ring bytes (incl. NULs).
    let ringA = Data([0x1b, 0x5b, 0x30, 0x6d, 0x00, 0xff, 0x41])   // ESC[0m + NUL + high byte
    let s = UpgradeState(lockFD: 5, sessions: [
        SessionState(paneID: "pane-abc", masterFD: 7, pid: 4242, cols: 120, rows: 40,
                     cwd: "/tmp/x", name: "build", ring: ringA),
        SessionState(paneID: "pane-def", masterFD: 9, pid: 4243, cols: 80, rows: 24,
                     cwd: nil, name: nil, ring: Data()),
    ])
    let blob = serializeUpgradeState(s)
    guard let back = parseUpgradeState(blob) else { assertionFailure("round-trip parse failed"); return }
    assert(back == s, "upgrade state round-trip mismatch")
    assert(back.lockFD == 5 && back.sessions.count == 2, "top-level fields")
    assert(back.sessions[0].masterFD == 7 && back.sessions[0].pid == 4242, "fd/pid preserved")
    assert(back.sessions[0].ring == ringA, "ring bytes preserved verbatim")
    assert(back.sessions[1].cwd == nil && back.sessions[1].name == nil, "absent optionals")
    // Corruption / truncation / version guards all yield nil (→ fresh-start fallback).
    assert(parseUpgradeState(Data()) == nil, "empty → nil")
    assert(parseUpgradeState(Data([0x00, 0x01, 0x02, 0x03])) == nil, "bad magic → nil")
    assert(parseUpgradeState(blob.dropLast()) == nil, "truncated → nil")
    var wrongVersion = serializeUpgradeState(s)
    wrongVersion[wrongVersion.startIndex + 7] = 0xfe   // corrupt the version's low byte
    assert(parseUpgradeState(wrongVersion) == nil, "version mismatch → nil")
    print("upgradeStateSelfCheck ok")
}
