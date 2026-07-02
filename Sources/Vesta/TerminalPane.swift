import AppKit
import GhosttyKit

/// One terminal pane: a real libghostty surface rendered (via Metal) into this
/// layer-backed NSView. The rest of Vesta talks only to this type, never to the
/// renderer. Adapted from Ghostty's own SurfaceView_AppKit.swift (MIT).
@MainActor final class TerminalPane: NSView, @preconcurrency NSTextInputClient, NSTextFieldDelegate, PaneContent {
    private(set) var id: Int
    let paneID: String                     // stable mux session id (UUID string)
    private(set) var cwd: String?          // from ghostty PWD action (OSC 7)
    private(set) var title: String = ""    // from ghostty SET_TITLE action (OSC 0/2)
    var onUpdate: (() -> Void)?            // cwd / title changed
    var onAttention: (() -> Void)?         // bell / desktop-notification fired

    /// The underlying ghostty surface. Optional because surface creation can fail.
    /// nonisolated(unsafe): it's a raw pointer, and deinit (which frees it) runs
    /// on the main thread for an NSView anyway.
    private nonisolated(unsafe) var surface: ghostty_surface_t?

    /// Live-pane registry. ghostty's action/close callbacks hand us a raw userdata
    /// pointer and we resolve it on a later main-queue hop — by which point the
    /// pane may have been closed (Cmd-W), so the pointer would dangle. Callbacks
    /// check `isLive` first; init/deinit keep the set current. NSLock because
    /// deinit isn't guaranteed on the main actor.
    private nonisolated static let liveLock = NSLock()
    private nonisolated(unsafe) static var live = Set<UnsafeMutableRawPointer>()
    nonisolated static func isLive(_ p: UnsafeMutableRawPointer) -> Bool {
        liveLock.lock(); defer { liveLock.unlock() }; return live.contains(p)
    }

    /// paneIDs for which `session-exited` must NOT fire: the user intentionally killed the
    /// shell (we suppress, since `session-closed` already fired), or it already fired once
    /// (latch against a duplicate close_surface). Guarded by liveLock; pruned in deinit.
    private nonisolated(unsafe) static var silencedExits = Set<String>()
    /// Mark a paneID's coming exit as intentional (call before MuxClient.kill).
    nonisolated static func suppressExit(_ paneID: String) {
        liveLock.lock(); silencedExits.insert(paneID); liveLock.unlock()
    }
    /// Returns true if `session-exited` should fire for this paneID; latches so a second
    /// close_surface for the same pane is suppressed.
    nonisolated static func shouldFireExit(_ paneID: String) -> Bool {
        liveLock.lock(); defer { liveLock.unlock() }
        let fire = !silencedExits.contains(paneID)
        silencedExits.insert(paneID)
        return fire
    }

    /// Marked (preedit) text accumulator for IME, and a keyDown text accumulator.
    private let markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    /// The last content size we were told about, used when backing props change.
    private var contentSize: NSSize = .init(width: 800, height: 600)

