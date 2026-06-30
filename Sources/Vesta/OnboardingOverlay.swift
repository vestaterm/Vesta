import AppKit
import CoreImage

/// First-run onboarding: a full-window overlay shown exactly once (gated on the
/// `VestaDidOnboard` UserDefaults flag — a plain bool, never keyed to version, so
/// app updates don't re-trigger it). Flow: V-flame intro animation → a short
/// feature tour → install the `vesta` CLI → add a first project. Every step is
/// skippable; the top-right Skip ends the whole thing. Respects Reduce Motion.
final class OnboardingOverlay: NSView {
    private let theme: Theme
    private let addProject: (String) -> Void
    private let onFinish: () -> Void

    private let mark = OnboardingMark()
    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let actionBtn = OnboardPad(title: "")          // step-specific (Install / Choose folder…)
    private let statusLabel = NSTextField(labelWithString: "")
    private let backBtn = OnboardPad(title: "Back")
    private let nextBtn = OnboardPad(title: "Next", filled: true)
    private let dots = NSStackView()

    // Pages after the intro. The intro is page -1 (animation), auto-advancing to 0.
    private enum Page: Int, CaseIterable { case welcome, tour1, tour2, tour3, cli, project }
    private var page = Page.welcome
    private var inIntro = true
    private var markCenterY: NSLayoutConstraint!

