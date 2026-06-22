import AppKit

/// Window + chrome + collapsible projects sidebar.
/// Uniform surface everywhere; seamless slim titlebar that flows into content.
/// Matches the locked mockup: hairlines (white @0.07) do the separating, never
/// brightness steps. Near-gray mint accent for selection + glow.
@MainActor
final class HaloWindowController: NSWindowController {

    private let theme: Theme

    // one near-uniform surface tone — from ghostty `background` / `halo-surface`
    private let surface: NSColor

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

    // MARK: – five action closures (wired by AppDelegate)
    private let onSelectSession:   (Int, Int) -> Void
    private let onCloseSession:    (Int, Int) -> Void
    private let onNewSession:      (Int) -> Void
    private let onToggleExpand:    (Int) -> Void
    private let onNewProject:      () -> Void
    private let onRenameProject:   (Int, String) -> Void
    private let onSetProjectColor: (Int, NSColor?) -> Void
    private let onRemoveProject:   (Int) -> Void

    private var sidebar: NSView!
    private var sidebarWidth: NSLayoutConstraint!
    private var toggleButton: NSButton!
    private var sidebarOpen = true
    // Track the "open" width so ⌘B always restores to whatever drag set.
    private var openWidth: CGFloat

    private var footer: NSTextField!
    private var dirLabel: NSTextField!

    // Mutable container for the projects stack — cleared+refilled by setProjects.
    private var projectsStack: NSStackView!

    init(theme: Theme, content: NSView,
         onSelectSession: @escaping (Int, Int) -> Void = { _, _ in },
         onCloseSession:  @escaping (Int, Int) -> Void = { _, _ in },
         onNewSession:    @escaping (Int) -> Void      = { _ in },
         onToggleExpand:  @escaping (Int) -> Void      = { _ in },
         onNewProject:    @escaping () -> Void          = {},
         onRenameProject:   @escaping (Int, String) -> Void  = { _, _ in },
         onSetProjectColor: @escaping (Int, NSColor?) -> Void = { _, _ in },
         onRemoveProject:   @escaping (Int) -> Void          = { _ in }) {
        self.theme = theme
        self.surface = theme.background
        self.openWidth = CGFloat(HaloConfig.shared.sidebarWidth)
        self.onSelectSession = onSelectSession
        self.onCloseSession  = onCloseSession
        self.onNewSession    = onNewSession
        self.onToggleExpand  = onToggleExpand
        self.onNewProject    = onNewProject
        self.onRenameProject   = onRenameProject
        self.onSetProjectColor = onSetProjectColor
        self.onRemoveProject   = onRemoveProject

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
        dirLabel?.attributedStringValue = dirAttributed(text)
    }

    /// Rebuild the PROJECTS area from the given snapshot.
    /// Single source of sidebar truth — called on every onChange.
    func setProjects(_ projects: [SidebarProject]) {
        guard let stack = projectsStack else { return }

        // Remove all previously arranged subviews (avoid constraint leaks).
        let old = stack.arrangedSubviews
        old.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }

        // PROJECTS header row: section label + trailing "+" button.
        // Pin trailing to stack so the header spans full sidebar width and the + sits at the right edge.
        let headerRow = makeProjHeaderRow(count: projects.count)
        stack.addArrangedSubview(headerRow)
        headerRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        stack.setCustomSpacing(6, after: headerRow)

