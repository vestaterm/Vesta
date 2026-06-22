import AppKit

struct Project { let name: String; let path: String }

/// Window + chrome + collapsible projects sidebar.
/// Uniform #161719 everywhere; seamless slim titlebar that flows into content.
/// Matches the locked mockup: hairlines (white @0.07) do the separating, never
/// brightness steps. Near-gray mint accent for selection + glow.
final class HaloWindowController: NSWindowController {

    private let theme: Theme

    // one near-uniform surface tone — from ghostty `background` / `halo-surface`
    private let surface: NSColor
    private let sbWidth = HaloConfig.shared.sidebarWidth   // halo-sidebar-width

    // hairline alphas straight from the mockup tokens
    private func hair(_ a: CGFloat = 0.07) -> NSColor { NSColor(white: 1, alpha: a) }

    // text tiers (oklch lightness → approx white alpha)
    private func txt(_ tier: Tier) -> NSColor {
        switch tier {
        case .full:  return NSColor(white: 0.93, alpha: 1)
        case .dim:   return NSColor(white: 0.66, alpha: 1)
        case .faint: return NSColor(white: 0.46, alpha: 1)
        }
    }
    private enum Tier { case full, dim, faint }

    private let projects: [Project]
    private let onSelectProject: (Project) -> Void
    private var selectedProject = 0

    private var sidebar: NSView!
    private var sidebarWidth: NSLayoutConstraint!
    private var toggleButton: NSButton!
    private var sidebarOpen = true

    private var projectRows: [(view: TaggedRow, dot: DotView, label: NSTextField, bar: NSView)] = []
    private var footer: NSTextField!
    private var dirLabel: NSTextField!

    init(theme: Theme, content: NSView,
         projects: [Project] = [], onSelectProject: @escaping (Project) -> Void = { _ in }) {
        self.theme = theme
        self.surface = theme.background
        self.projects = projects
        self.onSelectProject = onSelectProject

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = surface
        win.isMovableByWindowBackground = false
        win.center()

        super.init(window: win)

        buildContent(content: content)
        buildTitlebarAccessory()
        updateToggleTint()
    }

    required init?(coder: NSCoder) { fatalError("no xib") }

    // MARK: public updates

    func setStatus(_ text: String) { footer?.stringValue = text }
    func setDir(_ text: String) {
        // dir label shows "name / path"; mockup styles name bold, path dim.
        dirLabel?.attributedStringValue = dirAttributed(text)
    }

    // MARK: build

