import AppKit
import GhosttyKit

/// The single libghostty app instance for the whole process.
///
/// Owns the `ghostty_app_t` and the loaded `ghostty_config_t` (which IS the
/// native ghostty config sync — colors come from the user's real ghostty
/// config files). Surfaces created by `TerminalPane` bind to this app.
@MainActor
final class GhosttyApp {
    static let shared = GhosttyApp()

    let app: ghostty_app_t
    private(set) var config: ghostty_config_t

    /// Colors derived from the loaded config (background/foreground/cursor/
    /// palette) plus the vesta-* accent.
    private(set) var theme: Theme

    /// vesta-* keys we read ourselves from the config file text. libghostty
    /// doesn't know about these custom keys, so we parse them separately.
    private(set) var settings: [String: String]

    private init() {
        // libghostty resolves `theme = <name>` from $GHOSTTY_RESOURCES_DIR/themes.
        // A terminal launch inherits that env var; a Finder/`open` launch does NOT,
        // so named themes silently fall back to defaults. Point it at our bundled
        // copy (or an installed Ghostty) before init.
        GhosttyApp.ensureResourcesDir()

        // ghostty_init must run exactly once before anything else. It takes
        // argc/argv; we pass our real process arguments.
        _ = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

        // Build the configuration from the user's real ghostty config files
        // (native config sync). A bad config file doesn't fail this — libghostty
        // keeps defaults for unparseable keys — so the only failure is allocation.
        guard let cfg = GhosttyApp.loadConfig() else {
            GhosttyApp.die("Couldn't initialize the terminal configuration.")
        }
        self.config = cfg

        // Derive theme colors from the finalized config, and read vesta-* keys
        // ourselves from the config file text.
        let parsed = loadGhosttyConfig()
        self.settings = parsed.settings
        // vesta-* overrides. Build a LOCAL VestaConfig (not .shared — that reads
        // GhosttyApp.shared.settings, which isn't ready mid-init).
        let hc = VestaConfig(parsed.settings)
        var t = GhosttyApp.makeTheme(config: cfg, accent: hc.accent ?? parsed.theme.accent)
        if let s = hc.surface { t.background = s }   // vesta-surface overrides ghostty background
        self.theme = t

        // The runtime config wires libghostty back into our app. Every callback
        // the header declares must be non-null. Most can be minimal.
        // Pass the callbacks as @convention(c) top-level functions (nonisolated)
        // — NOT closures defined here. A closure created in this @MainActor init
        // inherits main-actor isolation, so ghostty calling it from its renderer
        // thread would trip a dispatch-queue assertion.
        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: vestaWakeupCB,
            action_cb: vestaActionCB,
            read_clipboard_cb: vestaReadClipboardCB,
            confirm_read_clipboard_cb: vestaConfirmReadClipboardCB,
            write_clipboard_cb: vestaWriteClipboardCB,
            close_surface_cb: vestaCloseSurfaceCB
        )

        // No app-level userdata needed: wakeup routes through the singleton, and
        // surface actions resolve via the surface's own userdata.
        guard let app = ghostty_app_new(&runtime, cfg) else {
            GhosttyApp.die("Couldn't start the terminal engine (libghostty).")
        }
        self.app = app