    init(id: Int, theme: Theme, cwd: String? = nil, paneID: String = UUID().uuidString) {
        self.id = id
        self.paneID = paneID
        self.cwd = cwd
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // ghostty renders Metal into our layer, so we must be layer-backed.
        wantsLayer = true
        autoresizingMask = [.width, .height]

        // Build the surface config: userdata points back at us so GhosttyApp's
        // runtime action callback can resolve the surface target to this pane.
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.font_size = 0 // inherit from ghostty config

        // When persist is on, run `vesta-attach <paneID>` instead of a bare shell
        // so the pane connects to (or creates) the daemon session for this paneID.
        // `vesta-persist = false` in config restores the bare-shell fallback.
        let muxCommand: String? = VestaConfig.shared.persist
            ? "\(muxHelperPath()) \(paneID)" : nil

        // The working directory string must outlive the ghostty_surface_new call.
        self.surface = withOptionalCString(cwd) { cwdPtr in
            config.working_directory = cwdPtr
            return withOptionalCString(muxCommand) { cmdPtr in
                if let cmdPtr { config.command = cmdPtr }
                return ghostty_surface_new(GhosttyApp.shared.app, &config)
            }
        }

        // Surfaces START UNFOCUSED. libghostty defaults a new surface to
        // focused=true, which makes its cursor blink (solid block) and keeps its
        // renderer/CVDisplayLink ticking at full rate. Vesta only ever toggled
        // focus through the NSView first-responder path, which touches exactly one
        // pane per window — so every split sibling, every restored-but-not-active
        // leaf, and every background-session pane stayed focused=true forever, all
        // blinking and burning CPU at once. Only the pane that actually becomes
        // first responder (in a key window) should be focused; becomeFirstResponder
        // and windowKeyChanged turn it on truthfully.
        if let surface { ghostty_surface_set_focus(surface, false) }

        // Tracking area so we receive mouseMoved/entered/exited.
        updateTrackingAreas()

        let p = Unmanaged.passUnretained(self).toOpaque()
        TerminalPane.liveLock.lock(); TerminalPane.live.insert(p); TerminalPane.liveLock.unlock()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        let p = Unmanaged.passUnretained(self).toOpaque()
        let pid = paneID
        TerminalPane.liveLock.lock()
        TerminalPane.live.remove(p)
        TerminalPane.silencedExits.remove(pid)   // pane gone → no more close_surface; bound the set
        TerminalPane.liveLock.unlock()
        if let surface { ghostty_surface_free(surface) }
    }

