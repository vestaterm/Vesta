import Foundation

enum Ports {
    /// Extract unique listening TCP ports from `lsof -nP -iTCP -sTCP:LISTEN` output.
    /// Lines look like: `node 1234 user 23u IPv4 ... TCP *:3000 (LISTEN)`
    static func parse(_ lsof: String) -> [Int] {
        var seen = Set<Int>()
        for line in lsof.split(separator: "\n") {
            guard line.contains("(LISTEN)"), let colon = line.range(of: ":", options: .backwards) else { continue }
            let tail = line[colon.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            if let port = Int(digits) { seen.insert(port) }
        }
        return seen.sorted()
    }

    /// Listen ports opened by `pid` and its descendants.
    // ponytail: misses re-parented procs. Upgrade path: proc_pidinfo or libproc.
    static func forShell(pid: pid_t) -> [Int] {
        var pids = [pid]; var frontier = [pid]
        while let p = frontier.popLast() {
            let kids = shell("/usr/bin/pgrep", ["-P", "\(p)"]).split(separator: "\n").compactMap { pid_t($0) }
            pids += kids; frontier += kids
        }
        let out = shell("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pids.map(String.init).joined(separator: ",")])
        return parse(out)
    }

    private static func shell(_ tool: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

func portsSelfCheck() {
    let sample = """
    node 1 u 1u IPv4 0t0 TCP *:3000 (LISTEN)
    node 1 u 2u IPv6 0t0 TCP [::1]:8080 (LISTEN)
    node 1 u 3u IPv4 0t0 TCP 127.0.0.1:3000 (LISTEN)
    sshd 9 u 4u IPv4 0t0 TCP *:22 (ESTABLISHED)
    """
    assert(Ports.parse(sample) == [3000, 8080], "listen ports deduped/sorted, got \(Ports.parse(sample))")
    print("portsSelfCheck OK")
}