        if projects.isEmpty {
            let empty = NSTextField(labelWithString: "no projects")
            empty.font = Fonts.mono(12)
            empty.textColor = txt(.faint)
            stack.addArrangedSubview(padded(empty, left: 20, right: 16))
        } else {
            for (pi, proj) in projects.enumerated() {
                let prow = makeProjectRow(pi, proj)
                stack.addArrangedSubview(prow)
                // Stretch project row to full stack width (constraint added after insertion).
                prow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
                var last: NSView = prow
                if proj.expanded {
                    stack.setCustomSpacing(3, after: prow)   // tighter gap before nested sessions
                    for (si, sess) in proj.sessions.enumerated() {
                        let srow = makeSessionRow(pi, si, sess)
                        stack.addArrangedSubview(srow)
                        srow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
                        last = srow
                    }
                }
                // Breathing room between project groups.
                if pi < projects.count - 1 { stack.setCustomSpacing(10, after: last) }
            }
        }
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

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: openWidth)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Inset below the ~30px titlebar so the terminal's first row doesn't
            // collide with the traffic lights / dir title (ghostty-style top gap).
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 34),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // Drag-resize grab strip pinned over the sidebar's right edge.
        let grab = SidebarGrabView()
        grab.translatesAutoresizingMaskIntoConstraints = false
        grab.onDrag = { [weak self] delta in self?.adjustSidebarWidth(by: delta) }
        root.addSubview(grab)
        NSLayoutConstraint.activate([
            grab.topAnchor.constraint(equalTo: root.topAnchor),
            grab.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            grab.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            grab.widthAnchor.constraint(equalToConstant: 5),
        ])

        window?.contentView = root
    }

    private func adjustSidebarWidth(by delta: CGFloat) {
        let clamped = (sidebarWidth.constant + delta).clamped(to: 160...420)
        sidebarWidth.constant = clamped
        openWidth = clamped
        sidebar.superview?.layoutSubtreeIfNeeded()
        updateToggleTint()
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

        // Scrollable content stack — top inset clears 30px titlebar zone
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 48, left: 0, bottom: 0, right: 0)

        // Preserve reference so setProjects can clear+refill it
        projectsStack = stack

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

    // MARK: – Row builders

    /// PROJECTS section header with count + trailing "+" new-project button.
    private func makeProjHeaderRow(count: Int) -> NSView {
        let countStr = String(format: "%02d", count)
        let header = sectionLabel("PROJECTS", count: countStr)

        let plus = tinyButton(symbol: "plus") { [weak self] in self?.onNewProject() }
        plus.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(plus)
        NSLayoutConstraint.activate([
            plus.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            plus.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 16),
            plus.heightAnchor.constraint(equalToConstant: 16),
        ])
        return header
    }

    /// Project row: [bar] caret · dot · name · branch …… +   (inner hstack = reliable alignment)
    private func makeProjectRow(_ pi: Int, _ p: SidebarProject) -> NSView {
        let active = p.active
        let tint = p.color ?? theme.accent

        let caretView = NSImageView()
        let caretImg = p.expanded
            ? NSImage(systemSymbolName: "chevron.down",  accessibilityDescription: nil)
            : NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        caretView.image = caretImg?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        caretView.contentTintColor = txt(.faint)
        caretView.setContentHuggingPriority(.required, for: .horizontal)

        let dot = DotView()
        dot.set(selected: active, accent: tint, off: p.color ?? txt(.faint))
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        let nameLabel = NSTextField(labelWithString: p.name)
        nameLabel.font = Fonts.mono(12.5, medium: active)
        nameLabel.textColor = active ? txt(.full) : txt(.dim)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [caretView, dot, nameLabel])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false

        if let branch = p.branch {
            let branchLabel = NSTextField(labelWithString: branch)
            branchLabel.font = Fonts.inst(10)
            branchLabel.textColor = txt(.faint)
            branchLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            content.addArrangedSubview(branchLabel)
            content.setCustomSpacing(8, after: nameLabel)
        }

        let addBtn = tinyButton(symbol: "plus") { [weak self] in self?.onNewSession(pi) }
        addBtn.translatesAutoresizingMaskIntoConstraints = false

        let bar = accentBar(active ? tint : .clear)

        let row = TaggedRow()
        row.tag1 = pi
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 5
        row.layer?.backgroundColor = active ? tint.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor

        row.addSubview(bar); row.addSubview(content); row.addSubview(addBtn)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bar.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            bar.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -5),
            bar.widthAnchor.constraint(equalToConstant: 2),

            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 13),
            content.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: addBtn.leadingAnchor, constant: -6),

            addBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            addBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            addBtn.widthAnchor.constraint(equalToConstant: 18),
            addBtn.heightAnchor.constraint(equalToConstant: 18),

            row.heightAnchor.constraint(equalToConstant: 30),
        ])

        // mouseDown (not a gesture recognizer) so the + NSButton hit-tests first.
        row.onClick = { [weak self] in self?.onToggleExpand(pi) }
        row.menu = makeProjectMenu(pi, name: p.name, hasColor: p.color != nil)
        return row
    }

    /// Session row (indented): [bar]  label …… ×
    private func makeSessionRow(_ pi: Int, _ si: Int, _ sess: SidebarSession) -> NSView {
        let active = sess.active

        let label = NSTextField(labelWithString: sess.label)
        label.font = Fonts.mono(12)
        label.textColor = active ? txt(.full) : txt(.dim)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = tinyButton(symbol: "xmark") { [weak self] in self?.onCloseSession(pi, si) }
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        let bar = accentBar(active ? theme.accent : .clear)

        let row = TaggedRow()
        row.tag1 = pi; row.tag2 = si
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 5
        row.layer?.backgroundColor = active ? theme.accent.withAlphaComponent(0.09).cgColor : NSColor.clear.cgColor

        row.addSubview(bar); row.addSubview(label); row.addSubview(closeBtn)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bar.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            bar.widthAnchor.constraint(equalToConstant: 2),

            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 32),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -6),

            closeBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            closeBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 16),
            closeBtn.heightAnchor.constraint(equalToConstant: 16),

            row.heightAnchor.constraint(equalToConstant: 26),
        ])

        row.onClick = { [weak self] in self?.onSelectSession(pi, si) }
        return row
    }

    /// A 2px rounded accent left-edge bar (shared by project + session rows).
    private func accentBar(_ color: NSColor) -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1
        bar.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        bar.layer?.backgroundColor = color.cgColor
        return bar
    }

    // MARK: – Project rename / recolor (right-click context menu)

    /// Preset project tints (mockup-friendly muted tones). "Custom…" opens the
    /// system color panel; "Reset" clears back to the accent.
    private static let colorPresets: [(String, NSColor)] = [
        ("Mint",   NSColor(srgbRed: 0.55, green: 0.73, blue: 0.66, alpha: 1)),
        ("Blue",   NSColor(srgbRed: 0.46, green: 0.62, blue: 0.80, alpha: 1)),
        ("Violet", NSColor(srgbRed: 0.64, green: 0.56, blue: 0.82, alpha: 1)),
        ("Amber",  NSColor(srgbRed: 0.85, green: 0.68, blue: 0.40, alpha: 1)),
        ("Rose",   NSColor(srgbRed: 0.84, green: 0.52, blue: 0.56, alpha: 1)),
        ("Slate",  NSColor(srgbRed: 0.58, green: 0.60, blue: 0.64, alpha: 1)),
    ]

    private func makeProjectMenu(_ pi: Int, name: String, hasColor: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(BlockMenuItem(title: "Rename…") { [weak self] in self?.promptRename(pi, current: name) })

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for (label, color) in Self.colorPresets {
            let item = BlockMenuItem(title: label) { [weak self] in self?.onSetProjectColor(pi, color) }
            item.image = Self.swatch(color)
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())
        colorMenu.addItem(BlockMenuItem(title: "Reset to accent") { [weak self] in self?.onSetProjectColor(pi, nil) })
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(title: "Remove Project") { [weak self] in
            self?.confirmRemove(pi, name: name)
        })
        return menu
    }

    /// Removing a project tears down its live terminal sessions — confirm first.
    private func confirmRemove(_ pi: Int, name: String) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "This closes the project's sessions and any running programs in them."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { onRemoveProject(pi) }
    }

    /// 12×12 filled rounded swatch for the color submenu.
    private static func swatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let img = NSImage(size: size)
        img.lockFocus()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3).addClip()
        color.setFill(); NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    /// Lazy native rename: a small modal NSAlert with a text field.
    private func promptRename(_ pi: Int, current: String) {
        let alert = NSAlert()
        alert.messageText = "Rename project"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            onRenameProject(pi, field.stringValue)
        }
    }

    // MARK: – Shared helpers

    /// Tiny SF Symbol button with a block action (avoids selector boilerplate for inline lambdas).
    private func tinyButton(symbol: String, action: @escaping () -> Void) -> NSButton {
        let btn = BlockButton(action: action)
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.title = ""
        btn.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .light)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        btn.contentTintColor = txt(.faint)
        return btn
    }

    /// Tiny uppercase dim label with wide letter-spacing + right-aligned count.
    private func sectionLabel(_ s: String, count: String) -> NSView {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: Fonts.inst(9.5),
            .foregroundColor: txt(.faint),
            .kern: 1.3,
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
            c.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -36), // leave room for + btn
            c.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 16),
        ])
        return row
    }

    /// Footer: status line(s) atop a hairline, then a dim version line.
    private func makeFooter() -> NSView {
        let block = NSView()
        block.translatesAutoresizingMaskIntoConstraints = false

        let topHair = NSView()
        topHair.translatesAutoresizingMaskIntoConstraints = false
        topHair.wantsLayer = true
        topHair.layer?.backgroundColor = hair(0.07).cgColor

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

    // MARK: – Titlebar accessory (toggle · folder · dir)

    private func buildTitlebarAccessory() {
        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .leading

        // ponytail: wide fixed frame — tabs gone from top strip so full width is free.
        // 700 gives plenty of room for the dir label without clipping.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: max(240, 700), height: 30))

        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.title = ""
        btn.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .light)
        btn.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle sidebar")?
            .withSymbolConfiguration(cfg)
        btn.contentTintColor = txt(.dim)
        btn.target = self
        btn.action = #selector(toggleSidebarAction)
        toggleButton = btn

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
            dirLabel.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -10),
        ])

        acc.view = host
        window?.addTitlebarAccessoryViewController(acc)
    }

    /// "name / path" → name bold (full), "/" faint, path dim. 11.5px.
    private func dirAttributed(_ raw: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
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

    // MARK: – Actions

    @objc private func toggleSidebarAction() { toggleSidebar() }

    func toggleSidebar() {
        sidebarOpen.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            // Use openWidth (updated by drag) so ⌘B restores to whatever drag set.
            sidebarWidth.animator().constant = sidebarOpen ? openWidth : 0
            sidebar.superview?.layoutSubtreeIfNeeded()
        }
        updateToggleTint()
    }

    private func updateToggleTint() {
        toggleButton?.contentTintColor = txt(.dim)
    }
}

