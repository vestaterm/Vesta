import AppKit

/// One panel line: text, an optional hex color, and an optional click handler (a Lua
/// registry ref). A plain string line becomes `PanelLine(text:)`.
struct PanelLine {
    var text: String
    var colorHex: String? = nil
    var clickRef: Int32? = nil      // click handler, or (when isInput) the submit handler
    var isInput: Bool = false       // editable field; clickRef fires with the typed text on Enter
    var placeholder: String? = nil
    var svg: String? = nil          // inline SVG markup → rendered as a (vector) image
    var imagePath: String? = nil    // image file path → rendered as an image
    var imageHeight: CGFloat = 0    // optional display height for svg/image lines
    var prefix: String = ""         // leading run drawn in prefixColor (e.g. a graph column)
    var prefixColorHex: String? = nil
}

/// Panel-level options from `vesta.panel(lines, opts)`.
struct PanelOpts {
    var title = ""
    var corner = "topright"
    var id = 0
    var bgHex: String? = nil
    var width: Double = 0
    var height: Double = 0   // >0 → lines scroll inside this fixed content height
    var allWindows = false   // window = "all" → render in every window; else only the active one
}

/// A clickable panel row (a list row with a subtle hover highlight). Takes pre-built
/// attributed text so a row can mix colors — e.g. a colored graph prefix + a white subject.
final class ClickableRow: NSView {
    let onClick: () -> Void
    private let label = NSTextField(labelWithString: "")
    init(attributed: NSAttributedString, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.clear.cgColor
        label.attributedStringValue = attributed
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// An editable panel row: a text field that calls `onSubmit(text)` on Enter and clears.
final class PanelInputRow: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    let onSubmit: (String) -> Void
    init(placeholder: String, theme: Theme, onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = theme.accent.withAlphaComponent(0.4).cgColor
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.textColor = NSColor(white: 0.95, alpha: 1)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            onSubmit(field.stringValue); field.stringValue = ""; return true
        }
        return false
    }
}

/// Top-down document view for a panel's scroll area (default NSView is bottom-up).
private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

/// A faint grid drawn over the host while a panel is being dragged, so the snap targets
/// are visible. Pass-through (never hit-tested).
private final class GridView: NSView {
    let step: CGFloat
    init(step: CGFloat) { self.step = step; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirty: NSRect) {
        NSColor(white: 1, alpha: 0.06).setStroke()
        let p = NSBezierPath(); p.lineWidth = 1
        var x: CGFloat = 0
        while x <= bounds.width { p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x, y: bounds.height)); x += step }
        var y: CGFloat = 0
        while y <= bounds.height { p.move(to: NSPoint(x: 0, y: y)); p.line(to: NSPoint(x: bounds.width, y: y)); y += step }
        p.stroke()
    }
}

/// A non-modal, plugin-controlled floating panel. Drag the title bar to move it (it snaps
/// to a grid and to the four corners); click the title bar to bring it to the front;
/// click the – to edge-minimize it (it hides to the nearest edge leaving a grab tab, click
/// to restore). Position + minimized state persist per title across launches.
final class PanelOverlay: NSView {
    enum Corner: String { case topright, topleft, bottomright, bottomleft }

    private let theme: Theme
    let corner: Corner
    let panelTitle: String
    private let titleLabel = NSTextField(labelWithString: "")
    private let minButton = NSButton()
    private let lineStack = NSStackView()
    private let maxHeight: CGFloat
    private(set) var clickRefs: [Int32] = []

    // free positioning
    private weak var host: NSView?
    private var leadingC: NSLayoutConstraint?
    private var topC: NSLayoutConstraint?
    private let grid: CGFloat = 20
    private let margin: CGFloat = 16
    private let peek: CGFloat = 30   // sliver left visible when edge-minimized

    // corner-anchored placement (stays glued to its corner on resize)
    private var anchor: Corner
    private var dx: CGFloat = 16
    private var dy: CGFloat = 44

    private var minimized = false
    private var dragging = false
    private var edge = "right"                   // which edge it docks to when minimized
    private var dragStart: NSPoint = .zero
    private var dragOrigin: (x: CGFloat, y: CGFloat) = (0, 0)
    private var gridView: GridView?

    /// Top-left origin (so internal top/leading constraints + the title-bar hit region map
    /// to the visual top). Without this the "title bar" drag region was the bottom strip.
    override var isFlipped: Bool { true }
    deinit { NotificationCenter.default.removeObserver(self) }

