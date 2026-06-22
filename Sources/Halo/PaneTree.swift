import AppKit

/// NSSplitView with a wide (grabbable) divider that *draws* as a 1px hairline —
/// so it looks like the demo's thin split line but is easy to drag-resize.
final class HaloSplitView: NSSplitView {
    override var dividerThickness: CGFloat { HaloConfig.shared.dividerWidth }
    override var dividerColor: NSColor { .clear }
    override func drawDivider(in rect: NSRect) {
        NSColor(white: 1, alpha: 0.07).setFill()
        if isVertical {
            NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
        } else {
            NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1).fill()
        }
    }
}

/// tmux-like visual splits built from nested NSSplitViews.
/// Each leaf is a `Leaf` (a container holding a TerminalPane + a focus overlay).
/// The tree is implicit in the AppKit view hierarchy of NSSplitViews; we keep a
/// flat ordered `leaves` array for cycling/listing and a `focusedId`.
@MainActor
final class PaneTree {
    /// A leaf container: holds the terminal plus a focus-ring overlay we toggle.
    private final class Leaf: NSView {
        let pane: TerminalPane
        let overlay: FocusOverlay
        init(pane: TerminalPane, accent: NSColor, surface: NSColor) {
            self.pane = pane
            self.overlay = FocusOverlay(accent: accent)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = surface.cgColor
            pane.autoresizingMask = [.width, .height]
            pane.frame = bounds
            addSubview(pane)
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = bounds
            addSubview(overlay)
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    /// Draws four ~9px corner ticks (1.5px) in accent when focused.
    private final class FocusOverlay: NSView {
        let accent: NSColor
        var focused = false { didSet { needsDisplay = true } }
        init(accent: NSColor) {
            self.accent = accent
            super.init(frame: .zero)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil } // never steal clicks
        override func draw(_ dirtyRect: NSRect) {
            // Skip when the pane is too small (mid-split it can be ~0): degenerate
            // corner-tick coords throw "No current point for line" → crash.
            guard focused, bounds.width > 28, bounds.height > 28,
                  bounds.width.isFinite, bounds.height.isFinite else { return }
            // mockup: 9px ticks, 1.5px stroke, inset 5px from each edge,
            // accent at 0.34 alpha (--mint-line).
            let t: CGFloat = 9, w: CGFloat = 1.5, inset: CGFloat = 5
            accent.withAlphaComponent(0.34).setStroke()
            let b = bounds.insetBy(dx: inset, dy: inset)
            let p = NSBezierPath()
            p.lineWidth = w
            // top-left
            p.move(to: NSPoint(x: b.minX, y: b.minY + t)); p.line(to: NSPoint(x: b.minX, y: b.minY)); p.line(to: NSPoint(x: b.minX + t, y: b.minY))
            // top-right
            p.move(to: NSPoint(x: b.maxX - t, y: b.minY)); p.line(to: NSPoint(x: b.maxX, y: b.minY)); p.line(to: NSPoint(x: b.maxX, y: b.minY + t))
            // bottom-left
            p.move(to: NSPoint(x: b.minX, y: b.maxY - t)); p.line(to: NSPoint(x: b.minX, y: b.maxY)); p.line(to: NSPoint(x: b.minX + t, y: b.maxY))
            // bottom-right
            p.move(to: NSPoint(x: b.maxX - t, y: b.maxY)); p.line(to: NSPoint(x: b.maxX, y: b.maxY)); p.line(to: NSPoint(x: b.maxX, y: b.maxY - t))
            p.stroke()
        }
    }

    private var theme: Theme
    private var leaves: [Leaf] = []
    private var focusedId: Int = 0
    private var nextId = 0
    private let root: NSView

    // zoom state
    private var zoomed = false
    private var zoomHidden: [(view: NSView, was: Bool)] = []

    /// Fired whenever focus moves or the focused pane's cwd/title changes.
    var onFocusChange: (() -> Void)?

    init(theme: Theme, cwd: String? = nil) {
        self.theme = theme
        root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.background.cgColor
        let first = makeLeaf(cwd: cwd)
        first.autoresizingMask = [.width, .height]
        first.frame = root.bounds
        root.addSubview(first)
        focusedId = first.pane.id
        installClickFocus()
        restyle()
    }

    // Click a pane to focus it; pass the event through so the terminal still
    // gets it (selection etc). ponytail: app-lifetime monitor, fine.
    private func installClickFocus() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, let win = self.root.window, e.window === win else { return e }
            let pt = self.root.convert(e.locationInWindow, from: nil)
            for l in self.leaves where l.convert(l.bounds, to: self.root).contains(pt) {
                if l.pane.id != self.focusedId { self.focusedId = l.pane.id; self.restyle() }
                break
            }
            return e
        }
    }

