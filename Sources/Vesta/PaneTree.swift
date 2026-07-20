import AppKit

/// Normalize a user-entered session name: trimmed, or nil when blank.
func normalizedSessionName(_ s: String?) -> String? {
    let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty ?? true) ? nil : trimmed
}

/// Protocol satisfied by any view that can live inside a Leaf.
/// `TerminalPane` and `BrowserPane` both conform.
@MainActor protocol PaneContent: NSView {
    func focusContent()
}

/// Terminal backing paint: clear when ghostty's background-opacity is in play, so the
/// translucent surface actually reaches the desktop instead of an opaque twin behind it.
@MainActor
func terminalBacking(_ c: NSColor) -> CGColor {
    VestaConfig.shared.terminalOpacity < 1 ? NSColor.clear.cgColor : c.cgColor
}

/// NSSplitView with a wide (grabbable) divider that *draws* as a 1px hairline —
/// so it looks like the demo's thin split line but is easy to drag-resize.
final class VestaSplitView: NSSplitView {
    /// Gutter paint for see-through terminals (set by PaneTree; tracks the theme). The
    /// divider gutter must not show raw desktop between translucent panes.
    var gutterColor: NSColor = .clear
    override var dividerThickness: CGFloat { VestaConfig.shared.dividerWidth }
    override var dividerColor: NSColor {
        VestaConfig.shared.terminalOpacity < 1
            ? gutterColor.withAlphaComponent(VestaConfig.shared.terminalOpacity) : .clear
    }
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
            layer?.backgroundColor = terminalBacking(surface)
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
            layer?.backgroundColor = terminalBacking(surface)
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

    // Non-nil ⇒ this session is DORMANT: its persisted split layout is kept as data and
    // no ghostty surfaces / vesta-attach processes are built until first activation
    // (materialize()). paneID/name/paneIDs/cwd/paneCount are all derivable from the layout,
    // so a dormant session shows in the sidebar + round-trips through windows.json losslessly
    // without a single live surface. ponytail: only the displayed tree is ever live.
    private var dormantLayout: [String: Any]?

    // zoom state
    private var zoomed = false
    private var zoomHidden: [(view: NSView, was: Bool)] = []

    // Split ratios pending application after the tree is mounted + laid out (restore path).
    private var pendingRatios: [(sv: VestaSplitView, ratio: Double)] = []

    /// Fired whenever focus moves or the focused pane's cwd/title changes.
    var onFocusChange: (() -> Void)?
    /// Fired when any pane in this tree rings the bell or fires a desktop notification.
    var onAttention: (() -> Void)?

    /// User-assigned session name (nil ⇒ derive a label from the focused pane).
    /// Persisted in Tabs.swift's per-session snapshot.
    private(set) var name: String?

    /// Stable per-session id (UUID string). Persisted; M3 reattaches by it.
    let paneID: String

    /// Set (or clear, when blank) this session's name. Fires onFocusChange so
    /// the sidebar + any open switcher re-render.
    func setName(_ s: String?) {
        name = normalizedSessionName(s)
        onFocusChange?()
    }

    init(theme: Theme, cwd: String? = nil, paneID: String = UUID().uuidString, name: String? = nil) {
        self.theme = theme
        self.paneID = paneID
        self.name = normalizedSessionName(name)
        root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = terminalBacking(theme.background)
        let first = makeTerminalLeaf(cwd: cwd, paneID: paneID)
        first.autoresizingMask = [.width, .height]
        first.frame = root.bounds
        root.addSubview(first)
        focusedId = first.id
        installClickFocus()
        restyle()
    }

    /// Rebuild a session from a serialized split layout (windows.json). Keeps the layout as
    /// data (DORMANT) and builds NOTHING — no ghostty surfaces, no daemon attach — until first
    /// activation (materialize()). Used by hydrate for every restored session; the one the
    /// window displays materializes on mount, the rest stay data. The big launch-time win.
    /// Each leaf carries its own persisted paneID for daemon reattach; divider ratios are
    /// best-effort, applied after the tree is mounted (see applyPendingRatios).
    init(theme: Theme, dormant layout: [String: Any], name: String? = nil) {
        self.theme = theme
        self.paneID = PaneTree.firstLeafID(layout) ?? UUID().uuidString
        self.name = normalizedSessionName(name)
        self.dormantLayout = layout
        root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = terminalBacking(theme.background)
        // Leaves + click monitor are built in materialize(), not here.
    }