    init(theme: Theme, addProject: @escaping (String) -> Void, onFinish: @escaping () -> Void) {
        self.theme = theme; self.addProject = addProject; self.onFinish = onFinish
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        build()
        if reduceMotion { inIntro = false; mark.showClean(); render() }
        else { mark.animate { [weak self] in self?.endIntro() } }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override func draw(_ dirtyRect: NSRect) {
        // Solid branded fill — onboarding owns a full-screen window of its own.
        theme.background.setFill(); dirtyRect.fill()
    }

    private func build() {
        let pink = NSColor(srgbRed: 1, green: 0x3d/255.0, blue: 0x7a/255.0, alpha: 1)

        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.alphaValue = reduceMotion ? 1 : 0   // hidden behind the intro until it ends
        addSubview(card)

        titleLabel.font = Fonts.inst(26)
        titleLabel.textColor = NSColor(white: 0.97, alpha: 1)
        titleLabel.usesSingleLineMode = false
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.preferredMaxLayoutWidth = 460
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.font = Fonts.mono(13.5)
        bodyLabel.textColor = NSColor(white: 0.72, alpha: 1)
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Fonts.mono(12)
        statusLabel.textColor = pink
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        actionBtn.onClick = { [weak self] in self?.runAction() }
        backBtn.onClick = { [weak self] in self?.goBack() }
        nextBtn.onClick = { [weak self] in self?.goNext() }

        dots.orientation = .horizontal; dots.spacing = 7
        dots.translatesAutoresizingMaskIntoConstraints = false
        for _ in Page.allCases { dots.addArrangedSubview(Dot()) }

        let skip = NSTextField(labelWithString: "Skip")
        skip.font = Fonts.mono(12); skip.textColor = NSColor(white: 0.5, alpha: 1)
        skip.translatesAutoresizingMaskIntoConstraints = false
        let skipClick = NSClickGestureRecognizer(target: self, action: #selector(skipAll))
        skip.addGestureRecognizer(skipClick)
        addSubview(skip)

        let nav = NSStackView(views: [backBtn, nextBtn])
        nav.orientation = .horizontal; nav.spacing = 10
        nav.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(titleLabel); card.addSubview(bodyLabel)
        card.addSubview(actionBtn); card.addSubview(statusLabel)
        card.addSubview(dots); card.addSubview(nav)

        markCenterY = mark.centerYAnchor.constraint(equalTo: centerYAnchor, constant: reduceMotion ? -150 : 0)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            markCenterY,
            mark.widthAnchor.constraint(equalToConstant: 180),
            mark.heightAnchor.constraint(equalToConstant: 180),

            skip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            skip.topAnchor.constraint(equalTo: topAnchor, constant: 22),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 24),
            card.widthAnchor.constraint(equalToConstant: 460),
            // Fixed height: title/body flow from the top, controls are pinned to the bottom,
            // so dots + nav stay put across slides regardless of body length.
            card.heightAnchor.constraint(equalToConstant: 300),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            // Bottom row: dots (left) + Back/Next (right), both pinned to the card bottom.
            dots.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            dots.centerYAnchor.constraint(equalTo: nav.centerYAnchor),
            nav.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            nav.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            // Action button sits just above the bottom row, fixed — not chained to body length.
            actionBtn.bottomAnchor.constraint(equalTo: nav.topAnchor, constant: -22),
            actionBtn.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: actionBtn.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: actionBtn.trailingAnchor, constant: 14),
        ])
        if !reduceMotion { render() }   // pre-fill so the fade-in reveals real content
    }

    // MARK: - Intro

    private func endIntro() {
        inIntro = false
        render()
        markCenterY.constant = -150   // slide the mark up to make room for the card
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            ctx.allowsImplicitAnimation = true
            mark.animator().alphaValue = 1
            card.animator().alphaValue = 1
            layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Navigation

    private func goNext() {
        guard !inIntro else { return }   // card buttons are invisible during the intro; ignore stray hits
        if let next = Page(rawValue: page.rawValue + 1) { page = next; render() }
        else { finish() }   // past the last page → done
    }
    private func goBack() {
        guard !inIntro else { return }
        if let prev = Page(rawValue: page.rawValue - 1) { page = prev; render() }
    }
    @objc private func skipAll() { finish() }

    private func runAction() {
        switch page {
        case .cli: installCLI()
        case .project: pickProject()
        default: break
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "VestaDidOnboard")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.onFinish()
        }
    }

    // MARK: - Per-page content

    private func render() {
        let content: (title: String, body: String, action: String?) = {
            switch page {
            case .welcome: return ("Welcome to Vesta",
                "A native macOS terminal built on real libghostty — persistent sessions, tmux-style splits, and a scriptable CLI. A quick tour, then we'll get you set up.", nil)
            case .tour1: return ("Sessions that outlive the app",
                "Your shells run under a tiny daemon, not the window. Quit Vesta with ⌘Q, reopen it, and every pane comes back — same shell, recent output and all.", nil)
            case .tour2: return ("Splits & a project sidebar",
                "⌘D / ⌘⇧D split a pane; click to focus, ⌘B toggles the sidebar. Projects own sessions down the left — drag to resize, right-click to rename or recolor.", nil)
            case .tour3: return ("Drive it from the CLI — and Lua",
                "The `vesta` command talks to the live app over a socket, so agents can open, split, and read panes. Drop an `init.lua` in ~/.config/vesta/plugins to script it yourself.", nil)
            case .cli: return ("Install the `vesta` command",
                "Copies vesta, vestad and vesta-attach to /usr/local/bin so the CLI works from any terminal. Needs your password (writing to a system path).", "Install CLI")
            case .project: return ("Add your first project",
                "Pick a folder to open as your first project. A session starts there right away — you can add more any time from the sidebar.", "Choose folder…")
            }
        }()

        titleLabel.stringValue = content.title
        bodyLabel.attributedStringValue = styledBody(content.body)
        statusLabel.stringValue = ""
        if let a = content.action { actionBtn.title = a; actionBtn.isHidden = false }
        else { actionBtn.isHidden = true }

        backBtn.isHidden = (page == .welcome)
        nextBtn.title = (page == .project) ? "Get started" : "Next"

        for (i, v) in dots.arrangedSubviews.enumerated() {
            (v as? Dot)?.on = (i == page.rawValue)
        }
    }

    /// Body text with `backtick` spans accented + monospaced, matching the landing's voice.
    private func styledBody(_ s: String) -> NSAttributedString {
        let base = Fonts.mono(13.5)
        let out = NSMutableAttributedString(string: s, attributes: [
            .font: base, .foregroundColor: NSColor(white: 0.72, alpha: 1),
        ])
        let pink = NSColor(srgbRed: 1, green: 0x3d/255.0, blue: 0x7a/255.0, alpha: 1)
        let str = s as NSString
        var search = NSRange(location: 0, length: str.length)
        while true {
            let open = str.range(of: "`", options: [], range: search)
            if open.location == NSNotFound { break }
            let afterOpen = NSRange(location: open.location + 1, length: str.length - open.location - 1)
            let close = str.range(of: "`", options: [], range: afterOpen)
            if close.location == NSNotFound { break }
            let span = NSRange(location: open.location, length: close.location - open.location + 1)
            out.addAttribute(.foregroundColor, value: pink, range: span)
            search = NSRange(location: close.location + 1, length: str.length - close.location - 1)
        }
        return out
    }

    // MARK: - CLI install

    private func installCLI() {
        guard let exe = Bundle.main.executablePath else { return }
        let dir = (exe as NSString).deletingLastPathComponent
        statusLabel.textColor = NSColor(white: 0.6, alpha: 1)
        statusLabel.stringValue = "installing…"
        // /usr/local/bin needs admin → AppleScript prompts for the password. Blocks, so
        // run it off-main. Main binary may be "Vesta" (bundle) or "vesta" (dev) — land it as "vesta".
        // Single-quote each path and escape any embedded quote so odd install paths don't break.
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "mkdir -p /usr/local/bin"
            + " && cp -f \(q(exe)) /usr/local/bin/vesta"
            + " && cp -f \(q(dir + "/vestad")) /usr/local/bin/vestad"
            + " && cp -f \(q(dir + "/vesta-attach")) /usr/local/bin/vesta-attach"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        DispatchQueue.global().async {
            var err: NSDictionary?
            let ok = NSAppleScript(source: script)?.executeAndReturnError(&err) != nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if ok {
                    self.statusLabel.textColor = NSColor(srgbRed: 1, green: 0x3d/255.0, blue: 0x7a/255.0, alpha: 1)
                    self.statusLabel.stringValue = "installed ✓"
                    self.actionBtn.isHidden = true
                } else {
                    self.statusLabel.textColor = NSColor(srgbRed: 0.9, green: 0.4, blue: 0.4, alpha: 1)
                    self.statusLabel.stringValue = "couldn't install — skip & run ./install.sh"
                }
            }
        }
    }

    // MARK: - First project

    private func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add project"
        panel.message = "Choose a folder to open as your first project"
        panel.begin { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            self.addProject(url.path)
            self.finish()
        }
    }

    // First responder so Esc skips the current step / intro.
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {            // Esc
            if inIntro { mark.stop(); endIntro() } else { goNext() }
        } else { super.keyDown(with: event) }
    }
    // Clicking during the intro skips straight to the tour.
    override func mouseDown(with event: NSEvent) {
        if inIntro { mark.stop(); endIntro() } else { super.mouseDown(with: event) }
    }
}