    init(theme: Theme, lines: [PanelLine], opts: PanelOpts) {
        self.theme = theme
        self.corner = Corner(rawValue: opts.corner) ?? .topright
        self.anchor = Corner(rawValue: opts.corner) ?? .topright
        self.panelTitle = opts.title
        self.maxHeight = CGFloat(opts.height)
        super.init(frame: .zero)
        wantsLayer = true
        let bg = opts.bgHex.flatMap(PanelOverlay.hexColor)?.withAlphaComponent(0.96) ?? NSColor(white: 0.11, alpha: 0.96)
        layer?.backgroundColor = bg.cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        if opts.width > 0 { widthAnchor.constraint(equalToConstant: opts.width).isActive = true }

        titleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = theme.accent
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // minimize button (– → hide to nearest edge)
        minButton.title = "–"
        minButton.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        minButton.isBordered = false
        minButton.contentTintColor = theme.accent
        minButton.target = self
        minButton.action = #selector(minimizeTapped)
        minButton.translatesAutoresizingMaskIntoConstraints = false
        minButton.setButtonType(.momentaryChange)

        lineStack.orientation = .vertical
        lineStack.alignment = .leading
        lineStack.spacing = 0   // tight so a graph-prefix column (│/●) connects between rows
        lineStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(minButton)

        // content area: a scroll view when height-capped, else the bare stack
        let content: NSView
        if maxHeight > 0 {
            let sv = NSScrollView()
            sv.hasVerticalScroller = true; sv.autohidesScrollers = true; sv.drawsBackground = false
            sv.translatesAutoresizingMaskIntoConstraints = false
            let doc = FlippedDoc(); doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(lineStack)
            sv.documentView = doc
            NSLayoutConstraint.activate([
                lineStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                lineStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                lineStack.topAnchor.constraint(equalTo: doc.topAnchor),
                lineStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
                doc.widthAnchor.constraint(equalTo: sv.contentView.widthAnchor),
                sv.heightAnchor.constraint(equalToConstant: maxHeight),
            ])
            content = sv
        } else {
            content = lineStack
        }
        addSubview(content)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            minButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            minButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            minButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        update(title: opts.title, lines: lines)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - hit testing

    /// The whole card captures clicks — to bring it to front (focus) and, from the title
    /// bar, to drag. Clickable / input rows take their own clicks. Capture is bounded to the
    /// card's own frame (AppKit only calls hitTest for points inside it), so a card never
    /// swallows clicks outside itself — click a panel behind's visible area to focus it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Bound to the card's own frame — an unconditional `return self` would claim points
        // outside the card too (AppKit polls every subview), swallowing the whole window.
        guard local.x >= 0, local.x <= bounds.width, local.y >= 0, local.y <= bounds.height else { return nil }
        let hit = super.hitTest(point)
        if hit === minButton { return minButton }
        if minimized { return self }
        // Title bar drags + focuses the card.
        if local.y <= 30 { return self }
        // Body: hand off to the real subview so scroll views get wheel events and clickable
        // rows get their clicks; only empty areas fall back to self (focus on click).
        return hit ?? self
    }

    // MARK: - placement