    private func buildContent(content: NSView) {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = surface.cgColor

        sidebar = makeSidebar()
        content.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebar)
        root.addSubview(content)

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: sbWidth)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window?.contentView = root
    }

    private func makeSidebar() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = surface.cgColor
        v.clipsToBounds = true

        // single right-edge hairline (white @0.07)
        let edge = NSView()
        edge.translatesAutoresizingMaskIntoConstraints = false
        edge.wantsLayer = true
        edge.layer?.backgroundColor = hair(0.07).cgColor
        v.addSubview(edge)

        // ── top: scrollless content stack ─────────────────────────
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        // top inset clears the 30px titlebar zone (toggle row lives up there)
        stack.edgeInsets = NSEdgeInsets(top: 46, left: 0, bottom: 0, right: 0)

        // PROJECTS label with count
        let count = String(format: "%02d", projects.count)
        stack.addArrangedSubview(sectionLabel("PROJECTS", count: count))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        for (i, p) in projects.enumerated() {
            stack.addArrangedSubview(makeProjectRow(i, p))
        }
        if projects.isEmpty {
            let empty = NSTextField(labelWithString: "no projects")
            empty.font = Fonts.mono(12)
            empty.textColor = txt(.faint)
            let wrap = padded(empty, left: 16, right: 16)
            stack.addArrangedSubview(wrap)
        }

        // ── footer block: status line + version ──────────────────
        let footBlock = makeFooter()

        v.addSubview(stack)
        v.addSubview(footBlock)

        NSLayoutConstraint.activate([
            edge.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            edge.topAnchor.constraint(equalTo: v.topAnchor),
            edge.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor),

            footBlock.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            footBlock.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            footBlock.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            footBlock.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 8),
        ])
        return v
    }

    /// Tiny uppercase dim label with wide letter-spacing + right-aligned count.
    private func sectionLabel(_ s: String, count: String) -> NSView {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: Fonts.inst(9.5),
            .foregroundColor: txt(.faint),
            .kern: 1.3,   // ~0.14em at 9.5px
        ])
        l.translatesAutoresizingMaskIntoConstraints = false

        let c = NSTextField(labelWithString: count)
        c.font = Fonts.inst(9.5)
        c.textColor = txt(.faint).withAlphaComponent(0.7)
        c.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(l)
        row.addSubview(c)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            l.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            c.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            c.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 16),
        ])
        return row
    }

    private func makeProjectRow(_ index: Int, _ p: Project) -> NSView {
        let selected = index == selectedProject

        let dot = DotView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.set(selected: selected, accent: theme.accent, off: txt(.faint))
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let label = NSTextField(labelWithString: p.name)
        label.font = Fonts.mono(12.5)
        label.textColor = selected ? txt(.full) : txt(.dim)

        let inner = NSStackView(views: [dot, label])
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false

        let row = TaggedRow()
        row.idx = index
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.backgroundColor = selected
            ? theme.accent.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor

        // 2px accent left-edge bar (inset 4px top/bottom), only when selected
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1
        bar.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        bar.layer?.backgroundColor = (selected ? theme.accent : NSColor.clear).cgColor

        row.addSubview(bar)
        row.addSubview(inner)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bar.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            bar.widthAnchor.constraint(equalToConstant: 2),

            inner.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            inner.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16),
            row.heightAnchor.constraint(equalToConstant: 23),  // ~5px pad both sides on 12.5px line
            row.widthAnchor.constraint(equalToConstant: sbWidth),
        ])
        row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(projectClicked(_:))))
        projectRows.append((row, dot, label, bar))
        return row
    }

    @objc private func projectClicked(_ g: NSClickGestureRecognizer) {
        guard let i = (g.view as? TaggedRow)?.idx, projects.indices.contains(i) else { return }
        selectedProject = i
        for (j, r) in projectRows.enumerated() {
            let on = j == i
            r.dot.set(selected: on, accent: theme.accent, off: txt(.faint))
            r.label.textColor = on ? txt(.full) : txt(.dim)
            r.bar.layer?.backgroundColor = (on ? theme.accent : NSColor.clear).cgColor
            r.view.layer?.backgroundColor = on
                ? theme.accent.withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
        }
        onSelectProject(projects[i])
    }

    /// Footer: status line(s) atop a hairline, then a dim version line.
    private func makeFooter() -> NSView {
        let block = NSView()
        block.translatesAutoresizingMaskIntoConstraints = false

        let topHair = NSView()
        topHair.translatesAutoresizingMaskIntoConstraints = false
        topHair.wantsLayer = true
        topHair.layer?.backgroundColor = hair(0.07).cgColor

        // status line — set via setStatus(); e.g. "▌ normal · ⎇ main ↑1 · 2 dirty"
        footer = NSTextField(labelWithString: "▌ normal")
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.font = Fonts.inst(10)
        footer.textColor = txt(.dim)
        footer.lineBreakMode = .byTruncatingTail
        footer.cell?.usesSingleLineMode = true

        let version = NSTextField(labelWithString: "halo 0.1.0")
        version.translatesAutoresizingMaskIntoConstraints = false
        version.font = Fonts.inst(9.5)
        version.textColor = txt(.faint)

        block.addSubview(topHair)
        block.addSubview(footer)
        block.addSubview(version)
        NSLayoutConstraint.activate([
            topHair.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            topHair.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            topHair.topAnchor.constraint(equalTo: block.topAnchor),
            topHair.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: block.trailingAnchor, constant: -16),
            footer.topAnchor.constraint(equalTo: topHair.bottomAnchor, constant: 12),

            version.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 16),
            version.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 8),
            version.bottomAnchor.constraint(equalTo: block.bottomAnchor, constant: -12),
        ])
        return block
    }

    // MARK: titlebar accessory (left-to-right: lights · toggle · dir)

    private func buildTitlebarAccessory() {
        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .leading

        // A titlebar accessory needs a CONCRETE frame — pure Auto Layout leaves it
        // zero-sized and invisible (the bug). Frame-based host, AL subviews within.
        // Width ends ~at the sidebar edge so the dir truncates there instead of
        // overlapping the tab strip (lights eat ~80px before the accessory starts).
        let host = NSView(frame: NSRect(x: 0, y: 0, width: max(120, sbWidth - 80), height: 30))

        // sidebar toggle — vertically centered on the traffic-light row
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.title = ""
        btn.imagePosition = .imageOnly
        // mockup: 15px glyph, light stroke (≈1.3px) — not the heavier .regular.
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .light)
        btn.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle sidebar")?
            .withSymbolConfiguration(cfg)
        btn.contentTintColor = txt(.dim)
        btn.target = self
        btn.action = #selector(toggleSidebarAction)
        toggleButton = btn

        // small folder icon + dir label
        let folder = NSImageView()
        folder.translatesAutoresizingMaskIntoConstraints = false
        let fcfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(fcfg)
        folder.contentTintColor = txt(.faint)

        dirLabel = NSTextField(labelWithString: "")
        dirLabel.translatesAutoresizingMaskIntoConstraints = false
        dirLabel.attributedStringValue = dirAttributed("halo")
        dirLabel.lineBreakMode = .byTruncatingTail
        dirLabel.cell?.usesSingleLineMode = true

        host.addSubview(btn)
        host.addSubview(folder)
        host.addSubview(dirLabel)

        // `.leading` accessory is placed immediately AFTER the traffic lights, so
        // the toggle needs only the mockup's small gap — not the lights' width.
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 6),
            btn.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            btn.widthAnchor.constraint(equalToConstant: 22),
            btn.heightAnchor.constraint(equalToConstant: 22),

            folder.leadingAnchor.constraint(equalTo: btn.trailingAnchor, constant: 8),
            folder.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            folder.widthAnchor.constraint(equalToConstant: 13),
            folder.heightAnchor.constraint(equalToConstant: 13),

            dirLabel.leadingAnchor.constraint(equalTo: folder.trailingAnchor, constant: 7),
            dirLabel.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            // keep the dir within the host (over the sidebar zone) so it truncates
            // before reaching the tab strip rather than overlapping it.
            dirLabel.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -10),
        ])

        acc.view = host
        window?.addTitlebarAccessoryViewController(acc)
    }

    /// "name / path" → name bold (full), "/" faint, path dim. 11.5px.
    private func dirAttributed(_ raw: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // Accept either "name / path" or "name/path" or just "name".
        let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let name = parts.first ?? raw
        result.append(NSAttributedString(string: name, attributes: [
            .font: Fonts.mono(11.5, medium: true),
            .foregroundColor: txt(.full),
        ]))
        if parts.count > 1, !parts[1].isEmpty {
            result.append(NSAttributedString(string: "/", attributes: [
                .font: Fonts.mono(11.5),
                .foregroundColor: txt(.faint),
            ]))
            result.append(NSAttributedString(string: parts[1], attributes: [
                .font: Fonts.mono(11.5),
                .foregroundColor: txt(.dim),
            ]))
        }
        return result
    }

    private func padded(_ view: NSView, left: CGFloat, right: CGFloat) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: left),
            view.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -right),
            view.topAnchor.constraint(equalTo: wrap.topAnchor),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    // MARK: actions

    @objc private func toggleSidebarAction() { toggleSidebar() }

    func toggleSidebar() {
        sidebarOpen.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            sidebarWidth.animator().constant = sidebarOpen ? sbWidth : 0
            sidebar.superview?.layoutSubtreeIfNeeded()
        }
        updateToggleTint()
    }

    private func updateToggleTint() {
        // mockup keeps the toggle dim grey in every state — never accent-tinted.
        toggleButton?.contentTintColor = txt(.dim)
    }
}