// MARK: - The V-flame mark (pixelate-resolve intro)

/// Renders the Vesta V-flame and runs the intro: square mosaic blocks shrink to
/// nothing while the fill resolves from pink → white (the landing-page motif).
private final class OnboardingMark: NSView {
    private var timer: Timer?
    private var t: CGFloat = 0          // 0 = corrupted (pink, big blocks), 1 = clean (white)
    private var onDone: (() -> Void)?
    private let ci = CIContext()

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    func animate(onDone: @escaping () -> Void) {
        self.onDone = onDone
        let total: CGFloat = 1.6, step: CGFloat = 1.0 / 60.0
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(step), repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            self.t = min(1, self.t + step / total)
            self.needsDisplay = true
            if self.t >= 1 { self.stop(); self.onDone?(); self.onDone = nil }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; t = 1; needsDisplay = true }
    func showClean() { t = 1; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let pink = NSColor(srgbRed: 1, green: 0x3d/255.0, blue: 0x7a/255.0, alpha: 1)
        // Fill resolves pink → white; ease so most of the color lands early.
        let e = t * t
        let color = blend(pink, .white, e)
        guard let base = renderFlame(color: color) else { return }
        let baseImg = NSImage(cgImage: base, size: bounds.size)

        if t >= 1 {
            baseImg.draw(in: bounds); return
        }
        // CIPixellate: block size big at t=0, → 1px as t→1. Center on the view.
        let scale = max(1, 30 * (1 - t))
        let input = CIImage(cgImage: base)
        let f = CIFilter(name: "CIPixellate")!
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: input.extent.midX, y: input.extent.midY), forKey: kCIInputCenterKey)
        f.setValue(scale, forKey: kCIInputScaleKey)
        guard let out = f.outputImage,
              let cg = ci.createCGImage(out, from: input.extent) else { baseImg.draw(in: bounds); return }
        NSImage(cgImage: cg, size: bounds.size).draw(in: bounds)
    }

    /// The V-monogram flame from assets/vesta-logo.svg, transcribed to a bezier and
    /// drawn upright (SVG y is top-down; AppKit origin is bottom-left → flip y).
    private func renderFlame(color: NSColor) -> CGImage? {
        let px = max(bounds.width, 1) * 2   // 2× for crispness
        guard let ctx = CGContext(data: nil, width: Int(px), height: Int(px),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = px / 512.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (512 - y) * s) }
        let path = CGMutablePath()
        path.move(to: p(188, 150))
        path.addCurve(to: p(252, 250), control1: p(196, 232), control2: p(236, 252))
        path.addCurve(to: p(256, 128), control1: p(232, 220), control2: p(236, 168))
        path.addCurve(to: p(322, 282), control1: p(300, 196), control2: p(322, 232))
        path.addLine(to: p(256, 392))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        return ctx.makeImage()
    }

    private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let a1 = a.usingColorSpace(.sRGB)!, b1 = b.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: a1.redComponent + (b1.redComponent - a1.redComponent) * t,
                       green: a1.greenComponent + (b1.greenComponent - a1.greenComponent) * t,
                       blue: a1.blueComponent + (b1.blueComponent - a1.blueComponent) * t,
                       alpha: 1)
    }
}