    // MARK: Public API

    var rootView: NSView { root }

    var focused: TerminalPane? { leaf(focusedId)?.pane }

    @discardableResult
    func splitFocused(_ s: Split, cwd: String?) -> TerminalPane {
        guard let old = leaf(focusedId) else { return makeAndAttachOrphan(cwd: cwd) }
        if zoomed { unzoom() }

        let newLeaf = makeLeaf(cwd: cwd)

        // An NSSplitView whose divider orientation matches the split.
        let sv = HaloSplitView()
        sv.isVertical = (s == .vertical)          // vertical split = side-by-side
        // frame-based layout: the mask + frame we set below only apply when this
        // is true. (false here is why split panes collapsed to zero size.)
        sv.translatesAutoresizingMaskIntoConstraints = true

        // Replace `old` in its superview with the split view, preserving layout.
        let parent = old.superview
        let oldFrame = old.frame
        let oldMask = old.autoresizingMask
        let idx = parent?.subviews.firstIndex(of: old)

        old.removeFromSuperview()
        old.translatesAutoresizingMaskIntoConstraints = true
        old.autoresizingMask = [.width, .height]
        newLeaf.translatesAutoresizingMaskIntoConstraints = true
        newLeaf.autoresizingMask = [.width, .height]
        sv.addArrangedSubview(old)
        sv.addArrangedSubview(newLeaf)

        sv.autoresizingMask = oldMask
        sv.frame = oldFrame
        if let parent {
            if let idx { parent.subviews.insert(sv, at: idx) } else { parent.addSubview(sv) }
        }
        sv.adjustSubviews()
        // adjustSubviews preserves the old pane's full frame → new pane gets 0.
        // Force a 50/50 split by positioning the divider at the midpoint.
        let extent = sv.isVertical ? oldFrame.width : oldFrame.height
        sv.setPosition((extent - sv.dividerThickness) / 2, ofDividerAt: 0)

        focusedId = newLeaf.pane.id
        restyle()
        return newLeaf.pane
    }

    func closeFocused() {
        guard leaves.count > 1, let target = leaf(focusedId) else { return }
        if zoomed { unzoom() }

        let parentSplit = target.superview as? NSSplitView
        leaves.removeAll { $0 === target }
        target.removeFromSuperview()

        // If the parent split now has a single child, collapse it: replace the
        // split view with that lone child in the grandparent.
        if let sv = parentSplit, sv.subviews.count == 1, let lone = sv.subviews.first {
            let grand = sv.superview
            let svFrame = sv.frame
            let svMask = sv.autoresizingMask
            let idx = grand?.subviews.firstIndex(of: sv)
            lone.removeFromSuperview()
            lone.translatesAutoresizingMaskIntoConstraints = true
            lone.autoresizingMask = svMask
            lone.frame = svFrame
            sv.removeFromSuperview()
            if let grand {
                if let idx { grand.subviews.insert(lone, at: idx) } else { grand.addSubview(lone) }
            }
            (grand as? NSSplitView)?.adjustSubviews()
        }

        focusedId = leaves.first?.pane.id ?? 0
        restyle()
    }

