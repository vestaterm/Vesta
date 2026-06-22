import Darwin
import Foundation

func controlSocketPath() -> String {
    let base = NSHomeDirectory() + "/Library/Application Support/halo"
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return base + "/control.sock"
}

let controlVerbs: Set<String> = ["split", "new-pane", "close", "focus", "zoom", "send-keys", "capture", "list", "open", "tab", "worktree", "browser"]

// MARK: - Socket helpers

private func makeSockaddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let n = min(bytes.count, raw.count - 1)
        for i in 0..<n { raw[i] = bytes[i] }
    }
    return addr
}

private func readLine(_ fd: Int32) -> String {
    var data = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == UInt8(ascii: "\n") { break }
        data.append(byte)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func writeLine(_ fd: Int32, _ s: String) {
    let line = s + "\n"
    line.withCString { ptr in _ = write(fd, ptr, strlen(ptr)) }
}

private func encode(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: d, encoding: .utf8) else { return "{\"ok\":false,\"error\":\"encode\"}" }
    return s
}

// MARK: - Server

// @unchecked Sendable: paneTree is only ever touched on the main thread (via the
// DispatchQueue.main.sync hop below); the queue/listenFD are server-thread only.
final class ControlServer: @unchecked Sendable {
    private let workspace: Workspace
    private let queue = DispatchQueue(label: "halo.control.server")
    private var listenFD: Int32 = -1

    init(workspace: Workspace) { self.workspace = workspace }

    func start() {
        queue.async { [weak self] in self?.run() }
    }

    private func run() {
        let path = controlSocketPath()
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = makeSockaddr(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        listenFD = fd
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { break }
            handle(conn)
            close(conn)
        }
    }

    private func handle(_ conn: Int32) {
        let line = readLine(conn)
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            writeLine(conn, encode(["ok": false, "error": "bad request"]))
            return
        }
        let args = (obj["args"] as? [Any])?.compactMap { "\($0)" } ?? []
        // hop to main (where the NSViews live); return a Sendable String.
        let reply: String = DispatchQueue.main.sync {
            MainActor.assumeIsolated { encode(self.dispatch(cmd, args)) }
        }
        writeLine(conn, reply)
    }

    private func argValue(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor private func leaf(_ args: [String]) -> TerminalPane? {
        let tree = workspace.activeTree
        if let first = args.first, first != "focused", let id = Int(first) {
            tree.focus(id: id)
        }
        return tree.focused
    }

    @MainActor private func dispatch(_ cmd: String, _ args: [String]) -> [String: Any] {
        let cwd = argValue(args, "--cwd")
        let tree = workspace.activeTree
        switch cmd {
        case "split":
            let horizontal = args.contains("-h") || args.contains("--horizontal")
            tree.splitFocused(horizontal ? .horizontal : .vertical, cwd: cwd)
            return ["ok": true]
        case "new-pane":
            tree.newPane(cwd: cwd)
            return ["ok": true]
        case "close":
            tree.closeFocused()
            return ["ok": true]
        case "focus":
            if let first = args.first, let id = Int(first) { tree.focus(id: id) }
            else { tree.focusNext() }
            return ["ok": true]
        case "zoom":
            tree.zoomFocused()
            return ["ok": true]
        case "send-keys":
            guard args.count >= 2, let pane = leaf(args) else {
                return ["ok": false, "error": "no pane"]
            }
            pane.sendKeys(args[1])
            return ["ok": true]
        case "capture":
            guard let pane = leaf(args) else { return ["ok": false, "error": "no pane"] }
            return ["ok": true, "text": pane.capture(scrollback: args.contains("--scrollback"))]
        case "list":
            return ["ok": true, "panes": tree.list(), "tab": workspace.active, "tabs": workspace.tabs.count]
        case "open":
            let path = args.first.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
            workspace.newTab(cwd: path)
            return ["ok": true, "path": path]
        case "tab":
            switch args.first {
            case "new": workspace.newTab(cwd: argValue(args, "--cwd") ?? tree.focusedCwd)
            case "next", .none: workspace.nextTab()
            case "prev": workspace.prevTab()
            case "close": workspace.closeTab()
            default: return ["ok": false, "error": "tab: new|next|prev|close"]
            }
            return ["ok": true, "tab": workspace.active]
        case "worktree":
            guard let branch = args.first else {
                return ["ok": false, "error": "worktree: branch required"]
            }
            let base = argValue(args, "--base")
            workspace.newWorktreeSession(workspace.activeP, branch: branch, base: base)
            return ["ok": true, "branch": branch, "base": base as Any]
        case "browser":
            let urlStr = args.first ?? "about:blank"
            let url = urlStr == "about:blank" ? URL(string: "about:blank")! : BrowserURL.normalize(urlStr)
            tree.openBrowser(url: url)
            return ["ok": true, "url": url.absoluteString]
        default:
            return ["ok": false, "error": "unknown cmd: \(cmd)"]
        }
    }
}

