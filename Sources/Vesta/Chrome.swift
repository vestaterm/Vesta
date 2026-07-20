import AppKit

/// Window + chrome + collapsible projects sidebar.
/// Uniform surface everywhere; seamless slim titlebar that flows into content.
/// Matches the locked mockup: hairlines (white @0.07) do the separating, never
/// brightness steps. Near-gray mint accent for selection + glow.
@MainActor
final class VestaWindowController: NSWindowController {

    private var theme: Theme

    // one near-uniform surface tone — from ghostty `background` / `vesta-surface`
    private var surface: NSColor

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

    // MARK: – action closures (wired by AppDelegate)
    private let onSelectSession:   (Int, Int) -> Void
    private let onCloseSession:    (Int, Int) -> Void
    private let onNewSession:      (Int) -> Void
    private let onToggleExpand:    (Int) -> Void
    private let onNewProject:      () -> Void
    private let onRenameProject:   (Int, String) -> Void
    private let onRenameSession:   (Int, Int, String?) -> Void
    private let onSetProjectColor: (Int, NSColor?) -> Void
    private let onRemoveProject:   (Int) -> Void
    private let onNewWorktree:     (Int, String) -> Void
    private let onChangeProjectDir: () -> Void

    private var sidebar: NSView!
    private var sidebarWidth: NSLayoutConstraint!
    private var toggleButton: NSButton!
    private var sidebarOpen = true
    // Track the "open" width so ⌘B always restores to whatever drag set.
    private var openWidth: CGFloat

    private var footer: NSTextField!
    private var dirLabel: NSTextField!
    private weak var titlebarAccessory: NSView?   // host of toggle/folder/path/pill — hidden during onboarding
    private weak var bellAccessory: NSView?        // trailing host of the bell — hidden during onboarding
    private var bellButton: NSButton!
    private var bellDot: NSView!                  // unread indicator overlaid on the bell
    var onBell: (() -> Void)?                      // set by AppDelegate → opens the notifications panel

    // Prefix-mode "armed" indicator (shown in the titlebar while waiting for the
    // next key). Color comes from theme.accent — never hardcoded.
    private var prefixPill: NSTextField?

    // Mutable container for the projects stack — cleared+refilled by setProjects.
    private var projectsStack: NSStackView!
    private var projCount: NSTextField?      // PROJECTS count, pinned in the header (not scrolled)
    private var projScroll: NSScrollView?    // wraps the project list; appearance tracks surface

