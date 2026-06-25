import Foundation
import AppKit
import CLua

// ── Swift⇄Lua bridge state ──────────────────────────────────────────────────
// All access is on the main thread (Lua is created and called only from the main run
// loop), so these globals need no locking. Lua C functions are bare C function pointers
// with no captured state, hence the file-level storage. nonisolated(unsafe) because the
// C callbacks are nonisolated; we uphold main-thread-only by construction.
nonisolated(unsafe) var luaState: OpaquePointer?
nonisolated(unsafe) var luaNotify: (String) -> Void = { FileHandle.standardError.write(Data("[halo.lua] \($0)\n".utf8)) }
nonisolated(unsafe) var luaCommands: [String: Int32] = [:]            // name → registry ref
nonisolated(unsafe) var luaEvents: [String: [Int32]] = [:]           // event → [registry refs]
nonisolated(unsafe) var luaBinds: [(spec: String, ref: Int32)] = []  // "cmd+shift+p" → registry ref
nonisolated(unsafe) var luaActiveInfo: () -> (cwd: String, title: String, paneID: String)? = { nil }
nonisolated(unsafe) var luaSendText: (String) -> Void = { _ in }
nonisolated(unsafe) var luaPluginSpecs: [String] = []                 // declared via halo.plugin(...)
nonisolated(unsafe) var luaControl: (String, [String]) -> [String: Any] = { _, _ in [:] }  // halo.cmd → control dispatch
nonisolated(unsafe) var luaScheduleTimer: (Double, Int32) -> Void = { _, _ in }            // halo.timer
nonisolated(unsafe) var luaClearTimers: () -> Void = {}                                     // reset on reload
nonisolated(unsafe) var luaShowPicker: ([String], Int32) -> Void = { _, _ in }             // halo.pick
nonisolated(unsafe) var luaSetStatus: (String) -> Void = { _ in }                          // halo.status

// Pop the function at stack slot 2 into the registry and return its ref (for on/command/bind).
private func refFunctionArg2(_ L: OpaquePointer?) -> Int32 {
    luaL_checktype(L, 2, halo_lua_tfunction())
    lua_pushvalue(L, 2)
    return luaL_ref(L, halo_lua_registryindex())
}

private func l_halo_notify(_ L: OpaquePointer?) -> Int32 {
    if let c = luaL_checklstring(L, 1, nil) { luaNotify(String(cString: c)) }
    return 0
}
private func l_halo_command(_ L: OpaquePointer?) -> Int32 {
    guard let c = luaL_checklstring(L, 1, nil) else { return 0 }
    luaCommands[String(cString: c)] = refFunctionArg2(L)
    return 0
}
private func l_halo_on(_ L: OpaquePointer?) -> Int32 {
    guard let c = luaL_checklstring(L, 1, nil) else { return 0 }
    luaEvents[String(cString: c), default: []].append(refFunctionArg2(L))
    return 0
}
private func l_halo_bind(_ L: OpaquePointer?) -> Int32 {
    guard let c = luaL_checklstring(L, 1, nil) else { return 0 }
    luaBinds.append((spec: String(cString: c), ref: refFunctionArg2(L)))
    return 0
}
private func l_halo_send(_ L: OpaquePointer?) -> Int32 {
    if let c = luaL_checklstring(L, 1, nil) { luaSendText(String(cString: c)) }
    return 0
}
private func l_halo_status(_ L: OpaquePointer?) -> Int32 {
    luaSetStatus(luaL_checklstring(L, 1, nil).map { String(cString: $0) } ?? "")
    return 0
}
private func l_halo_plugin(_ L: OpaquePointer?) -> Int32 {
    if let c = luaL_checklstring(L, 1, nil) { luaPluginSpecs.append(String(cString: c)) }
    return 0
}

