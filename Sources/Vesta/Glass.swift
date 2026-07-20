import AppKit

/// Marker subclass so flattenTitlebar's material-hunter (which hides every
/// NSVisualEffectView it finds) never hides glass WE installed.
final class GlassView: NSVisualEffectView {}

/// Native-glass base for ephemeral chrome (command palette, picker, confirm, toasts):
/// a blur under the content with the theme color applied as a translucent TINT wash
/// instead of the old opaque fill. Working surfaces stay flat — glass marks the
/// transient layer only ("glass moments").
@MainActor
func installGlass(_ panel: NSView, tint: NSColor, alpha: CGFloat = 0.45, corner: CGFloat = 9,
                  blending: NSVisualEffectView.BlendingMode = .behindWindow) {
    // behindWindow, not withinWindow: within-window blur cannot sample the terminal's
    // Metal layer, so AppKit paints a mismatched fallback rectangle behind the panel
    // ("two backgrounds"). Desktop sampling composites correctly over everything.
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor.clear.cgColor

    let wash = NSView()
    wash.translatesAutoresizingMaskIntoConstraints = false
    wash.wantsLayer = true
    wash.layer?.backgroundColor = tint.withAlphaComponent(alpha).cgColor
    wash.layer?.cornerRadius = corner
    panel.addSubview(wash, positioned: .below, relativeTo: nil)

    let fx = GlassView()
    fx.material = .hudWindow
    fx.blendingMode = blending
    fx.state = .active
    fx.wantsLayer = true
    fx.layer?.cornerRadius = corner
    fx.layer?.masksToBounds = true
    fx.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(fx, positioned: .below, relativeTo: wash)

    for v: NSView in [wash, fx] {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: panel.topAnchor),
            v.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
    }
}
