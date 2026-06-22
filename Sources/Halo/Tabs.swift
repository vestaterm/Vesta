import AppKit

/// Owns the set of tabs (each tab is its own PaneTree) and swaps the active
/// one into view. Container = [TabBar | active tree] stacked vertically.
@MainActor
final class Workspace {
    private(set) var tabs: [PaneTree] = []
    private(set) var active = 0
    let container = NSView()
    private let bar = TabBar()
    private let body = NSView()
    private let theme: Theme
    var onChange: (() -> Void)?   // tab switched, or focused pane's cwd/title changed

    init(theme: Theme, cwd: String? = nil) {
        self.theme = theme
        bar.theme = theme
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.background.cgColor

        for v in [bar, body] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        bar.onSelect = { [weak self] i in self?.selectTab(i) }
        bar.onClose  = { [weak self] i in self?.closeTab(at: i) }
        bar.onNew    = { [weak self] in self?.newTab(cwd: self?.activeTree.focusedCwd) }
        newTab(cwd: cwd)
    }

    var activeTree: PaneTree { tabs[active] }

    func newTab(cwd: String?) {
        let tree = PaneTree(theme: theme, cwd: cwd)
        tree.onFocusChange = { [weak self] in self?.handleChange() }
        tabs.append(tree)
        active = tabs.count - 1
        showActive()
    }

    func closeTab(at i: Int) {
        guard tabs.count > 1, tabs.indices.contains(i) else { return }
        tabs.remove(at: i)
        if active >= tabs.count { active = tabs.count - 1 }
        showActive()
    }
    func closeTab() { closeTab(at: active) }

    func selectTab(_ i: Int) { guard tabs.indices.contains(i) else { return }; active = i; showActive() }
    func nextTab() { guard !tabs.isEmpty else { return }; active = (active + 1) % tabs.count; showActive() }
    func prevTab() { guard !tabs.isEmpty else { return }; active = (active - 1 + tabs.count) % tabs.count; showActive() }

    private func showActive() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let v = activeTree.rootView
        v.frame = body.bounds
        v.autoresizingMask = [.width, .height]
        body.addSubview(v)
        handleChange()
    }

    private func handleChange() {
        bar.update(titles: tabs.map { $0.focusedLabel }, active: active)
        onChange?()
    }
}

/// Slim tab strip. Uniform #161719; active tab = brighter text + a 2px accent
/// underline. A trailing "+" opens a new tab.
final class TabBar: NSView {
    var theme = Theme() { didSet { layer?.backgroundColor = theme.background.cgColor } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private let stack = NSStackView()
    private let plus = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor
        // Seamless: no bottom border — the strip flows into the pane grid,
        // whose hairline gaps do the separating.

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        addSubview(stack)

        plus.translatesAutoresizingMaskIntoConstraints = false
        plus.isBordered = false
        plus.title = ""
        plus.imagePosition = .imageOnly
        let pcfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?
            .withSymbolConfiguration(pcfg)
        plus.contentTintColor = theme.foreground.withAlphaComponent(0.40)
        plus.target = self
        plus.action = #selector(newTab)
        addSubview(plus)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            plus.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 6),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 22),
            plus.heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func newTab() { onNew?() }
    @objc private func selectTab(_ s: NSClickGestureRecognizer) {
        if let i = (s.view as? ChipView)?.idx { onSelect?(i) }
    }
    @objc private func closeTab(_ b: NSButton) { onClose?(b.tag) }

    private var lastSignature = ""

    func update(titles: [String], active: Int) {
        // Only rebuild when the tab set actually changes — not on every pane
        // focus. Cuts constraint churn (and the crashes it caused).
        let sig = "\(active)|" + titles.joined(separator: "\u{1}")
        guard sig != lastSignature else { return }
        lastSignature = sig

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let closeable = titles.count > 1
        for (i, title) in titles.enumerated() {
            stack.addArrangedSubview(makeChip(index: i, title: title, active: i == active, closeable: closeable))
        }
    }

    private func makeChip(index: Int, title: String, active: Bool, closeable: Bool) -> NSView {
        let chip = ChipView()
        chip.idx = index
        chip.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title.isEmpty ? "shell" : title)
        label.font = active ? Fonts.mono(11.5, medium: true) : Fonts.mono(11.5)
        // active = brighter near-white; inactive = dim
        label.textColor = NSColor(white: active ? 0.93 : 0.55, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)

        var labelTrailing: NSLayoutConstraint
        if closeable {
            let x = NSButton()
            x.translatesAutoresizingMaskIntoConstraints = false
            x.isBordered = false
            x.title = ""
            x.imagePosition = .imageOnly
            x.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
            x.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
            x.contentTintColor = theme.foreground.withAlphaComponent(active ? 0.5 : 0.3)
            x.tag = index
            x.target = self
            x.action = #selector(closeTab(_:))
            chip.addSubview(x)
            NSLayoutConstraint.activate([
                x.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                x.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8),
                x.widthAnchor.constraint(equalToConstant: 14),
                x.heightAnchor.constraint(equalToConstant: 14),
            ])
            labelTrailing = label.trailingAnchor.constraint(equalTo: x.leadingAnchor, constant: -4)
        } else {
            labelTrailing = label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -12)
        }

        // accent underline for the active tab
        if active {
            let u = NSView()
            u.translatesAutoresizingMaskIntoConstraints = false
            u.wantsLayer = true
            u.layer?.backgroundColor = theme.accent.cgColor
            chip.addSubview(u)
            NSLayoutConstraint.activate([
                u.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
                u.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
                u.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
                u.heightAnchor.constraint(equalToConstant: 2),
            ])
        }

        labelTrailing.priority = .defaultHigh
        let wMax = chip.widthAnchor.constraint(lessThanOrEqualToConstant: 200)
        wMax.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            labelTrailing,
            chip.heightAnchor.constraint(equalToConstant: 30),   // self-contained; = bar height
            chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            wMax,
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(selectTab(_:)))
        chip.addGestureRecognizer(click)
        return chip
    }
}

/// A tab chip view that exposes an integer `tag` for the gesture handler.
private final class ChipView: NSView {
    var idx = 0
    // a faint right-edge divider between tabs (white @0.06 hairline tone)
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.06).setFill()
        NSRect(x: bounds.maxX - 1, y: 7, width: 1, height: bounds.height - 14).fill()
    }
}

@MainActor
func tabsSelfCheck() {
    let ws = Workspace(theme: Theme())
    assert(ws.tabs.count == 1, "one tab at init")
    ws.newTab(cwd: nil)
    assert(ws.tabs.count == 2 && ws.active == 1, "second tab active")
    ws.selectTab(0); assert(ws.active == 0)
    ws.closeTab(at: 1); assert(ws.tabs.count == 1, "back to one")
    ws.closeTab(); assert(ws.tabs.count == 1, "never closes the last tab")
    print("tabsSelfCheck OK")
}