// MARK: – Supporting types

/// A row/view that carries two integer indices for gesture handlers.
/// Index values are read at tap-time from the view — never captured in closures
/// that outlive a setProjects rebuild — so they cannot go stale.
final class TaggedRow: NSView {
    var tag1 = 0   // project index
    var tag2 = 0   // session index (unused for project rows)
    var onClick: (() -> Void)?

    // Claim every click on the row EXCEPT over real buttons (the +/× actions).
    // Decorative subviews (labels, caret, dot) would otherwise swallow the click
    // and the row's mouseDown would never fire — that's why collapse/select looked dead.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : (bounds.contains(convert(point, from: superview)) ? self : hit)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    // Light hover highlight so rows feel interactive.
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        if (layer?.backgroundColor.flatMap { $0.alpha } ?? 0) < 0.01 {
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
        }
    }
    override func mouseExited(with event: NSEvent) {
        if let bg = layer?.backgroundColor, bg.alpha <= 0.05 {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// NSMenuItem with a stored closure — avoids @objc/#selector for inline menu actions.
private final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void
    init(title: String, block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { block() }
}

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

/// Drag-resize grab strip: 5px wide, sets resize-left-right cursor, fires onDrag(delta).
private final class SidebarGrabView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with e: NSEvent) {
        lastX = e.locationInWindow.x
    }

    override func mouseDragged(with e: NSEvent) {
        let x = e.locationInWindow.x
        let delta = x - lastX
        lastX = x
        onDrag?(delta)
    }
}

