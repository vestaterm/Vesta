import AppKit

// Shared types every module agrees on. Keep this small.

/// Colors pulled from the user's ghostty config (the "must" sync).
struct Theme {
    var background = NSColor(srgbRed: 0x16/255.0, green: 0x17/255.0, blue: 0x19/255.0, alpha: 1)
    var foreground = NSColor(white: 0.92, alpha: 1)
    var cursor     = NSColor(white: 0.92, alpha: 1)
    var palette: [NSColor] = []   // 16 ANSI colors; empty ⇒ renderer defaults
    // near-gray mint accent: oklch(0.86 0.018 190)
    var accent     = NSColor(srgbRed: 0.83, green: 0.86, blue: 0.85, alpha: 1)
}

enum Split { case horizontal, vertical }   // split orientation of the divider
enum Dir   { case left, right, up, down }   // focus navigation
