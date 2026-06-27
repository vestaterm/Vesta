import AppKit

/// Custom About panel (replaces the stock one): app icon, name, tagline, then
/// Version / Build / Commit rows and Docs / GitHub buttons. Version/build/commit
/// come from the bundle (stamped by make-app.sh from the git tag + history).
@MainActor
final class AboutWindowController: NSWindowController {
    private let repo = "https://github.com/notnaki/Vesta"
    private let docsURL = "https://notnaki.github.io/vesta-site/docs.html"
    private let theme: Theme

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

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

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
