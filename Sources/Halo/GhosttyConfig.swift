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

func loadGhosttyConfig() -> (theme: Theme, settings: [String: String]) {
    let env = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    let xdg = env["XDG_CONFIG_HOME"]

    var configCandidates: [String] = []
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
        themeCandidates.append("/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(themeName)")
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

// MARK: - halo-* customization

/// Halo's own config knobs, read from the SAME ghostty config file (keys
/// prefixed `halo-`). libghostty ignores unknown keys, so they pass straight
/// through `settings`. Every value defaults to the current hardcoded look, so
/// an empty config changes nothing.
struct HaloConfig {
    var surface: NSColor?       // nil ⇒ use theme.background (ghostty `background`)
    var accent: NSColor?        // nil ⇒ theme accent
    var sidebarWidth: CGFloat
    var fontFamily: String      // UI/dir/tab/project text (Geist Mono)
    var fontMono: String        // uppercase instrument labels (Martian Mono)
    var fontScale: CGFloat      // multiplier on all chrome font sizes
    var dividerWidth: CGFloat   // split grab/draw thickness

    init(_ s: [String: String]) {
        surface      = s["halo-surface"].flatMap(ghosttyColor)
        accent       = s["halo-accent"].flatMap(ghosttyColor)
        sidebarWidth = s["halo-sidebar-width"].flatMap(Double.init).map { CGFloat($0) } ?? 224
        fontFamily   = s["halo-font-family"] ?? "GeistMono"
        fontMono     = s["halo-font-mono"]   ?? "MartianMono"
        fontScale    = CGFloat((s["halo-font-size"].flatMap(Double.init) ?? 13) / 13)
        dividerWidth = s["halo-divider-width"].flatMap(Double.init).map { CGFloat($0) } ?? 8
    }

    /// Built from the real config once GhosttyApp is up. Safe to read from any UI
    /// code (Fonts/Chrome/PaneTree) — all of it runs after GhosttyApp.shared init.
    @MainActor static let shared = HaloConfig(GhosttyApp.shared.settings)
}

// MARK: - Self-check

func ghosttyConfigSelfCheck() -> String {
    let sample = """
    # sample
    background = #161719
    foreground = ffffff

    palette = 1=#ff0000
    palette = 2=0x00ff00
    halo-opacity = 0.9
    halo-accent = #889b94
    halo-sidebar-width = 260
    """
    let pairs = parseGhosttyConfig(sample)
    let theme = buildTheme(from: pairs)
    assert(theme.background == ghosttyColor("#161719"), "background decode")
    assert(ghosttyColor("0x00ff00") == ghosttyColor("#00ff00"), "0x form decode")
    assert(pairs.contains { $0 == ("palette", "1=#ff0000") }, "palette pair preserved")
    var settings: [String: String] = [:]
    for (k, v) in pairs { settings[k] = v }
    assert(settings["halo-opacity"] == "0.9", "halo-* key passthrough")
    let hc = HaloConfig(settings)
    assert(hc.accent == ghosttyColor("#889b94"), "halo-accent parsed")
    assert(hc.sidebarWidth == 260, "halo-sidebar-width parsed")
    assert(HaloConfig([:]).sidebarWidth == 224, "halo defaults preserved")
    return "ghosttyConfigSelfCheck OK"
}
