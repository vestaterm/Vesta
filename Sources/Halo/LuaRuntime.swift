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
/// A declared plugin: repo (owner/repo or URL), an optional pinned ref (tag/commit/branch),
/// and a load priority (higher loads first; ties broken by name).
struct PluginSpec { var repo: String; var ref: String?; var priority: Int = 0 }
nonisolated(unsafe) var luaPluginSpecs: [PluginSpec] = []             // declared via halo.plugin(...)
nonisolated(unsafe) var luaControl: (String, [String]) -> [String: Any] = { _, _ in [:] }  // halo.cmd → control dispatch
nonisolated(unsafe) var luaScheduleTimer: (Double, Int32) -> Void = { _, _ in }            // halo.timer
nonisolated(unsafe) var luaClearTimers: () -> Void = {}                                     // reset on reload
nonisolated(unsafe) var luaShowPicker: ([String], Int32) -> Void = { _, _ in }             // halo.pick
nonisolated(unsafe) var luaSetStatus: (String) -> Void = { _ in }                          // halo.status
nonisolated(unsafe) var luaPanel: ([PanelLine], PanelOpts) -> Int = { _, _ in 0 }           // halo.panel → id
nonisolated(unsafe) var luaClosePanel: (Int) -> Void = { _ in }                            // halo.close
nonisolated(unsafe) var luaClearPanels: () -> Void = {}                                     // reset on reload
nonisolated(unsafe) var luaShowPrompt: (String, String, Int32) -> Void = { _, _, _ in }    // halo.prompt(msg[, default], fn)
nonisolated(unsafe) var luaShowConfirm: (String, Int32) -> Void = { _, _ in }              // halo.confirm
nonisolated(unsafe) var luaConfigOverrides: [String: String] = [:]                         // halo.set (Lua wins)

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
/// halo.set(key, value) — override a config key (Lua wins over the file/UI). Chrome
/// aliases (accent/surface/…) get the `halo-` prefix; any other key is treated as a raw
/// ghostty key (e.g. `background`) and reaches libghostty. Value coerced to a string.
/// Short names that map to Halo's own chrome knobs (everything else is a raw ghostty key).
private let haloConfigAliases: Set<String> = [
    "accent", "surface", "font-family", "sidebar-width", "font-size", "divider-width"]

