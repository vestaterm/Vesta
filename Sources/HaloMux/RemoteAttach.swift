import Foundation

/// A parsed `ssh://[user@]host[:port]` remote-attach destination.
public struct RemoteTarget: Equatable {
    public let user: String?     // ssh login user, nil = ssh default
    public let host: String      // hostname or IP
    public let port: Int         // ssh port, 22 if unspecified
    public let session: String?  // optional named session on the remote
    public init(user: String?, host: String, port: Int, session: String?) {
        self.user = user; self.host = host; self.port = port; self.session = session
    }
}

/// Parse `ssh://[user@]host[:port]`. Returns nil if the scheme isn't ssh,
/// the host is empty, or the port is non-numeric/out of range.
/// `session` is the optional positional arg passed after the URL on the CLI.
public func parseRemoteURL(_ s: String, session: String?) -> RemoteTarget? {
    let prefix = "ssh://"
    guard s.hasPrefix(prefix) else { return nil }
    var rest = String(s.dropFirst(prefix.count))   // [user@]host[:port]
    guard !rest.isEmpty else { return nil }

    var user: String?
    if let at = rest.firstIndex(of: "@") {
        user = String(rest[..<at])
        rest = String(rest[rest.index(after: at)...])
    }

    var host = rest
    var port = 22
    if rest.hasPrefix("[") {                       // bracketed IPv6: [::1][:port]
        guard let close = rest.firstIndex(of: "]") else { return nil }
        host = String(rest[rest.index(after: rest.startIndex)..<close])
        let after = rest[rest.index(after: close)...]
        if after.hasPrefix(":") {
            guard let p = Int(after.dropFirst()), p > 0, p <= 65535 else { return nil }
            port = p
        } else if !after.isEmpty {
            return nil
        }
    } else if let colon = rest.lastIndex(of: ":") {
        host = String(rest[..<colon])
        let portStr = rest[rest.index(after: colon)...]
        guard let p = Int(portStr), p > 0, p <= 65535 else { return nil }
        port = p
    }
    guard !host.isEmpty else { return nil }
    return RemoteTarget(user: user, host: host, port: port, session: session)
}

/// Result of probing the remote helper's protocol version.
public enum RemoteProbe: Equatable {
    case missing            // helper not installed / not on PATH
    case version(Int)       // installed, reports this muxProtocolVersion
}

/// Parse the remote probe command's stdout. The probe runs
/// `halod --proto-version` on the host, which prints `halod-proto <N>`.
/// Anything else (empty, "command not found", garbage) => .missing.
public func parseProbeOutput(_ raw: String) -> RemoteProbe {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = "halod-proto "
    guard let r = trimmed.range(of: token) else { return .missing }
    let after = trimmed[r.upperBound...].prefix { $0.isNumber }
    guard let n = Int(after) else { return .missing }
    return .version(n)
}

/// Deploy decision: keep the remote helper iff it's present AND its protocol
/// version exactly matches ours. Missing or any skew => redeploy over scp.
public func shouldDeploy(_ probe: RemoteProbe) -> Bool {
    switch probe {
    case .missing:          return true
    case .version(let v):   return v != muxProtocolVersion
    }
}

public func remoteAttachSelfCheck() {
    // ssh-URL parse
    assert(parseRemoteURL("ssh://example.com", session: nil)
           == RemoteTarget(user: nil, host: "example.com", port: 22, session: nil))
    assert(parseRemoteURL("ssh://bob@10.0.0.5:2222", session: "build")
           == RemoteTarget(user: "bob", host: "10.0.0.5", port: 2222, session: "build"))
    assert(parseRemoteURL("ssh://[::1]:22", session: nil)
           == RemoteTarget(user: nil, host: "::1", port: 22, session: nil))
    assert(parseRemoteURL("http://example.com", session: nil) == nil)   // wrong scheme
    assert(parseRemoteURL("ssh://", session: nil) == nil)               // empty host
    assert(parseRemoteURL("ssh://host:notaport", session: nil) == nil)  // bad port
    // remote-deploy decision: present && versionOK -> skip, else deploy
    assert(shouldDeploy(.missing) == true)
    assert(shouldDeploy(.version(muxProtocolVersion + 1)) == true)   // skew -> deploy
    assert(shouldDeploy(.version(muxProtocolVersion - 1)) == true)   // skew -> deploy
    assert(shouldDeploy(.version(muxProtocolVersion)) == false)      // match -> skip
    // probe output parsing (helper prints "halod-proto <N>" or nothing)
    assert(parseProbeOutput("halod-proto \(muxProtocolVersion)\n") == .version(muxProtocolVersion))
    assert(parseProbeOutput("  halod-proto 7  ") == .version(7))
    assert(parseProbeOutput("") == .missing)
    assert(parseProbeOutput("bash: halod: command not found") == .missing)
    print("remoteAttachSelfCheck ok")
}
