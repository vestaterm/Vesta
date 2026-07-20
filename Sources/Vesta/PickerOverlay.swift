import AppKit

/// One row of a picker: a label plus an optional dimmed description (command-palette style).
struct PickItem { let label: String; let desc: String? }

/// Per-call sizing for a picker (from vesta.pick/menu/pickmulti opts). All optional:
/// `width` overrides the default; `fixedHeight` forces the list area to that height (the
/// old always-tall look); otherwise the list hugs its rows up to `maxHeight`, then scrolls.
struct PickOpts {
    var width: CGFloat? = nil       // nil → hug the widest row (clamped); set → fixed width
    var fixedHeight: CGFloat? = nil
    var maxHeight: CGFloat = 440
}

private final class FlippedClipView: NSClipView { override var isFlipped: Bool { true } }

/// A picker list row that reports clicks (click-to-select).
private final class PickRowView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A generic picker overlay (the UI behind `vesta.pick`, `vesta.menu`, `vesta.pickmulti`,
/// `vesta.prompt`, `vesta.confirm`). A dim scrim over the window with a search field + filtered
/// list; type to filter (case-insensitive substring on the label), ↑/↓ to move, Enter to
/// choose, Esc to cancel. In multi-select mode Tab marks/unmarks and Enter confirms the set.
final class PickerOverlay: NSView, NSTextFieldDelegate {
    private let theme: Theme
    private let items: [PickItem]
    private var shown: [Int] = []          // indices into `items`, after filtering
    private var cursor = 0                  // index into `shown`
    private var marked: Set<Int> = []       // indices into `items` (multi-select)
    private let multiSelect: Bool
    private let isPrompt: Bool
    private let onIndices: ([Int]) -> Void  // chosen item indices (single → one element)
    private let onText: (String) -> Void    // prompt text
    private let onCancel: () -> Void
    private let input = NSTextField()
    private let listStack = NSStackView()
    private let opts: PickOpts
    private weak var panelView: NSView?      // the floating card; scrim-clicks outside it cancel

    /// Designated init: index-based selection over `items`.
    private init(theme: Theme, items: [PickItem], multiSelect: Bool, isPrompt: Bool,
                 opts: PickOpts = PickOpts(),
                 onIndices: @escaping ([Int]) -> Void, onText: @escaping (String) -> Void,
                 onCancel: @escaping () -> Void) {
        self.theme = theme
        self.items = items
        self.multiSelect = multiSelect
        self.isPrompt = isPrompt
        self.opts = opts
        self.onIndices = onIndices
        self.onText = onText
        self.onCancel = onCancel
        super.init(frame: .zero)
        build()
        apply(query: "")
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Convenience inits (preserve existing call sites)

    /// Single-select rich picker returning the chosen index (`vesta.pick` with descriptions,
    /// `vesta.menu`). Multi-select variant returns every marked index.
    convenience init(theme: Theme, richItems: [PickItem], multiSelect: Bool, opts: PickOpts = PickOpts(),
                     onPick: @escaping ([Int]) -> Void, onCancel: @escaping () -> Void) {
        self.init(theme: theme, items: richItems, multiSelect: multiSelect, isPrompt: false, opts: opts,
                  onIndices: onPick, onText: { _ in }, onCancel: onCancel)
    }

    /// Free-text prompt (`vesta.prompt`): a field with no list; Enter submits the typed text.
    /// Fixed-width (no list to hug, and free text wants room).
    convenience init(theme: Theme, prompt: String, initial: String = "",
                     onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.init(theme: theme, items: [], multiSelect: false, isPrompt: true, opts: PickOpts(width: 520),
                  onIndices: { _ in }, onText: onSubmit, onCancel: onCancel)
        input.placeholderString = prompt
        input.stringValue = initial
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill(); dirtyRect.fill()
    }
    override func mouseDown(with event: NSEvent) {
        // Cancel only when clicking the dim scrim OUTSIDE the card; clicks on the card
        // (and its rows) are handled by the rows themselves, not treated as dismiss.
        let p = convert(event.locationInWindow, from: nil)
        if let panel = panelView, panel.frame.contains(p) { return }
        onCancel()
    }

    private func build() {
        wantsLayer = true
        autoresizingMask = [.width, .height]

        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        installGlass(panel, tint: NSColor(white: 0.10, alpha: 1))   // glass moment: blur + dark tint
        panel.layer?.cornerRadius = 9
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
        addSubview(panel)
        panelView = panel

        input.placeholderString = multiSelect ? "Filter… (Tab to mark, Enter to confirm)" : "Filter…"
        input.delegate = self
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.focusRingType = .none
        input.isBezeled = false
        input.drawsBackground = false
        input.textColor = NSColor(white: 0.95, alpha: 1)
        input.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 1
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true          // overflow is scrollable + discoverable
        scroll.scrollerStyle = .overlay            // floats over content, reserves no width
        scroll.autohidesScrollers = true           // hidden until the list actually overflows
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = FlippedClipView()     // top-anchor the list so it hugs from the top
        scroll.documentView = listStack

        panel.addSubview(input)
        panel.addSubview(scroll)
        // Sizing: width from opts. Height — if opts.fixedHeight is set, the list area is
        // exactly that (the old always-tall look); otherwise it hugs its rows up to
        // opts.maxHeight, then scrolls. Always capped to the window so it never overflows.
        var cons: [NSLayoutConstraint] = [
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 90),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.widthAnchor.constraint(equalToConstant: opts.width ?? contentWidth()),
            input.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            input.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
            scroll.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.8),
            listStack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ]
        if let h = opts.fixedHeight {
            let fixed = scroll.heightAnchor.constraint(equalToConstant: h)
            fixed.priority = .defaultHigh   // yields to the window cap above
            cons.append(fixed)
        } else {
            let hug = scroll.heightAnchor.constraint(equalTo: listStack.heightAnchor)
            hug.priority = .defaultHigh     // hug content; the caps below win when exceeded
            cons += [hug, scroll.heightAnchor.constraint(lessThanOrEqualToConstant: opts.maxHeight)]
        }
        NSLayoutConstraint.activate(cons)
    }

    private func apply(query: String) {
        let q = query.lowercased()
        shown = items.indices.filter { q.isEmpty || items[$0].label.lowercased().contains(q) }
        cursor = 0
        rebuildRows()
    }

    private static let rowFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func rowText(_ itemIndex: Int) -> NSAttributedString {
        let it = items[itemIndex]
        let f = PickerOverlay.rowFont
        let s = NSMutableAttributedString()
        if multiSelect {
            s.append(NSAttributedString(string: marked.contains(itemIndex) ? "✓ " : "  ",
                                        attributes: [.foregroundColor: theme.accent, .font: f]))
        }
        s.append(NSAttributedString(string: it.label, attributes: [.foregroundColor: NSColor(white: 0.92, alpha: 1), .font: f]))
        if let d = it.desc, !d.isEmpty {
            s.append(NSAttributedString(string: "  \(d)", attributes: [.foregroundColor: NSColor(white: 0.5, alpha: 1), .font: f]))
        }
        return s
    }

    /// Default width: the widest row (or the filter placeholder) plus padding, clamped to a
    /// sane range so a tiny list isn't cramped and a long label doesn't run off-screen.
    private func contentWidth() -> CGFloat {
        var w: CGFloat = 0
        for i in items.indices { w = max(w, rowText(i).size().width) }
        let ph = (input.placeholderString ?? "") as NSString
        w = max(w, ph.size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width)
        return min(680, max(300, ceil(w) + 56))   // + row/scroll/panel horizontal padding
    }

    private func rebuildRows() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, itemIndex) in shown.prefix(200).enumerated() {
            let row = NSTextField(labelWithAttributedString: rowText(itemIndex))
            row.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            row.lineBreakMode = .byTruncatingTail
            row.translatesAutoresizingMaskIntoConstraints = false
            let pad = PickRowView()
            pad.onClick = { [weak self] in self?.chooseShown(i) }
            pad.translatesAutoresizingMaskIntoConstraints = false
            pad.wantsLayer = true
            pad.layer?.backgroundColor = (i == cursor ? theme.accent.withAlphaComponent(0.30) : .clear).cgColor
            pad.layer?.cornerRadius = 4
            pad.addSubview(row)
            listStack.addArrangedSubview(pad)
            NSLayoutConstraint.activate([
                pad.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                pad.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
                row.topAnchor.constraint(equalTo: pad.topAnchor, constant: 4),
                row.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -4),
                row.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 8),
                row.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -8),
            ])
        }
    }

    func controlTextDidChange(_ obj: Notification) { apply(query: input.stringValue) }

    // Arrows / Tab / Enter / Esc come through the field editor.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            if !shown.isEmpty { cursor = min(cursor + 1, shown.count - 1); rebuildRows() }; return true
        case #selector(NSResponder.moveUp(_:)):
            if !shown.isEmpty { cursor = max(cursor - 1, 0); rebuildRows() }; return true
        case #selector(NSResponder.insertTab(_:)):
            guard multiSelect, shown.indices.contains(cursor) else { return true }
            let it = shown[cursor]
            if marked.contains(it) { marked.remove(it) } else { marked.insert(it) }
            rebuildRows(); return true
        case #selector(NSResponder.insertNewline(_:)):
            if isPrompt { onText(input.stringValue) }
            else if multiSelect { onIndices(marked.sorted()) }
            else if shown.indices.contains(cursor) { onIndices([shown[cursor]]) }
            else { onCancel() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel(); return true
        default: return false
        }
    }

    /// Click-select a visible row: single-select confirms it, multi-select toggles its mark.
    private func chooseShown(_ shownIdx: Int) {
        guard shown.indices.contains(shownIdx), !isPrompt else { return }
        cursor = shownIdx
        if multiSelect {
            let it = shown[shownIdx]
            if marked.contains(it) { marked.remove(it) } else { marked.insert(it) }
            rebuildRows()
        } else {
            onIndices([shown[shownIdx]])
        }
    }

    /// Focus the text field once we're in the window hierarchy (async so the window is ready).
    override func viewDidMoveToWindow() {
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.input) }
    }
}
