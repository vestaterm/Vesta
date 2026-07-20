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

/// Borderless child window that can still take keyboard focus (Esc / typing in overlays).
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

extension NSWindow {
    /// True while a transient glass overlay (palette/prompt/confirm/notifications) covers
    /// this window as a child OverlayWindow — used to keep pane focus/click handlers from
    /// stealing first-responder out from under it.
    var hasModalOverlay: Bool { childWindows?.contains { $0 is OverlayWindow } == true }
}

/// Hosts one transient glass overlay (palette, prompt, confirm, notifications) in a
/// borderless CHILD window over the main one. Two wins over the old subview hosting:
/// behind-window blur samples the terminal underneath (a subview's blur reaches past
/// the window to the desktop), and no constraint chain can ever resize the main window.
/// Closes itself when the parent resizes/minimizes/closes (popover behavior).
@MainActor
final class ChildOverlay {
    private var window: NSWindow?
    private var obs: [NSObjectProtocol] = []
    var isOpen: Bool { window != nil }

    func present(_ view: NSView, over parent: NSWindow) {
        close()
        let w = OverlayWindow(contentRect: parent.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.contentView = view
        parent.addChildWindow(w, ordered: .above)
        w.makeKeyAndOrderFront(nil)
        window = w
        for name in [NSWindow.didResizeNotification, NSWindow.willMiniaturizeNotification,
                     NSWindow.willCloseNotification] {
            obs.append(NotificationCenter.default.addObserver(
                forName: name, object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                })
        }
    }

    func close() {
        obs.forEach { NotificationCenter.default.removeObserver($0) }
        obs = []
        guard let w = window else { return }
        window = nil
        let parent = w.parent
        parent?.removeChildWindow(w)
        w.orderOut(nil)
        parent?.makeKey()   // hand focus straight back to the terminal
    }
}