/// A row/view that carries an integer index for gesture handlers.
final class TaggedRow: NSView { var idx = 0 }

/// A 6px status dot; mint with a soft glow when selected, dim otherwise.
final class DotView: NSView {
    private var selected = false
    private var accent = NSColor.white
    private var off = NSColor.gray

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(selected: Bool, accent: NSColor, off: NSColor) {
        self.selected = selected; self.accent = accent; self.off = off
        guard let layer else { return }
        layer.cornerRadius = 3
        layer.backgroundColor = (selected ? accent : off).cgColor
        if selected {
            layer.shadowColor = accent.cgColor
            layer.shadowRadius = 3.5
            layer.shadowOpacity = 0.9
            layer.shadowOffset = .zero
            layer.masksToBounds = false
        } else {
            layer.shadowOpacity = 0
        }
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
    }
}

func chromeSelfCheck() {
    let wc = HaloWindowController(theme: Theme(), content: NSView(),
                                 projects: [Project(name: "halo", path: "/tmp")])
    assert(wc.window != nil, "window must exist")
    wc.setStatus("▌ normal · ⎇ main ↑1 · 2 dirty")
    wc.setDir("halo / ~/dev/halo")
    wc.toggleSidebar(); wc.toggleSidebar()
    assert(wc.window?.contentView?.subviews.count ?? 0 >= 2, "sidebar + content present")
    print("chromeSelfCheck OK")
}
