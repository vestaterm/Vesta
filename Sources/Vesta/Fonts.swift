import AppKit
import CoreText

/// The demo's identity is monospace: Martian Mono for tiny instrument labels,
/// Geist Mono for everything else. Bundled + registered at launch.
enum Fonts {
    static func register() {
        guard let dir = fontsDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        // .ttf (Geist/Martian) + .otf (Redaction grades). Registered process-wide,
        // so libghostty can use them too (e.g. `font-family = "Redaction 50"`).
        for u in urls where ["ttf", "otf"].contains(u.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
        }
    }

    /// Locate the bundled Fonts directory WITHOUT `Bundle.module` — its generated accessor
    /// only checks `Bundle.main.bundleURL/Vesta_vesta.bundle` (the app ROOT) and a compile-time
    /// build path, so it `fatalError`s in a distributed .app (resources live in Contents/
    /// Resources) on any machine but the build host. Search the real locations instead.
    static func fontsDirectory() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        // Newer SwiftPM (Xcode 27) builds the resource bundle as a real macOS bundle, so the
        // fonts sit under Vesta_vesta.bundle/Contents/Resources/ instead of at its root.
        let inBundle = ["Vesta_vesta.bundle/Fonts", "Vesta_vesta.bundle/Contents/Resources/Fonts"]
        if let res = Bundle.main.resourceURL {                       // .app: Contents/Resources
            candidates += inBundle.map { res.appendingPathComponent($0) }
            candidates.append(res.appendingPathComponent("Fonts"))
        }
        // `swift run` (no .app): the SPM resource bundle sits next to the executable.
        candidates += inBundle.map { Bundle.main.bundleURL.appendingPathComponent($0) }
        return candidates.first { fm.fileExists(atPath: $0.path) }
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