    init(theme: Theme, content: NSView,
         onSelectSession: @escaping (Int, Int) -> Void = { _, _ in },
         onCloseSession:  @escaping (Int, Int) -> Void = { _, _ in },
         onNewSession:    @escaping (Int) -> Void      = { _ in },
         onToggleExpand:  @escaping (Int) -> Void      = { _ in },
         onNewProject:    @escaping () -> Void          = {},
         onRenameProject:   @escaping (Int, String) -> Void      = { _, _ in },
         onRenameSession:   @escaping (Int, Int, String?) -> Void = { _, _, _ in },
         onSetProjectColor: @escaping (Int, NSColor?) -> Void     = { _, _ in },
         onRemoveProject:   @escaping (Int) -> Void          = { _ in },
         onNewWorktree:     @escaping (Int, String) -> Void  = { _, _ in },
         onChangeProjectDir: @escaping () -> Void            = {}) {
        self.theme = theme
        self.surface = theme.background
        // Restore the dragged sidebar width if saved, else the config default.
        let savedWidth = UserDefaults.standard.double(forKey: "VestaSidebarWidth")
        self.openWidth = savedWidth > 0 ? CGFloat(savedWidth) : CGFloat(VestaConfig.shared.sidebarWidth)
        // Restore collapsed/open state across launches (defaults to open).
        self.sidebarOpen = UserDefaults.standard.object(forKey: "VestaSidebarOpen") as? Bool ?? true
        self.onSelectSession = onSelectSession
        self.onCloseSession  = onCloseSession
        self.onNewSession    = onNewSession
        self.onToggleExpand  = onToggleExpand
        self.onNewProject    = onNewProject
        self.onRenameProject   = onRenameProject
        self.onRenameSession   = onRenameSession
        self.onSetProjectColor = onSetProjectColor
        self.onRemoveProject   = onRemoveProject
        self.onNewWorktree     = onNewWorktree
        self.onChangeProjectDir = onChangeProjectDir

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.titlebarSeparatorStyle = .none      // no hairline between titlebar and content
        // Translucency needs a non-opaque window from FIRST paint — applyTheme doesn't run
        // on the plain launch path, so this can't wait for it.
        win.isOpaque = !VestaConfig.shared.seeThrough
        win.backgroundColor = VestaConfig.shared.seeThrough ? .clear : surface
        win.isMovableByWindowBackground = false
        // Keep the window object alive when the user closes it, so the app can
        // re-show it (closing the window doesn't quit Vesta).
        win.isReleasedWhenClosed = false
        win.center()
        // Remember window size/position across launches (falls back to centered).
        win.setFrameAutosaveName("VestaMainWindow")
        win.collectionBehavior.insert(.fullScreenPrimary)

        super.init(window: win)

        buildContent(content: content)
        buildTitlebarAccessory()
        updateToggleTint()
        flattenTitlebarSoon()
        // AppKit re-shows the titlebar material on key/main changes — re-flatten then.
        for n: NSNotification.Name in [NSWindow.didBecomeKeyNotification,
                                       NSWindow.didBecomeMainNotification,
                                       NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: n, object: win, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flattenTitlebarSoon() }
            }
        }
        // Cursor blink follows window-key state: the focused pane blinks only while
        // the window is key (an inactive window shows a hollow, non-blinking cursor).
        // Only the first-responder terminal pane reacts; all other surfaces are
        // already unfocused. resignFirstResponder/becomeFirstResponder handle the
        // intra-window case; these two handle the window gaining/losing key.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { [weak win] _ in
            MainActor.assumeIsolated { (win?.firstResponder as? TerminalPane)?.windowKeyChanged(true) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak win] _ in
            MainActor.assumeIsolated { (win?.firstResponder as? TerminalPane)?.windowKeyChanged(false) }
        }
    }

    private weak var titlebarBacking: NSView?

    /// A transparent titlebar still shows two seams over a very dark surface: AppKit's faint
    /// material/background view, and `_NSTitlebarDecorationView`'s bottom hairline at the
    /// titlebar/content boundary (visible over the terminal, hidden over the same-colour
    /// sidebar). Own an opaque backing pinned over the titlebar (sized via autoresizing —
    /// Auto Layout doesn't work inside NSTitlebarView, which positions children by frame; it
    /// collapsed to 0×0), extended a few px below to cover the boundary, and hide the
    /// background/decoration/separator views. The backing is click-through so dragging works,
    /// and the accessory + traffic lights are lifted back above it. ponytail: view grafts are
    /// the only durable handle AppKit gives for the titlebar.
    private var rootGlass: GlassView?   // glass mode's behind-window material (root-level)
    private var titlebarBand: NSView?   // glass mode's full-width titlebar tint strip

    func flattenTitlebar() {
        window?.titlebarSeparatorStyle = .none
        // Glass mode: no opaque backing (the root material is the look), but the system's
        // own titlebar decorations must STILL be hidden — they paint a mismatched dark
        // strip over the terminal side (the "weird seam"). Fall through to hide(), skip
        // the backing install.
        let glass = VestaConfig.shared.glassSidebar
        guard let bar = window?.standardWindowButton(.closeButton)?.superview else { return }
        if glass {
            if let frame = window?.contentView?.superview {
                func hideDecor(_ v: NSView) {
                    if v is GlassView { return }
                    let n = "\(type(of: v))"
                    if v is NSVisualEffectView || n.contains("Separator")
                        || n.contains("Decoration") || n.contains("TitlebarBackground") {
                        v.isHidden = true
                    }
                    v.subviews.forEach(hideDecor)
                }
                frame.subviews.forEach(hideDecor)
            }
            titlebarBacking?.isHidden = true   // stale backing from a pre-toggle run
            return
        }
        titlebarBacking?.isHidden = false
        let backing = titlebarBacking ?? {
            let b = TitlebarBackingView()
            b.wantsLayer = true
            b.translatesAutoresizingMaskIntoConstraints = true
            b.autoresizingMask = [.width, .height]
            bar.addSubview(b)
            titlebarBacking = b
            return b
        }()
        backing.frame = bar.bounds.insetBy(dx: 0, dy: -6)   // cover the titlebar + the boundary seam
        backing.layer?.backgroundColor = surface.cgColor
        // Front so it covers the material wherever it sits; then lift the accessory + traffic
        // lights back above it so they stay visible and clickable.
        bar.addSubview(backing, positioned: .above, relativeTo: nil)
        // Lift each accessory's clip view (leading: toggle/folder/path; trailing: bell) back
        // above the backing so they stay visible — walk up from a known child to the bar.
        let anchors: [NSButton?] = [toggleButton, bellButton]
        for anchor in anchors {
            var node: NSView? = anchor
            while let n = node, n.superview !== bar { node = n.superview }
            if let accChild = node, accChild.superview === bar {
                bar.addSubview(accChild, positioned: .above, relativeTo: backing)
            }
        }
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            if let b = window?.standardWindowButton(type), b.superview === bar {
                bar.addSubview(b, positioned: .above, relativeTo: nil)
            }
        }
        // Belt-and-suspenders: hide the material/background and the decoration hairline.
        if let frame = window?.contentView?.superview {
            func hide(_ v: NSView) {
                if v is GlassView { return }   // OUR glass (overlays / glass mode) is never prey
                let n = "\(type(of: v))"
                if v !== backing,
                   v is NSVisualEffectView || n.contains("Separator")
                     || n.contains("Decoration") || n.contains("TitlebarBackground") {
                    v.isHidden = true
                }
                v.subviews.forEach(hide)
            }
            frame.subviews.forEach(hide)
        }
    }

    /// The titlebar's effect view is created lazily — on a cold first window it can appear
    /// *after* a single flatten pass runs (the material then shows until something re-themes
    /// the window, e.g. a new window). Retry on a short bounded schedule to catch it whenever
    /// AppKit builds it. ponytail: a few timed retries beat the lazy-init race; AppKit exposes
    /// no "titlebar ready" hook. Also re-run on reload / key-window changes (observers in init).
    func flattenTitlebarSoon() {
        for ms in [0, 80, 200, 500, 1000] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                self?.flattenTitlebar()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("no xib") }

    // MARK: public updates

    /// Live config reload (no relaunch): adopt new colors. Sidebar rows rebuild
    /// with the new accent on the next setProjects() (the caller's refresh()).
    func applyTheme(_ t: Theme) {
        theme = t
        surface = t.background
        let glass = VestaConfig.shared.glassSidebar
        window?.isOpaque = !VestaConfig.shared.seeThrough
        window?.backgroundColor = VestaConfig.shared.seeThrough ? .clear : surface
        // Live toggle is best-effort (full glass applies on relaunch): OFF hides the stale
        // material; ON can't retrofit a blur into an existing window, only re-tint.
        rootGlass?.isHidden = !glass
        titlebarBand?.isHidden = !glass
        titlebarBand?.layer?.backgroundColor = surface.withAlphaComponent(VestaConfig.shared.sidebarOpacity).cgColor
        sidebar?.layer?.backgroundColor = glass
            ? surface.withAlphaComponent(VestaConfig.shared.sidebarOpacity).cgColor : surface.cgColor
        if let projScroll { applyScrollAppearance(projScroll) }
        flattenTitlebarSoon()
        prefixPill?.textColor = t.accent
        prefixPill?.layer?.borderColor = t.accent.cgColor
        prefixPill?.layer?.backgroundColor = t.accent.withAlphaComponent(0.12).cgColor
        bellButton?.contentTintColor = txt(.faint)            // re-theme the bell + unread dot
        bellDot?.layer?.backgroundColor = t.accent.cgColor
    }

    // Footer = git/normal status, plus an optional plugin status (vesta.status) appended
    // so the two don't clobber each other.
    private var baseStatus = "▌ normal"
    private var luaStatus = ""
    func setStatus(_ text: String) { baseStatus = text; renderFooter() }
    func setLuaStatus(_ s: String) { luaStatus = s; renderFooter() }
    private func renderFooter() {
        let full = luaStatus.isEmpty ? baseStatus : "\(baseStatus) · \(luaStatus)"
        footer?.stringValue = full
        footer?.toolTip = full   // single-line footer truncates; the tooltip keeps it whole
    }
    func setDir(_ text: String) {
        dirLabel?.attributedStringValue = dirAttributed(text)
        // Custom titlebar hides the system title, but set it anyway so Mission
        // Control, the Window menu, and ⌘` show a meaningful label.
        window?.title = text
    }

    /// Show/hide the prefix-armed indicator (driven by PrefixState.onArmedChange).
    func setPrefixArmed(_ armed: Bool) { prefixPill?.isHidden = !armed }

    /// Rebuild the PROJECTS area from the given snapshot.
    /// Single source of sidebar truth — called on every onChange.
    func setProjects(_ projects: [SidebarProject]) {
        guard let stack = projectsStack else { return }

        // Remove all previously arranged subviews (avoid constraint leaks).
        let old = stack.arrangedSubviews
        old.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }

        // The PROJECTS header is pinned outside the scroll view — just refresh its count here.
        projCount?.stringValue = String(format: "%02d", projects.count)

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
                prow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -8).isActive = true
                var last: NSView = prow
                if proj.expanded {
                    stack.setCustomSpacing(3, after: prow)   // tighter gap before nested sessions
                    for (si, sess) in proj.sessions.enumerated() {
                        let srow = makeSessionRow(pi, si, sess)
                        stack.addArrangedSubview(srow)
                        srow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -8).isActive = true
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
        // Glass mode: root paints nothing; a behind-window material at the very back gives
        // the sidebar AND the titlebar strip their blur (the terminal side is covered by the
        // workspace container's opaque background). Solid surface otherwise.
        root.layer?.backgroundColor = VestaConfig.shared.seeThrough
            ? NSColor.clear.cgColor : surface.cgColor
        if VestaConfig.shared.glassSidebar {
            let fx = GlassView()
            fx.material = .sidebar
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(fx)
            NSLayoutConstraint.activate([
                fx.topAnchor.constraint(equalTo: root.topAnchor),
                fx.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                fx.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                fx.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            rootGlass = fx
            // Unified glass titlebar: tint the strip over the terminal to MATCH the
            // sidebar, so the top band reads as one continuous piece of glass. Constrained
            // to START at the sidebar's edge (below) — overlapping the sidebar would
            // double-tint it (0.55 over 0.55) and re-create the seam.
            let band = NSView()
            band.wantsLayer = true
            band.translatesAutoresizingMaskIntoConstraints = false
            band.layer?.backgroundColor = surface.withAlphaComponent(VestaConfig.shared.sidebarOpacity).cgColor
            titlebarBand = band
        }

        sidebar = makeSidebar()
        content.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebar)
        root.addSubview(content)
        if let band = titlebarBand {
            root.addSubview(band)
            NSLayoutConstraint.activate([
                band.topAnchor.constraint(equalTo: root.topAnchor),
                band.heightAnchor.constraint(equalToConstant: 34),
                band.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                band.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: sidebarOpen ? openWidth : 0)
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
        setSidebarWidth(sidebarWidth.constant + delta)
    }

    /// Absolute sidebar-width setter (drag + Settings panel), clamped + persisted.
    func setSidebarWidth(_ w: CGFloat) {
        let clamped = w.clamped(to: 160...420)
        sidebarWidth.constant = clamped
        openWidth = clamped
        UserDefaults.standard.set(Double(clamped), forKey: "VestaSidebarWidth")
        // Any visible width means the sidebar is open — keep the toggle state (and the
        // persisted bit) in sync so ⌘B isn't a dead press after resizing while collapsed.
        sidebarOpen = true
        UserDefaults.standard.set(true, forKey: "VestaSidebarOpen")
        sidebar.superview?.layoutSubtreeIfNeeded()
        updateToggleTint()
    }

    private func makeSidebar() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.clipsToBounds = true
        // Glass mode: the blur lives on ROOT (covers sidebar + titlebar strip); the sidebar
        // is just the surface color demoted to a tint OVER that blur. Solid otherwise.
        v.layer?.backgroundColor = VestaConfig.shared.glassSidebar
            ? surface.withAlphaComponent(VestaConfig.shared.sidebarOpacity).cgColor : surface.cgColor

        // single right-edge hairline (white @0.07)
        let edge = NSView()
        edge.translatesAutoresizingMaskIntoConstraints = false
        edge.wantsLayer = true
        edge.layer?.backgroundColor = hair(0.07).cgColor
        v.addSubview(edge)

        // PROJECTS header — pinned below the titlebar, NOT part of the scrolling list.
        let header = makeProjHeaderRow(count: 0)
        header.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(header)

        // The scrolling project list.
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        // Side insets so the outlined cards float instead of touching the sidebar edges.
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 0)
        projectsStack = stack   // setProjects clears + refills it

        // Scroll the list so many projects/sessions don't grow the window. A flipped clip view
        // anchors content to the top; the appearance tracks the surface so the overlay scroller
        // knob matches the theme instead of defaulting to a light system knob.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView = FlippedClipView()
        scroll.contentView.drawsBackground = false
        scroll.documentView = stack
        applyScrollAppearance(scroll)
        projScroll = scroll

        let footBlock = makeFooter()

        v.addSubview(scroll)
        v.addSubview(footBlock)

        NSLayoutConstraint.activate([
            edge.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            // Start below the ~34px titlebar so the divider doesn't slice through the title strip.
            edge.topAnchor.constraint(equalTo: v.topAnchor, constant: 34),
            edge.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),

            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 44),   // clears the titlebar
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: footBlock.topAnchor, constant: -8),

            // Document (stack) fills the clip width; its height is intrinsic → scrolls when tall.
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            footBlock.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            footBlock.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            footBlock.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    /// Match the scroller knob to the surface: a dark surface gets the dark appearance (light
    /// knob), a light surface the aqua appearance — so the overlay scroller never clashes.
    private func applyScrollAppearance(_ scroll: NSScrollView) {
        let c = surface.usingColorSpace(.deviceRGB)
        let lum = c.map { 0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent } ?? 0
        scroll.appearance = NSAppearance(named: lum < 0.5 ? .darkAqua : .aqua)
    }

    // MARK: – Row builders

    /// PROJECTS section header with count + trailing "+" new-project button.
    private func makeProjHeaderRow(count: Int) -> NSView {
        let countStr = String(format: "%02d", count)
        let header = sectionLabel("PROJECTS", count: countStr)

        let plus = tinyButton(symbol: "plus", label: "Add project") { [weak self] in self?.onNewProject() }
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

    /// Project DIVIDER: ▾ name ── hairline ── (count | +). Projects are grouping labels,
    /// not cards — sessions carry the visual weight (cmux-style). Click = expand/collapse;
    /// the + is hover-revealed so a stray click near the edge can't create a session.
    private func makeProjectRow(_ pi: Int, _ p: SidebarProject) -> NSView {
        let tint = p.color ?? theme.accent

        let nameLabel = NSTextField(labelWithString: "\(p.expanded ? "▾" : "▸") \(p.name)")
        nameLabel.font = Fonts.mono(11, medium: p.active)
        nameLabel.textColor = p.active ? tint : tint.withAlphaComponent(0.75)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let branch = p.branch { nameLabel.toolTip = "\(p.name) · ⎇ \(branch)" }

        let hairline = NSView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = hair(0.08).cgColor
        hairline.heightAnchor.constraint(equalToConstant: 1).isActive = true
        hairline.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Collapsed projects keep their session count visible (no information lost).
        let count = NSTextField(labelWithString: p.expanded ? "" : "\(p.sessions.count)")
        count.font = Fonts.mono(9.5)
        count.textColor = txt(.faint)
        count.setContentHuggingPriority(.required, for: .horizontal)

        let addBtn = tinyButton(symbol: "plus", label: "New session") { [weak self] in self?.onNewSession(pi) }
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.alphaValue = 0   // hover-revealed

        let content = NSStackView(views: [nameLabel, hairline, count, addBtn])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false

        let row = TaggedRow()
        row.tag1 = pi
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 5
        row.hoverHighlight = false   // dividers don't need a hover wash; the + reveal is enough
        row.onHover = { [weak addBtn] inside in addBtn?.animator().alphaValue = inside ? 1 : 0 }

        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 11),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            content.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            addBtn.widthAnchor.constraint(equalToConstant: 18),
            addBtn.heightAnchor.constraint(equalToConstant: 18),
            row.heightAnchor.constraint(equalToConstant: 26),
        ])

        row.onClick = { [weak self] in self?.onToggleExpand(pi) }
        row.menu = makeProjectMenu(pi, name: p.name, hasColor: p.color != nil)
        return row
    }

    /// Session CARD: outlined, self-sizing — title row (label + plain-text meta) over up
    /// to 4 verbatim scrollback lines (TailStore). Heat is paint only: the inner-left rail
    /// tints mint while the session waits for you (attention), never the geometry.
    /// × is hover-revealed; the whole card selects.
    private func makeSessionRow(_ pi: Int, _ si: Int, _ sess: SidebarSession) -> NSView {
        let active = sess.active

        let label = NSTextField(labelWithString: sess.label)
        label.font = Fonts.mono(12, medium: active)
        label.textColor = active ? txt(.full) : txt(.dim)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Chip-free meta: ⊞panes · ●dirty · :port · age — one dim run of text.
        var meta: [String] = []
        if sess.paneCount > 1 { meta.append("⊞\(sess.paneCount)") }
        if sess.dirty > 0 { meta.append("●\(sess.dirty)") }
        if let port = sess.ports.first { meta.append(":\(port)") }
        if sess.attention { meta.append(sess.attentionAge ?? "●") }
        var titleViews: [NSView] = [label]
        // Split schematic (vesta-sidebar-panes): pane-count cells, focused-first lit.
        // ponytail: count-based grid, not real topology — read PaneTree.serializeLayout
        // and draw the true split tree if anyone asks.
        if VestaConfig.shared.sidebarPanes, sess.paneCount > 1 {
            titleViews.insert(PaneSchematic(count: sess.paneCount, accent: theme.accent, dim: txt(.faint)), at: 0)
        }
        if !meta.isEmpty {
            let m = NSTextField(labelWithString: meta.joined(separator: " · "))
            m.font = Fonts.mono(9.5)
            m.textColor = sess.attention ? theme.accent : txt(.faint)
            m.setContentCompressionResistancePriority(.required, for: .horizontal)
            m.setContentHuggingPriority(.required, for: .horizontal)
            titleViews.append(m)
            // Reserve the top-right corner so the revealed × never covers the meta text.
            let pad = NSView()
            pad.translatesAutoresizingMaskIntoConstraints = false
            pad.widthAnchor.constraint(equalToConstant: 14).isActive = true
            titleViews.append(pad)
        }
        let title = NSStackView(views: titleViews)
        title.orientation = .horizontal
        title.alignment = .centerY
        title.spacing = 6

        var rows: [NSView] = [title]
        if !sess.tail.isEmpty {
            let lines = sess.tail.suffix(TailStore.maxLines).map { (t: String) -> NSView in
                let l = NSTextField(labelWithString: t)
                l.font = Fonts.mono(9)
                l.textColor = txt(.faint)
                l.lineBreakMode = .byTruncatingTail
                l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return l
            }
            let tailStack = NSStackView(views: lines)
            tailStack.orientation = .vertical
            tailStack.alignment = .leading
            tailStack.spacing = 2
            let rule = NSView()
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.wantsLayer = true
            rule.layer?.backgroundColor = hair(0.10).cgColor
            rule.layer?.cornerRadius = 1
            rule.widthAnchor.constraint(equalToConstant: 2).isActive = true
            let tail = NSStackView(views: [rule, tailStack])
            tail.orientation = .horizontal
            tail.alignment = .top
            tail.spacing = 7
            rule.heightAnchor.constraint(equalTo: tailStack.heightAnchor).isActive = true
            rows.append(tail)
        }

        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let closeBtn = tinyButton(symbol: "xmark", label: "Close session") { [weak self] in self?.onCloseSession(pi, si) }
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.alphaValue = 0   // hover-revealed: no permanent destructive target

        // Heat rail (paint only): waiting-for-you (bell/attention) tints the inner edge.
        let bar = accentBar(sess.attention ? theme.accent : .clear)

        let row = TaggedRow()
        row.tag1 = pi; row.tag2 = si
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 7
        row.layer?.borderWidth = 1
        row.layer?.borderColor = hair(active ? 0.16 : 0.07).cgColor
        row.layer?.backgroundColor = active ? theme.accent.withAlphaComponent(0.07).cgColor : NSColor.clear.cgColor
        row.onHover = { [weak closeBtn] inside in closeBtn?.animator().alphaValue = inside ? 1 : 0 }

        row.addSubview(bar); row.addSubview(content); row.addSubview(closeBtn)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 1),
            bar.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            bar.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -5),
            bar.widthAnchor.constraint(equalToConstant: 2),

            // Title pinned to the card TOP (never centered) — tails grow downward.
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 11),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),

            closeBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -7),
            closeBtn.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            closeBtn.widthAnchor.constraint(equalToConstant: 16),
            closeBtn.heightAnchor.constraint(equalToConstant: 16),

            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])

        row.onClick = { [weak self] in self?.onSelectSession(pi, si) }
        row.onDoubleClick = { [weak self] in
            self?.promptRenameSession(pi, si, current: sess.label)
        }
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
        menu.addItem(BlockMenuItem(title: "New worktree session…") { [weak self] in
            self?.promptWorktree(pi)
        })

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
    // ponytail: cache the rasterized swatch per color — every sidebar rebuild remade one
    // NSImage (lockFocus) per preset × project. Colors are a fixed handful; no eviction.
    private static var swatchCache: [NSColor: NSImage] = [:]
    private static func swatch(_ color: NSColor) -> NSImage {
        if let img = swatchCache[color] { return img }
        let size = NSSize(width: 12, height: 12)
        let img = NSImage(size: size)
        img.lockFocus()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3).addClip()
        color.setFill(); NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        swatchCache[color] = img
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

    /// Native rename prompt for a session (double-click a session row).
    private func promptRenameSession(_ pi: Int, _ si: Int, current: String) {
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "Leave blank to clear the name and use the folder name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            onRenameSession(pi, si, field.stringValue)
        }
    }

    /// Prompt for a branch name to create a git-worktree-isolated session.
    private func promptWorktree(_ pi: Int) {
        let alert = NSAlert()
        alert.messageText = "New worktree session"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "branch name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let branch = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { return }
            onNewWorktree(pi, branch)
        }
    }

    // MARK: – Shared helpers

    /// Tiny SF Symbol button with a block action (avoids selector boilerplate for inline lambdas).
    private func tinyButton(symbol: String, label: String, action: @escaping () -> Void) -> NSButton {
        let btn = BlockButton(action: action)
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.title = ""
        btn.imagePosition = .imageOnly
        btn.setAccessibilityLabel(label)
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .light)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
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
        projCount = c   // pinned header builds this once; setProjects updates its value

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
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let version = NSTextField(labelWithString: Updater.currentVersion)
        version.translatesAutoresizingMaskIntoConstraints = false
        version.font = Fonts.inst(9.5)
        version.textColor = txt(.faint)
        version.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Update indicator (hidden until an update is available / downloading / ready).
        // Clickable: starts the download, or relaunches once the new version is staged.
        let upd = UpdateBadge { [weak self] in self?.onUpdate?() }
        upd.font = Fonts.inst(10)
        upd.translatesAutoresizingMaskIntoConstraints = false
        upd.isHidden = true
        upd.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateBadge = upd

        // ONE line: status left (truncates, full text in tooltip), update + version right —
        // the footer never stacks, so plugin status can't grow it into a column of clutter.
        let rows = NSStackView(views: [footer, upd, version])
        rows.orientation = .horizontal
        rows.alignment = .centerY
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false

        block.addSubview(topHair)
        block.addSubview(rows)
        NSLayoutConstraint.activate([
            topHair.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            topHair.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            topHair.topAnchor.constraint(equalTo: block.topAnchor),
            topHair.heightAnchor.constraint(equalToConstant: 1),

            rows.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -12),
            rows.topAnchor.constraint(equalTo: topHair.bottomAnchor, constant: 12),
            rows.bottomAnchor.constraint(equalTo: block.bottomAnchor, constant: -12),
        ])
        return block
    }

    /// Set by AppDelegate → opens the update flow when the sidebar badge is clicked.
    var onUpdate: (() -> Void)?
    private var updateBadge: UpdateBadge?

    /// Drive the sidebar update indicator. `text == nil` hides it; otherwise it shows the
    /// status (accent) and is clickable when `clickable` (available / ready states).
    func setUpdateStatus(_ text: String?, clickable: Bool) {
        guard let b = updateBadge else { return }
        if let text {
            b.stringValue = text
            b.textColor = theme.accent
            b.isClickable = clickable
            b.isHidden = false
        } else {
            b.isHidden = true
        }
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

        // Folder icon → change the active project's default directory.
        let folder = BlockButton(action: { [weak self] in self?.onChangeProjectDir() })
        folder.translatesAutoresizingMaskIntoConstraints = false
        folder.isBordered = false
        folder.bezelStyle = .regularSquare
        folder.title = ""
        folder.imagePosition = .imageOnly
        let fcfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Change project folder")?
            .withSymbolConfiguration(fcfg)
        folder.contentTintColor = txt(.faint)
        folder.toolTip = "Change the project's default folder"

        dirLabel = NSTextField(labelWithString: "")
        dirLabel.translatesAutoresizingMaskIntoConstraints = false
        dirLabel.attributedStringValue = dirAttributed("vesta")
        dirLabel.lineBreakMode = .byTruncatingTail
        dirLabel.cell?.usesSingleLineMode = true

        let pill = NSTextField(labelWithString: "PREFIX")
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.font = Fonts.inst(9.5)
        pill.alignment = .center
        pill.textColor = theme.accent                         // color sync: theme.accent
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 4
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = theme.accent.cgColor        // color sync: theme.accent
        pill.layer?.backgroundColor = theme.accent.withAlphaComponent(0.12).cgColor
        pill.isHidden = true
        host.addSubview(pill)
        prefixPill = pill

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

            pill.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            pill.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 16),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])

        // Keep the dir label from overlapping the prefix pill when it's visible.
        // .defaultHigh so it yields to the looser host-trailing bound when the pill is hidden.
        let dirVsPill = dirLabel.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -8)
        dirVsPill.priority = .defaultHigh
        dirVsPill.isActive = true

        acc.view = host
        titlebarAccessory = host
        window?.addTitlebarAccessoryViewController(acc)
        buildBellAccessory()
    }

    /// The notifications bell, in its OWN trailing titlebar accessory so it pins to the
    /// window's rightmost edge (the leading accessory above holds the toggle/folder/path).
    private func buildBellAccessory() {
        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .trailing
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 30))

        let bell = NSButton()
        bell.translatesAutoresizingMaskIntoConstraints = false
        bell.isBordered = false
        bell.bezelStyle = .regularSquare
        bell.title = ""
        bell.imagePosition = .imageOnly
        bell.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Notifications")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        bell.contentTintColor = txt(.faint)
        bell.toolTip = "Notifications"
        bell.target = self
        bell.action = #selector(bellAction)
        bellButton = bell

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = theme.accent.cgColor
        dot.isHidden = true
        bellDot = dot

        host.addSubview(bell); host.addSubview(dot)
        NSLayoutConstraint.activate([
            bell.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            bell.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            bell.widthAnchor.constraint(equalToConstant: 20),
            bell.heightAnchor.constraint(equalToConstant: 20),
            bell.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 2),
            dot.trailingAnchor.constraint(equalTo: bell.trailingAnchor, constant: 1),
            dot.topAnchor.constraint(equalTo: bell.topAnchor, constant: 1),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        acc.view = host
        bellAccessory = host
        window?.addTitlebarAccessoryViewController(acc)
    }

    /// Onboarding "clean slate": hide every titlebar accessory (sidebar toggle, folder,
    /// path, prefix pill) so only the traffic lights remain. Restored when onboarding ends.
    func setChromeHidden(_ hidden: Bool) {
        titlebarAccessory?.isHidden = hidden
        bellAccessory?.isHidden = hidden
    }

    @objc private func bellAction() { onBell?() }

    /// Reflect the unread-notification count on the bell (dot shown when > 0).
    func setUnread(_ n: Int) { bellDot?.isHidden = (n == 0) }

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
        UserDefaults.standard.set(sidebarOpen, forKey: "VestaSidebarOpen")   // remember across launches
        // Set the model constant DIRECTLY (authoritative), then animate only the layout pass.
        // Driving the constant through .animator() changes it incrementally over the duration, so
        // a competing layout — e.g. setProjects() firing while an agent streams output — interrupts
        // the animation and freezes the constant partway, parking the sidebar half-collapsed.
        // Use openWidth (updated by drag) so ⌘B restores to whatever drag set.
        sidebarWidth.constant = sidebarOpen ? openWidth : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
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
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?   // hover-revealed actions (+/×)
    var hoverHighlight = true        // background wash on hover (off for divider rows)

    // Claim every click on the row EXCEPT over real buttons (the +/× actions).
    // Decorative subviews (labels, caret, dot) would otherwise swallow the click
    // and the row's mouseDown would never fire — that's why collapse/select looked dead.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let b = hit as? NSButton {
            // A hover-revealed button at alpha 0 still hit-tests in AppKit — an invisible ×
            // must never eat a click (that's a destructive mis-click). Fall through to the row.
            return b.alphaValue > 0.01 ? b : self
        }
        return bounds.contains(convert(point, from: superview)) ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let d = onDoubleClick { d(); return }
        onClick?()
    }

    // Light hover highlight so rows feel interactive.
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
        // Rows are rebuilt (≤1/s) while output streams; a stationary cursor gets no fresh
        // mouseEntered, which would leave the hover-revealed ×/+ invisible-forever. Re-assert.
        if let w = window {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(p), bounds.width > 0 { setHovered(true) }
        }
    }
    /// Single hover implementation — the mouseEntered/Exited overrides and the
    /// rebuild re-assert all funnel here, so no path ever needs a synthetic NSEvent.
    private func setHovered(_ inside: Bool) {
        onHover?(inside)
        guard hoverHighlight else { return }
        if inside, (layer?.backgroundColor.flatMap { $0.alpha } ?? 0) < 0.01 {
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
        } else if !inside, let bg = layer?.backgroundColor, bg.alpha <= 0.05 {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
}

/// Tiny split-topology schematic on a session card (vesta-sidebar-panes): up to four
/// cells, the first (focused) lit. ponytail: count-based layout, not the real split tree.
final class PaneSchematic: NSView {
    init(count: Int, accent: NSColor, dim: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let n = min(count, 4)
        let cols = n == 1 ? 1 : 2
        let rowsN = n <= 2 ? 1 : 2
        let w: CGFloat = 18, h: CGFloat = 12, gap: CGFloat = 1.5
        let cw = (w - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let ch = (h - gap * CGFloat(rowsN - 1)) / CGFloat(rowsN)
        for i in 0..<n {
            let cell = CALayer()
            let r = i / cols, c = i % cols
            cell.frame = CGRect(x: CGFloat(c) * (cw + gap), y: CGFloat(rowsN - 1 - r) * (ch + gap),
                                width: cw, height: ch)
            cell.cornerRadius = 1.5
            cell.backgroundColor = (i == 0 ? accent.withAlphaComponent(0.55) : dim.withAlphaComponent(0.35)).cgColor
            layer?.addSublayer(cell)
        }
        widthAnchor.constraint(equalToConstant: w).isActive = true
        heightAnchor.constraint(equalToConstant: h).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("no xib") }
}

/// Opaque fill pinned over the titlebar to defeat AppKit's translucent material. Click-through
/// (returns nil from hitTest) so the titlebar still drags/zooms the window normally.
private final class TitlebarBackingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Sidebar-footer update indicator: a label that becomes a pointing-hand link while an
/// update is actionable (available → download, or staged → relaunch).
private final class UpdateBadge: NSTextField {
    var isClickable = false { didSet { window?.invalidateCursorRects(for: self) } }
    private let handler: () -> Void
    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isEditable = false; isBordered = false; drawsBackground = false; isSelectable = false
        lineBreakMode = .byTruncatingTail
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(fire)))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { if isClickable { addCursorRect(bounds, cursor: .pointingHand) } }
    @objc private func fire() { if isClickable { handler() } }
}