/// NSButton subclass that stores a block action — avoids `@objc` / `#selector`
/// boilerplate for inline lambdas in row builders.
private final class BlockButton: NSButton {
    private var block: () -> Void
    init(action: @escaping () -> Void) {
        self.block = action
        super.init(frame: .zero)
        self.target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { block() }
}

// MARK: – Comparable clamp helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: – Self-check

@MainActor func chromeSelfCheck() {
    // Build with a couple of SidebarProject values: one active+expanded with 2 sessions,
    // one collapsed. Pure AppKit — no Workspace/ghostty involved.
    let wc = HaloWindowController(theme: Theme(), content: NSView())
    assert(wc.window != nil, "window must exist")

    let s1 = SidebarSession(label: "shell", active: true)
    let s2 = SidebarSession(label: "vim",   active: false)
    let projects: [SidebarProject] = [
        SidebarProject(name: "halo",  branch: "main", expanded: true,  active: true,  sessions: [s1, s2]),
        SidebarProject(name: "relay", branch: nil,    expanded: false, active: false, sessions: []),
    ]
    wc.setProjects(projects)

    // Calling setProjects again must not crash (rebuild without leaking constraints)
    wc.setProjects(projects)

    wc.setStatus("▌ normal · ⎇ main ↑1 · 2 dirty")
    wc.setDir("halo / ~/dev/halo")

    // toggleSidebar twice must leave sidebar open and not crash
    wc.toggleSidebar(); wc.toggleSidebar()

    assert(wc.window?.contentView?.subviews.count ?? 0 >= 2, "sidebar + content present")
    print("chromeSelfCheck OK")
}