private func l_halo_set(_ L: OpaquePointer?) -> Int32 {
    guard let kc = luaL_checklstring(L, 1, nil) else { return 0 }
    var key = String(cString: kc)
    if haloConfigAliases.contains(key) { key = "halo-" + key }   // chrome knob; else a ghostty key
    let val: String
    if let vc = lua_tolstring(L, 2, nil) { val = String(cString: vc) }   // string / number
    else { val = lua_toboolean(L, 2) != 0 ? "true" : "false" }            // boolean
    luaConfigOverrides[key] = val
    return 0
}
/// halo.plugin("owner/repo" [, { ref = "v1.2.0", priority = 10 }]) — declare a plugin,
/// optionally pinned to a ref and/or with an explicit load priority.
private func l_halo_plugin(_ L: OpaquePointer?) -> Int32 {
    guard let c = luaL_checklstring(L, 1, nil) else { return 0 }
    var spec = PluginSpec(repo: String(cString: c))
    if lua_type(L, 2) == halo_lua_ttable() {
        lua_getfield(L, 2, "ref")
        spec.ref = lua_tolstring(L, -1, nil).map { String(cString: $0) }
        lua_settop(L, -2)
        lua_getfield(L, 2, "priority"); spec.priority = Int(lua_tointegerx(L, -1, nil)); lua_settop(L, -2)
    }
    luaPluginSpecs.append(spec)
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

/// Read a Lua array (table) of strings at stack `idx`.
private func luaStringArray(_ L: OpaquePointer?, _ idx: Int32) -> [String] {
    luaL_checktype(L, idx, halo_lua_ttable())
    let len = Int(lua_rawlen(L, idx))
    var out: [String] = []
    if len > 0 {
        for i in 1...len {
            lua_rawgeti(L, idx, lua_Integer(i))
            if let c = lua_tolstring(L, -1, nil) { out.append(String(cString: c)) }
            lua_settop(L, -2)
        }
    }
    return out
}

/// Read the panel `lines` array: each element is a string OR a table {text, color, click}.
private func panelLines(_ L: OpaquePointer?, _ idx: Int32) -> [PanelLine] {
    luaL_checktype(L, idx, halo_lua_ttable())
    let len = Int(lua_rawlen(L, idx))
    var out: [PanelLine] = []
    guard len > 0 else { return out }
    for i in 1...len {
        lua_rawgeti(L, idx, lua_Integer(i))                 // push element (-1)
        if lua_isstring(L, -1) != 0 {
            out.append(PanelLine(text: lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? ""))
            lua_settop(L, -2)
        } else {
            var line = PanelLine(text: "")
            lua_getfield(L, -1, "text");  line.text = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? ""; lua_settop(L, -2)
            lua_getfield(L, -1, "color"); line.colorHex = lua_tolstring(L, -1, nil).map { String(cString: $0) }; lua_settop(L, -2)
            lua_getfield(L, -1, "click")
            if lua_type(L, -1) == halo_lua_tfunction() { line.clickRef = luaL_ref(L, halo_lua_registryindex()) }  // pops fn
            else { lua_settop(L, -2) }
            out.append(line)
            lua_settop(L, -2)                               // pop element table
        }
    }
    return out
}

/// halo.panel(lines [, opts]) → id. opts = {title, corner, bg, width, id}. With an existing
/// id it updates that panel in place; otherwise it creates one. The custom-UI workhorse.
private func l_halo_panel(_ L: OpaquePointer?) -> Int32 {
    let lines = panelLines(L, 1)
    var o = PanelOpts()
    if lua_type(L, 2) == halo_lua_ttable() {
        func str(_ k: String) -> String? { lua_getfield(L, 2, k); defer { lua_settop(L, -2) }; return lua_tolstring(L, -1, nil).map { String(cString: $0) } }
        if let t = str("title") { o.title = t }
        if let c = str("corner") { o.corner = c }
        o.bgHex = str("bg")
        o.allWindows = (str("window") == "all")   // "all" → every window; default "active"
        lua_getfield(L, 2, "id");    o.id = Int(lua_tointegerx(L, -1, nil)); lua_settop(L, -2)
        lua_getfield(L, 2, "width"); o.width = lua_tonumberx(L, -1, nil);    lua_settop(L, -2)
    }
    lua_pushinteger(L, lua_Integer(luaPanel(lines, o)))
    return 1
}
/// halo.close(id) — remove a panel created by halo.panel.
private func l_halo_close(_ L: OpaquePointer?) -> Int32 {
    luaClosePanel(Int(luaL_checkinteger(L, 1)))
    return 0
}
/// halo.prompt(message, fn) — ask for a line of text; fn(text) runs on Enter (one-shot).
private func l_halo_prompt(_ L: OpaquePointer?) -> Int32 {
    let msg = luaL_checklstring(L, 1, nil).map { String(cString: $0) } ?? ""
    // halo.prompt(msg, fn) or halo.prompt(msg, default, fn): a string at slot 2 is the default.
    let hasDefault = lua_type(L, 2) != halo_lua_tfunction()
    let def = hasDefault ? (lua_tolstring(L, 2, nil).map { String(cString: $0) } ?? "") : ""
    let fnIdx: Int32 = hasDefault ? 3 : 2
    luaL_checktype(L, fnIdx, halo_lua_tfunction())
    lua_pushvalue(L, fnIdx)
    let ref = luaL_ref(L, halo_lua_registryindex())
    luaShowPrompt(msg, def, ref)
    return 0
}

/// halo.confirm(message, fn): yes/no dialog; calls fn(true) on Yes, fn(false) on No/cancel.
private func l_halo_confirm(_ L: OpaquePointer?) -> Int32 {
    let msg = luaL_checklstring(L, 1, nil).map { String(cString: $0) } ?? ""
    luaL_checktype(L, 2, halo_lua_tfunction())
    lua_pushvalue(L, 2)
    let ref = luaL_ref(L, halo_lua_registryindex())
    luaShowConfirm(msg, ref)
    return 0
}

/// git-clone a plugin (run off-main). `spec` is "owner/repo" (→ GitHub) or a full URL.
/// Run git with args; true on exit 0.
@discardableResult
func runGit(_ args: [String]) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

/// The resolved HEAD commit of a git checkout (nil for a non-git drop-in folder).
func gitHeadCommit(_ dir: String) -> String? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", dir, "rev-parse", "HEAD"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    guard p.terminationStatus == 0 else { return nil }
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

/// Clone a plugin, optionally checking out a pinned ref. Returns the resolved commit, or nil
/// on failure. A pinned ref needs full history (depth-1 can't reach an arbitrary commit/tag).
func gitClonePlugin(_ spec: String, to dir: String, ref: String? = nil) -> String? {
    // owner/repo → GitHub; a full URL (https/git@/file://) or absolute path is used as-is.
    let url = (spec.contains("://") || spec.hasPrefix("git@") || spec.hasPrefix("/")) ? spec : "https://github.com/\(spec).git"
    let ok = ref == nil ? runGit(["clone", "--depth", "1", url, dir]) : runGit(["clone", url, dir])
    guard ok else { return nil }
    if let ref { _ = runGit(["-C", dir, "checkout", "--quiet", ref]) }
    return gitHeadCommit(dir)
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
/// Invoke a registry-ref callback with a single boolean arg (halo.confirm).
func luaCallBool(ref: Int32, _ b: Bool) {
    guard let L = luaState else { return }
    lua_rawgeti(L, halo_lua_registryindex(), lua_Integer(ref))
    lua_pushboolean(L, b ? 1 : 0)
    if lua_pcallk(L, 1, 0, 0, 0, nil) != 0 {
        let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "error"
        luaNotify("lua: \(err)")
        lua_settop(L, -2)
    }
}
/// True if any plugin registered a `pane-output` handler (gates the output tap so it
/// costs nothing when unused).
func luaHasPaneOutputHandler() -> Bool { !(luaEvents["pane-output"]?.isEmpty ?? true) }

/// Fire `pane-output` handlers with (paneID, chunk). The chunk is raw terminal bytes —
/// pushed with lua_pushlstring (byte-safe; lua_pushstring truncates at the first NUL).
/// Main thread only (Lua is single-threaded).
func luaFirePaneOutput(paneID: String, chunk: Data) {
    guard let L = luaState, let refs = luaEvents["pane-output"], !refs.isEmpty, !chunk.isEmpty else { return }
    for ref in refs {
        lua_rawgeti(L, halo_lua_registryindex(), lua_Integer(ref))
        paneID.withCString { _ = lua_pushstring(L, $0) }
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            lua_pushlstring(L, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
        }
        if lua_pcallk(L, 2, 0, 0, 0, nil) != 0 {
            let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "error"
            luaNotify("lua: \(err)")
            lua_settop(L, -2)
        }
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
        luaConfigOverrides.removeAll()
        luaClearTimers(); luaClearPanels()
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
        reg("panel",   l_halo_panel)
        reg("close",   l_halo_close)
        reg("prompt",  l_halo_prompt)
        reg("confirm", l_halo_confirm)
        reg("set",     l_halo_set)
        lua_setglobal(L, "halo")
        runPrelude()   // convenience wrappers over halo.cmd
        runInit()
        loadPlugins()                // declared (halo.plugin) + drop-in plugins/*/
        luaFire("config-reloaded")   // handlers registered in init.lua/plugins react to (re)load
    }

    /// Strip a trailing .git and take the last path component → the plugin's folder name.
    static func pluginName(_ repo: String) -> String {
        ((repo as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Load plugins: declared via `halo.plugin("owner/repo")` (cloned to plugins/ if missing,
    /// pinned to a ref when given) plus any drop-in `plugins/*/` folder. Each plugin's
    /// `init.lua` (or `plugin/init.lua`) runs with the same `halo` global. Loaded in priority
    /// order; the resolved commit/ref/version of each is written to the lockfile.
    private func loadPlugins() {
        let base = Self.pluginsDir
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let disabled = disabledPlugins()
        let declared = Dictionary(luaPluginSpecs.map { (Self.pluginName($0.repo), $0) },
                                  uniquingKeysWith: { a, _ in a })

        // 1. Install any declared-but-missing plugins (async on first run so the UI isn't blocked
        //    by a clone). Pinned ref is checked out; the resolved commit goes in the lockfile.
        for (name, spec) in declared where !disabled.contains(name) {
            let dir = base + "/" + name
            guard !FileManager.default.fileExists(atPath: dir) else { continue }
            let repo = spec.repo, ref = spec.ref
            luaNotify("installing plugin \(name)…")
            DispatchQueue.global(qos: .userInitiated).async {
                let commit = gitClonePlugin(repo, to: dir, ref: ref)
                DispatchQueue.main.async {
                    guard let commit else { luaNotify("plugin \(repo): clone failed"); return }
                    self.loadPluginEntry(dir)
                    var lock = self.readLock()
                    lock[name] = LockEntry(repo: repo, ref: ref, commit: commit, version: self.readManifest(dir).version)
                    self.writeLock(lock)
                    luaNotify("plugin \(name) installed")
                }
            }
        }

        // 2. Load all installed (present, enabled) plugins in a deterministic order:
        //    priority desc (declared opts win over manifest, default 0), then name.
        struct Item { let name: String; let dir: String; let priority: Int; let version: String? }
        var items: [Item] = []
        for e in (try? FileManager.default.contentsOfDirectory(atPath: base))?.sorted() ?? [] {
            let dir = base + "/" + e
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                  !disabled.contains(e) else { continue }
            let m = readManifest(dir)
            let prio = declared[e]?.priority ?? m.priority ?? 0
            items.append(Item(name: e, dir: dir, priority: prio, version: m.version))
        }
        items.sort { $0.priority != $1.priority ? $0.priority > $1.priority : $0.name < $1.name }
        for it in items { loadPluginEntry(it.dir) }

        // 3. Rebuild the lockfile from the installed git checkouts (records the resolved commit
        //    + manifest version per plugin; non-git drop-ins are skipped). Rebuilding — rather
        //    than merging — prunes entries for plugins that have since been removed. Entries for
        //    plugins still cloning (step 1, async) are re-added by their completion handler.
        var lock: [String: LockEntry] = [:]
        for it in items {
            guard let commit = gitHeadCommit(it.dir) else { continue }
            let spec = declared[it.name]
            lock[it.name] = LockEntry(repo: spec?.repo ?? "", ref: spec?.ref, commit: commit, version: it.version)
        }
        writeLock(lock)
    }

    // MARK: - Manifest + lockfile

    static var lockPath: String { configDir + "/plugins.lock" }

    /// One pinned plugin in the lockfile.
    struct LockEntry: Codable { var repo: String; var ref: String?; var commit: String; var version: String? }

    func readLock() -> [String: LockEntry] {
        guard let data = FileManager.default.contents(atPath: Self.lockPath),
              let lock = try? JSONDecoder().decode([String: LockEntry].self, from: data) else { return [:] }
        return lock
    }
    func writeLock(_ lock: [String: LockEntry]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(lock) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.lockPath), options: .atomic)
    }

    /// Read a plugin's optional `manifest.lua` (must `return { version=, priority= }`). It runs in
    /// the shared Lua state; a well-behaved manifest only returns a table. Missing/invalid → nils.
    func readManifest(_ dir: String) -> (version: String?, priority: Int?) {
        guard let L = luaState else { return (nil, nil) }
        let path = dir + "/manifest.lua"
        guard FileManager.default.fileExists(atPath: path) else { return (nil, nil) }
        if path.withCString({ luaL_loadfilex(L, $0, nil) }) != 0 || lua_pcallk(L, 0, 1, 0, 0, nil) != 0 {
            lua_settop(L, -2); return (nil, nil)
        }
        defer { lua_settop(L, -2) }   // pop the returned value
        guard lua_type(L, -1) == halo_lua_ttable() else { return (nil, nil) }
        lua_getfield(L, -1, "version")
        let version = lua_tolstring(L, -1, nil).map { String(cString: $0) }
        lua_settop(L, -2)
        lua_getfield(L, -1, "priority")
        var isInt: Int32 = 0
        let pv = lua_tointegerx(L, -1, &isInt)
        let priority = isInt != 0 ? Int(pv) : nil
        lua_settop(L, -2)
        return (version, priority)
    }

    static var disabledPath: String { configDir + "/disabled-plugins" }

    /// Names of plugins the user has turned off (skipped at load). One name per line.
    func disabledPlugins() -> Set<String> {
        guard let t = try? String(contentsOfFile: Self.disabledPath, encoding: .utf8) else { return [] }
        return Set(t.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Persist a plugin's enabled state. The caller triggers the full reload (config + chrome).
    func setPluginEnabled(_ name: String, _ enabled: Bool) {
        var d = disabledPlugins()
        if enabled { d.remove(name) } else { d.insert(name) }
        try? d.sorted().joined(separator: "\n").write(toFile: Self.disabledPath, atomically: true, encoding: .utf8)
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

    /// Update every installed plugin, then reload. A pinned plugin (ref in the declaration or
    /// lockfile) fetches + checks out that ref (so a moved tag/branch updates); an unpinned one
    /// fast-forwards. `start()` then rewrites the lockfile with the new resolved commits.
    @discardableResult
    func syncPlugins() -> [String] {
        let base = Self.pluginsDir
        let lock = readLock()
        let declared = Dictionary(luaPluginSpecs.map { (Self.pluginName($0.repo), $0) },
                                  uniquingKeysWith: { a, _ in a })
        let names = installedPlugins()
        for n in names {
            let dir = base + "/" + n
            runGit(["-C", dir, "fetch", "--quiet", "--tags"])
            if let ref = declared[n]?.ref ?? lock[n]?.ref {
                runGit(["-C", dir, "checkout", "--quiet", ref])
            } else {
                runGit(["-C", dir, "pull", "--ff-only", "--quiet"])
            }
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
