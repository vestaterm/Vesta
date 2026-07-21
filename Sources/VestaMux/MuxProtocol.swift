import Foundation

public let muxProtocolVersion = 5

public struct SessionInfo: Codable, Equatable {
    public let id: String
    public let name: String?
    public let cwd: String?
    public let alive: Bool
    public let attachedCount: Int
    public init(id: String, name: String?, cwd: String?, alive: Bool, attachedCount: Int) {
        self.id = id; self.name = name; self.cwd = cwd; self.alive = alive; self.attachedCount = attachedCount
    }
}

public enum ClientFrame: Equatable {
    case hello(paneID: String, cols: Int, rows: Int, cwd: String? = nil)
    case input(Data)
    case resize(cols: Int, rows: Int)
    case detach
    case kill
    case list
    case subscribe(paneID: String)   // v5: passive output-only reader (GUI pane-output tap)
    case upgrade(path: String)       // v6: swap the daemon to a new binary in place (self-exec)
    case info                        // v6: probe the daemon's own executable identity (SHA-256)
    case pids                        // v7: paneID → login-shell pid map (port scan under persist)
}

public enum ServerFrame: Equatable {
    case helloAck(version: Int)
    // On attach the daemon replays the raw output ring as a normal `output` frame
    // (no separate snapshot/screen state — ghostty parses the bytes). Live output
    // is the same frame. `exited` ends the session; `sessions` answers `list`.
    case output(Data)
    case exited(status: Int32)
    case sessions([SessionInfo])
    // v6: reply to `upgrade`. Sent ONLY on failure (ok:false + reason). On success the daemon
    // execs the new binary, which closes this socket → the client sees EOF (success signal).
    case upgradeResult(ok: Bool, message: String)
    case info(sha: String)           // v6: reply to `info` — the daemon's own exe SHA-256 (hex)
    case pids([String: Int32])       // v7: reply to `pids` — alive sessions' shell pids
}

// ── byte helpers ────────────────────────────────────────────────────────
private func putU32(_ v: UInt32, into d: inout Data) {
    d.append(UInt8(v >> 24 & 0xff)); d.append(UInt8(v >> 16 & 0xff))
    d.append(UInt8(v >> 8 & 0xff));  d.append(UInt8(v & 0xff))
}
private func getU32(_ d: Data, _ i: Int) -> UInt32 {
    (UInt32(d[d.startIndex + i]) << 24) | (UInt32(d[d.startIndex + i + 1]) << 16)
    | (UInt32(d[d.startIndex + i + 2]) << 8) | UInt32(d[d.startIndex + i + 3])
}
// A field = [UInt32 BE len][len bytes].
private func putField(_ bytes: Data, into d: inout Data) { putU32(UInt32(bytes.count), into: &d); d.append(bytes) }
private func putStr(_ s: String, into d: inout Data) { putField(Data(s.utf8), into: &d) }
// Optional string: 1 present-flag byte, then a field if present.
private func putOptStr(_ s: String?, into d: inout Data) {
    if let s { d.append(1); putStr(s, into: &d) } else { d.append(0) }
}

// Frame the [tag][payload] tail behind a total-length prefix.
private func frame(_ tag: UInt8, _ payload: Data) -> Data {
    var d = Data()
    putU32(UInt32(payload.count + 1), into: &d)   // +1 for the tag
    d.append(tag)
    d.append(payload)
    return d
}

public func encode(_ f: ClientFrame) -> Data {
    var p = Data()
    switch f {
    case let .hello(paneID, cols, rows, cwd):
        putStr(paneID, into: &p); putU32(UInt32(cols), into: &p); putU32(UInt32(rows), into: &p)
        putOptStr(cwd, into: &p)   // v4: spawn cwd (older daemons stop reading after rows)
        return frame(0x01, p)
    case let .input(data):
        putField(data, into: &p); return frame(0x02, p)
    case let .resize(cols, rows):
        putU32(UInt32(cols), into: &p); putU32(UInt32(rows), into: &p); return frame(0x03, p)
    case .detach: return frame(0x04, p)
    case .kill:   return frame(0x05, p)
    case .list:   return frame(0x06, p)
    case let .subscribe(paneID):
        putStr(paneID, into: &p); return frame(0x07, p)
    case let .upgrade(path):
        putStr(path, into: &p); return frame(0x08, p)
    case .info: return frame(0x09, p)
    case .pids: return frame(0x0a, p)
    }
}

