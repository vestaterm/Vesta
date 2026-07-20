import AppKit

/// A small native settings panel for the common `vesta-*` keys. Each control
/// writes straight to Vesta's own config (creating it, seeded from ghostty).
/// Sidebar width applies live; colors/fonts/divider apply on relaunch.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let onSidebarWidth: (CGFloat) -> Void
    private let onImport: () -> Void
    private let onOpenConfig: () -> Void
    private let onReload: () -> Void
    private let onReset: () -> Void
    private var configView: NSTextView?   // full-config editor (any ghostty key)
    private var accent: NSColor = .controlAccentColor   // selection rings in the icon grid
    private var iconCells: [IconCell] = []
    private var pluginBoxes: [NSButton] = []   // for the plugin filter field
    private var lockRows: [(key: String, control: NSView, badge: NSTextField)] = []   // Lua-ownable rows

    init(theme: Theme,
         onSidebarWidth: @escaping (CGFloat) -> Void,
         onImport: @escaping () -> Void,
         onOpenConfig: @escaping () -> Void,
         onReload: @escaping () -> Void,
         onReset: @escaping () -> Void) {
        self.onSidebarWidth = onSidebarWidth
        self.onImport = onImport
        self.onOpenConfig = onOpenConfig
        self.onReload = onReload
        self.onReset = onReset
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Vesta Settings"
        win.minSize = NSSize(width: 460, height: 520)
        super.init(window: win)
        build(theme: theme)
        refreshLocks()
        win.center()
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    private func build(theme: Theme) {
        let cfg = VestaConfig.shared
        accent = cfg.accent ?? theme.accent

        // Dark, app-consistent chrome (the rest of Vesta is near-black).
        window?.appearance = NSAppearance(named: .darkAqua)
        window?.backgroundColor = NSColor(white: 0.12, alpha: 1)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Each section: an uppercase header + a rounded card holding its rows.
        func addSection(_ title: String, _ rows: [NSView]) {
            let h = sectionHeader(title)
            stack.addArrangedSubview(h)
            let c = card(rows)
            stack.addArrangedSubview(c)
            c.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(7, after: h)
            stack.setCustomSpacing(22, after: c)
        }

        // ── App Icon ──────────────────────────────────────────────────────────────
        if !AboutWindowController.loadVariants().isEmpty {
            let caption = NSTextField(wrappingLabelWithString:
                "Click a flame to set the app icon. It’s written onto Vesta.app, so it sticks in Finder and the Dock — and survives quitting and updates.")
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = NSColor(white: 0.5, alpha: 1)
            caption.preferredMaxLayoutWidth = 392
            addSection("App Icon", [iconGrid(), caption])
        }

        // ── Appearance ──────────────────────────────────────────────────────────────
        let accentWell = NSColorWell(); accentWell.color = cfg.accent ?? theme.accent
        accentWell.target = self; accentWell.action = #selector(accentChanged(_:))
        let surface = NSColorWell(); surface.color = cfg.surface ?? theme.background
        surface.target = self; surface.action = #selector(surfaceChanged(_:))
        // Terminal background = ghostty's own `background` key (what libghostty paints
        // behind text). Distinct from Surface (Vesta's chrome). Applies on Reload.
        let termBG = NSColorWell()
        termBG.color = GhosttyApp.shared.settings["background"]
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .flatMap(PanelOverlay.hexColor) ?? theme.background
        termBG.target = self; termBG.action = #selector(termBGChanged(_:))
        addSection("Appearance", [
            row("Accent", accentWell, key: "vesta-accent"),
            row("Surface", surface, key: "vesta-surface"),
            row("Terminal bg", termBG, key: "background"),
        ])

        // ── Typography ────────────────────────────────────────────────────────────
        addSection("Typography", [
            row("Font", fontPopup(), key: "vesta-font-family"),
            row("Font size", slider(Double(cfg.fontScale * 13), 9, 22, #selector(fontChanged(_:))), key: "vesta-font-size"),
        ])

        // ── Layout ──────────────────────────────────────────────────────────────────
        addSection("Layout", [
            row("Sidebar width", slider(Double(cfg.sidebarWidth), 160, 420, #selector(sidebarChanged(_:))), key: "vesta-sidebar-width"),
            row("Divider width", slider(Double(cfg.dividerWidth), 1, 14, #selector(dividerChanged(_:))), key: "vesta-divider-width"),
        ])

        // ── Plugins — enable/disable installed Lua plugins (reloads on toggle) ──────
        let installed = LuaRuntime.shared.installedPlugins()
        if !installed.isEmpty {
            let disabled = LuaRuntime.shared.disabledPlugins()
            pluginBoxes = installed.map { name in
                // Ellipsize over-long names for display; keep the full name in `identifier`
                // (NSButton resists shrinking, so layout-based truncation is unreliable —
                // we truncate the string instead). toggle + filter read the identifier.
                let shown = name.count > 40 ? String(name.prefix(39)) + "…" : name
                let cb = NSButton(checkboxWithTitle: shown, target: self, action: #selector(pluginToggled(_:)))
                cb.identifier = NSUserInterfaceItemIdentifier(name)
                cb.toolTip = name
                cb.state = disabled.contains(name) ? .off : .on
                return cb
            }
            let list = NSStackView(views: pluginBoxes)
            list.orientation = .vertical; list.alignment = .leading; list.spacing = 7
            list.translatesAutoresizingMaskIntoConstraints = false
            let listScroll = NSScrollView()
            listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true
            listScroll.drawsBackground = false
            listScroll.translatesAutoresizingMaskIntoConstraints = false
            let listDoc = FlippedView(); listDoc.translatesAutoresizingMaskIntoConstraints = false
            listDoc.addSubview(list)
            listScroll.documentView = listDoc
            NSLayoutConstraint.activate([
                list.leadingAnchor.constraint(equalTo: listDoc.leadingAnchor),
                list.trailingAnchor.constraint(equalTo: listDoc.trailingAnchor),
                list.topAnchor.constraint(equalTo: listDoc.topAnchor, constant: 2),
                list.bottomAnchor.constraint(equalTo: listDoc.bottomAnchor, constant: -2),
                listDoc.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
            ])
            // Cap the visible height so hundreds of plugins scroll instead of stretching
            // the page; small lists size to their content.
            let h = min(CGFloat(installed.count) * 21 + 6, 168)
            listScroll.heightAnchor.constraint(equalToConstant: h).isActive = true

            var rows: [NSView] = []
            var search: NSSearchField?
            if installed.count > 8 {   // a filter only earns its place once the list is long
                let s = NSSearchField()
                s.placeholderString = "Filter \(installed.count) plugins"
                s.target = self; s.action = #selector(filterPlugins(_:))
                search = s; rows.append(s)
            }
            rows.append(listScroll)
            addSection("Plugins", rows)
            search?.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
            listScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }

        // ── Configuration — full editor; accepts ANY ghostty key ────────────────────
        let note = NSTextField(wrappingLabelWithString:
            "Sidebar width applies live. Reload applies colors, fonts, theme, and edited config. The editor takes any ghostty option (ghostty.org/docs/config).")
        note.font = .systemFont(ofSize: 11); note.textColor = NSColor(white: 0.5, alpha: 1)
        note.preferredMaxLayoutWidth = 392

        let btns = NSStackView(views: [
            button("Import ghostty config", #selector(importTapped)),
            button("Open config file", #selector(openTapped)),
            button("Reset", #selector(resetTapped)),
        ])
        btns.orientation = .horizontal; btns.spacing = 8

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.string = currentConfigText()
        scroll.documentView = tv
        self.configView = tv
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let saveRow = NSStackView(views: [button("Reload", #selector(reloadTapped)), button("Save config", #selector(saveConfigTapped))])
        saveRow.orientation = .horizontal; saveRow.spacing = 8

        addSection("Configuration", [note, btns, scroll, saveRow])
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true   // fill the card

        // Everything lives in a vertical scroll view so the window never outgrows the
        // screen — the content is tall, so we scroll it inside a fixed-height window.
        let content = window!.contentView!
        let page = NSScrollView()
        page.hasVerticalScroller = true
        page.autohidesScrollers = true
        page.drawsBackground = false
        page.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        page.documentView = doc
        content.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.topAnchor.constraint(equalTo: content.topAnchor),
            page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: page.contentView.widthAnchor),   // no horizontal scroll
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -22),
        ])
        // Open at a height that fits on-screen (scroll handles the overflow).
        if let vis = NSScreen.main?.visibleFrame {
            window?.setContentSize(NSSize(width: 480, height: min(720, vis.height - 80)))
            window?.center()
        }
    }

    // MARK: - icon picker + section chrome

    private func iconGrid() -> NSView {
        let variants = AboutWindowController.loadVariants()
        let saved = UserDefaults.standard.string(forKey: AboutWindowController.iconKey) ?? variants.first?.name
        iconCells = variants.map { v in
            IconCell(name: v.name, image: v.image, selected: v.name == saved, accent: accent) { [weak self] n in self?.pickIcon(n) }
        }
        // Rows of 6, packed left (a stretched NSGridView spread them across the width).
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        var i = 0
        while i < iconCells.count {
            let r = NSStackView(views: Array(iconCells[i ..< min(i + 6, iconCells.count)]))
            r.orientation = .horizontal; r.spacing = 10; r.alignment = .centerY
            grid.addArrangedSubview(r)
            i += 6
        }
        return grid
    }

    private func pickIcon(_ name: String) {
        AboutWindowController.applyIcon(named: name)
        for c in iconCells { c.selected = (c.name == name) }
    }

    private func sectionHeader(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.attributedStringValue = NSAttributedString(string: s.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.5, alpha: 1),
            .kern: 0.8,
        ])
        return l
    }

    private func card(_ rows: [NSView]) -> NSView {
        let inner = NSStackView(views: rows)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        let v = CardView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -14),
        ])
        return v
    }

    /// Vesta's current config text — the editable file if it exists, else the
    /// ghostty config it would import from, else empty.
    private func currentConfigText() -> String {
        if let t = try? String(contentsOfFile: vestaConfigPath(), encoding: .utf8) { return t }
        if let src = ghosttyConfigPath(), let t = try? String(contentsOfFile: src, encoding: .utf8) { return t }
        return ""
    }

    private func row(_ label: String, _ control: NSView, key: String? = nil) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 12)
        l.textColor = NSColor(white: 0.78, alpha: 1)
        l.alignment = .left
        l.widthAnchor.constraint(equalToConstant: 104).isActive = true
        var views: [NSView] = [l, control]
        // Lua wins: a key set via vesta.set is Lua-owned — disable the control and badge
        // it with the owning script. Evaluated in refreshLocks (not here) so a reload
        // that drops the override (plugin disabled, line removed) unlocks live.
        if let key {
            let badge = NSTextField(labelWithString: "")
            badge.font = .systemFont(ofSize: 10); badge.textColor = .secondaryLabelColor
            views.append(badge)
            lockRows.append((key, control, badge))
        }
        let r = NSStackView(views: views)
        r.orientation = .horizontal; r.spacing = 10; r.alignment = .centerY
        return r
    }

    /// Re-evaluate which rows are Lua-owned. Called at build and after every config
    /// reload — overrides are rebuilt from the scripts that actually ran, so a
    /// disabled plugin's lock disappears without an app restart.
    func refreshLocks() {
        for (key, control, badge) in lockRows {
            let owner = luaConfigOverrideOwner[key]
            (control as? NSControl)?.isEnabled = owner == nil
            badge.stringValue = owner.map { "· set by \($0)" } ?? ""
            badge.isHidden = owner == nil
        }
    }
    private func slider(_ v: Double, _ lo: Double, _ hi: Double, _ action: Selector) -> NSSlider {
        let s = NSSlider(value: v, minValue: lo, maxValue: hi, target: self, action: action)
        s.widthAnchor.constraint(equalToConstant: 200).isActive = true
        s.isContinuous = true
        return s
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 11)
        return b
    }

    /// ghostty's built-in default terminal font (used when `font-family` is unset).
    private static let defaultFontFamily = "JetBrains Mono"
    private static let defaultSuffix = " (default)"

    /// Terminal font picker (ghostty `font-family`). Bundled families first, then
    /// every installed family; the default is tagged "(default)". Applies + reloads.
    private func fontPopup() -> NSPopUpButton {
        let p = NSPopUpButton()
        p.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let def = Self.defaultFontFamily
        var bundled = ["Geist Mono", "Martian Mono",
                       "Redaction", "Redaction 10", "Redaction 20", "Redaction 35",
                       "Redaction 50", "Redaction 70", "Redaction 100"]
        // Ensure the default appears even if it isn't an installed family.
        let installed = NSFontManager.shared.availableFontFamilies.sorted()
        if !installed.contains(def) && !bundled.contains(def) { bundled.insert(def, at: 0) }
        let label = { (fam: String) in fam == def ? fam + Self.defaultSuffix : fam }
        p.addItems(withTitles: bundled.map(label))
        p.menu?.addItem(.separator())
        p.addItems(withTitles: installed.map(label))

        let current = GhosttyApp.shared.settings["font-family"]?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        // Select the configured font, else the default entry.
        p.selectItem(withTitle: label(current?.isEmpty == false ? current! : def))
        p.target = self; p.action = #selector(fontFamilyChanged(_:))
        return p
    }

    // Each control persists immediately to Vesta's config.
    @objc private func accentChanged(_ s: NSColorWell)  { setVestaConfigKey("vesta-accent", hexString(s.color)) }
    @objc private func surfaceChanged(_ s: NSColorWell) { setVestaConfigKey("vesta-surface", hexString(s.color)) }
    @objc private func termBGChanged(_ s: NSColorWell)  { setVestaConfigKey("background", hexString(s.color)); onReload() }
    @objc private func sidebarChanged(_ s: NSSlider) {
        setVestaConfigKey("vesta-sidebar-width", "\(Int(s.doubleValue))")
        onSidebarWidth(CGFloat(s.doubleValue))   // live
    }
    @objc private func fontChanged(_ s: NSSlider)    { setVestaConfigKey("vesta-font-size", "\(Int(s.doubleValue))") }
    @objc private func dividerChanged(_ s: NSSlider) { setVestaConfigKey("vesta-divider-width", "\(Int(s.doubleValue))") }
    /// Write the editor's full text to Vesta's config, then offer to relaunch so
    /// libghostty re-reads it (colors/font/theme need a fresh config load).
    @objc private func saveConfigTapped() {
        guard let text = configView?.string else { return }
        let path = vestaConfigPath()
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)

        onReload()
    }

    /// Change the terminal font (ghostty `font-family`) and apply immediately.
    @objc private func fontFamilyChanged(_ p: NSPopUpButton) {
        guard let title = p.titleOfSelectedItem else { return }
        let name = title.hasSuffix(Self.defaultSuffix)
            ? String(title.dropLast(Self.defaultSuffix.count)) : title
        setVestaConfigKey("font-family", name)
        configView?.string = currentConfigText()
        onReload()
    }

    /// Delete Vesta's config (revert to ghostty config / defaults), then reload.
    @objc private func resetTapped() {
        let a = NSAlert()
        a.messageText = "Reset Vesta config?"
        a.informativeText = "Deletes your Vesta config and reverts to your ghostty config / defaults."
        a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        onReset()
        configView?.string = currentConfigText()
    }

    /// Filter the (potentially huge) plugin list by substring — hidden rows collapse out
    /// of the stack so scrolling stays short.
    @objc private func filterPlugins(_ f: NSSearchField) {
        let q = f.stringValue.lowercased()
        for cb in pluginBoxes {
            let name = cb.identifier?.rawValue ?? cb.title
            cb.isHidden = !(q.isEmpty || name.lowercased().contains(q))
        }
    }

    @objc private func pluginToggled(_ b: NSButton) {
        LuaRuntime.shared.setPluginEnabled(b.identifier?.rawValue ?? b.title, b.state == .on)
        onReload()
    }

    @objc private func importTapped() { onImport() }
    @objc private func openTapped()   { onOpenConfig() }
    @objc private func reloadTapped() { onReload() }
}

