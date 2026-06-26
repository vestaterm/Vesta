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
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Vesta Settings"
        win.minSize = NSSize(width: 420, height: 460)
        super.init(window: win)
        build(theme: theme)
        win.center()
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    private func build(theme: Theme) {
        let cfg = VestaConfig.shared
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let accent = NSColorWell(); accent.color = cfg.accent ?? theme.accent
        accent.target = self; accent.action = #selector(accentChanged(_:))
        stack.addArrangedSubview(row("Accent", accent, key: "vesta-accent"))

        let surface = NSColorWell(); surface.color = cfg.surface ?? theme.background
        surface.target = self; surface.action = #selector(surfaceChanged(_:))
        stack.addArrangedSubview(row("Surface", surface, key: "vesta-surface"))

        // Terminal background = ghostty's own `background` key (what libghostty paints
        // behind text). Distinct from Surface (Vesta's chrome). Applies on Reload.
        let termBG = NSColorWell()
        termBG.color = GhosttyApp.shared.settings["background"]
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .flatMap(PanelOverlay.hexColor) ?? theme.background
        termBG.target = self; termBG.action = #selector(termBGChanged(_:))
        stack.addArrangedSubview(row("Terminal bg", termBG, key: "background"))

        stack.addArrangedSubview(row("Font", fontPopup(), key: "vesta-font-family"))

        stack.addArrangedSubview(row("Sidebar width",
            slider(Double(cfg.sidebarWidth), 160, 420, #selector(sidebarChanged(_:))), key: "vesta-sidebar-width"))
        stack.addArrangedSubview(row("Font size",
            slider(Double(cfg.fontScale * 13), 9, 22, #selector(fontChanged(_:))), key: "vesta-font-size"))
        stack.addArrangedSubview(row("Divider width",
            slider(Double(cfg.dividerWidth), 1, 14, #selector(dividerChanged(_:))), key: "vesta-divider-width"))

        let note = NSTextField(labelWithString: "Sidebar width applies live; click Reload to apply colors, fonts, theme, and any edited config.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping; note.preferredMaxLayoutWidth = 340
        stack.addArrangedSubview(note)

        let btns = NSStackView(views: [
            button("Import ghostty config", #selector(importTapped)),
            button("Open config file", #selector(openTapped)),
            button("Reset config", #selector(resetTapped)),
            button("Reload", #selector(reloadTapped)),
        ])
        btns.orientation = .horizontal; btns.spacing = 8
        stack.addArrangedSubview(btns)

        // Plugins — enable/disable installed Lua plugins (reloads on toggle).
        let installed = LuaRuntime.shared.installedPlugins()
        if !installed.isEmpty {
            let ph = NSTextField(labelWithString: "Plugins")
            ph.font = .boldSystemFont(ofSize: 12)
            stack.addArrangedSubview(ph)
            let disabled = LuaRuntime.shared.disabledPlugins()
            for name in installed {
                let cb = NSButton(checkboxWithTitle: name, target: self, action: #selector(pluginToggled(_:)))
                cb.state = disabled.contains(name) ? .off : .on
                stack.addArrangedSubview(cb)
            }
        }

        // ── Full config editor — accepts ANY ghostty key (libghostty parses the
        // whole file), so this is the complete config surface, not just vesta-*.
        let header = NSTextField(labelWithString: "Config — any ghostty option (see ghostty.org/docs/config)")
        header.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(header)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.string = currentConfigText()
        scroll.documentView = tv
        self.configView = tv
        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(button("Save config", #selector(saveConfigTapped)))

        let content = window!.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
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
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
        var views: [NSView] = [l, control]
        // Lua wins: if init.lua sets this key, it's Lua-owned — disable the control and badge it.
        if let key, luaConfigOverrides[key] != nil {
            (control as? NSControl)?.isEnabled = false
            let badge = NSTextField(labelWithString: "· set by init.lua")
            badge.font = .systemFont(ofSize: 10); badge.textColor = .secondaryLabelColor
            views.append(badge)
        }
        let r = NSStackView(views: views)
        r.orientation = .horizontal; r.spacing = 10; r.alignment = .centerY
        return r
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

    @objc private func pluginToggled(_ b: NSButton) {
        LuaRuntime.shared.setPluginEnabled(b.title, b.state == .on)
        onReload()
    }

    @objc private func importTapped() { onImport() }
    @objc private func openTapped()   { onOpenConfig() }
    @objc private func reloadTapped() { onReload() }
}