public func encode(_ f: ServerFrame) -> Data {
    var p = Data()
    switch f {
    case let .helloAck(version):
        putU32(UInt32(version), into: &p); return frame(0x11, p)
    case let .output(data):
        putField(data, into: &p); return frame(0x14, p)
    case let .exited(status):
        putU32(UInt32(bitPattern: status), into: &p); return frame(0x15, p)
    case let .sessions(list):
        putU32(UInt32(list.count), into: &p)
        for s in list {
            putStr(s.id, into: &p); putOptStr(s.name, into: &p); putOptStr(s.cwd, into: &p)
            p.append(s.alive ? 1 : 0); putU32(UInt32(s.attachedCount), into: &p)
        }
        return frame(0x16, p)
    case let .upgradeResult(ok, message):
        p.append(ok ? 1 : 0); putStr(message, into: &p); return frame(0x18, p)
    case let .info(sha):
        putStr(sha, into: &p); return frame(0x19, p)
    case let .pids(map):
        putU32(UInt32(map.count), into: &p)
        for (id, pid) in map { putStr(id, into: &p); putU32(UInt32(bitPattern: pid), into: &p) }
        return frame(0x1a, p)
    }
}

// Pull one complete frame off the front of buf, or nil if not fully buffered.
// On success removes the consumed bytes from buf and returns (tag, payload).
private func pullFrame(from buf: inout Data) -> (UInt8, Data)? {
    guard buf.count >= 4 else { return nil }
    let payloadLen = Int(getU32(buf, 0))      // counts tag + payload
    let total = 4 + payloadLen
    guard buf.count >= total else { return nil }   // partial: leave buf untouched
    let tag = buf[buf.startIndex + 4]
    let payload = buf.subdata(in: (buf.startIndex + 5)..<(buf.startIndex + total))
    buf.removeSubrange(buf.startIndex..<(buf.startIndex + total))
    return (tag, payload)
}

// Cursor reader over a payload Data.
private struct Reader {
    let d: Data; var i: Int = 0
    init(_ d: Data) { self.d = d }
    mutating func u32() -> UInt32 {
        let v = (UInt32(d[d.startIndex + i]) << 24) | (UInt32(d[d.startIndex + i + 1]) << 16)
            | (UInt32(d[d.startIndex + i + 2]) << 8) | UInt32(d[d.startIndex + i + 3])
        i += 4; return v
    }
    mutating func field() -> Data {
        let n = Int(u32())
        let s = d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + n)); i += n; return s
    }
    mutating func str() -> String { String(decoding: field(), as: UTF8.self) }
    mutating func byte() -> UInt8 { let b = d[d.startIndex + i]; i += 1; return b }
    mutating func optStr() -> String? { byte() == 1 ? str() : nil }
    func remaining() -> Int { d.count - i }
}

public func decodeClientFrame(from buf: inout Data) -> ClientFrame? {
    guard let (tag, payload) = pullFrame(from: &buf) else { return nil }
    var r = Reader(payload)
    switch tag {
    case 0x01:
        let id = r.str(); let c = Int(r.u32()); let rr = Int(r.u32())
        let cwd = r.remaining() > 0 ? r.optStr() : nil   // v4 field; tolerate v3 clients without it
        return .hello(paneID: id, cols: c, rows: rr, cwd: cwd)
    case 0x02: return .input(r.field())
    case 0x03: return .resize(cols: Int(r.u32()), rows: Int(r.u32()))
    case 0x04: return .detach
    case 0x05: return .kill
    case 0x06: return .list
    case 0x07: return .subscribe(paneID: r.str())
    case 0x08: return .upgrade(path: r.str())
    case 0x09: return .info
    case 0x0a: return .pids
    default:   return nil
    }
}

