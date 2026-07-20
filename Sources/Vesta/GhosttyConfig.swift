import AppKit
import Foundation

// MARK: - Hex → NSColor

func ghosttyColor(_ raw: String) -> NSColor? {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    else if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    let r = CGFloat((v >> 16) & 0xFF) / 255.0
    let g = CGFloat((v >> 8) & 0xFF) / 255.0
    let b = CGFloat(v & 0xFF) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

/// NSColor → "#rrggbb" (sRGB), for persisting custom project colors.
func hexString(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    let to255 = { (v: CGFloat) in Int((v * 255).rounded()) }
    return String(format: "#%02x%02x%02x", to255(c.redComponent), to255(c.greenComponent), to255(c.blueComponent))
}

// MARK: - Parsing

/// Parse ghostty's `key = value` format into ordered pairs (no filesystem).
/// Blank lines and `#` comments ignored. Values may contain `=`.
func parseGhosttyConfig(_ text: String) -> [(String, String)] {
    var out: [(String, String)] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if key.isEmpty { continue }
        out.append((key, val))
    }
    return out
}

// MARK: - Theme builder

private func buildTheme(from pairs: [(String, String)]) -> Theme {
    var theme = Theme(
        background: ghosttyColor("#161719") ?? .black,
        foreground: .white,
        cursor: .white,
        palette: [],
        accent: NSColor(srgbRed: 0.55, green: 0.56, blue: 0.58, alpha: 1)
    )
    var palette: [Int: NSColor] = [:]
    for (k, v) in pairs {
        switch k {
        case "background":
            if let c = ghosttyColor(v) { theme.background = c }
        case "foreground":
            if let c = ghosttyColor(v) { theme.foreground = c }
        case "cursor-color":
            if let c = ghosttyColor(v) { theme.cursor = c }
        case "palette":
            // value form: `N=#rrggbb`
            if let eq = v.firstIndex(of: "="),
               let n = Int(v[..<eq].trimmingCharacters(in: .whitespaces)),
               (0...15).contains(n),
               let c = ghosttyColor(String(v[v.index(after: eq)...])) {
                palette[n] = c
            }
        default:
            break
        }
    }
    if palette.count == 16 {
        theme.palette = (0...15).compactMap { palette[$0] }
    }
    return theme
}

// MARK: - Loading

private func firstExisting(_ paths: [String]) -> String? {
    paths.first { FileManager.default.fileExists(atPath: $0) }
}

private func readFile(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

/// Vesta's own config file (XDG). When present, Vesta loads this instead of
/// ghostty's so you can customize Vesta independently — "Import ghostty config"
/// seeds it. Absent ⇒ Vesta keeps reading your live ghostty config (color sync).
func vestaConfigPath() -> String {
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
        return "\(xdg)/vesta/config"
    }
    return "\(NSHomeDirectory())/.config/vesta/config"
}

/// Update or insert a `key = value` line in Vesta's own config (creating it,
/// seeded from the ghostty config so the user's theme isn't lost on first write).
/// Used by the Settings panel.
func setVestaConfigKey(_ key: String, _ value: String) {
    let path = vestaConfigPath()
    var text = try? String(contentsOfFile: path, encoding: .utf8)
    if text == nil, let src = ghosttyConfigPath() {
        text = try? String(contentsOfFile: src, encoding: .utf8)   // seed from ghostty
    }
    var lines = (text ?? "").components(separatedBy: "\n")
    var replaced = false
    for i in lines.indices {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
        if t[..<eq].trimmingCharacters(in: .whitespaces) == key {
            lines[i] = "\(key) = \(value)"; replaced = true; break
        }
    }
    if !replaced { lines.append("\(key) = \(value)") }
    try? FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

/// Vesta's self-contained ghostty resources dir (themes/, shell-integration/),
/// resolved so named-theme color sync works WITHOUT relying on an installed
/// Ghostty: bundled inside Vesta.app first, then the repo's vendored copy (dev),
/// then $GHOSTTY_RESOURCES_DIR, then an installed Ghostty as a last resort.
func ghosttyResourcesDir() -> String? {
    let fm = FileManager.default
    var candidates: [String] = []
    if let r = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path { candidates.append(r) }
    candidates.append(fm.currentDirectoryPath + "/Resources/ghostty")   // dev: `swift run` from repo root
    if let env = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] { candidates.append(env) }
    candidates.append("/Applications/Ghostty.app/Contents/Resources/ghostty")
    candidates.append("\(NSHomeDirectory())/Applications/Ghostty.app/Contents/Resources/ghostty")
    return candidates.first { fm.fileExists(atPath: $0 + "/themes") }
}