// MARK: - Small controls

/// A bordered text button matching ConfirmOverlay's pads. `filled` = accented primary.
private final class OnboardPad: NSView {
    var onClick: (() -> Void)?
    var title: String { didSet { label.stringValue = title } }
    private let label = NSTextField(labelWithString: "")
    private let filled: Bool

    init(title: String, filled: Bool = false) {
        self.title = title; self.filled = filled
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        let pink = NSColor(srgbRed: 1, green: 0x3d/255.0, blue: 0x7a/255.0, alpha: 1)
        layer?.backgroundColor = (filled ? pink.withAlphaComponent(0.18) : .clear).cgColor
        layer?.borderColor = (filled ? pink.withAlphaComponent(0.6) : NSColor(white: 1, alpha: 0.16)).cgColor
        label.stringValue = title
        label.font = Fonts.mono(12.5, medium: true)
        label.textColor = filled ? NSColor(white: 1, alpha: 1) : NSColor(white: 0.78, alpha: 1)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(hit)))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func hit() { onClick?() }
}

/// A page-indicator dot.
private final class Dot: NSView {
    var on = false { didSet { restyle() } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 3
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 6), heightAnchor.constraint(equalToConstant: 6),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func restyle() {
        let pink = NSColor(srgbRed: 1, green: 0x3d/255.0, blue: 0x7a/255.0, alpha: 1)
        layer?.backgroundColor = (on ? pink : NSColor(white: 1, alpha: 0.2)).cgColor
    }
}
