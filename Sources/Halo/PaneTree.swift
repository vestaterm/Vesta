import AppKit

/// Protocol satisfied by any view that can live inside a Leaf.
/// `TerminalPane` and `BrowserPane` both conform.
@MainActor protocol PaneContent: NSView {
    func focusContent()
}

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
/// Each leaf is a `Leaf` (a container holding a PaneContent + a focus overlay).
/// The tree is implicit in the AppKit view hierarchy of NSSplitViews; we keep a
/// flat ordered `leaves` array for cycling/listing and a `focusedId`.
@MainActor
final class PaneTree {
    /// A leaf container: holds the content view plus a focus-ring overlay we toggle.
    private final class Leaf: NSView {
        /// Stable id assigned from PaneTree.nextId — independent of content type.
        let id: Int
        let content: PaneContent
        let overlay: FocusOverlay
        init(id: Int, content: PaneContent, accent: NSColor, surface: NSColor) {
            self.id = id
            self.content = content
            self.overlay = FocusOverlay(accent: accent)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = surface.cgColor
            content.autoresizingMask = [.width, .height]
            content.frame = bounds
            addSubview(content)
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = bounds
            addSubview(overlay)
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Re-apply colors on a live config reload (no relaunch).
        func applyTheme(accent: NSColor, surface: NSColor) {
            layer?.backgroundColor = surface.cgColor
            overlay.accent = accent
        }
    }

    /// Draws four ~9px corner ticks (1.5px) in accent when focused.
    private final class FocusOverlay: NSView {
        var accent: NSColor { didSet { needsDisplay = true } }
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
    private var searchTotals: [ObjectIdentifier: Int] = [:]   // per-pane match totals (multiplex sum)
    private var nextId = 0
    private let root: NSView

    // zoom state
    private var zoomed = false
    private var zoomHidden: [(view: NSView, was: Bool)] = []

    /// Fired whenever focus moves or the focused pane's cwd/title changes.
    var onFocusChange: (() -> Void)?
    /// Fired when any pane in this tree rings the bell or fires a desktop notification.
    var onAttention: (() -> Void)?

    /// User-assigned session name (nil ⇒ derive a label from the focused pane).
    /// Persisted in Tabs.swift's per-session snapshot.
    private(set) var name: String?

    /// Set (or clear, when blank) this session's name. Fires onFocusChange so
    /// the sidebar + any open switcher re-render.
    func setName(_ s: String?) {
        let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        onFocusChange?()
    }

    init(theme: Theme, cwd: String? = nil) {
        self.theme = theme
        root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.background.cgColor
        let first = makeTerminalLeaf(cwd: cwd)
        first.autoresizingMask = [.width, .height]
        first.frame = root.bounds
        root.addSubview(first)
        focusedId = first.id
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
                if l.id != self.focusedId { self.focusedId = l.id; self.restyle() }
                break
            }
            return e
        }
    }

    // MARK: Public API

    var rootView: NSView { root }

    /// The focused leaf's content cast to TerminalPane, or nil if it's a browser leaf.
    var focused: TerminalPane? { (leaf(focusedId)?.content) as? TerminalPane }

    // MARK: Split + attach (shared core for terminal and browser splits)

    /// Inserts `newLeaf` next to the currently-focused leaf in an NSSplitView.
    /// Returns the inserted leaf. If no focused leaf exists, falls back to just
    /// appending `newLeaf` to root.
    @discardableResult
    private func splitAndAttach(_ newLeaf: Leaf, split s: Split) -> Leaf {
        guard let old = leaf(focusedId) else {
            newLeaf.autoresizingMask = [.width, .height]
            newLeaf.frame = root.bounds
            root.addSubview(newLeaf)
            focusedId = newLeaf.id
            restyle()
            return newLeaf
        }
        if zoomed { unzoom() }

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

        focusedId = newLeaf.id
        restyle()
        return newLeaf
    }