/// The ghostty config Vesta would import from (first existing), or nil.
func ghosttyConfigPath() -> String? {
    let home = NSHomeDirectory()
    var c: [String] = []
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] { c.append("\(xdg)/ghostty/config") }
    c.append("\(home)/.config/ghostty/config")
    c.append("\(home)/Library/Application Support/com.mitchellh.ghostty/config")
    return firstExisting(c)
}

func loadGhosttyConfig() -> (theme: Theme, settings: [String: String]) {
    let env = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    let xdg = env["XDG_CONFIG_HOME"]

    // Vesta's own config wins when present, else fall back to ghostty's.
    var configCandidates: [String] = [vestaConfigPath()]
    if let xdg { configCandidates.append("\(xdg)/ghostty/config") }
    configCandidates.append("\(home)/.config/ghostty/config")
    configCandidates.append("\(home)/Library/Application Support/com.mitchellh.ghostty/config")

    guard let configPath = firstExisting(configCandidates),
          let text = readFile(configPath) else {
        return (Theme(), [:])
    }

    let mainPairs = parseGhosttyConfig(text)

    // Resolve named theme file if present; main config overrides theme values.
    var basePairs: [(String, String)] = []
    if let themeName = mainPairs.last(where: { $0.0 == "theme" })?.1 {
        var themeCandidates: [String] = ["\(home)/.config/ghostty/themes/\(themeName)"]
        if let xdg { themeCandidates.append("\(xdg)/ghostty/themes/\(themeName)") }
        if let res = ghosttyResourcesDir() { themeCandidates.append("\(res)/themes/\(themeName)") }
        if let tp = firstExisting(themeCandidates), let tt = readFile(tp) {
            basePairs = parseGhosttyConfig(tt)
        }
    }

    let allPairs = basePairs + mainPairs
    let theme = buildTheme(from: allPairs)

    var settings: [String: String] = [:]
    for (k, v) in allPairs { settings[k] = v } // last-wins
    return (theme, settings)
}

// MARK: - vesta-* customization

/// Vesta's own config knobs, read from the SAME ghostty config file (keys
/// prefixed `vesta-`). libghostty ignores unknown keys, so they pass straight
/// through `settings`. Every value defaults to the current hardcoded look, so
/// an empty config changes nothing.
struct VestaConfig {
    var surface: NSColor?       // nil ⇒ use theme.background (ghostty `background`)
    var accent: NSColor?        // nil ⇒ theme accent
    var sidebarWidth: CGFloat
    var fontFamily: String      // UI/dir/tab/project text (Geist Mono)
    var fontMono: String        // uppercase instrument labels (Martian Mono)
    var fontScale: CGFloat      // multiplier on all chrome font sizes
    var dividerWidth: CGFloat   // split grab/draw thickness
    var persist: Bool           // vesta-persist: spawn vesta-attach (mux) instead of a bare shell
    var sidebarTails: Bool      // vesta-sidebar-tails: output-tail lines on session cards
    var sidebarPanes: Bool      // vesta-sidebar-panes: split schematic on session cards
    var glassSidebar: Bool      // vesta-glass-sidebar: translucent sidebar (colors become tints).
                                // Terminal translucency is SEPARATE: ghostty's own background-opacity.
    var sidebarOpacity: CGFloat // vesta-sidebar-opacity: sidebar tint alpha in glass mode
    var terminalOpacity: CGFloat // ghostty background-opacity (read here so the chrome can
                                 // un-paint the opaque backing that would block see-through)

