import Darwin
import Foundation
import VestaMux

func controlSocketPath() -> String {
    let base = NSHomeDirectory() + "/Library/Application Support/vesta"
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return base + "/control.sock"
}

let controlVerbs: Set<String> = ["split", "new-pane", "close", "focus", "zoom", "send-keys", "capture", "list", "open", "tab", "worktree", "browser", "reload", "search", "kill", "new-window", "state", "sessions", "select", "rename", "project", "notify", "run", "plugins"]

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
    /// Resolves the key window's workspace (multi-window); nil if no window.
    private let workspaceProvider: @MainActor () -> Workspace?
    private let queue = DispatchQueue(label: "vesta.control.server")
    private var listenFD: Int32 = -1
    /// Live config reload (set by AppDelegate; re-themes chrome + surfaces).
    var onReload: (@MainActor () -> Void)?
    /// Open a new window in THIS running instance (so `vesta` with the app open opens a
    /// window instead of launching a second instance). Set by AppDelegate.
    var onNewWindow: (@MainActor () -> Void)?
    /// Full structured dump of every window → project → session → pane (set by
    /// AppDelegate, which alone can see all windows + the shared store).
    var stateProvider: (@MainActor () -> [String: Any])?

    init(workspaceProvider: @escaping @MainActor () -> Workspace?) { self.workspaceProvider = workspaceProvider }

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
        // Owner-only: this socket can inject keystrokes (send-keys) and read
        // scrollback (capture), so no other local user may connect to it.
        chmod(path, 0o600)
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
        guard let workspace = workspaceProvider() else { return nil }
        let tree = workspace.activeTree
        if let first = args.first, first != "focused", let id = Int(first) {
            tree.focus(id: id)
        }
        return tree.focused
    }

    /// Run a verb the same way the CLI does — used by Lua's `vesta.cmd(...)` so plugins
    /// get every control verb (capture/state/split/tab/select/…) natively.
    @MainActor func invoke(_ cmd: String, _ args: [String]) -> [String: Any] { dispatch(cmd, args) }

    @MainActor private func dispatch(_ cmd: String, _ args: [String]) -> [String: Any] {
        // App-level verbs that don't need a current window.
        switch cmd {
        case "state", "sessions":
            return stateProvider?() ?? ["ok": false, "error": "no state"]
        case "notify":
            // notify [--desktop] [--title <t>] <message…>. --desktop forces a banner even when
            // focused; default posts a banner only when backgrounded. Always shows in-app.
            var rest = args, desktop = false, title: String? = nil
            if let i = rest.firstIndex(of: "--desktop") { desktop = true; rest.remove(at: i) }
            if let i = rest.firstIndex(of: "--title") {
                if i + 1 < rest.count { title = rest[i + 1]; rest.removeSubrange(i...(i + 1)) }
                else { rest.remove(at: i) }   // bare trailing --title: drop it, don't leak into the message
            }
            guard !rest.isEmpty else { return ["ok": false, "error": "notify: <message> required"] }
            luaNotifyRich(rest.joined(separator: " "), title, desktop)
            return ["ok": true]
        case "run":
            guard let name = args.first else { return ["ok": false, "error": "run: <command> required"] }
            return luaRunCommand(name) ? ["ok": true, "ran": name]
                                       : ["ok": false, "error": "no Lua command: \(name)"]
        case "plugins":
            switch args.first {
            case "sync":         return ["ok": true, "plugins": LuaRuntime.shared.syncPlugins()]
            case "list", .none:
                var locked: [String: [String: Any]] = [:]
                for (n, e) in LuaRuntime.shared.readLock() {
                    var d: [String: Any] = ["commit": e.commit]
                    if let r = e.ref { d["ref"] = r }
                    if let v = e.version { d["version"] = v }
                    locked[n] = d
                }
                return ["ok": true,
                        "plugins": LuaRuntime.shared.installedPlugins(),
                        "disabled": LuaRuntime.shared.disabledPlugins().sorted(),
                        "locked": locked]
            case "enable", "disable":
                guard let name = args.dropFirst().first else {
                    return ["ok": false, "error": "plugins \(args[0]) <name>"]
                }
                let enabled = args[0] == "enable"
                LuaRuntime.shared.setPluginEnabled(name, enabled)
                onReload?()   // re-run init/plugins (skipping disabled) + reapply config/chrome
                return ["ok": true, "plugin": name, "enabled": enabled]
            default:             return ["ok": false, "error": "plugins: list|sync|enable|disable <name>"]
            }
        case "new-window":
            onNewWindow?()
            return ["ok": true]
        case "kill":
            guard let id = args.first else { return ["ok": false, "error": "kill: <id> required"] }
            MuxClient.kill(paneID: id)
            return ["ok": true, "killed": id]
        default: break
        }
        guard let workspace = workspaceProvider() else { return ["ok": false, "error": "no window"] }
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
            case "new": workspace.newTab(cwd: argValue(args, "--cwd"))   // nil → project's default dir
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
        case "reload":
            onReload?()
            return ["ok": true]
        case "search":
            workspace.activeTree.focused?.search(args.first ?? "")
            return ["ok": true]
        case "select":
            guard args.count >= 2, let p = Int(args[0]), let s = Int(args[1]) else {
                return ["ok": false, "error": "select: <project> <session> (0-based indices)"]
            }
            workspace.selectSession(p, s)
            return ["ok": true, "project": p, "session": s]
        case "rename":
            guard let name = args.first else { return ["ok": false, "error": "rename: <name> required"] }
            workspace.renameSession(workspace.activeP, workspace.activeS, name)
            return ["ok": true, "name": name]
        case "project":
            switch args.first {
            case "new":
                // `project new [PATH] [--name X]` — PATH is the positional after "new"
                // (the CLI injects the caller's cwd when omitted; nil → home).
                let path = (args.count >= 2 && !args[1].hasPrefix("--")) ? args[1] : nil
                workspace.newProject(at: path)
                if let name = argValue(args, "--name") { workspace.renameProject(workspace.activeP, name) }
            case "rename":
                guard args.count >= 2 else { return ["ok": false, "error": "project rename <name>"] }
                workspace.renameProject(workspace.activeP, args[1])
            case "dir":
                // `project dir [PATH]` — change the active project's default dir (PATH or caller's cwd).
                guard args.count >= 2, !args[1].hasPrefix("--") else { return ["ok": false, "error": "project dir <path>"] }
                workspace.setProjectDir(workspace.activeP, args[1])
            case "remove":
                workspace.removeProject(workspace.activeP)
            case "color":
                guard args.count >= 2 else { return ["ok": false, "error": "project color <#hex|none>"] }
                workspace.setProjectColor(workspace.activeP, args[1] == "none" ? nil : ghosttyColor(args[1]))
            default:
                return ["ok": false, "error": "project: new [PATH] [--name X] | dir [PATH] | rename <name> | remove | color <#hex|none>"]
            }
            return ["ok": true, "project": workspace.activeP]
        default:
            return ["ok": false, "error": "unknown cmd: \(cmd)"]
        }
    }
}