    func focusNext() {
        guard !leaves.isEmpty else { return }
        let i = leaves.firstIndex { $0.pane.id == focusedId } ?? -1
        focusedId = leaves[(i + 1) % leaves.count].pane.id
        restyle()
    }

    func focus(id: Int) {
        guard leaf(id) != nil else { return }
        focusedId = id
        restyle()
    }

    func zoomFocused() {
        if zoomed { unzoom(); return }
        guard let target = leaf(focusedId) else { return }
        // Walk up from the leaf to root, hiding every sibling along the way.
        var node: NSView = target
        while let parent = node.superview, parent !== root.superview, node !== root {
            if parent is NSSplitView {
                for sib in parent.subviews where sib !== node {
                    zoomHidden.append((sib, sib.isHidden))
                    sib.isHidden = true
                }
            }
            if parent === root { break }
            node = parent
        }
        zoomed = true
        relayoutSplits(root)
    }

    func newPane(cwd: String?) {
        splitFocused(.vertical, cwd: cwd)
    }

    func list() -> [[String: Any]] {
        leaves.map { ["id": $0.pane.id, "focused": $0.pane.id == focusedId] }
    }

    // MARK: Internals

    private func unzoom() {
        for (v, was) in zoomHidden { v.isHidden = was }
        zoomHidden.removeAll()
        zoomed = false
        relayoutSplits(root)
    }

    private func relayoutSplits(_ v: NSView) {
        for sub in v.subviews {
            (sub as? NSSplitView)?.adjustSubviews()
            relayoutSplits(sub)
        }
    }

    private func leaf(_ id: Int) -> Leaf? { leaves.first { $0.pane.id == id } }

    private func makeLeaf(cwd: String?) -> Leaf {
        let pane = TerminalPane(id: nextId, theme: theme, cwd: cwd)
        nextId += 1
        pane.onUpdate = { [weak self] in
            guard let self, pane.id == self.focusedId else { return }
            self.onFocusChange?()
        }
        let l = Leaf(pane: pane, accent: theme.accent, surface: theme.background)
        leaves.append(l)
        return l
    }

    /// Fallback when the tree somehow has no focused leaf (shouldn't happen).
    private func makeAndAttachOrphan(cwd: String?) -> TerminalPane {
        let l = makeLeaf(cwd: cwd)
        l.autoresizingMask = [.width, .height]
        l.frame = root.bounds
        root.addSubview(l)
        focusedId = l.pane.id
        restyle()
        return l.pane
    }

    private func restyle() {
        for l in leaves {
            let on = (l.pane.id == focusedId)
            l.overlay.focused = on
            if on { l.pane.window?.makeFirstResponder(l.pane) }
        }
        onFocusChange?()
    }

    /// The focused pane's label + cwd, for the tab/titlebar/footer.
    var focusedLabel: String { focused?.label ?? "shell" }
    var focusedCwd: String? { focused?.cwd }
    /// The focused pane's live program title (from SET_TITLE/OSC 0/2); empty when none set.
    var focusedTitle: String { focused?.title ?? "" }
    /// PID of the foreground process in the focused pane (for port scanning).
    var focusedPID: pid_t? { focused?.foregroundPID }
    /// Number of split panes in this session (for the sidebar's "· N panes").
    var paneCount: Int { leaves.count }
}

@MainActor
func paneTreeSelfCheck() {
    let t = PaneTree(theme: Theme())
    assert(t.list().count == 1, "expected 1 leaf at init")
    assert(t.focused != nil, "expected a focused pane at init")
    t.splitFocused(.vertical, cwd: nil)
    assert(t.list().count == 2, "expected 2 leaves after split")
    let focusedCount = t.list().filter { ($0["focused"] as? Bool) == true }.count
    assert(focusedCount == 1, "exactly one leaf must be focused")
    print("paneTreeSelfCheck OK")
}
