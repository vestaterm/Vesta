import AppKit

/// One panel line: text, an optional hex color, and an optional click handler (a Lua
/// registry ref). A plain string line becomes `PanelLine(text:)`.
struct PanelLine {
    var text: String
    var colorHex: String? = nil
    var clickRef: Int32? = nil      // click handler, or (when isInput) the submit handler
    var isInput: Bool = false       // editable field; clickRef fires with the typed text on Enter
    var placeholder: String? = nil
}

/// Panel-level options from `vesta.panel(lines, opts)`.
struct PanelOpts {
    var title = ""
    var corner = "topright"
    var id = 0
    var bgHex: String? = nil
    var width: Double = 0
    var allWindows = false   // window = "all" → render in every window; else only the active one
}

/// A clickable panel row rendered as a button (filled, accent-tinted, hover highlight).
/// Receives clicks (the rest of the panel passes through to the terminal) and runs its
/// handler — turns a panel into buttons / a menu.
final class ClickableRow: NSView {
    let onClick: () -> Void
    private let label = NSTextField(labelWithString: "")
    private let baseFill: NSColor
    init(text: String, textColor: NSColor, fill: NSColor, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.baseFill = fill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = fill.cgColor
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = textColor
        label.stringValue = text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = (baseFill.blended(withFraction: 0.35, of: .white) ?? baseFill).cgColor
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = baseFill.cgColor }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// An editable panel row: a text field that calls `onSubmit(text)` on Enter and clears.
/// Turns a panel into a small form (a search box, a quick-note input, a command line).
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

/// A non-modal, plugin-controlled floating panel: a titled box of lines pinned to a corner.
/// Lines can be colored and/or clickable. Plugins build live custom UI with it (a git
/// panel, a clock, a menu) and update it on a `vesta.timer`. Non-clickable areas pass clicks
/// through to the terminal underneath.
final class PanelOverlay: NSView {
    enum Corner: String { case topright, topleft, bottomright, bottomleft }

    private let theme: Theme
    let corner: Corner
    private let titleLabel = NSTextField(labelWithString: "")
    private let lineStack = NSStackView()
    /// Click handler refs currently shown — freed by AppDelegate on update/close.
    private(set) var clickRefs: [Int32] = []

    init(theme: Theme, lines: [PanelLine], opts: PanelOpts) {
        self.theme = theme
        self.corner = Corner(rawValue: opts.corner) ?? .topright
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

        lineStack.orientation = .vertical
        lineStack.alignment = .leading
        lineStack.spacing = 2
        lineStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(lineStack)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            lineStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            lineStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            lineStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            lineStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        update(title: opts.title, lines: lines)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks pass through, EXCEPT on a clickable row (so the terminal stays usable).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        var v = hit
        while let cur = v {
            if cur is ClickableRow { return cur }
            if cur is PanelInputRow { return hit }   // let the text field take the click (focus to type)
            if cur === self { break }
            v = cur.superview
        }
        return nil
    }

    /// Replace the panel's content. Returns the click refs it no longer shows (so the
    /// caller can free them).
    @discardableResult
    func update(title: String, lines: [PanelLine]) -> [Int32] {
        let stale = clickRefs
        clickRefs = []
        titleLabel.stringValue = title
        titleLabel.isHidden = title.isEmpty
        lineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in lines.prefix(60) {
            let color = line.colorHex.flatMap(PanelOverlay.hexColor) ?? NSColor(white: 0.9, alpha: 1)
            if line.isInput {
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
                // Button look: accent-tinted fill, accent (or custom) text.
                let textColor = line.colorHex == nil ? theme.accent : color
                let fill = (line.colorHex.flatMap(PanelOverlay.hexColor) ?? theme.accent).withAlphaComponent(0.16)
                let row = ClickableRow(text: line.text, textColor: textColor, fill: fill) { luaCall(ref: ref) }
                lineStack.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: lineStack.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: lineStack.trailingAnchor).isActive = true
            } else {
                let l = NSTextField(labelWithString: line.text)
                l.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                l.textColor = color
                l.lineBreakMode = .byTruncatingTail
                lineStack.addArrangedSubview(l)
            }
        }
        return stale
    }

    func pin(into host: NSView) {
        let m: CGFloat = 16
        var cons: [NSLayoutConstraint] = []
        switch corner {
        case .topright:    cons = [topAnchor.constraint(equalTo: host.topAnchor, constant: m + 28),
                                   trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m)]
        case .topleft:     cons = [topAnchor.constraint(equalTo: host.topAnchor, constant: m + 28),
                                   leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)]
        case .bottomright: cons = [bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -m),
                                   trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m)]
        case .bottomleft:  cons = [bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -m),
                                   leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)]
        }
        NSLayoutConstraint.activate(cons)
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