/// Top-down document view for the settings scroll view (default NSView is bottom-up).
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Subtle rounded background for a settings section.
private final class CardView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor(white: 1, alpha: 0.05).setFill(); p.fill()
        NSColor(white: 1, alpha: 0.09).setStroke(); p.lineWidth = 1; p.stroke()
    }
}

/// A clickable app-icon thumbnail with an accent selection ring.
private final class IconCell: NSView {
    let name: String
    private let onPick: (String) -> Void
    private let accent: NSColor
    var selected: Bool { didSet { needsDisplay = true } }

    init(name: String, image: NSImage, selected: Bool, accent: NSColor, onPick: @escaping (String) -> Void) {
        self.name = name; self.onPick = onPick; self.accent = accent; self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let iv = NSImageView(image: image)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 52),
            heightAnchor.constraint(equalToConstant: 52),
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            iv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            iv.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            iv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSBezierPath(roundedRect: r, xRadius: 13, yRadius: 13).fill(with: NSColor(white: 1, alpha: selected ? 0.10 : 0.04))
        if selected {
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 12.5, yRadius: 12.5)
            accent.setStroke(); ring.lineWidth = 2; ring.stroke()
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onPick(name) }
}

private extension NSBezierPath {
    func fill(with color: NSColor) { color.setFill(); fill() }
}
