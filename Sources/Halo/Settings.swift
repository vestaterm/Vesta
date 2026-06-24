import AppKit

/// A small native settings panel for the common `halo-*` keys. Each control
/// writes straight to Halo's own config (creating it, seeded from ghostty).
/// Sidebar width applies live; colors/fonts/divider apply on relaunch.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let onSidebarWidth: (CGFloat) -> Void
    private let onImport: () -> Void
    private let onOpenConfig: () -> Void

    init(theme: Theme,
         onSidebarWidth: @escaping (CGFloat) -> Void,
         onImport: @escaping () -> Void,
         onOpenConfig: @escaping () -> Void) {
        self.onSidebarWidth = onSidebarWidth
        self.onImport = onImport
        self.onOpenConfig = onOpenConfig
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 360),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Halo Settings"
        super.init(window: win)
        build(theme: theme)
        win.center()
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    private func build(theme: Theme) {
        let cfg = HaloConfig.shared
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let accent = NSColorWell(); accent.color = cfg.accent ?? theme.accent
        accent.target = self; accent.action = #selector(accentChanged(_:))
        stack.addArrangedSubview(row("Accent", accent))

        let surface = NSColorWell(); surface.color = cfg.surface ?? theme.background
        surface.target = self; surface.action = #selector(surfaceChanged(_:))
        stack.addArrangedSubview(row("Surface", surface))

        stack.addArrangedSubview(row("Sidebar width",
            slider(Double(cfg.sidebarWidth), 160, 420, #selector(sidebarChanged(_:)))))
        stack.addArrangedSubview(row("Font size",
            slider(Double(cfg.fontScale * 13), 9, 22, #selector(fontChanged(_:)))))
        stack.addArrangedSubview(row("Divider width",
            slider(Double(cfg.dividerWidth), 1, 14, #selector(dividerChanged(_:)))))

        let note = NSTextField(labelWithString: "Sidebar width applies now; colors, font, and divider apply on relaunch.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping; note.preferredMaxLayoutWidth = 340
        stack.addArrangedSubview(note)

        let btns = NSStackView(views: [
            button("Import ghostty config", #selector(importTapped)),
            button("Open config file", #selector(openTapped)),
            button("Relaunch", #selector(relaunchTapped)),
        ])
        btns.orientation = .horizontal; btns.spacing = 8
        stack.addArrangedSubview(btns)

        let content = window!.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
        ])
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let r = NSStackView(views: [l, control])
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

    // Each control persists immediately to Halo's config.
    @objc private func accentChanged(_ s: NSColorWell)  { setHaloConfigKey("halo-accent", hexString(s.color)) }
    @objc private func surfaceChanged(_ s: NSColorWell) { setHaloConfigKey("halo-surface", hexString(s.color)) }
    @objc private func sidebarChanged(_ s: NSSlider) {
        setHaloConfigKey("halo-sidebar-width", "\(Int(s.doubleValue))")
        onSidebarWidth(CGFloat(s.doubleValue))   // live
    }
    @objc private func fontChanged(_ s: NSSlider)    { setHaloConfigKey("halo-font-size", "\(Int(s.doubleValue))") }
    @objc private func dividerChanged(_ s: NSSlider) { setHaloConfigKey("halo-divider-width", "\(Int(s.doubleValue))") }
    @objc private func importTapped() { onImport() }
    @objc private func openTapped()   { onOpenConfig() }
    @objc private func relaunchTapped() {
        let p = Bundle.main.bundlePath
        if p.hasSuffix(".app") {
            Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-n", p])
        }
        NSApp.terminate(nil)
    }
}