    /// True while this session is dormant (persisted layout only, no live surfaces).
    var isDormant: Bool { dormantLayout != nil }

    /// Build the live surfaces from the dormant layout on first activation. Idempotent —
    /// a no-op once already live. Mirrors init(theme:layout:).
    func materialize() {
        guard let layout = dormantLayout else { return }
        dormantLayout = nil
        let child = buildNode(layout)
        child.autoresizingMask = [.width, .height]
        child.frame = root.bounds
        root.addSubview(child)
        focusedId = leaves.first?.id ?? 0
        installClickFocus()
        restyle()
        applyPendingRatios()
    }

    /// The first terminal leaf's paneID in a serialized layout (DFS, so it skips a
    /// browser top-left leaf — which has no paneID — and finds the next terminal).
    private static func firstLeafID(_ node: [String: Any]) -> String? {
        if let a = node["a"] as? [String: Any], let b = node["b"] as? [String: Any] {
            return firstLeafID(a) ?? firstLeafID(b)
        }
        return node["paneID"] as? String
    }

    // Click a pane to focus it; pass the event through so the terminal still
    // gets it (selection etc). ponytail: app-lifetime monitor, fine.
    private func installClickFocus() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, let win = self.root.window, e.window === win else { return e }
            // A modal picker/confirm overlay owns its clicks — don't refocus the pane
            // underneath it (that steals first-responder from the picker's field editor).
            if win.contentView?.subviews.contains(where: { $0 is PickerOverlay || $0 is ConfirmOverlay }) == true { return e }
            let pt = self.root.convert(e.locationInWindow, from: nil)
            for l in self.leaves where l.convert(l.bounds, to: self.root).contains(pt) {
                if l.id != self.focusedId { self.focusedId = l.id; self.restyle() }
                break
            }
            return e
        }
    }

    // MARK: Public API

    /// The live view tree. Accessing it means we're about to DISPLAY this session, so
    /// materialize on demand — this is what turns a dormant session live on activation.
    var rootView: NSView { materialize(); return root }

    /// The focused leaf's content cast to TerminalPane, or nil if it's a browser leaf.
    var focused: TerminalPane? { (leaf(focusedId)?.content) as? TerminalPane }

    /// Sidebar tail: last rendered lines of the focused pane's VIEWPORT. Reading the
    /// grid (not the byte stream) is what makes TUI apps work — claude/vim repaint via
    /// cursor moves with no newlines, so a stream tail collapses to one line.
    var tailLines: [String] {
        guard dormantLayout == nil, let f = focused else { return [] }
        return PaneTree.lastLines(f.capture(scrollback: false), max: TailStore.maxLines)
    }

    /// Last ≤max non-empty, non-chrome lines of a viewport, anchored on the latest activity.
    /// A plain shell just yields its last lines. A TUI agent (Claude Code) paints its own chrome
    /// at the viewport bottom — bordered input box, status bars — so we drop those lines, then, if
    /// any surviving line is a ⏺ message/tool marker, drop everything BEFORE the last one (a block
    /// longer than `max` still tails to its bottom `max` lines — the marker itself may scroll off). That
    /// pins the sidebar card to the newest real conversation instead of the empty prompt box.
    nonisolated static func lastLines(_ text: String, max: Int) -> [String] {
        var kept: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || isChrome(t) { continue }
            kept.append(t)
        }
        if let anchor = kept.lastIndex(where: { $0.hasPrefix("⏺") }) {
            kept = Array(kept[anchor...])
        }
        return Array(kept.suffix(max))
    }

    /// ponytail: a cheap heuristic, not a parser — flag a rendered viewport line as TUI "chrome"
    /// (Claude Code's bordered input box + status bars) so the sidebar tail can skip it. Two
    /// signals: the line is mostly box-drawing/block glyphs (U+2500–257F, U+2580–259F), or it
    /// carries a known status fragment. Spinner lines (✳ ✻ ✶) are deliberately NOT chrome —
    /// they're live activity and should show through.
    nonisolated static func isChrome(_ line: String) -> Bool {
        if line.hasPrefix("⏵") { return true }
        if line.contains("ctx [") || line.contains("(shift+tab") || line.contains("? for shortcuts") {
            return true
        }
        let glyphs = line.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !glyphs.isEmpty else { return false }
        let boxy = glyphs.filter { (0x2500...0x257F).contains($0.value) || (0x2580...0x259F).contains($0.value) }
        return boxy.count * 2 >= glyphs.count
    }

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

        let sv = VestaSplitView()
        sv.gutterColor = theme.background
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
        splitAndAttach(makeBrowserLeaf(url: url), split: .vertical)
    }

    private func makeBrowserLeaf(url: URL) -> Leaf {
        let id = nextId; nextId += 1
        let leaf = Leaf(id: id, content: BrowserPane(url: url, theme: theme),
                        accent: theme.accent, surface: theme.background)
        leaves.append(leaf)
        return leaf
    }

    /// Every TerminalPane paneID in this tree (for switcher dedup / pane-output / kill).
    /// Dormant: read from the persisted layout — the daemon panes exist regardless of
    /// whether we've built surfaces for them.
    var paneIDs: [String] {
        if let l = dormantLayout { return PaneTree.layoutPaneIDs(l) }
        return leaves.compactMap { ($0.content as? TerminalPane)?.paneID }
    }

    /// Every live TerminalPane in this tree (browser leaves excluded) — used by
    /// broadcast send-keys and `pane status` to fan out / look up by paneID.
    var panes: [TerminalPane] { leaves.compactMap { $0.content as? TerminalPane } }

    /// Explicit kill (prefix-x / menu): terminate the shell under vestad, then close
    /// the pane locally. Distinct from Cmd-W, which only detaches.
    func killFocusedSession() {
        if let pane = focused { TerminalPane.suppressExit(pane.paneID); MuxClient.kill(paneID: pane.paneID) }
        closeFocused()
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

    // MARK: Split-layout (de)serialization — windows.json topology persistence

    /// Serialize the split topology to a nested dict for windows.json:
    /// a split is {vertical, ratio, a, b}; a terminal leaf is {paneID, cwd?};
    /// a browser leaf is {browser: <url>}.
    func serializeLayout() -> [String: Any] { dormantLayout ?? nodeDict(root.subviews.first) }

    /// Collect every terminal-leaf paneID in a serialized layout (DFS) — a dormant
    /// session's live daemon pane ids without building a single surface. nonisolated: pure.
    nonisolated static func layoutPaneIDs(_ node: [String: Any]) -> [String] {
        if let a = node["a"] as? [String: Any], let b = node["b"] as? [String: Any] {
            return layoutPaneIDs(a) + layoutPaneIDs(b)
        }
        return (node["paneID"] as? String).map { [$0] } ?? []
    }

    /// Count leaves (terminal or browser) in a serialized layout — the sidebar's "· N panes".
    nonisolated static func layoutLeafCount(_ node: [String: Any]) -> Int {
        if let a = node["a"] as? [String: Any], let b = node["b"] as? [String: Any] {
            return layoutLeafCount(a) + layoutLeafCount(b)
        }
        return 1
    }

    /// The top-left leaf's cwd in a serialized layout (DFS) — a dormant session's label + serialize dir.
    nonisolated static func firstLeafCwd(_ node: [String: Any]) -> String? {
        if let a = node["a"] as? [String: Any], let b = node["b"] as? [String: Any] {
            return firstLeafCwd(a) ?? firstLeafCwd(b)
        }
        return node["cwd"] as? String
    }

    private func nodeDict(_ v: NSView?) -> [String: Any] {
        if let sv = v as? VestaSplitView, sv.arrangedSubviews.count == 2 {
            let total = sv.isVertical ? sv.bounds.width : sv.bounds.height
            let first = sv.isVertical ? sv.arrangedSubviews[0].frame.width
                                      : sv.arrangedSubviews[0].frame.height
            let ratio = total > 0 ? min(0.95, max(0.05, Double(first / total))) : 0.5
            return ["vertical": sv.isVertical, "ratio": ratio,
                    "a": nodeDict(sv.arrangedSubviews[0]),
                    "b": nodeDict(sv.arrangedSubviews[1])]
        }
        if let leaf = v as? Leaf {
            if let term = leaf.content as? TerminalPane {
                var d: [String: Any] = ["paneID": term.paneID]
                if let c = term.cwd { d["cwd"] = c }
                return d
            }
            if let br = leaf.content as? BrowserPane, let u = br.webView.url {
                return ["browser": u.absoluteString]
            }
        }
        return [:]   // degenerate node → rebuilt as a fresh terminal leaf
    }

    /// Build a view subtree from a serialized layout node, registering leaves and
    /// recording split ratios to apply once laid out.
    private func buildNode(_ node: [String: Any]) -> NSView {
        if let a = node["a"] as? [String: Any], let b = node["b"] as? [String: Any] {
            let sv = VestaSplitView()
        sv.gutterColor = theme.background
            sv.isVertical = (node["vertical"] as? Bool) ?? false
            sv.translatesAutoresizingMaskIntoConstraints = true
            for child in [buildNode(a), buildNode(b)] {
                child.translatesAutoresizingMaskIntoConstraints = true
                child.autoresizingMask = [.width, .height]
                sv.addArrangedSubview(child)
            }
            pendingRatios.append((sv, (node["ratio"] as? Double) ?? 0.5))
            return sv
        }
        if let urlStr = node["browser"] as? String, let url = URL(string: urlStr) {
            return makeBrowserLeaf(url: url)
        }
        return makeTerminalLeaf(cwd: node["cwd"] as? String,
                                paneID: (node["paneID"] as? String) ?? UUID().uuidString)
    }

    /// Set divider positions from saved ratios. Frames are 0 until the tree is mounted
    /// in a window, so retry on a short schedule; once extents are real the position
    /// sticks. ponytail: best-effort — if never mounted, panes stay evenly split.
    private func applyPendingRatios() {
        guard !pendingRatios.isEmpty else { return }
        let schedule = [0.0, 0.1, 0.3, 0.6]
        for delay in schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                for (sv, ratio) in self.pendingRatios.reversed() {   // outer splits first
                    let extent = sv.isVertical ? sv.bounds.width : sv.bounds.height
                    guard extent > 1 else { continue }
                    sv.setPosition((extent - sv.dividerThickness) * CGFloat(ratio), ofDividerAt: 0)
                }
                if delay == schedule.last { self.pendingRatios.removeAll() }   // done; drop split refs
            }
        }
    }

    private func makeTerminalLeaf(cwd: String?, paneID: String = UUID().uuidString) -> Leaf {
        let id = nextId; nextId += 1
        let pane = TerminalPane(id: id, theme: theme, cwd: cwd, paneID: paneID)
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
        root.layer?.backgroundColor = terminalBacking(t.background)
        guard dormantLayout == nil else { return }   // dormant: theme adopted at materialize()
        for l in leaves {
            l.applyTheme(accent: t.accent, surface: t.background)
            (l.content as? TerminalPane)?.updateConfig(GhosttyApp.shared.config)
        }
        restyle()
    }

    /// Make the focused pane the window's first responder so typing works without
    /// a click (called when this session becomes the active one).
    func focusActivePane() { leaf(focusedId)?.content.focusContent() }

    /// The focused pane's label + cwd, for the tab/titlebar/footer. Dormant sessions derive
    /// a label/cwd from the persisted layout (no live pane to ask).
    var focusedLabel: String {
        if dormantLayout != nil { return (focusedCwd as NSString?)?.lastPathComponent ?? "shell" }
        return focused?.label ?? "shell"
    }
    var focusedCwd: String? {
        if let l = dormantLayout { return PaneTree.firstLeafCwd(l) }
        return focused?.cwd
    }
    /// The focused pane's stable session id (for "mirror here"). nil if a browser leaf is focused.
    var focusedPaneID: String? { focused?.paneID }
    /// The focused pane's live program title (from SET_TITLE/OSC 0/2); empty when none set.
    var focusedTitle: String { focused?.title ?? "" }
    /// PID of the foreground process in the focused pane (for port scanning).
    var focusedPID: pid_t? { focused?.foregroundPID }
    /// Number of split panes in this session (for the sidebar's "· N panes").
    var paneCount: Int { dormantLayout.map { PaneTree.layoutLeafCount($0) } ?? leaves.count }
}

