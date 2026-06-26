import AppKit

/// One row of a picker: a label plus an optional dimmed description (command-palette style).
struct PickItem { let label: String; let desc: String? }

/// A generic picker overlay (the UI behind `halo.pick`, `halo.menu`, `halo.pickmulti`,
/// `halo.prompt`, `halo.confirm`). A dim scrim over the window with a search field + filtered
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

    /// Designated init: index-based selection over `items`.
    private init(theme: Theme, items: [PickItem], multiSelect: Bool, isPrompt: Bool,
                 onIndices: @escaping ([Int]) -> Void, onText: @escaping (String) -> Void,
                 onCancel: @escaping () -> Void) {
        self.theme = theme
        self.items = items
        self.multiSelect = multiSelect
        self.isPrompt = isPrompt
        self.onIndices = onIndices
        self.onText = onText
        self.onCancel = onCancel
        super.init(frame: .zero)
        build()
        apply(query: "")
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Convenience inits (preserve existing call sites)

    /// Single-select string picker (`halo.pick` of plain strings; also `halo.confirm`).
    convenience init(theme: Theme, items: [String], onChoose: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        let pis = items.map { PickItem(label: $0, desc: nil) }
        self.init(theme: theme, items: pis, multiSelect: false, isPrompt: false,
                  onIndices: { idx in if let i = idx.first { onChoose(pis[i].label) } },
                  onText: { _ in }, onCancel: onCancel)
    }

    /// Single-select rich picker returning the chosen index (`halo.pick` with descriptions,
    /// `halo.menu`). Multi-select variant returns every marked index.
    convenience init(theme: Theme, richItems: [PickItem], multiSelect: Bool,
                     onPick: @escaping ([Int]) -> Void, onCancel: @escaping () -> Void) {
        self.init(theme: theme, items: richItems, multiSelect: multiSelect, isPrompt: false,
                  onIndices: onPick, onText: { _ in }, onCancel: onCancel)
    }

    /// Free-text prompt (`halo.prompt`): a field with no list; Enter submits the typed text.
    convenience init(theme: Theme, prompt: String, initial: String = "",
                     onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.init(theme: theme, items: [], multiSelect: false, isPrompt: true,
                  onIndices: { _ in }, onText: onSubmit, onCancel: onCancel)
        input.placeholderString = prompt
        input.stringValue = initial
    }

    /// Yes/No confirm (`halo.confirm`): a two-item pick with the message as the field label.
    convenience init(theme: Theme, confirm message: String,
                     onChoose: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.init(theme: theme, items: ["Yes", "No"], onChoose: onChoose, onCancel: onCancel)
        input.placeholderString = message
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill(); dirtyRect.fill()
    }
    override func mouseDown(with event: NSEvent) { onCancel() }   // click scrim → cancel

    private func build() {
        wantsLayer = true
        autoresizingMask = [.width, .height]

        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.98).cgColor
        panel.layer?.cornerRadius = 9
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
        addSubview(panel)

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
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = listStack

        panel.addSubview(input)
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 90),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.widthAnchor.constraint(equalToConstant: 520),
            panel.heightAnchor.constraint(lessThanOrEqualToConstant: 380),
            input.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            input.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
            listStack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    private func apply(query: String) {
        let q = query.lowercased()
        shown = items.indices.filter { q.isEmpty || items[$0].label.lowercased().contains(q) }
        cursor = 0
        rebuildRows()
    }

    private func rowText(_ itemIndex: Int) -> NSAttributedString {
        let it = items[itemIndex]
        let s = NSMutableAttributedString()
        if multiSelect {
            s.append(NSAttributedString(string: marked.contains(itemIndex) ? "✓ " : "  ",
                                        attributes: [.foregroundColor: theme.accent]))
        }
        s.append(NSAttributedString(string: it.label, attributes: [.foregroundColor: NSColor(white: 0.92, alpha: 1)]))
        if let d = it.desc, !d.isEmpty {
            s.append(NSAttributedString(string: "  \(d)", attributes: [.foregroundColor: NSColor(white: 0.5, alpha: 1)]))
        }
        return s
    }

    private func rebuildRows() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, itemIndex) in shown.prefix(200).enumerated() {
            let row = NSTextField(labelWithAttributedString: rowText(itemIndex))
            row.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            row.lineBreakMode = .byTruncatingTail
            row.translatesAutoresizingMaskIntoConstraints = false
            let pad = NSView()
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

    /// Focus the text field once we're in the window hierarchy (async so the window is ready).
    override func viewDidMoveToWindow() {
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.input) }
    }
}