/// Push a Swift value as a Lua value (recursively for arrays/dicts) — used to hand
/// `halo.cmd(...)` results (e.g. capture text, the full state tree) back to Lua.
private func pushLuaValue(_ L: OpaquePointer?, _ v: Any) {
    switch v {
    case let s as String:  s.withCString { _ = lua_pushstring(L, $0) }
    case let b as Bool:    lua_pushboolean(L, b ? 1 : 0)
    case let i as Int:     lua_pushinteger(L, lua_Integer(i))
    case let d as Double:  lua_pushnumber(L, d)
    case let arr as [Any]:
        lua_createtable(L, Int32(arr.count), 0)
        for (i, e) in arr.enumerated() { pushLuaValue(L, e); lua_rawseti(L, -2, lua_Integer(i + 1)) }
    case let dict as [String: Any]:
        lua_createtable(L, 0, Int32(dict.count))
        for (k, val) in dict { pushLuaValue(L, val); lua_setfield(L, -2, k) }
    default: lua_pushnil(L)
    }
}

/// halo.cmd(verb, ...string args) → runs a control verb (same as the CLI) and returns
/// its result as a Lua table. Gives plugins capture/state/split/tab/select/open/zoom/…
private func l_halo_cmd(_ L: OpaquePointer?) -> Int32 {
    guard let c = luaL_checklstring(L, 1, nil) else { return 0 }
    let verb = String(cString: c)
    var args: [String] = []
    let n = lua_gettop(L)
    if n >= 2 { for i in 2...n { if let a = lua_tolstring(L, i, nil) { args.append(String(cString: a)) } } }
    pushLuaValue(L, luaControl(verb, args))
    return 1
}

/// halo.timer(seconds, fn) — call fn every `seconds` (repeating). Cleared on reload.
private func l_halo_timer(_ L: OpaquePointer?) -> Int32 {
    let secs = lua_tonumberx(L, 1, nil)
    luaL_checktype(L, 2, halo_lua_tfunction())
    lua_pushvalue(L, 2)
    let ref = luaL_ref(L, halo_lua_registryindex())
    luaScheduleTimer(secs, ref)
    return 0
}

/// halo.pick(items, fn) — show a filterable picker; fn(chosen) runs on selection. The
/// fn ref is one-shot (freed after choose/cancel via luaUnref).
private func l_halo_pick(_ L: OpaquePointer?) -> Int32 {
    luaL_checktype(L, 1, halo_lua_ttable())
    let len = Int(lua_rawlen(L, 1))
    var items: [String] = []
    if len > 0 {
        for i in 1...len {
            lua_rawgeti(L, 1, lua_Integer(i))
            if let c = lua_tolstring(L, -1, nil) { items.append(String(cString: c)) }
            lua_settop(L, -2)
        }
    }
    luaL_checktype(L, 2, halo_lua_tfunction())
    lua_pushvalue(L, 2)
    let ref = luaL_ref(L, halo_lua_registryindex())
    luaShowPicker(items, ref)
    return 0
}

/// Free a one-shot registry ref (halo.pick callbacks after they fire/cancel).
func luaUnref(_ ref: Int32) {
    if let L = luaState { luaL_unref(L, halo_lua_registryindex(), ref) }
}

/// git-clone a plugin (run off-main). `spec` is "owner/repo" (→ GitHub) or a full URL.
func gitClonePlugin(_ spec: String, to dir: String) -> Bool {
    let url = (spec.hasPrefix("http") || spec.hasPrefix("git@")) ? spec : "https://github.com/\(spec).git"
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["clone", "--depth", "1", url, dir]
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}
private func l_halo_active(_ L: OpaquePointer?) -> Int32 {
    guard let info = luaActiveInfo() else { lua_pushnil(L); return 1 }
    lua_createtable(L, 0, 3)
    info.cwd.withCString    { _ = lua_pushstring(L, $0) }; lua_setfield(L, -2, "cwd")
    info.title.withCString  { _ = lua_pushstring(L, $0) }; lua_setfield(L, -2, "title")
    info.paneID.withCString { _ = lua_pushstring(L, $0) }; lua_setfield(L, -2, "paneID")
    return 1
}