    /// Push a freshly-loaded config to this surface (live reload, no relaunch).
    func updateConfig(_ cfg: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, cfg)
    }

    // MARK: - Public API (contract)

    /// Label for the tab / titlebar: cwd basename (short, stable), else the
    /// terminal title, else "shell".
    var label: String {
        if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        if !title.isEmpty { return title }
        return "shell"
    }

    /// Re-theme. ghostty owns its colors via the native config, so this is a
    /// no-op; colors update by reloading the ghostty config upstream.
    // ponytail: theming is driven entirely by ghostty's config, not per-pane.
    func apply(_ theme: Theme) {}

    // MARK: - PaneContent

    func focusContent() {
        guard let window else { return }
        // Don't steal first-responder from a modal picker/confirm overlay covering the
        // window — otherwise restyle()/focusActivePane()/plugin focus calls yank focus
        // off the picker and its arrow/Esc keys leak through to the terminal.
        if window.contentView?.subviews.contains(where: { $0 is PickerOverlay || $0 is ConfirmOverlay }) == true { return }
        window.makeFirstResponder(self)
    }

    /// Type text into the pane (used by `vesta send-keys`).
    func sendKeys(_ s: String) {
        guard let surface, !s.isEmpty else { return }
        // ghostty_surface_text inserts via bracketed paste, which DEFERS newlines —
        // so a trailing "\n" never submits the command. Insert printable segments as
        // text, but submit each line break with a real Return key event.
        let lines = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        for (i, line) in lines.enumerated() {
            let part = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            if !part.isEmpty {
                part.withCString { ghostty_surface_text(surface, $0, UInt(part.utf8.count)) }
            }
            if i < lines.count - 1 { sendReturn() }
        }
    }

    /// Synthesize an Enter key press (keyCode 0x24) so the shell executes the line.
    private func sendReturn() {
        guard let ev = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 0x24) else { return }
        keyAction(GHOSTTY_ACTION_PRESS, event: ev)
        keyAction(GHOSTTY_ACTION_RELEASE, event: ev)
    }

    // MARK: - Edit menu (responder-chain copy/paste via ghostty binding actions)

    private func bindingAction(_ name: String) {
        guard let surface else { return }
        name.withCString { ghostty_surface_binding_action(surface, $0, UInt(name.utf8.count)) }
    }
    @objc func copy(_ sender: Any?)  { bindingAction("copy_to_clipboard") }   // no-op if no selection

    // MARK: - In-terminal search (⌘F)
    // Vesta provides the input field; libghostty runs the search and highlights
    // matches in the grid, reporting match counts via SEARCH_TOTAL/SEARCH_SELECTED.

    private var searchBar: NSStackView?
    private var searchInput: NSTextField?
    private var searchCount: NSTextField?
    private var searchTotal = 0
    private var searchSelected = -1
    /// Multiplexed search: set by PaneTree to fan the query/clear out to every pane
    /// in the session, so matches highlight across the whole split — not just here.
    var broadcastSearch: ((String) -> Void)?
    var broadcastEndSearch: (() -> Void)?
    /// In multiplex mode, report this surface's match total up to PaneTree so the
    /// pane showing the search bar can display the session-wide total.
    var reportTotal: ((TerminalPane, Int) -> Void)?

    /// True when this pane is the one showing the search field.
    var searchVisible: Bool { searchBar.map { !$0.isHidden } ?? false }

    /// Apply a search needle to THIS surface only (libghostty highlights its matches).
    func applySearchNeedle(_ q: String) { bindingAction("search:" + q) }
    func endSearchHere() { bindingAction("end_search"); searchTotal = 0; searchSelected = -1 }

    /// Display a session-wide match total (multiplex): no per-match position.
    func showSearchTotal(_ total: Int) {
        searchCount?.stringValue = total == 0 ? "no matches" : "\(total) match\(total == 1 ? "" : "es")"
    }

    /// Open the search field (⌘F).
    func startSearch() {
        if searchBar == nil { buildSearchBar() }
        searchBar?.isHidden = false
        bindingAction("start_search")
        window?.makeFirstResponder(searchInput)
    }

    /// Open search pre-filled with `needle` and run it (for the `vesta search` CLI).
    func search(_ needle: String) {
        startSearch()
        searchInput?.stringValue = needle
        runSearch()
    }

    private func buildSearchBar() {
        let input = NSTextField()
        input.placeholderString = "Find"
        input.delegate = self
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.focusRingType = .none
        input.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let count = NSTextField(labelWithString: "")
        count.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true

        let close = NSButton(title: "✕", target: self, action: #selector(closeSearchTapped))
        close.isBordered = false
        close.font = .systemFont(ofSize: 11)

        let bar = NSStackView(views: [input, count, close])
        bar.orientation = .horizontal; bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.97).cgColor
        bar.layer?.cornerRadius = 8
        bar.layer?.borderWidth = 1
        bar.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        searchBar = bar; searchInput = input; searchCount = count
    }

    @objc private func closeSearchTapped() { endSearch() }

    func endSearch() {
        if let b = broadcastEndSearch { b() } else { endSearchHere() }
        searchBar?.isHidden = true
        searchInput?.stringValue = ""
        searchTotal = 0; searchSelected = -1
        window?.makeFirstResponder(self)
    }

    private func runSearch() {
        let q = searchInput?.stringValue ?? ""
        if let b = broadcastSearch { b(q) } else { applySearchNeedle(q) }
        if q.isEmpty { searchTotal = 0; searchSelected = -1; updateSearchCount() }
    }

    func setSearchTotal(_ t: Int) {
        searchTotal = t
        if let r = reportTotal { r(self, t) }   // multiplex: PaneTree aggregates
        else { updateSearchCount() }             // single pane: show position/total
    }
    func setSearchSelected(_ s: Int) {
        searchSelected = s
        if reportTotal == nil { updateSearchCount() }   // multiplex has no cross-pane position
    }
    private func updateSearchCount() {
        guard let label = searchCount else { return }
        if (searchInput?.stringValue ?? "").isEmpty { label.stringValue = "" }
        else if searchTotal == 0 { label.stringValue = "no matches" }
        else if searchSelected >= 0 { label.stringValue = "\(searchSelected + 1)/\(searchTotal)" }
        else { label.stringValue = "\(searchTotal)" }
    }

    // NSTextFieldDelegate: live query + enter/escape navigation.
    func controlTextDidChange(_ obj: Notification) { runSearch() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(insertNewline(_:)):
            let prev = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            bindingAction(prev ? "navigate_search:previous" : "navigate_search:next")
            return true
        case #selector(cancelOperation(_:)):
            endSearch(); return true
        default:
            return false
        }
    }
    @objc func paste(_ sender: Any?) {
        // Insert clipboard text directly via the surface (bracketed paste) — more
        // reliable than the binding action, and correct (multi-line won't auto-run).
        guard let surface, let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
        s.withCString { ghostty_surface_text(surface, $0, UInt(s.utf8.count)) }
    }

    /// Best-effort capture of the screen (or full scrollback) as plain text.
    func capture(scrollback: Bool) -> String {
        guard let surface else { return "" }
        // Read either the whole scrollback (SCREEN) or the viewport.
        let tag = scrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let cstr = text.text else { return "" }
        return String(cString: cstr)
    }

    /// PID of the foreground process group leader in this surface's PTY.
    /// Returns nil if no surface or ghostty reports 0 (nothing running).
    var foregroundPID: pid_t? {
        guard let surface else { return nil }
        let p = ghostty_surface_foreground_pid(surface)   // UInt64; 0 ⇒ none
        return p > 0 ? pid_t(p) : nil
    }

    /// Called (on the main actor) by GhosttyApp's action callback when ghostty
    /// reports a new title / working directory for this surface.
    func setLiveTitle(_ t: String) { if t != title { title = t; onUpdate?() } }
    func setLiveCwd(_ c: String)   { if c != cwd  { cwd = c;  onUpdate?() } }

    /// Called (on the main actor) when ghostty fires RING_BELL or DESKTOP_NOTIFICATION.
    func fireAttention() { onAttention?() }

    // MARK: - NSView

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        // Focus the surface only when the window is actually key. A pane made
        // first responder in a background window must not blink; windowKeyChanged
        // turns it on when (and if) the window becomes key.
        if ok, let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow ?? false) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    /// Sync surface focus to the window's key state. Called by the window
    /// controller on key/resign so the focused pane's cursor blinks only while the
    /// window is key — matching stock Ghostty, where an inactive window shows a
    /// hollow, non-blinking cursor. Only the first-responder pane reacts; every
    /// other surface is already unfocused and stays that way.
    func windowKeyChanged(_ isKey: Bool) {
        guard let surface, window?.firstResponder === self else { return }
        ghostty_surface_set_focus(surface, isKey)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        contentSize = newSize
        guard let surface else { return }
        // A split relayout re-frames us *after* we're already in the window, so
        // re-assert DPI here — otherwise the new pane keeps a stale 1.0 scale
        // (tiny font) while its cell grid is sized for 2x.
        syncContentScale()
        let scaled = convertToBacking(newSize)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    /// Push the authoritative content scale to ghostty from the window's backing
    /// scale factor. Deriving it from a frame/backing *ratio* (the old code) reads
    /// 1.0 before the view's backing store resolves during a split → half-size
    /// font on split panes. The window's backingScaleFactor is correct immediately.
    private func syncContentScale() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        // Keep the layer from double-scaling the Metal contents.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()

        syncContentScale()

        let scaled = convertToBacking(contentSize)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))

        // Track which display we're on so vsync uses the right refresh rate.
        if let window {
            ghostty_surface_set_display_id(surface, window.screen?.displayID ?? 0)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Trigger a backing-properties pass so scale/size/display are correct
        // once we're attached to a window.
        viewDidChangeBackingProperties()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    // Rendering: ghostty owns it. It runs its own renderer thread + CVDisplayLink
    // (keyed to the display id we pass). We must NOT call ghostty_surface_draw
    // ourselves — doing so from the main thread trips ghostty's queue assertion.

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }

        // Translate mods (e.g. option-as-alt) so character composition matches.
        let translationModsGhostty = eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface, ghosttyMods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) { translationMods.insert(flag) }
            else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedBefore = markedText.length > 0

        // Accumulate any text the IME commits during interpretKeyEvents.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([translationEvent])

        // Push preedit state into ghostty.
        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                _ = keyAction(action, event: event,
                              translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(action, event: event,
                          translationEvent: translationEvent,
                          text: ghosttyCharacters(translationEvent),
                          composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        let mods = ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 { action = GHOSTTY_ACTION_PRESS }
        _ = keyAction(action, event: event)
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var key_ev = ghosttyKeyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        key_ev.composing = composing

        // Only encode UTF8 text if it isn't a bare control character; ghostty
        // encodes control characters itself.
        if let text, !text.isEmpty, let cp = text.utf8.first, cp >= 0x20 {
            return text.withCString { ptr in
                key_ev.text = ptr
                return ghostty_surface_key(surface, key_ev)
            }
        }
        return ghostty_surface_key(surface, key_ev)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        // Anchor at the real click location FIRST. ghostty starts a selection at its
        // last-known mouse position; hover updates can be stale right before a press
        // (and after a prior selection the position sits at the previous drag's end),
        // so without this a click/drag selects from the wrong cell and a plain click
        // can spuriously extend the old selection.
        sendMousePos(event)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT,
                                     ghosttyMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT,
                                     ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        sendMousePos(event)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT,
                                     ghosttyMods(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT,
                                     ghosttyMods(event.modifierFlags))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, mouseButton(for: event),
                                     ghosttyMods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, mouseButton(for: event),
                                     ghosttyMods(event.modifierFlags))
    }

    private func mouseButton(for event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // Negative coords tell ghostty the cursor left the viewport.
        ghostty_surface_mouse_pos(surface, -1, -1, ghosttyMods(event.modifierFlags))
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // ghostty uses a top-left origin; AppKit is bottom-left.
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y,
                                  ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision { x *= 2; y *= 2 }

        // Pack the scroll mods bitfield (bit 0 = precision). ghostty reads
        // momentum from higher bits; precision alone is enough for Vesta.
        // ponytail: momentum phase is not forwarded — scrolling still works.
        let mods: ghostty_input_scroll_mods_t = precision ? 1 : 0
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange { NSRange() }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText.setAttributedString(v)
        case let v as String: markedText.setAttributedString(NSAttributedString(string: v))
        default: break
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: w, height: h)
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        var chars = ""
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        // If we're mid-keyDown, accumulate so keyAction can encode it.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        sendKeys(chars)
    }

    override func doCommand(by selector: Selector) {
        // Swallow unimplemented commands to avoid the system beep.
    }

    /// Push the current marked (preedit) text into ghostty.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