    func place(into host: NSView) {
        self.host = host
        let lc = leadingAnchor.constraint(equalTo: host.leadingAnchor)
        let tc = topAnchor.constraint(equalTo: host.topAnchor)
        leadingC = lc; topC = tc
        NSLayoutConstraint.activate([lc, tc])
        host.layoutSubtreeIfNeeded()
        if let p = PanelStore.get(panelTitle) {
            anchor = Corner(rawValue: p.corner) ?? anchor
            dx = CGFloat(p.dx); dy = CGFloat(p.dy); edge = p.edge; minimized = p.minimized
            minButton.title = minimized ? "+" : "–"
        } else {
            defaultOffsets()
        }
        reposition()
        // Corner-anchored panels stay glued to their corner on resize (and stay in view).
        host.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(hostResized),
                                               name: NSView.frameDidChangeNotification, object: host)
    }

    @objc private func hostResized() { reposition() }

    private func defaultOffsets() {
        dx = margin
        dy = (anchor == .topright || anchor == .topleft) ? margin + 28 : margin
    }

    private func setXY(_ x: CGFloat, _ y: CGFloat) { leadingC?.constant = x; topC?.constant = y }

    /// Top-left for the current corner + offsets, capped so the panel stays fully in view.
    private func normalXY() -> (CGFloat, CGFloat) {
        guard let host = host else { return (dx, dy) }
        let s = fittingSize, hb = host.bounds
        let cdx = min(max(0, dx), max(0, hb.width - s.width))
        let cdy = min(max(0, dy), max(0, hb.height - s.height))
        switch anchor {
        case .topleft:     return (cdx, cdy)
        case .topright:    return (hb.width - s.width - cdx, cdy)
        case .bottomleft:  return (cdx, hb.height - s.height - cdy)
        case .bottomright: return (hb.width - s.width - cdx, hb.height - s.height - cdy)
        }
    }

    /// Apply the placement — normal, or docked off the minimized edge leaving a peek tab.
    private func reposition() {
        guard let host = host, !dragging else { return }   // never fight an in-progress drag
        let s = fittingSize, hb = host.bounds
        let top: CGFloat = margin + 28   // never under the window titlebar
        var (nx, ny) = normalXY()
        nx = min(max(nx, 0), max(0, hb.width - s.width))
        ny = min(max(ny, top), max(top, hb.height - s.height))
        if !minimized { setXY(nx, ny); return }
        switch edge {
        case "left":  setXY(-(s.width - peek), ny)
        case "right": setXY(hb.width - peek, ny)
        case "top":   setXY(nx, -(s.height - peek))
        default:      setXY(nx, hb.height - peek)
        }
    }

    // MARK: - drag → move, snap to nearest corner, bring to front

    // NOTE: bring-to-front (an addSubview reorder) is deferred to mouseUp. Reordering during
    // mouseDown disrupts AppKit's mouse tracking, losing the mouseUp → a stuck drag that
    // follows every move. So mouseDown only records intent.
    override func mouseDown(with event: NSEvent) {
        if minimized { return }     // restore + focus handled on mouseUp
        // drag only when grabbed by the title bar; elsewhere the click just focuses on mouseUp.
        let local = convert(event.locationInWindow, from: nil)
        dragging = local.y <= 30
        if dragging {
            NSCursor.closedHand.set()
            dragStart = event.locationInWindow
            dragOrigin = (leadingC?.constant ?? 0, topC?.constant ?? 0)
            showGrid(true)
        }
    }

    // Cursor via cursorUpdate (not cursor rects, which AppKit re-applies every move and
    // flicker against an in-drag set): open hand over the title bar, closed while dragging.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }
    override func cursorUpdate(with event: NSEvent) {
        if dragging { NSCursor.closedHand.set(); return }
        let local = convert(event.locationInWindow, from: nil)
        if local.x >= 0, local.x <= bounds.width, local.y >= 0, local.y <= 30 { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, !minimized, let host = host else { return }
        NSCursor.closedHand.set()   // keep it closed through the drag (no cursor-rect to fight)
        let p = event.locationInWindow
        // window coords: +x right, +y up; topC grows downward → invert dy.
        let s = fittingSize, hb = host.bounds
        let top = margin + 28   // stay clear of the window titlebar / traffic lights
        let x = min(max(dragOrigin.x + (p.x - dragStart.x), 0), max(0, hb.width - s.width))
        let y = min(max(dragOrigin.y - (p.y - dragStart.y), top), max(top, hb.height - s.height))
        setXY(x, y)   // clamp live so it can't be dragged off-window / under the titlebar
    }

    override func mouseUp(with event: NSEvent) {
        if minimized { restore(); bringToFront(); cursorUpdate(with: event); return }
        if dragging { dragging = false; showGrid(false); snapToNearestCorner(); persist() }
        bringToFront()                 // focus / raise — safe here (end of the event sequence)
        cursorUpdate(with: event)      // settle the cursor (open over title, arrow elsewhere)
    }

    /// Panel center → nearest corner → grid-snapped offset from that corner, then re-glue.
    private func snapToNearestCorner() {
        guard let host = host else { return }
        let s = fittingSize, hb = host.bounds
        let x = leadingC?.constant ?? 0, y = topC?.constant ?? 0
        let left = (x + s.width / 2) < hb.width / 2
        let top  = (y + s.height / 2) < hb.height / 2
        anchor = top ? (left ? .topleft : .topright) : (left ? .bottomleft : .bottomright)
        let offX = left ? x : (hb.width  - s.width  - x)
        let offY = top  ? y : (hb.height - s.height - y)
        dx = max(0, (offX / grid).rounded() * grid)
        dy = max(0, (offY / grid).rounded() * grid)
        reposition()
    }

    private func bringToFront() {
        guard let host = host, host.subviews.last !== self else { return }   // already front → no flash
        host.addSubview(self, positioned: .above, relativeTo: nil)   // top of z-order
        var p = currentPlacement(); p.z = PanelStore.nextZ()
        PanelStore.set(panelTitle, p)
    }

    private func showGrid(_ on: Bool) {
        guard let host = host else { return }
        if on {
            let g = GridView(step: grid)
            g.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(g, positioned: .below, relativeTo: self)
            NSLayoutConstraint.activate([
                g.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                g.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                g.topAnchor.constraint(equalTo: host.topAnchor),
                g.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            gridView = g
        } else {
            gridView?.removeFromSuperview(); gridView = nil
        }
    }

    // MARK: - edge minimize

    @objc private func minimizeTapped() {
        if minimized { restore() } else { minimizeToEdge() }
    }

    private func nearestEdge() -> String {
        guard let host = host else { return "right" }
        let s = fittingSize, hb = host.bounds
        let x = leadingC?.constant ?? 0, y = topC?.constant ?? 0
        let dl = x, dr = hb.width - (x + s.width), dt = y, db = hb.height - (y + s.height)
        let m = min(dl, dr, dt, db)
        if m == dl { return "left" }; if m == dr { return "right" }
        if m == dt { return "top" }; return "bottom"
    }

    private func minimizeToEdge() {
        edge = nearestEdge()
        minimized = true
        minButton.title = "+"
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22; ctx.allowsImplicitAnimation = true
            reposition(); host?.layoutSubtreeIfNeeded()
        }
        persist()
    }

    private func restore() {
        minimized = false
        minButton.title = "–"
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22; ctx.allowsImplicitAnimation = true
            reposition(); host?.layoutSubtreeIfNeeded()
        }
        persist()
    }

    private func currentPlacement() -> PanelPlacement {
        PanelPlacement(corner: anchor.rawValue, dx: Double(dx), dy: Double(dy),
                       minimized: minimized, edge: edge, z: PanelStore.get(panelTitle)?.z ?? 0)
    }

    private func persist() { PanelStore.set(panelTitle, currentPlacement()) }

    // MARK: - content

    /// Replace the panel's content. Returns the click refs it no longer shows.
    @discardableResult
    func update(title: String, lines: [PanelLine]) -> [Int32] {
        let stale = clickRefs
        clickRefs = []
        titleLabel.stringValue = title
        titleLabel.isHidden = title.isEmpty
        lineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in lines.prefix(200) {
            let color = line.colorHex.flatMap(PanelOverlay.hexColor) ?? NSColor(white: 0.9, alpha: 1)
            if line.svg != nil || line.imagePath != nil {
                let img = line.svg.flatMap { NSImage(data: Data($0.utf8)) }
                    ?? line.imagePath.flatMap { NSImage(contentsOfFile: $0) }
                let iv = NSImageView()
                iv.image = img
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.imageAlignment = .alignTopLeft
                iv.translatesAutoresizingMaskIntoConstraints = false
                let sz = img?.size ?? NSSize(width: 200, height: 80)
                let h = line.imageHeight > 0 ? line.imageHeight : sz.height
                let w = sz.height > 0 ? sz.width * (h / sz.height) : sz.width
                iv.widthAnchor.constraint(equalToConstant: max(1, w)).isActive = true
                iv.heightAnchor.constraint(equalToConstant: max(1, h)).isActive = true
                lineStack.addArrangedSubview(iv)
            } else if line.isInput {
                if let ref = line.clickRef { clickRefs.append(ref) }
                let ref = line.clickRef
                let row = PanelInputRow(placeholder: line.placeholder ?? line.text, theme: theme) { text in
                    if let ref { luaCall(ref: ref, stringArg: text) }
                }
                lineStack.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: lineStack.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: lineStack.trailingAnchor).isActive = true
            } else if let ref = line.clickRef {
                clickRefs.append(ref)
                let row = ClickableRow(attributed: attributedLine(line, defaultColor: theme.accent)) { luaCall(ref: ref) }
                lineStack.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: lineStack.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: lineStack.trailingAnchor).isActive = true
            } else {
                let l = NSTextField(labelWithString: "")
                l.attributedStringValue = attributedLine(line, defaultColor: NSColor(white: 0.9, alpha: 1))
                l.lineBreakMode = .byTruncatingTail
                lineStack.addArrangedSubview(l)
            }
        }
        if host != nil { reposition() }   // content changed size → keep it glued/in-view
        return stale
    }

    /// A line as attributed text: an optional colored `prefix` (e.g. a │/● graph column)
    /// followed by `text` in its color. Lets one row mix a colored graph with a white subject.
    private func attributedLine(_ line: PanelLine, defaultColor: NSColor) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let m = NSMutableAttributedString()
        if !line.prefix.isEmpty {
            let pc = line.prefixColorHex.flatMap(PanelOverlay.hexColor) ?? theme.accent
            m.append(NSAttributedString(string: line.prefix, attributes: [.font: font, .foregroundColor: pc]))
        }
        let tc = line.colorHex.flatMap(PanelOverlay.hexColor) ?? defaultColor
        m.append(NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: tc]))
        return m
    }

    /// Parse "#rrggbb" / "#rgb" → NSColor (nil on bad input).
    static func hexColor(_ s: String) -> NSColor? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