// ── Calling Lua back from Swift (events, commands, binds) ────────────────────
/// Invoke a stored Lua function (registry ref) with an optional string arg. Errors are
/// reported via notify and never propagate. Main thread only.
func luaCall(ref: Int32, stringArg: String? = nil) {
    guard let L = luaState else { return }
    lua_rawgeti(L, halo_lua_registryindex(), lua_Integer(ref))   // push the function
    var nargs: Int32 = 0
    if let s = stringArg { s.withCString { _ = lua_pushstring(L, $0) }; nargs = 1 }
    if lua_pcallk(L, nargs, 0, 0, 0, nil) != 0 {
        let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "error"
        luaNotify("lua: \(err)")
        lua_settop(L, -2)   // pop the error
    }
}
/// Fire every handler registered for `event` via halo.on (with an optional string payload).
func luaFire(_ event: String, _ arg: String? = nil) {
    guard luaState != nil, let refs = luaEvents[event] else { return }
    for r in refs { luaCall(ref: r, stringArg: arg) }
}
/// Run a Lua command registered via halo.command. Returns false if no such command.
@discardableResult
func luaRunCommand(_ name: String) -> Bool {
    guard let r = luaCommands[name] else { return false }
    luaCall(ref: r); return true
}

/// Embedded Lua 5.4 runtime. Runs `~/.config/halo/init.lua` with a `halo` global:
/// `notify`, `command(name, fn)`, `on(event, fn)`, `bind(chord, fn)`, `send(text)`,
/// `active()`. The state is rebuilt on `halo reload`. A bad script reports via notify,
/// never crashes the app.
@MainActor
final class LuaRuntime {
    static let shared = LuaRuntime()
    static var configDir: String { NSHomeDirectory() + "/.config/halo" }
    static var initScriptPath: String { configDir + "/init.lua" }
    static var pluginsDir: String { configDir + "/plugins" }

    func start() {
        if let old = luaState { lua_close(old); luaState = nil }
        // Drop refs/timers from the previous load (reload re-registers everything fresh).
        luaCommands.removeAll(); luaEvents.removeAll(); luaBinds.removeAll(); luaPluginSpecs.removeAll()
        luaClearTimers()
        guard let L = luaL_newstate() else { return }
        luaState = L
        luaL_openlibs(L)
        lua_createtable(L, 0, 10)   // the `halo` table
        func reg(_ name: String, _ fn: lua_CFunction) {
            lua_pushcclosure(L, fn, 0); lua_setfield(L, -2, name)
        }
        reg("notify",  l_halo_notify)
        reg("command", l_halo_command)
        reg("on",      l_halo_on)
        reg("bind",    l_halo_bind)
        reg("send",    l_halo_send)
        reg("active",  l_halo_active)
        reg("plugin",  l_halo_plugin)
        reg("cmd",     l_halo_cmd)
        reg("timer",   l_halo_timer)
        reg("pick",    l_halo_pick)
        reg("status",  l_halo_status)
        lua_setglobal(L, "halo")
        runPrelude()   // convenience wrappers over halo.cmd
        runInit()
        loadPlugins()                // declared (halo.plugin) + drop-in plugins/*/
        luaFire("config-reloaded")   // handlers registered in init.lua/plugins react to (re)load
    }