    init(_ s: [String: String]) {
        surface      = s["vesta-surface"].flatMap(ghosttyColor)
        accent       = s["vesta-accent"].flatMap(ghosttyColor)
        sidebarWidth = s["vesta-sidebar-width"].flatMap(Double.init).map { CGFloat($0) } ?? 224
        fontFamily   = s["vesta-font-family"] ?? "GeistMono"
        fontMono     = s["vesta-font-mono"]   ?? "MartianMono"
        fontScale    = CGFloat((s["vesta-font-size"].flatMap(Double.init) ?? 13) / 13)
        dividerWidth = s["vesta-divider-width"].flatMap(Double.init).map { CGFloat($0) } ?? 8
        persist      = (s["vesta-persist"].map { $0 != "false" && $0 != "0" }) ?? true   // default ON in M3
        sidebarTails = (s["vesta-sidebar-tails"].map { $0 != "false" && $0 != "0" }) ?? true
        sidebarPanes = (s["vesta-sidebar-panes"].map { $0 == "true" || $0 == "1" }) ?? false
        glassSidebar = (s["vesta-glass-sidebar"].map { $0 == "true" || $0 == "1" }) ?? false
        sidebarOpacity = CGFloat(min(max(s["vesta-sidebar-opacity"].flatMap(Double.init) ?? 0.55, 0), 1))
        terminalOpacity = CGFloat(min(max(s["background-opacity"].flatMap(Double.init) ?? 1, 0), 1))
    }

    /// Any translucency in play → the window itself must be non-opaque.
    var seeThrough: Bool { glassSidebar || terminalOpacity < 1 }

    /// Built from the real config once GhosttyApp is up. Safe to read from any UI
    /// code (Fonts/Chrome/PaneTree) — all of it runs after GhosttyApp.shared init.
    /// `var` so a live reload can rebuild it from the re-read config.
    @MainActor static var shared = VestaConfig(GhosttyApp.shared.settings)

    /// Rebuild from the freshly-reloaded config (called by reload).
    @MainActor static func refresh() { shared = VestaConfig(GhosttyApp.shared.settings) }
}

// MARK: - Self-check

func ghosttyConfigSelfCheck() -> String {
    let sample = """
    # sample
    background = #161719
    foreground = ffffff

    palette = 1=#ff0000
    palette = 2=0x00ff00
    vesta-opacity = 0.9
    vesta-accent = #889b94
    vesta-sidebar-width = 260
    """
    let pairs = parseGhosttyConfig(sample)
    let theme = buildTheme(from: pairs)
    assert(theme.background == ghosttyColor("#161719"), "background decode")
    assert(ghosttyColor("0x00ff00") == ghosttyColor("#00ff00"), "0x form decode")
    assert(pairs.contains { $0 == ("palette", "1=#ff0000") }, "palette pair preserved")
    var settings: [String: String] = [:]
    for (k, v) in pairs { settings[k] = v }
    assert(settings["vesta-opacity"] == "0.9", "vesta-* key passthrough")
    let hc = VestaConfig(settings)
    assert(hc.accent == ghosttyColor("#889b94"), "vesta-accent parsed")
    assert(hc.sidebarWidth == 260, "vesta-sidebar-width parsed")
    assert(VestaConfig([:]).sidebarWidth == 224, "vesta defaults preserved")

    // Malformed / edge lines must be skipped or normalized, never crash.
    let junk = """
    # comment
    bare-word-no-equals
       # indented comment
    = orphaned value
    empty-value =
    spaced key = a = b
    """
    let jp = parseGhosttyConfig(junk)
    assert(jp.count == 2, "only the two well-formed lines survive")
    assert(!jp.contains { $0.0 == "bare-word-no-equals" }, "line without '=' skipped")
    assert(!jp.contains { $0.0.isEmpty }, "empty key skipped")
    assert(jp.contains { $0 == ("empty-value", "") }, "empty value allowed")
    assert(jp.contains { $0 == ("spaced key", "a = b") }, "value keeps embedded '='")
    assert(parseGhosttyConfig("").isEmpty, "empty input → no pairs")
    assert(ghosttyColor("#12345") == nil && ghosttyColor("zzzzzz") == nil, "bad hex → nil")
    return "ghosttyConfigSelfCheck OK"
}
