import Darwin
import Foundation
import VestaMux

func controlSocketPath() -> String {
    let base = NSHomeDirectory() + "/Library/Application Support/vesta"
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return base + "/control.sock"
}

let controlVerbs: Set<String> = ["split", "new-pane", "close", "focus", "zoom", "send-keys", "capture", "list", "open", "tab", "worktree", "browser", "reload", "search", "kill", "new-window", "state", "sessions", "select", "rename", "ws", "group", "project", "notify", "run", "plugins", "pane"]

// MARK: - Socket helpers

/// Read up to a newline; nil if the line exceeds `limit` (don't let a client
/// that never sends \n grow our memory forever). Server requests are tiny; the
/// CLI reads replies with a bigger limit (capture --scrollback can be large).
private func readLine(_ fd: Int32, limit: Int = 1 << 20) -> String? {
    var data = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == UInt8(ascii: "\n") { break }
        if data.count >= limit { return nil }
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
        // Taking the path from a live instance stays unconditional and is usually right: during
        // an update relaunch the incoming build SHOULD own the CLI, and a dev build run beside
        // the installed app is doing it on purpose. What was missing is any record of it — a
        // process that bound here and then exited left the path naming a dead inode, and every
        // `vesta` command failed with "app not running" with nothing anywhere to say why. The
        // next launch reclaims it, but only if you think to try.
        //
        // ponytail: log and take over, no negotiation. Waiting for the incumbent to leave
        // sounds safer and measurably is not — on macOS a queued connection holds a backlog
        // slot until it is accepted, even after the prober closes it, so a poll loop against a
        // momentarily stalled owner fills the 8-slot backlog, reads the resulting ECONNREFUSED
        // as "gone", and evicts it anyway. Nondeterministically, and while making real `vesta`
        // commands fail for as long as the probing lasts.
        if socketIsLive(path) { NSLog("[vesta] control socket taken over from another instance") }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        // The one listen fd in the app that was missing this; vestad/Daemon.swift sets it on
        // its own listener for the same reason. A child that inherits this fd keeps the socket
        // answering connects after this process is gone, so controlSocketAlive() reports an
        // instance that does not exist and `vesta` blocks forever waiting on a reply from it.
        setCloseOnExec(fd)
        var addr = makeSockaddrUn(path)
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
        guard let line = readLine(conn) else {   // overflowed the 1 MiB cap
            writeLine(conn, encode(["ok": false, "error": "line too long"]))
            return   // caller closes the connection
        }
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

    /// The active workspace's group, as an index into `ws.groups` — nil when it's a bare
    /// top-level row. This is the split every `project` verb turns on.
    @MainActor private func activeGroup(_ ws: Workspace) -> Int? {
        guard ws.wss.indices.contains(ws.activeW), let id = ws.wss[ws.activeW].groupID
        else { return nil }
        return ws.groups.firstIndex { $0.id == id }
    }

    /// The name a workspace answers to for `--project` filters: its group's name if it has
    /// one, else its own label (a bare row is its own one-member "project" to old plugins).
    @MainActor private func projectName(_ ws: Workspace, _ i: Int) -> String {
        if let id = ws.wss[i].groupID, let g = ws.groups.first(where: { $0.id == id }) { return g.name }
        return ws.wss[i].tree.name ?? ws.wss[i].tree.focusedLabel
    }

    /// Legacy `<project> <session>` indices → a flat workspace index, resolved through the
    /// top-level sidebar units: a group is one unit and its members are its sessions; a bare
    /// workspace is a unit holding only itself. nil ⇒ out of range.
    @MainActor private func flatIndex(_ ws: Workspace, unit p: Int, member s: Int) -> Int? {
        let units = Workspace.topLevelUnits(groupIDs: ws.wss.map(\.groupID))
        guard units.indices.contains(p), units[p].indices.contains(s) else { return nil }
        return units[p][s]
    }

    /// The inverse: a flat workspace index → the legacy `<project> <session>` pair. Every
    /// reply that used to carry those indices still does, so a plugin echoing them back into
    /// `select` round-trips. (0, 0) when the store is empty — no reply can name a row anyway.
    @MainActor private func unitMember(_ ws: Workspace, _ i: Int) -> (project: Int, session: Int) {
        let units = Workspace.topLevelUnits(groupIDs: ws.wss.map(\.groupID))
        guard let p = units.firstIndex(where: { $0.contains(i) }),
              let s = units[p].firstIndex(of: i) else { return (0, 0) }
        return (p, s)
    }

    /// `sessions --json`: one record per workspace (id, name, group, cwd, pane count,
    /// active/attention flags) sliced from the shared sidebar model. `id` keeps its legacy
    /// `"P.S"` form — the top-level unit and the position inside it — because that string is
    /// what plugins split and feed back to `select`; the flat store index rides alongside it
    /// as the int `workspace`, and `select` takes either. `project` is kept as an alias of
    /// `group` (falling back to the row's own label) so old plugins keep resolving; it also filters.
    @MainActor private func sessionsJSON(project: String?) -> [String: Any] {
        guard let ws = workspaceProvider() else { return ["ok": false, "error": "no window"] }
        var out: [[String: Any]] = []
        let legacyID = Workspace.legacyIDs(groupIDs: ws.wss.map(\.groupID))
        for (i, w) in ws.wss.enumerated() where project == nil || projectName(ws, i) == project {
            let t = w.tree
            var d: [String: Any] = [
                "id": legacyID[i], "workspace": i,
                "name": t.name ?? t.focusedLabel, "project": projectName(ws, i),
                "panes": t.paneCount, "active": i == ws.activeW,   // paneCount works while dormant
                "attention": ws.hasAttention(t),
            ]
            if let id = w.groupID, let g = ws.groups.first(where: { $0.id == id }) { d["group"] = g.name }
            if let c = t.focusedCwd { d["cwd"] = c }
            out.append(d)
        }
        return ["ok": true, "sessions": out]
    }

    /// Run a verb the same way the CLI does — used by Lua's `vesta.cmd(...)` so plugins
    /// get every control verb (capture/state/split/tab/select/…) natively.
    @MainActor func invoke(_ cmd: String, _ args: [String]) -> [String: Any] { dispatch(cmd, args) }

    @MainActor private func dispatch(_ cmd: String, _ args: [String]) -> [String: Any] {
        // App-level verbs that don't need a current window.
        switch cmd {
        case "sessions" where args.contains("--json") || args.contains("--project"):
            // --project implies structured output; the readable path has no filter.
            return sessionsJSON(project: argValue(args, "--project"))
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
            return MuxClient.kill(paneID: id) ? ["ok": true, "killed": id]
                                              : ["ok": false, "error": "kill: daemon unreachable or no ack"]
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
            // Kills the shell, like ⌘W. Dropping the leaf without killing strands the shell:
            // its paneID leaves PaneTree.paneIDs and nothing can reach it again, so an agent
            // scripting `vesta close` in a loop would quietly pile up live shells holding ports.
            tree.killFocusedSession()
            return ["ok": true]
        case "focus":
            if let first = args.first, let id = Int(first) { tree.focus(id: id) }
            else { tree.focusNext() }
            return ["ok": true]
        case "zoom":
            tree.zoomFocused()
            return ["ok": true]
        case "send-keys":
            // Submits the line by default (appends Enter), so a command actually runs;
            // pass --no-enter to send the keystrokes without a trailing Return.
            // Broadcast modes fan the same text out to every pane of a target set:
            //   --all             every pane in the focused workspace
            //   --session <N|P.S> every pane of workspace N (or legacy unit P, member S)
            //   --project <name>  every pane of every workspace in the named group
            var rest = args
            var enter = true
            if let i = rest.firstIndex(of: "--no-enter") { rest.remove(at: i); enter = false }

            // One broadcast mode at a time — otherwise the loser flag would be
            // treated as the <text> and typed into every pane.
            guard ["--all", "--session", "--project"].filter(rest.contains).count <= 1 else {
                return ["ok": false, "error": "send-keys: --all, --session, --project are mutually exclusive"]
            }
            var targets: [PaneTree]? = nil
            if let i = rest.firstIndex(of: "--all") {
                rest.remove(at: i); targets = [tree]
            } else if let i = rest.firstIndex(of: "--session") {
                guard i + 1 < rest.count else { return ["ok": false, "error": "send-keys --session <N>"] }
                let sid = rest[i + 1]; rest.removeSubrange(i...(i + 1))
                // "3" is the flat workspace index; "1.0" is the legacy P.S pair, resolved
                // through the same top-level units `select` uses.
                let ix = sid.split(separator: ".").compactMap { Int($0) }
                let flat: Int? = ix.count == 1 ? ix[0]
                    : (ix.count == 2 ? flatIndex(workspace, unit: ix[0], member: ix[1]) : nil)
                guard let f = flat, workspace.wss.indices.contains(f) else {
                    return ["ok": false, "error": "send-keys --session <N> (select-style index)"]
                }
                targets = [workspace.wss[f].tree]
            } else if let i = rest.firstIndex(of: "--project") {
                guard i + 1 < rest.count else { return ["ok": false, "error": "send-keys --project <name>"] }
                let name = rest[i + 1]; rest.removeSubrange(i...(i + 1))
                let matched = workspace.wss.indices
                    .filter { projectName(workspace, $0) == name }
                    .map { workspace.wss[$0].tree }
                guard !matched.isEmpty else { return ["ok": false, "error": "send-keys --project: no project '\(name)'"] }
                targets = matched
            }

            if let targets {
                guard let text = rest.first else { return ["ok": false, "error": "send-keys: <text> required"] }
                let body = enter && !text.hasSuffix("\n") ? text + "\n" : text
                // A --session/--project broadcast can name a dormant session: materialize it on
                // demand so its live panes exist to receive the keys (it's what the user asked for).
                targets.forEach { $0.materialize() }
                let panes = targets.flatMap { $0.panes }
                for p in panes { p.sendKeys(body) }
                return ["ok": true, "panes": panes.count]
            }

            guard rest.count >= 2, let pane = leaf(rest) else {
                return ["ok": false, "error": "no pane"]
            }
            let text = rest[1]
            pane.sendKeys(enter && !text.hasSuffix("\n") ? text + "\n" : text)
            return ["ok": true, "panes": 1]
        case "capture":
            guard let pane = leaf(args) else { return ["ok": false, "error": "no pane"] }
            return ["ok": true, "text": pane.capture(scrollback: args.contains("--scrollback"))]
        case "pane":
            // pane status <paneID> — per-pane slice of what `state` dumps: cwd, title,
            // alive (a foreground process is running under the pty), plus attention.
            guard args.first == "status", args.count >= 2 else {
                return ["ok": false, "error": "pane status <paneID>"]
            }
            let paneID = args[1]
            for (i, w) in workspace.wss.enumerated() {
                let t = w.tree
                // paneIDs works while dormant (reads the layout); materialize on match so a
                // live TerminalPane exists to report cwd/title/alive.
                guard t.paneIDs.contains(paneID) else { continue }
                t.materialize()
                guard let pane = t.panes.first(where: { $0.paneID == paneID }) else { continue }
                let fg = pane.foregroundPID   // read once: `alive` and `pid` must agree
                var d: [String: Any] = [
                    "ok": true, "paneID": paneID, "workspace": i, "session": "\(i)",
                    "project": projectName(workspace, i),
                    "title": pane.title, "alive": fg != nil,
                    "attention": workspace.hasAttention(t),
                ]
                if let id = w.groupID, let g = workspace.groups.first(where: { $0.id == id }) {
                    d["group"] = g.name
                }
                if let c = pane.cwd { d["cwd"] = c }
                if let fg { d["pid"] = Int(fg) }
                return d
            }
            return ["ok": false, "error": "pane status: no pane \(paneID)"]
        case "list":
            return ["ok": true, "panes": tree.list(), "tab": workspace.active, "tabs": workspace.tabs.count]
        case "open":
            let path = args.first.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
            workspace.newTab(cwd: path)
            return ["ok": true, "path": path]
        case "tab":
            switch args.first {
            case "new": workspace.newTab(cwd: argValue(args, "--cwd"))   // nil → the active workspace's cwd
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
            workspace.newWorktreeWorkspace(from: workspace.activeW, branch: branch, base: base)
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
            // One index = the flat workspace (what `sessions --json` reports as `id`). Two =
            // the legacy <project> <session> pair, resolved through the top-level units.
            let ix = args.compactMap { Int($0) }
            let target: Int?
            switch ix.count {
            case 1: target = ix[0]
            case 2...: target = flatIndex(workspace, unit: ix[0], member: ix[1])
            default:
                return ["ok": false, "error": "select: <workspace> (0-based), or <project> <session>"]
            }
            guard let t = target, workspace.wss.indices.contains(t) else {
                return ["ok": false, "error": "select: no such workspace (\(args.joined(separator: " ")))"]
            }
            workspace.selectWorkspace(t)
            // `workspace` is the new flat truth; project/session are the legacy pair for the
            // same row (what old plugins read back out of this reply).
            let um = unitMember(workspace, t)
            return ["ok": true, "workspace": t, "project": um.project, "session": um.session]
        case "rename":
            guard let name = args.first else { return ["ok": false, "error": "rename: <name> required"] }
            // Blank clears the custom name and falls back to the folder label (sidebar convention).
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            workspace.renameWorkspace(workspace.activeW, trimmed.isEmpty ? nil : trimmed)
            return ["ok": true, "name": name]
        case "ws":
            // The flat model's own verb: always the WORKSPACE (the row), never its group.
            switch args.first {
            case "new":
                // `ws new [PATH] [--name X]` — PATH is the positional after "new" (the CLI
                // injects the caller's cwd when omitted; nil → the active workspace's cwd).
                let path = (args.count >= 2 && !args[1].hasPrefix("--")) ? args[1] : nil
                workspace.newWorkspace(at: path)
                if let name = argValue(args, "--name") { workspace.renameWorkspace(workspace.activeW, name) }
            case "rename":
                guard args.count >= 2 else { return ["ok": false, "error": "ws rename <name>"] }
                // Blank clears the custom name and falls back to the folder label (as `rename` does).
                let trimmed = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
                workspace.renameWorkspace(workspace.activeW, trimmed.isEmpty ? nil : trimmed)
            case "color":
                guard args.count >= 2 else { return ["ok": false, "error": "ws color <#hex|none>"] }
                workspace.setWorkspaceColor(workspace.activeW,
                                            args[1] == "none" ? nil : ghosttyColor(args[1]))
            case "close":
                // No id: the CLI names the row by "whatever is active right now", so there is
                // no earlier moment whose identity we could be checking against.
                workspace.closeWorkspace(workspace.activeW)
            default:
                return ["ok": false, "error": "ws: new [PATH] [--name X] | rename <name> | color <#hex|none> | close"]
            }
            return ["ok": true, "workspace": workspace.activeW]
        case "group":
            // Acts on the active workspace's group. Every verb but `new` needs one to exist.
            let g = activeGroup(workspace)
            switch args.first {
            case "new":
                guard g == nil else { return ["ok": false, "error": "active workspace is already in a group"] }
                workspace.newGroupFromWorkspace(workspace.activeW)
                // The new group is named after the row; an explicit name overrides that.
                if args.count >= 2, let ng = activeGroup(workspace) { workspace.renameGroup(ng, args[1]) }
            case "rename":
                guard let g else { return ["ok": false, "error": "active workspace is not in a group"] }
                guard args.count >= 2 else { return ["ok": false, "error": "group rename <name>"] }
                workspace.renameGroup(g, args[1])   // renameGroup ignores a blank name (a group must be named)
            case "color":
                guard let g else { return ["ok": false, "error": "active workspace is not in a group"] }
                guard args.count >= 2 else { return ["ok": false, "error": "group color <#hex|none>"] }
                workspace.setGroupColor(g, args[1] == "none" ? nil : ghosttyColor(args[1]))
            case "ungroup":
                guard let g else { return ["ok": false, "error": "active workspace is not in a group"] }
                // Name the group in the reply BEFORE it stops existing.
                let name = workspace.groups[g].name
                workspace.ungroup(g)
                return ["ok": true, "group": name, "workspace": workspace.activeW]
            case "remove":
                guard let g else { return ["ok": false, "error": "active workspace is not in a group"] }
                let name = workspace.groups[g].name
                workspace.removeGroup(g)   // closes every member, then drops the group
                return ["ok": true, "group": name, "workspace": workspace.activeW]
            default:
                return ["ok": false, "error": "group: new [name] | rename <name> | color <#hex|none> | ungroup | remove"]
            }
            guard let now = activeGroup(workspace) else {
                return ["ok": false, "error": "active workspace is not in a group"]
            }
            return ["ok": true, "group": workspace.groups[now].name, "workspace": workspace.activeW]
        case "project":
            // Legacy alias of `ws`/`group`: it acts on the active row's GROUP when it has
            // one, else on the workspace itself — which is exactly what a "project" was.
            let g = activeGroup(workspace)
            switch args.first {
            case "new":
                // `project new [PATH] [--name X]` — PATH is the positional after "new"
                // (the CLI injects the caller's cwd when omitted; nil → the active cwd).
                let path = (args.count >= 2 && !args[1].hasPrefix("--")) ? args[1] : nil
                workspace.newWorkspace(at: path)
                if let name = argValue(args, "--name") { workspace.renameWorkspace(workspace.activeW, name) }
            case "rename":
                guard args.count >= 2 else { return ["ok": false, "error": "project rename <name>"] }
                if let g { workspace.renameGroup(g, args[1]) }
                else { workspace.renameWorkspace(workspace.activeW, args[1]) }
            case "dir":
                return ["ok": false,
                        "error": "project dir was removed — each workspace owns its cwd (cd in the shell)"]
            case "remove":
                if let g { workspace.removeGroup(g) } else { workspace.closeWorkspace(workspace.activeW) }
            case "color":
                guard args.count >= 2 else { return ["ok": false, "error": "project color <#hex|none>"] }
                let c = args[1] == "none" ? nil : ghosttyColor(args[1])
                if let g { workspace.setGroupColor(g, c) } else { workspace.setWorkspaceColor(workspace.activeW, c) }
            default:
                return ["ok": false, "error": "project: new [PATH] [--name X] | rename <name> | remove | color <#hex|none>"]
            }
            // Legacy readers keyed off "project" (the old project index) — keep it pointing
            // at the active row's top-level unit, alongside the flat workspace index.
            let um = unitMember(workspace, workspace.activeW)
            return ["ok": true, "workspace": workspace.activeW,
                    "project": um.project, "session": um.session]
        default:
            return ["ok": false, "error": "unknown cmd: \(cmd)"]
        }
    }
}

// MARK: - CLI client

/// True if something is listening on the unix socket at `path`. A leftover socket FILE whose
/// owner is gone reads as false (connect gets ECONNREFUSED), which is what lets a new instance
/// reclaim a stale path — the distinction ControlServer.run depends on.
func socketIsLive(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return false }
    defer { close(fd) }
    var addr = makeSockaddrUn(path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
    }
}

