import AppKit

/// Custom About panel (replaces the stock one): app icon, name, tagline, then
/// Version / Build / Commit rows and Docs / GitHub buttons. Version/build/commit
/// come from the bundle (stamped by make-app.sh from the git tag + history).
/// Easter egg: click the icon to cycle through flame color + corruption variants.
@MainActor
final class AboutWindowController: NSWindowController {
    private let repo = "https://github.com/vestaterm/Vesta"
    private let docsURL = "https://vestaterm.github.io/vesta-site/docs.html"
    private let theme: Theme
    private var iconView: NSImageView!
    private var iconVariants: [(name: String, image: NSImage)] = []
    private var iconIdx = 0
    static let iconKey = "VestaIconVariant"   // persisted chosen-variant NAME (filename stem)

    init(theme: Theme) {
        self.theme = theme
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = NSColor(white: 0.16, alpha: 1)
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.center()
        super.init(window: win)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func info(_ key: String) -> String? { Bundle.main.infoDictionary?[key] as? String }

    private func build() {
        guard let content = window?.contentView else { return }

        // Easter egg: click the icon to cycle the Icon Composer flame variants (white →
        // pink → corruption stages), bundled under Resources/icon-variants. Falls back to the
        // live app icon if they're missing (e.g. the dev binary).
        iconVariants = Self.loadVariants()
        if iconVariants.isEmpty { iconVariants = [("", NSApp.applicationIconImage)] }
        let savedName = UserDefaults.standard.string(forKey: Self.iconKey)
        iconIdx = iconVariants.firstIndex(where: { $0.name == savedName }) ?? 0
        let icon = NSImageView(image: iconVariants[iconIdx].image)
        iconView = icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        icon.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(cycleIcon)))

        let name = NSTextField(labelWithString: "Vesta")
        name.font = .systemFont(ofSize: 28, weight: .bold)
        name.textColor = NSColor(white: 0.97, alpha: 1)
        name.alignment = .center

        let tagline = NSTextField(wrappingLabelWithString:
            "A native macOS terminal for running AI coding agents in parallel, built on libghostty.")
        tagline.font = .systemFont(ofSize: 12.5)
        tagline.textColor = NSColor(white: 0.62, alpha: 1)
        tagline.alignment = .center
        tagline.translatesAutoresizingMaskIntoConstraints = false
        tagline.widthAnchor.constraint(equalToConstant: 300).isActive = true

        // Version / Build / Commit grid.
        let version = info("CFBundleShortVersionString") ?? "0.0.0"
        let build = info("CFBundleVersion") ?? "—"
        let commit = info("VestaGitCommit") ?? ""
        var commitView: NSView = monoValue("—")
        if !commit.isEmpty {
            commitView = LinkLabel(text: commit, color: theme.accent) { [weak self] in
                guard let self, let u = URL(string: "\(self.repo)/commit/\(commit)") else { return }
                NSWorkspace.shared.open(u)
            }
        }
        let grid = NSGridView(views: [
            [rowLabel("Version"), monoValue(version)],
            [rowLabel("Build"), monoValue(build)],
            [rowLabel("Commit"), commitView],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowSpacing = 5
        grid.columnSpacing = 10
        // Pin the grid to its content width so the vertical stack's .centerX truly centers the
        // block (otherwise the grid stretches to the widest sibling and its columns sit left).
        grid.translatesAutoresizingMaskIntoConstraints = false
        let gw = grid.fittingSize.width
        if gw > 0 { grid.widthAnchor.constraint(equalToConstant: gw).isActive = true }

        let docs = textButton("Docs") { [weak self] in
            if let u = URL(string: self?.docsURL ?? "") { NSWorkspace.shared.open(u) }
        }
        let gh = textButton("GitHub") { [weak self] in
            if let u = URL(string: self?.repo ?? "") { NSWorkspace.shared.open(u) }
        }
        let buttons = NSStackView(views: [docs, gh])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, name, tagline, spacer(8), grid, spacer(10), buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(8, after: name)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let topPad: CGFloat = 26, botPad: CGFloat = 22
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: topPad),
        ])
        // Size the window snugly to the content (no big empty margins).
        content.layoutSubtreeIfNeeded()
        let h = topPad + stack.fittingSize.height + botPad
        window?.setContentSize(NSSize(width: 340, height: h))
        window?.center()
    }

    // MARK: - icon easter egg

    @objc private func cycleIcon() {
        guard iconVariants.count > 1 else { return }
        iconIdx = (iconIdx + 1) % iconVariants.count
        let next = iconVariants[iconIdx]
        iconView.wantsLayer = true
        // Crossfade: phase out, swap, phase back in.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            iconView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.iconView.image = next.image
            // Permanently apply the chosen variant (live tile + on-disk bundle icon + persist).
            Self.applyIcon(named: next.name)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.iconView.animator().alphaValue = 1
            }
        })
    }

    /// Bundled Icon Composer flame variants as (name, image) — name is the filename stem
    /// (e.g. "00-white"), sorted so the order is white → pink → corruption stages. Keyed by
    /// NAME (not position) so a missing/undecodable file can't shift the saved choice.
    static func loadVariants() -> [(name: String, image: NSImage)] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("icon-variants"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "icns" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in NSImage(contentsOf: url).map { (url.deletingPathExtension().lastPathComponent, $0) } }
    }

    /// The shipped-default variant name (the first, white); choosing it clears the custom icon.
    static var defaultVariant: String { loadVariants().first?.name ?? "" }

    /// Permanently switch the app icon to the variant named `name`: live Dock tile, write the
    /// icon onto the Vesta.app bundle (so Finder/Dock keep it while quit), and persist the
    /// choice. Re-applied on launch so it survives an in-place self-update. Returns whether
    /// the on-disk stamp succeeded (false e.g. on a read-only install — the live tile still
    /// updates, just not the on-quit Finder icon).
    @discardableResult
    static func applyIcon(named name: String) -> Bool {
        let variants = loadVariants()
        guard let v = variants.first(where: { $0.name == name }) ?? variants.first else { return false }
        NSApp.applicationIconImage = v.image   // live Dock tile while running
        UserDefaults.standard.set(v.name, forKey: iconKey)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        // The first variant (white) is the shipped default → clear any custom icon; else stamp
        // it. setIcon returns false if it can't write the bundle (read-only / non-admin).
        let isDefault = v.name == variants.first?.name
        return NSWorkspace.shared.setIcon(isDefault ? nil : v.image, forFile: Bundle.main.bundleURL.path, options: [])
    }

    // MARK: - small builders

    private func rowLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13)
        l.textColor = NSColor(white: 0.92, alpha: 1)
        return l
    }
    private func monoValue(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        l.textColor = NSColor(white: 0.7, alpha: 1)
        return l
    }
    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
    private func textButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.bezelStyle = .rounded
        return b
    }
}

/// A monospaced, accent-colored clickable value (the commit hash → opens GitHub). A text
/// field (not a button) so it shares the exact metrics/left-edge of the Version/Build values.
private final class LinkLabel: NSTextField {
    private let handler: () -> Void
    init(text: String, color: NSColor, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isEditable = false; isBordered = false; drawsBackground = false; isSelectable = false
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textColor = color
        stringValue = text
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(fire)))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    @objc private func fire() { handler() }
}

/// NSButton that runs a closure.
private final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        self.title = title
        target = self; self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