    /// Load plugins: declared via `halo.plugin("owner/repo")` (cloned to plugins/ if
    /// missing) plus any drop-in `plugins/*/` folder. Each plugin's `init.lua` (or
    /// `plugin/init.lua`) runs with the same `halo` global, so it registers commands /
    /// events / binds like init.lua does.
    private func loadPlugins() {
        let base = Self.pluginsDir
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        var handled = Set<String>()
        for spec in luaPluginSpecs {
            let name = ((spec as NSString).lastPathComponent as NSString)
                .deletingPathExtension   // strip a trailing .git
            let dir = base + "/" + name
            handled.insert(dir)
            if FileManager.default.fileExists(atPath: dir) {
                loadPluginEntry(dir)
            } else {
                luaNotify("installing plugin \(spec)…")
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = gitClonePlugin(spec, to: dir)
                    DispatchQueue.main.async {
                        if ok { self.loadPluginEntry(dir); luaNotify("plugin \(name) installed") }
                        else  { luaNotify("plugin \(spec): clone failed") }
                    }
                }
            }
        }
        // Drop-in: any plugins/*/ folder not already declared.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        for e in entries.sorted() {
            let dir = base + "/" + e
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                  !handled.contains(dir) else { continue }
            loadPluginEntry(dir)
        }
    }

    /// Run a plugin's entry script (`<dir>/init.lua` or `<dir>/plugin/init.lua`).
    private func loadPluginEntry(_ dir: String) {
        guard let L = luaState else { return }
        let entry = [dir + "/init.lua", dir + "/plugin/init.lua"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let entry else { return }
        let loaded = entry.withCString { luaL_loadfilex(L, $0, nil) }
        if loaded != 0 || lua_pcallk(L, 0, 0, 0, 0, nil) != 0 {
            let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "error"
            luaNotify("plugin \((dir as NSString).lastPathComponent): \(err)")
            lua_settop(L, -2)
        }
    }

    /// Names of installed plugin folders (for `halo plugins`).
    func installedPlugins() -> [String] {
        let base = Self.pluginsDir
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return entries.filter { e in
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: base + "/" + e, isDirectory: &d) && d.boolValue
        }.sorted()
    }

    /// `git pull` every installed plugin, then reload so updates take effect.
    @discardableResult
    func syncPlugins() -> [String] {
        let base = Self.pluginsDir
        let names = installedPlugins()
        for n in names {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", base + "/" + n, "pull", "--ff-only", "--quiet"]
            try? p.run(); p.waitUntilExit()
        }
        start()
        return names
    }

    /// Convenience wrappers over halo.cmd, defined in Lua so plugins get ergonomic helpers
    /// (halo.capture/state/split/tab/select/open/zoom/browser/focus) without shelling out.
    private func runPrelude() {
        guard let L = luaState else { return }
        let prelude = """
        function halo.capture(scrollback)
          local r = scrollback and halo.cmd("capture","focused","--scrollback") or halo.cmd("capture","focused")
          return r and r.text or ""
        end
        function halo.state() return halo.cmd("state") end
        function halo.split(h) if h then halo.cmd("split","-h") else halo.cmd("split") end end
        function halo.open(p) halo.cmd("open", p) end
        function halo.tab(a) halo.cmd("tab", a or "new") end
        function halo.select(p,s) halo.cmd("select", tostring(p), tostring(s)) end
        function halo.zoom() halo.cmd("zoom") end
        function halo.browser(u) halo.cmd("browser", u or "about:blank") end
        function halo.focus(id) if id then halo.cmd("focus", tostring(id)) else halo.cmd("focus") end end
        """
        if prelude.withCString({ luaL_loadstring(L, $0) }) != 0 || lua_pcallk(L, 0, 0, 0, 0, nil) != 0 {
            let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "error"
            luaNotify("prelude: \(err)"); lua_settop(L, -2)
        }
    }

    private func runInit() {
        guard let L = luaState else { return }
        let path = Self.initScriptPath
        guard FileManager.default.fileExists(atPath: path) else { return }   // no config → no-op
        let loaded = path.withCString { luaL_loadfilex(L, $0, nil) }
        if loaded != 0 || lua_pcallk(L, 0, 0, 0, 0, nil) != 0 {
            let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "unknown error"
            luaNotify("init.lua: \(err)")
            lua_settop(L, -2)
        }
    }
}