/// Pure checks of the dormant-session layout helpers (no ghostty / NSApp needed): a dormant
/// session derives its pane ids, pane count, and label-cwd entirely from persisted data, and
/// serializeLayout echoes that data back verbatim (lossless windows.json round-trip).
func dormantLayoutSelfCheck() {
    // A vertical split: terminal leaf | (horizontal split of terminal + browser).
    let layout: [String: Any] = [
        "vertical": true, "ratio": 0.5,
        "a": ["paneID": "P1", "cwd": "/work/api"],
        "b": ["vertical": false, "ratio": 0.5,
              "a": ["paneID": "P2", "cwd": "/work/web"],
              "b": ["browser": "https://example.com"]],
    ]
    assert(PaneTree.layoutPaneIDs(layout) == ["P1", "P2"], "collects terminal paneIDs DFS, skips browser")
    assert(PaneTree.layoutLeafCount(layout) == 3, "counts every leaf incl. browser")
    assert(PaneTree.firstLeafCwd(layout) == "/work/api", "first leaf cwd = top-left terminal")
    // Flat single-leaf layout (hydrate's fallback shape) round-trips too.
    let flat: [String: Any] = ["paneID": "P9", "cwd": "/tmp"]
    assert(PaneTree.layoutPaneIDs(flat) == ["P9"], "flat layout paneID")
    assert(PaneTree.layoutLeafCount(flat) == 1, "flat layout is one leaf")
    assert(PaneTree.firstLeafCwd(flat) == "/tmp", "flat layout cwd")
    print("dormantLayoutSelfCheck OK")
}