// MARK: - CLI client

/// True if a Vesta instance is already listening on the control socket (used so a bare
/// `vesta` opens a window in the running app instead of launching a second instance).
func controlSocketAlive() -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return false }
    defer { close(fd) }
    var addr = makeSockaddr(controlSocketPath())
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
    }
}

func runControlCLI(_ args: [String]) -> Int32 {
    guard let verb = args.first else { return 1 }
    var rest = Array(args.dropFirst())
    // `vesta project new|dir` with no PATH → default to the caller's working directory (resolved
    // here, since the app's cwd differs from the shell's). An explicit path is left untouched.
    if verb == "project", rest.first == "new" || rest.first == "dir",
       !(rest.count >= 2 && !rest[1].hasPrefix("--")) {
        rest.insert(FileManager.default.currentDirectoryPath, at: 1)
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { FileHandle.standardError.write(Data("vesta: app not running\n".utf8)); return 1 }
    defer { close(fd) }
    var addr = makeSockaddr(controlSocketPath())
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connected == 0 else {
        FileHandle.standardError.write(Data("vesta: app not running\n".utf8))
        return 1
    }

    writeLine(fd, encode(["cmd": verb, "args": rest]))
    let line = readLine(fd)
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        FileHandle.standardError.write(Data("vesta: bad reply\n".utf8))
        return 1
    }

    let ok = (obj["ok"] as? Bool) ?? false
    if !ok {
        let err = (obj["error"] as? String) ?? "error"
        FileHandle.standardError.write(Data("vesta: \(err)\n".utf8))
        return 1
    }

    if verb == "list", let panes = obj["panes"] as? [Any] {
        for p in panes { print(p) }
    } else if verb == "plugins", let names = obj["plugins"] as? [String] {
        let off = Set(obj["disabled"] as? [String] ?? [])
        let locked = obj["locked"] as? [String: [String: Any]] ?? [:]
        if let p = obj["plugin"] as? String {        // enable/disable result
            print("\(p): \((obj["enabled"] as? Bool) == true ? "enabled" : "disabled")")
        } else if names.isEmpty {
            print("(no plugins)")
        } else {
            for n in names {
                var parts = [n]
                if let info = locked[n] {
                    if let v = info["version"] as? String { parts.append("v\(v)") }
                    if let r = info["ref"] as? String { parts.append("@\(r)") }
                    if let c = info["commit"] as? String { parts.append("(\(c.prefix(7)))") }
                }
                if off.contains(n) { parts.append("(disabled)") }
                print(parts.joined(separator: "  "))
            }
        }
    } else if verb == "state" {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) { print(s) }
    } else if verb == "sessions", let projects = obj["projects"] as? [[String: Any]] {
        // The key window's active (project,session) — marked with ▸ so `vesta select` is obvious.
        let key = (obj["windows"] as? [[String: Any]])?.first { ($0["key"] as? Bool) == true }
        let ap = key?["activeProject"] as? Int, asn = key?["activeSession"] as? Int
        for p in projects {
            let pi = p["index"] as? Int ?? 0
            let pname = p["name"] as? String ?? "?"
            for s in (p["sessions"] as? [[String: Any]] ?? []) {
                let si = s["index"] as? Int ?? 0
                let name = (s["name"] as? String) ?? (s["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "shell"
                let cwd = s["cwd"] as? String ?? ""
                let mark = (pi == ap && si == asn) ? "▸" : " "
                print("\(mark) \(pi) \(si)\t\(pname) / \(name)\t\(cwd)")
            }
        }
    } else if verb == "capture", let text = obj["text"] as? String {
        print(text)
    } else if verb == "open", let path = obj["path"] as? String {
        print(path)
    } else {
        print("ok")
    }
    return 0
}

/// `vesta help` — discoverable capability list for humans and AI harnesses.
func printUsage() {
    print("""
    vesta — native macOS terminal (libghostty) + control CLI

    Usage:
      vesta                  launch the GUI app
      vesta <verb> [args]    drive the running app over the control socket
      vesta help             show this message

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
      reload                                re-read the config and apply colors/font/theme live
      notify <message>                      show a toast banner in the active window
      run <name>                            run a Lua command registered via vesta.command
      plugins [list|sync]                   list installed Lua plugins (marks disabled), or git-pull + reload them
      plugins enable|disable <name>         turn a plugin on/off and reload
      state                                 dump all windows→projects→sessions→panes as JSON
      sessions                              readable session list with select indices (▸ = active)
      select <project> <session>            switch the active window to a session (0-based)
      rename <name>                         rename the active session
      project new [PATH] [--name X]|dir [PATH]|rename <name>|remove|color <#hex|none>   manage projects (new/dir: PATH or caller's cwd)
      kill <id>                             terminate a session's shell under the daemon

    Config (in your ghostty config; libghostty ignores the vesta- keys):
      vesta-projects = ~/a, ~/b      sidebar projects
      vesta-accent = #889b94         selection / focus / tab accent
      vesta-surface = #161719        window + pane background override
      vesta-sidebar-width = 224      sidebar width in px
      vesta-font-family = GeistMono  UI text family
      vesta-font-mono = MartianMono  instrument-label family
      vesta-font-size = 13           base UI font size
      vesta-divider-width = 8        split divider grab width
    Colors also sync from your ghostty background/foreground/palette.

    Socket: ~/Library/Application Support/vesta/control.sock
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
