import AppKit

/// A generic fuzzy-ish picker overlay (the UI primitive behind `halo.pick`). A dim scrim
/// over the window with a search field + filtered list; type to filter (case-insensitive
/// substring), ↑/↓ to move, Enter to choose, Esc to cancel. Plugins use this to build
/// fzf-style pickers — the kind of UI that was impossible before.
final class PickerOverlay: NSView, NSTextFieldDelegate {
    private let theme: Theme
    private let allItems: [String]
    private var shown: [String] = []
    private var selected = 0
    private let input = NSTextField()
    private let listStack = NSStackView()
    private let onChoose: (String) -> Void
    private let onCancel: () -> Void
    private var isPrompt = false   // free-text input (halo.prompt) vs list pick (halo.pick)

    /// Free-text prompt (halo.prompt): a field with no list; Enter submits the typed text.
    convenience init(theme: Theme, prompt: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.init(theme: theme, items: [], onChoose: onSubmit, onCancel: onCancel)
        isPrompt = true
        input.placeholderString = prompt
    }

    init(theme: Theme, items: [String], onChoose: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.theme = theme
        self.allItems = items
        self.onChoose = onChoose
        self.onCancel = onCancel
        super.init(frame: .zero)
        build()
        apply(query: "")
    }
    required init?(coder: NSCoder) { fatalError() }

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

        input.placeholderString = "Filter…"
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
        shown = q.isEmpty ? allItems : allItems.filter { $0.lowercased().contains(q) }
        selected = 0
        rebuildRows()
    }

    private func rebuildRows() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, item) in shown.prefix(200).enumerated() {
            let row = NSTextField(labelWithString: item)
            row.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            row.textColor = NSColor(white: 0.9, alpha: 1)
            row.lineBreakMode = .byTruncatingTail
            row.wantsLayer = true
            row.layer?.cornerRadius = 4
            row.translatesAutoresizingMaskIntoConstraints = false
            let pad = NSView()
            pad.translatesAutoresizingMaskIntoConstraints = false
            pad.wantsLayer = true
            pad.layer?.backgroundColor = (i == selected ? theme.accent.withAlphaComponent(0.30) : .clear).cgColor
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

    // Arrows / Enter / Esc come through the field editor.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            if !shown.isEmpty { selected = min(selected + 1, shown.count - 1); rebuildRows() }; return true
        case #selector(NSResponder.moveUp(_:)):
            if !shown.isEmpty { selected = max(selected - 1, 0); rebuildRows() }; return true
        case #selector(NSResponder.insertNewline(_:)):
            if isPrompt { onChoose(input.stringValue) }
            else if shown.indices.contains(selected) { onChoose(shown[selected]) }
            else { onCancel() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel(); return true
        default: return false
        }
    }

    /// Focus the text field once we're in the window hierarchy (async so the window is
    /// ready). Without this the field never gets keyboard focus and you can't type.
    override func viewDidMoveToWindow() {
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.input) }
    }
}