    @discardableResult
    func splitFocused(_ s: Split, cwd: String?) -> TerminalPane {
        let newLeaf = makeTerminalLeaf(cwd: cwd)
        splitAndAttach(newLeaf, split: s)
        // makeAndAttachOrphan path is handled inside splitAndAttach when leaf(focusedId)==nil
        return newLeaf.content as! TerminalPane
    }

    /// Open a browser pane next to the focused pane (vertical split by default).
    func openBrowser(url: URL) {
        let browser = BrowserPane(url: url, theme: theme)
        let id = nextId; nextId += 1
        let newLeaf = Leaf(id: id, content: browser, accent: theme.accent, surface: theme.background)
        leaves.append(newLeaf)
        splitAndAttach(newLeaf, split: .vertical)
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

        focusedId = leaves.first?.id ?? 0
        restyle()
    }

    func focusNext() {
        guard !leaves.isEmpty else { return }
        let i = leaves.firstIndex { $0.id == focusedId } ?? -1
        focusedId = leaves[(i + 1) % leaves.count].id
        restyle()
    }

    func focusPrev() {
        guard !leaves.isEmpty else { return }
        let i = leaves.firstIndex { $0.id == focusedId } ?? 0
        focusedId = leaves[(i - 1 + leaves.count) % leaves.count].id
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
        leaves.map { ["id": $0.id, "focused": $0.id == focusedId] }
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

    private func leaf(_ id: Int) -> Leaf? { leaves.first { $0.id == id } }

    private func makeTerminalLeaf(cwd: String?) -> Leaf {
        let id = nextId; nextId += 1
        let pane = TerminalPane(id: id, theme: theme, cwd: cwd)
        pane.onUpdate = { [weak self] in
            guard let self, id == self.focusedId else { return }
            self.onFocusChange?()
        }
        pane.onAttention = { [weak self] in self?.onAttention?() }
        // Multiplexed search: a query/clear from any pane's search bar fans out to
        // every terminal pane in this session, so matches highlight across the split.
        pane.broadcastSearch = { [weak self] q in
            self?.searchTotals.removeAll()
            self?.leaves.forEach { ($0.content as? TerminalPane)?.applySearchNeedle(q) }
        }
        pane.broadcastEndSearch = { [weak self] in
            self?.searchTotals.removeAll()
            self?.leaves.forEach { ($0.content as? TerminalPane)?.endSearchHere() }
        }
        // Each pane reports its match total; show the session-wide sum on whichever
        // pane is displaying the search field.
        pane.reportTotal = { [weak self] p, total in
            guard let self else { return }
            self.searchTotals[ObjectIdentifier(p)] = total
            let sum = self.searchTotals.values.reduce(0, +)
            self.leaves.lazy.compactMap { $0.content as? TerminalPane }
                .first { $0.searchVisible }?.showSearchTotal(sum)
        }
        let l = Leaf(id: id, content: pane, accent: theme.accent, surface: theme.background)
        leaves.append(l)
        return l
    }

    private func restyle() {
        let multi = leaves.count > 1
        for l in leaves {
            let on = (l.id == focusedId)
            l.overlay.focused = on && multi   // no focus ticks when there's a single pane
            if on { l.content.focusContent() }
        }
        onFocusChange?()
    }

    /// Re-apply a reloaded theme/config to this session's panes (no relaunch):
    /// chrome colors on the leaves, fresh config to each terminal surface.
    func applyTheme(_ t: Theme) {
        theme = t
        root.layer?.backgroundColor = t.background.cgColor
        for l in leaves {
            l.applyTheme(accent: t.accent, surface: t.background)
            (l.content as? TerminalPane)?.updateConfig(GhosttyApp.shared.config)
        }
        restyle()
    }

    /// Make the focused pane the window's first responder so typing works without
    /// a click (called when this session becomes the active one).
    func focusActivePane() { leaf(focusedId)?.content.focusContent() }

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
    assert(t.name == nil, "new PaneTree has no name")
    t.setName("build")
    assert(t.name == "build", "setName stores the name")
    t.setName("  ")
    assert(t.name == nil, "blank name clears back to nil")
    print("paneTreeSelfCheck OK")
}