/// Top-anchored clip view: default NSClipView is bottom-up, which makes a short list sit at the
/// bottom of the scroll area and scroll the wrong way. Flipping anchors content to the top.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
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
    let wc = VestaWindowController(theme: Theme(), content: NSView())
    assert(wc.window != nil, "window must exist")

    let s1 = SidebarSession(label: "shell", active: true)
    let s2 = SidebarSession(label: "vim",   active: false)
    let projects: [SidebarProject] = [
        SidebarProject(name: "vesta",  branch: "main", expanded: true,  active: true,  sessions: [s1, s2]),
        SidebarProject(name: "relay", branch: nil,    expanded: false, active: false, sessions: []),
    ]
    wc.setProjects(projects)

    // Calling setProjects again must not crash (rebuild without leaking constraints)
    wc.setProjects(projects)

    wc.setStatus("▌ normal · ⎇ main ↑1 · 2 dirty")
    wc.setDir("vesta / ~/dev/vesta")

    // toggleSidebar twice must leave sidebar open and not crash
    wc.toggleSidebar(); wc.toggleSidebar()

    assert(wc.window?.contentView?.subviews.count ?? 0 >= 2, "sidebar + content present")
    wc.setPrefixArmed(true)
    wc.setPrefixArmed(false)   // toggling must not crash and leaves the pill hidden
    print("chromeSelfCheck OK")
}