/// Calls `body` with a C string for `value`, or NULL if `value` is nil. The
/// pointer is only valid within the closure.
@MainActor
private func withOptionalCString<T>(_ value: String?,
                                    _ body: (UnsafePointer<CChar>?) -> T) -> T {
    if let value { return value.withCString { body($0) } }
    return body(nil)
}

// MARK: - Input helpers (adapted from Ghostty.Input / NSEvent+Extension, MIT)

/// Translate AppKit modifier flags into a ghostty mods enum.
private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    // Sided modifiers.
    let raw = flags.rawValue
    if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(mods)
}

/// Translate a ghostty mods enum back into AppKit modifier flags.
private func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags(rawValue: 0)
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
}

/// Build a ghostty key event from an NSEvent. Text/composing are set by the
/// caller since those have lifetime constraints we can't satisfy here.
private func ghosttyKeyEvent(
    _ event: NSEvent,
    _ action: ghostty_input_action_e,
    translationMods: NSEvent.ModifierFlags? = nil
) -> ghostty_input_key_s {
    var key_ev = ghostty_input_key_s()
    key_ev.action = action
    key_ev.keycode = UInt32(event.keyCode)
    key_ev.text = nil
    key_ev.composing = false
    key_ev.mods = ghosttyMods(event.modifierFlags)
    // control/command never contribute to text translation; assume the rest did.
    key_ev.consumed_mods = ghosttyMods(
        (translationMods ?? event.modifierFlags).subtracting([.control, .command]))

    key_ev.unshifted_codepoint = 0
    if event.type == .keyDown || event.type == .keyUp {
        if let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            key_ev.unshifted_codepoint = cp.value
        }
    }
    return key_ev
}

/// The text to forward for a key event, dropping control characters (ghostty
/// encodes those itself) and PUA function-key codepoints.
private func ghosttyCharacters(_ event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }
    if characters.count == 1, let scalar = characters.unicodeScalars.first {
        if scalar.value < 0x20 {
            return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
        }
        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
    }
    return characters
}

private extension NSScreen {
    /// The CoreGraphics display ID for this screen, used for vsync.
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