        // Initial focus follows the application's active state.
        ghostty_app_set_focus(app, NSApp.isActive)
    }

    /// Ensure libghostty can find its themes dir even when launched from Finder
    /// (where the shell's GHOSTTY_RESOURCES_DIR isn't inherited). Prefer a copy
    /// bundled inside Vesta.app; fall back to an installed Ghostty.
    private static func ensureResourcesDir() {
        if ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] != nil { return }
        if let dir = ghosttyResourcesDir() { setenv("GHOSTTY_RESOURCES_DIR", dir, 1) }
    }

    /// Show a fatal-error alert (instead of a silent crash) and exit cleanly.
    private static func die(_ message: String) -> Never {
        let a = NSAlert()
        a.messageText = "Vesta can't start"
        a.informativeText = message + "\n\nCheck your config (Vesta ▸ Settings…) and try again."
        a.alertStyle = .critical
        a.runModal()
        exit(1)
    }

    // MARK: - Ticking

    /// Drive libghostty forward. Must run on the main actor.
    func tick() { ghostty_app_tick(app) }

    // MARK: - Live reload

    /// Build a fresh ghostty_config_t from Vesta's config files (the native
    /// config sync: new → load → finalize). Returns nil only if allocation fails.
    private static func loadConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        if FileManager.default.fileExists(atPath: vestaConfigPath()) {
            vestaConfigPath().withCString { ghostty_config_load_file(cfg, $0) }
        } else {
            ghostty_config_load_default_files(cfg)
        }
        // config-in-Lua: ghostty keys set via vesta.set() (e.g. `background`) reach libghostty
        // only through a file. Write them last so Lua wins, then load on top of the user config.
        let ghosttyOverrides = luaConfigOverrides.filter { !$0.key.hasPrefix("vesta-") }
        let path = LuaRuntime.configDir + "/.lua-overrides.conf"
        if ghosttyOverrides.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            let body = ghosttyOverrides.sorted { $0.key < $1.key }
                .map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
            try? body.write(toFile: path, atomically: true, encoding: .utf8)
            path.withCString { ghostty_config_load_file(cfg, $0) }
        }
        ghostty_config_finalize(cfg)
        return cfg
    }

    /// Re-read the config and re-derive the theme WITHOUT relaunching. The app's
    /// config is swapped and pushed to libghostty; callers then push the returned
    /// theme through the chrome and call `TerminalPane.updateConfig` per surface.
    @discardableResult
    func reloadConfig() -> Theme {
        guard let cfg = GhosttyApp.loadConfig() else { return theme }
        let old = config
        config = cfg
        ghostty_app_update_config(app, cfg)

        let parsed = loadGhosttyConfig()
        settings = parsed.settings
        for (k, v) in luaConfigOverrides { settings[k] = v }   // config-in-Lua: Lua wins over the file
        VestaConfig.refresh()   // rebuild the cached vesta-* knobs (fonts/width/etc.)
        let hc = VestaConfig.shared
        var t = GhosttyApp.makeTheme(config: cfg, accent: hc.accent ?? parsed.theme.accent)
        if let s = hc.surface { t.background = s }
        theme = t
        ghostty_config_free(old)
        return t
    }

    // MARK: - Theme

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(c.r) / 255.0,
                       green: CGFloat(c.g) / 255.0,
                       blue: CGFloat(c.b) / 255.0,
                       alpha: 1)
    }

    private static func makeTheme(config: ghostty_config_t, accent: NSColor) -> Theme {
        var theme = Theme()
        if let bg = color(config, "background") { theme.background = bg }
        if let fg = color(config, "foreground") { theme.foreground = fg }
        if let cur = color(config, "cursor-color") { theme.cursor = cur }
        theme.accent = accent

        // The full 256-entry palette; we expose the first 16 ANSI colors.
        var palette = ghostty_config_palette_s()
        let key = "palette"
        if ghostty_config_get(config, &palette, key, UInt(key.utf8.count)) {
            var colors: [NSColor] = []
            withUnsafeBytes(of: palette.colors) { raw in
                let buf = raw.bindMemory(to: ghostty_config_color_s.self)
                for i in 0..<16 {
                    let c = buf[i]
                    colors.append(NSColor(srgbRed: CGFloat(c.r) / 255.0,
                                          green: CGFloat(c.g) / 255.0,
                                          blue: CGFloat(c.b) / 255.0,
                                          alpha: 1))
                }
            }
            theme.palette = colors
        }
        return theme
    }

    // MARK: - Callback helpers

    // MARK: - Callbacks (C ABI, no captures)

    /// Wakeup arrives on ghostty's event-loop thread. Hop to main and tick.
    nonisolated fileprivate static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { GhosttyApp.shared.tick() }
        }
    }

    /// The action callback resolves the surface target to a TerminalPane and
    /// forwards the action to it on the main actor.
    nonisolated fileprivate static func action(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        // This callback can arrive on ghostty's RENDERER thread (during drawFrame),
        // so we must NOT touch @MainActor pane state here. Resolve the surface and
        // copy any C strings synchronously (they may not outlive this call), then
        // update the pane on the main actor.
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let ud = ghostty_surface_userdata(surface)
        else { return false }   // app-level actions intentionally unhandled

        let newTitle: String?
        let newPwd: String?
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            newTitle = action.action.set_title.title.map { String(cString: $0) }; newPwd = nil
        case GHOSTTY_ACTION_PWD:
            newPwd = action.action.pwd.pwd.map { String(cString: $0) }; newTitle = nil
        case GHOSTTY_ACTION_RING_BELL, GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            nonisolated(unsafe) let udSafe2 = ud
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard TerminalPane.isLive(udSafe2) else { return }   // pane may have closed
                    Unmanaged<TerminalPane>.fromOpaque(udSafe2).takeUnretainedValue().fireAttention()
                }
            }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = Int(action.action.search_total.total)
            nonisolated(unsafe) let u = ud
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard TerminalPane.isLive(u) else { return }
                Unmanaged<TerminalPane>.fromOpaque(u).takeUnretainedValue().setSearchTotal(total)
            }}
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let sel = Int(action.action.search_selected.selected)
            nonisolated(unsafe) let u = ud
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard TerminalPane.isLive(u) else { return }
                Unmanaged<TerminalPane>.fromOpaque(u).takeUnretainedValue().setSearchSelected(sel)
            }}
            return true
        default:
            return false
        }

        nonisolated(unsafe) let udSafe = ud   // raw pointer, resolved on main
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard TerminalPane.isLive(udSafe) else { return }   // pane may have closed
                let pane = Unmanaged<TerminalPane>.fromOpaque(udSafe).takeUnretainedValue()
                if let newTitle { pane.setLiveTitle(newTitle) }
                if let newPwd { pane.setLiveCwd(newPwd) }
            }
        }
        return true
    }

    /// Reading the clipboard. The callback doesn't hand us a surface handle and
    /// the Contract's TerminalPane doesn't expose one, so we return false and let
    /// the paste binding pass through to the terminal as text.
    // ponytail: paste handled by the surface's own text path, not OSC-52 read.
    nonisolated fileprivate static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        return false
    }

    /// We don't show a confirmation UI; complete the request unconfirmed.
    // ponytail: no clipboard confirmation dialog; OSC-52 reads just no-op.
    nonisolated fileprivate static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {}

    /// Writing the clipboard: copy the first text/plain entry to the pasteboard.
    nonisolated fileprivate static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let content, len > 0
        else { return }
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime) == "text/plain",
                  let data = item.data
            else { continue }
            let str = String(cString: data)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
            return
        }
    }

    /// The surface's child process exited / requested close. Tell the pane.
    nonisolated fileprivate static func closeSurface(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        nonisolated(unsafe) let ud = userdata
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard TerminalPane.isLive(ud) else { return }   // pane closed (Cmd-W) before this ran
                let pane = Unmanaged<TerminalPane>.fromOpaque(ud).takeUnretainedValue()
                // Shell exited on its own → session-exited. Suppressed when the user
                // intentionally closed it (session-closed already fired) or when a
                // duplicate close_surface arrives for the same pane (shouldFireExit latches).
                if !processAlive, TerminalPane.shouldFireExit(pane.paneID) {
                    luaFire("session-exited", pane.paneID)
                }
                pane.onUpdate?()
            }
        }
    }
}

