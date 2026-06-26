import AppKit
import CoreText

/// The demo's identity is monospace: Martian Mono for tiny instrument labels,
/// Geist Mono for everything else. Bundled + registered at launch.
enum Fonts {
    static func register() {
        guard let dir = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        // .ttf (Geist/Martian) + .otf (Redaction grades). Registered process-wide,
        // so libghostty can use them too (e.g. `font-family = "Redaction 50"`).
        for u in urls where ["ttf", "otf"].contains(u.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
        }
    }

    /// Martian Mono — condensed, technical. For uppercase instrument labels.
    /// Family + scale come from `vesta-font-mono` / `vesta-font-size`.
    @MainActor static func inst(_ size: CGFloat) -> NSFont {
        let c = VestaConfig.shared
        let s = size * c.fontScale
        return NSFont(name: "\(c.fontMono)-Regular", size: s)
            ?? .monospacedSystemFont(ofSize: s, weight: .regular)
    }

    /// Geist Mono — clean, readable. For dir/project/tab text.
    /// Family + scale come from `vesta-font-family` / `vesta-font-size`.
    @MainActor static func mono(_ size: CGFloat, medium: Bool = false) -> NSFont {
        let c = VestaConfig.shared
        let s = size * c.fontScale
        return NSFont(name: "\(c.fontFamily)-\(medium ? "Medium" : "Regular")", size: s)
            ?? .monospacedSystemFont(ofSize: s, weight: medium ? .medium : .regular)
    }
}