public func decodeServerFrame(from buf: inout Data) -> ServerFrame? {
    guard let (tag, payload) = pullFrame(from: &buf) else { return nil }
    var r = Reader(payload)
    switch tag {
    case 0x11: return .helloAck(version: Int(r.u32()))
    case 0x14: return .output(r.field())
    case 0x15: return .exited(status: Int32(bitPattern: r.u32()))
    case 0x16:
        let n = Int(r.u32())
        var list: [SessionInfo] = []
        for _ in 0..<n {
            let id = r.str(); let name = r.optStr(); let cwd = r.optStr()
            let alive = r.byte() == 1; let count = Int(r.u32())
            list.append(SessionInfo(id: id, name: name, cwd: cwd, alive: alive, attachedCount: count))
        }
        return .sessions(list)
    case 0x18: return .upgradeResult(ok: r.byte() == 1, message: r.str())
    case 0x19: return .info(sha: r.str())
    case 0x1a:
        let n = Int(r.u32())
        var map: [String: Int32] = [:]
        for _ in 0..<n { let id = r.str(); map[id] = Int32(bitPattern: r.u32()) }
        return .pids(map)
    default: return nil
    }
}

public func muxProtocolSelfCheck() {
    // Round-trip every ClientFrame case.
    let clientCases: [ClientFrame] = [
        .hello(paneID: "abc-123", cols: 80, rows: 24, cwd: "/tmp/x"),
        .hello(paneID: "no-cwd", cols: 80, rows: 24, cwd: nil),
        .input(Data([0x01, 0x02, 0xff, 0x00])),
        .resize(cols: 120, rows: 40),
        .detach, .kill, .list,
        .subscribe(paneID: "sub-1"),
        .upgrade(path: "/Applications/Vesta.app/Contents/MacOS/vestad"),
        .info,
        .pids,
    ]
    for f in clientCases {
        var buf = encode(f)
        let out = decodeClientFrame(from: &buf)
        assert(out == f, "client round-trip \(f)")
        assert(buf.isEmpty, "client decode consumed the whole frame")
    }
    // Round-trip every ServerFrame case.
    let info = SessionInfo(id: "p1", name: "build", cwd: "/tmp", alive: true, attachedCount: 2)
    let serverCases: [ServerFrame] = [
        .helloAck(version: 1),
        .output(Data([0x68, 0x69])),
        .exited(status: 137),
        .sessions([info, SessionInfo(id: "p2", name: nil, cwd: nil, alive: false, attachedCount: 0)]),
        .upgradeResult(ok: false, message: "new binary not executable"),
        .upgradeResult(ok: true, message: ""),
        .info(sha: "3acca5829d4db4a21f9cda77d2baf8f1345ec651aebe50bd990f92328ae4c9da"),
        .pids(["p1": 4242, "p2": 99]),
        .pids([:]),
    ]
    for f in serverCases {
        var buf = encode(f)
        let out = decodeServerFrame(from: &buf)
        assert(out == f, "server round-trip \(f)")
        assert(buf.isEmpty, "server decode consumed the whole frame")
    }
    // Partial buffer: a frame missing its last byte decodes to nil and leaves buf untouched.
    var full = encode(ClientFrame.input(Data([0xaa, 0xbb, 0xcc])))
    let truncated = full.dropLast()
    var partial = Data(truncated)
    let before = partial
    assert(decodeClientFrame(from: &partial) == nil, "partial frame yields nil")
    assert(partial == before, "partial decode does not consume bytes")
    // A buffer with one full frame + a partial second frame returns the first and
    // leaves exactly the partial bytes.
    full.append(truncated)
    var two = full
    assert(decodeClientFrame(from: &two) == .input(Data([0xaa, 0xbb, 0xcc])), "first of two decodes")
    assert(two == Data(truncated), "second (partial) frame left intact")
    print("muxProtocolSelfCheck ok")
}