/// True if a Vesta instance is already listening on the control socket (used so a bare
/// `vesta` opens a window in the running app instead of launching a second instance).
func controlSocketAlive() -> Bool { socketIsLive(controlSocketPath()) }

func runControlCLI(_ args: [String]) -> Int32 {
    guard let verb = args.first else { return 1 }
    var rest = Array(args.dropFirst())
    // `vesta ws new` (and its legacy alias `project new`) with no PATH → default to the caller's
    // working directory (resolved here, since the app's cwd differs from the shell's). An
    // explicit path is left untouched.
    if verb == "ws" || verb == "project", rest.first == "new",
       !(rest.count >= 2 && !rest[1].hasPrefix("--")) {
        rest.insert(FileManager.default.currentDirectoryPath, at: 1)
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { FileHandle.standardError.write(Data("vesta: app not running\n".utf8)); return 1 }
    defer { close(fd) }
    var addr = makeSockaddrUn(controlSocketPath())
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connected == 0 else {
        FileHandle.standardError.write(Data("vesta: app not running\n".utf8))
        return 1
    }

    writeLine(fd, encode(["cmd": verb, "args": rest]))
    guard let line = readLine(fd, limit: 64 << 20),   // replies can be big (capture --scrollback)
          let data = line.data(using: .utf8),
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
    } else if verb == "pane" || (verb == "sessions" && obj["sessions"] != nil) {
        // Structured output (pane status / sessions --json): print the reply as pretty JSON.
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) { print(s) }
    } else if verb == "send-keys", let n = obj["panes"] as? Int {
        print("ok (\(n) pane\(n == 1 ? "" : "s"))")
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
      send-keys --all|--session <N>|--project <name> <text>   broadcast (--all = focused workspace's panes)
      capture [ID|focused] [--scrollback]   print a pane's text
      pane status <paneID>                  JSON: cwd, title, alive, attention for one pane
      list                                  list panes/tabs as JSON
      open [PATH]                           open PATH in a new workspace (default ~)
      tab new|next|prev|close [--cwd DIR]   manage workspaces (alias: one workspace = one tab)
      worktree <branch> [--base <ref>]      open a git-worktree-isolated workspace on <branch>
      browser [url|port]                    open an embedded browser pane (port → http://localhost:PORT)
      reload                                re-read the config and apply colors/font/theme live
      notify <message>                      show a toast banner in the active window
      run <name>                            run a Lua command registered via vesta.command
      plugins [list|sync]                   list installed Lua plugins (marks disabled), or git-pull + reload them
      plugins enable|disable <name>         turn a plugin on/off and reload
      state                                 dump workspaces + groups + windows as JSON (plus a `projects` compat view)
      sessions [--json] [--project <name>]  readable workspace list (▸ = active); --json for structured records (--project implies --json)
      select <workspace>                    switch the active window to a workspace (0-based flat index)
      select <project> <session>            legacy form: group P, member S
      rename <name>                         rename the active workspace (blank clears it)
      ws new [PATH] [--name X]              open a new workspace (PATH defaults to the caller's cwd)
      ws rename <name>|color <#hex|none>|close   act on the active workspace (rename: blank clears)
      group new [name]                      wrap the active workspace in a new group (named after it by default)
      group rename <name>|color <#hex|none>|ungroup|remove   act on the active workspace's group
      project …                             legacy alias: `ws` when the row is bare, `group` when it's grouped
      kill <id>                             terminate a workspace's shell under the daemon

    Config (in your ghostty config; libghostty ignores the vesta- keys):
      vesta-projects = ~/a, ~/b      folders seeded as sidebar workspaces
      vesta-accent = #889b94         selection / focus / tab accent
      vesta-surface = #161719        window + pane background override
      vesta-sidebar-width = 224      sidebar width in px
      vesta-font-family = GeistMono  UI text family
      vesta-font-mono = MartianMono  instrument-label family
      vesta-font-size = 13           base UI font size
      vesta-divider-width = 8        split divider grab width
      vesta-sidebar-tails = true     output-tail lines on session cards
      vesta-sidebar-panes = false    split schematic on session cards
      vesta-glass-sidebar = false    translucent sidebar (colors become tints)
      vesta-sidebar-opacity = 0.55   sidebar tint strength in glass mode (0..1)
      background-opacity = 0.85      ghostty key: terminal translucency (separate from sidebar)
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
    assert(controlVerbs.contains("pane"))
    // The flat model's verbs, plus the legacy alias they replaced — argv routing sends a verb to
    // the socket only if it's in this set, so a missing entry makes `vesta ws new` launch a
    // SECOND app instance instead of talking to the running one.
    assert(controlVerbs.contains("ws"))
    assert(controlVerbs.contains("group"))
    assert(controlVerbs.contains("project"))

    // socketIsLive decides whether run() logs a takeover, and controlSocketAlive (the bare-argv
    // bootstrap) is the same call — so the states it must tell apart are pinned against a real
    // socket rather than a mock. This does NOT cover run() itself, which needs a live app.
    let path = NSTemporaryDirectory() + "vesta-selfcheck-\(getpid()).sock"
    unlink(path)
    assert(!socketIsLive(path), "no file at path → not live")
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    assert(fd >= 0, "selfcheck could not open a socket")
    // A listen fd that survives exec keeps answering connects after this process is gone, which
    // is what makes a stale control.sock indistinguishable from a live one. run() sets this on
    // its listener; pin that it takes on the same socket type.
    assert(setCloseOnExec(fd), "setCloseOnExec must succeed on an AF_UNIX socket")
    assert(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0, "FD_CLOEXEC must actually be set")
    var addr = makeSockaddrUn(path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    // listen() must run OUTSIDE the assert — assert is compiled out under -O, so calling it in
    // the condition means the release smoke test binds a socket it never listens on.
    let listening = listen(fd, 1)
    assert(bound == 0 && listening == 0, "selfcheck could not bind \(path)")
    assert(socketIsLive(path), "bound + listening → live, so a second instance must wait")
    // THE CASE THE BUG TURNED ON: the owner is gone but its socket file remains. This must read
    // as not-live, or a crashed instance would leave the CLI unreclaimable forever.
    close(fd)
    assert(FileManager.default.fileExists(atPath: path), "precondition: socket file outlives its owner")
    assert(!socketIsLive(path), "orphaned socket file → not live, so the path is reclaimable")
    unlink(path)
    print("controlSelfCheck ok")
}
