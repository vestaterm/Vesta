import Foundation
import CLua

// `halo.notify(msg)` bridge target. The Lua state is created and called only on the main
// thread (from the app run loop), so this single global is safe. AppDelegate may override
// it (e.g. to show a real notification); the default logs to stderr so the smoke test is
// visible in `swift run halo`.
nonisolated(unsafe) var luaNotify: (String) -> Void = { msg in
    FileHandle.standardError.write(Data("[halo.lua] \(msg)\n".utf8))
}

/// `halo.notify(message)` — read the string arg and hand it to the Swift side.
/// Lua C functions are bare C function pointers (no captured state), hence the global.
private func lua_halo_notify(_ L: OpaquePointer?) -> Int32 {
    if let c = luaL_checklstring(L, 1, nil) { luaNotify(String(cString: c)) }
    return 0
}

/// Minimal embedded Lua 5.4 runtime. Phase 1 smoke test: it runs
/// `~/.config/halo/init.lua` with a `halo` global table exposing only `halo.notify`.
/// Proves the C embedding + Swift⇄Lua bridge works before the real API (events,
/// commands, keybinds) lands on top. A bad script reports via notify, never crashes.
///
/// NOTE: the Lua C API is heavily macro-based and Swift can't import C macros, so this
/// uses the underlying real functions (lua_createtable not lua_newtable, lua_pcallk not
/// lua_pcall, luaL_loadfilex not luaL_loadfile, lua_settop not lua_pop, …).
@MainActor
final class LuaRuntime {
    static let shared = LuaRuntime()
    private var L: OpaquePointer?

    static var initScriptPath: String { NSHomeDirectory() + "/.config/halo/init.lua" }

    /// (Re)create the state and run init.lua. Called at launch and on `halo reload`.
    func start() {
        if let old = L { lua_close(old); L = nil }
        guard let state = luaL_newstate() else { return }
        L = state
        luaL_openlibs(state)
        // halo = { notify = <cfn> }
        lua_createtable(state, 0, 1)
        let notifyFn: lua_CFunction = lua_halo_notify
        lua_pushcclosure(state, notifyFn, 0)
        lua_setfield(state, -2, "notify")
        lua_setglobal(state, "halo")
        runInit()
    }

    private func runInit() {
        guard let L else { return }
        let path = Self.initScriptPath
        guard FileManager.default.fileExists(atPath: path) else { return }   // no config → no-op
        let loaded = path.withCString { luaL_loadfilex(L, $0, nil) }
        // LUA_OK == 0. Load OR call failure leaves an error string on the stack.
        if loaded != 0 || lua_pcallk(L, 0, 0, 0, 0, nil) != 0 {
            let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "unknown error"
            luaNotify("init.lua: \(err)")
            lua_settop(L, -2)   // pop the error message (lua_pop(L,1))
        }
    }
}