// MARK: - Top-level C callbacks (nonisolated; NOT closures in @MainActor init)
// ghostty invokes these from its own threads; keeping them at file scope avoids
// inheriting main-actor isolation (which would assert when called off-main).

private func vestaWakeupCB(_ ud: UnsafeMutableRawPointer?) {
    GhosttyApp.wakeup(ud)
}
private func vestaActionCB(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    GhosttyApp.action(app, target: target, action: action)
}
private func vestaReadClipboardCB(_ ud: UnsafeMutableRawPointer?, _ loc: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
    GhosttyApp.readClipboard(ud, location: loc, state: state)
}
private func vestaConfirmReadClipboardCB(_ ud: UnsafeMutableRawPointer?, _ str: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ req: ghostty_clipboard_request_e) {
    GhosttyApp.confirmReadClipboard(ud, string: str, state: state, request: req)
}
private func vestaWriteClipboardCB(_ ud: UnsafeMutableRawPointer?, _ loc: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ len: Int, _ confirm: Bool) {
    GhosttyApp.writeClipboard(ud, location: loc, content: content, len: len, confirm: confirm)
}
private func vestaCloseSurfaceCB(_ ud: UnsafeMutableRawPointer?, _ alive: Bool) {
    GhosttyApp.closeSurface(ud, processAlive: alive)
}