/// Pure checks of the content-aware tail (PaneTree.lastLines / isChrome): a Claude-Code viewport
/// anchors on its last ⏺ block and drops the input box + status bars; a plain shell is untouched;
/// box-drawing-only rows are dropped; spinner rows are kept as live activity.
func tailFocusSelfCheck() {
    // Claude-like viewport: two ⏺ markers, then a tool result, then the input box + status bars.
    let claude = """
    ⏺ I'll read the file now.
    ⏺ Read(PaneTree.swift)
      ⎿ Read 40 lines
    Done reading the file.
    ╭──────────────────────────╮
    │ >                        │
    ╰──────────────────────────╯
      ⏵⏵ auto mode on (shift+tab to cycle)
    ctx [▓▓▓   ] 52% +118/-11
    ? for shortcuts
    """
    let ct = PaneTree.lastLines(claude, max: 4)
    assert(ct == ["⏺ Read(PaneTree.swift)", "⎿ Read 40 lines", "Done reading the file."],
           "anchors on last ⏺ block, drops input box + status bars: \(ct)")
    assert(!ct.contains { $0.contains("ctx [") || $0.hasPrefix("⏵") || $0.contains("shortcuts") },
           "no chrome survives")

    // Plain shell viewport: no chrome, no ⏺ — last ≤max lines unchanged.
    let shell = "$ ls\nfile1.txt file2.txt\n$ echo hi\nhi"
    assert(PaneTree.lastLines(shell, max: 4) == ["$ ls", "file1.txt file2.txt", "$ echo hi", "hi"],
           "plain shell tail is unchanged")

    // Box-drawing-only rows are dropped, real text kept.
    let boxy = "some text\n──────────────\n│││││││\nmore text"
    assert(PaneTree.lastLines(boxy, max: 4) == ["some text", "more text"], "box-drawing lines dropped")

    // Spinner is live activity, not chrome — it stays.
    let spin = "Working on it.\n✳ Perusing… (4m 6s · ↓ 12.7k tokens)"
    assert(PaneTree.lastLines(spin, max: 4) == ["Working on it.", "✳ Perusing… (4m 6s · ↓ 12.7k tokens)"],
           "spinner line kept")
    assert(!PaneTree.isChrome("✳ Perusing… (4m 6s · ↓ 12.7k tokens)"), "spinner is not chrome")
    print("tailFocusSelfCheck OK")
}

func sessionNameSelfCheck() {
    assert(normalizedSessionName(nil) == nil, "nil name → nil")
    assert(normalizedSessionName("  ") == nil, "blank name → nil")
    assert(normalizedSessionName("build") == "build", "name kept")
    assert(normalizedSessionName("  build  ") == "build", "name trimmed")
    print("sessionNameSelfCheck OK")
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