// MARK: - CLI client

func runControlCLI(_ args: [String]) -> Int32 {
    guard let verb = args.first else { return 1 }
    let rest = Array(args.dropFirst())

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { FileHandle.standardError.write(Data("halo: app not running\n".utf8)); return 1 }
    defer { close(fd) }
    var addr = makeSockaddr(controlSocketPath())
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connected == 0 else {
        FileHandle.standardError.write(Data("halo: app not running\n".utf8))
        return 1
    }

    writeLine(fd, encode(["cmd": verb, "args": rest]))
    let line = readLine(fd)
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        FileHandle.standardError.write(Data("halo: bad reply\n".utf8))
        return 1
    }

    let ok = (obj["ok"] as? Bool) ?? false
    if !ok {
        let err = (obj["error"] as? String) ?? "error"
        FileHandle.standardError.write(Data("halo: \(err)\n".utf8))
        return 1
    }

    if verb == "list", let panes = obj["panes"] as? [Any] {
        for p in panes { print(p) }
    } else if verb == "capture", let text = obj["text"] as? String {
        print(text)
    } else if verb == "open", let path = obj["path"] as? String {
        print(path)
    } else {
        print("ok")
    }
    return 0
}

/// `halo help` — discoverable capability list for humans and AI harnesses.
func printUsage() {
    print("""
    halo — native macOS terminal (libghostty) + control CLI

    Usage:
      halo                  launch the GUI app
      halo <verb> [args]    drive the running app over the control socket
      halo help             show this message

    Control verbs:
      split [-h|--horizontal] [--cwd DIR]   split the focused pane (default vertical)
      new-pane [--cwd DIR]                  open a new pane next to the focused one
      close                                 close the focused pane
      focus [ID]                            focus pane ID, or cycle to the next
      zoom                                  toggle zoom on the focused pane
      send-keys <ID|focused> <text>         type text into a pane
      capture [ID|focused] [--scrollback]   print a pane's text
      list                                  list panes/tabs as JSON
      open [PATH]                           open PATH in a new tab (default ~)
      tab new|next|prev|close [--cwd DIR]   manage tabs
      worktree <branch> [--base <ref>]      open a git-worktree-isolated session on <branch>
      browser [url|port]                    open an embedded browser pane (port → http://localhost:PORT)

    Config (in your ghostty config; libghostty ignores the halo- keys):
      halo-projects = ~/a, ~/b      sidebar projects
      halo-accent = #889b94         selection / focus / tab accent
      halo-surface = #161719        window + pane background override
      halo-sidebar-width = 224      sidebar width in px
      halo-font-family = GeistMono  UI text family
      halo-font-mono = MartianMono  instrument-label family
      halo-font-size = 13           base UI font size
      halo-divider-width = 8        split divider grab width
    Colors also sync from your ghostty background/foreground/palette.

    Socket: ~/Library/Application Support/halo/control.sock
    """)
}

func controlSelfCheck() {
    let req: [String: Any] = ["cmd": "split", "args": ["-v"]]
    let data = try! JSONSerialization.data(withJSONObject: req)
    let back = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    assert(back["cmd"] as? String == "split")
    assert((back["args"] as? [Any])?.count == 1)
    assert(controlVerbs.contains("split"))
    print("controlSelfCheck ok")
}
