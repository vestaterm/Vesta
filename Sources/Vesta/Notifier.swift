import AppKit
import UserNotifications

/// One in-app + desktop notification.
struct VestaNote: Identifiable {
    let id = UUID()
    let title: String?
    let message: String
    let date: Date
}

/// Desktop notifications via Notification Center. Posts only when the app isn't frontmost,
/// or when a notify call forces it (`vesta.notify(msg, { desktop = true })`). No-op for the
/// bundle-less dev binary — UNUserNotificationCenter needs a real .app bundle, so there it's
/// in-app only. A delegate lets a forced banner show even while the app is active.
enum Notifier {
    // Held for the app's lifetime as the UN delegate; only touched on the main thread.
    nonisolated(unsafe) private static let delegate = ForegroundPresenter()
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Ask once at launch (bundled only). Safe to call when unavailable.
    static func requestAuth() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post to Notification Center if it should be shown there. `force` overrides the
    /// "skip while focused" rule. Returns nothing — in-app display is handled by the caller.
    static func post(title: String?, body: String, force: Bool) {
        guard available, force || !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title ?? "Vesta"
        content.body = body
        content.sound = .default
        // nil trigger → deliver immediately. Unique id so repeats don't coalesce/replace.
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Allow a forced banner to appear even when Vesta is the active app (the system
    /// otherwise suppresses foreground notifications). We only post while active when forced,
    /// so always presenting is correct.
    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }
}

/// The in-app notifications dropdown (opened by the titlebar bell). A click-anywhere scrim
/// with a panel pinned top-right under the titlebar, listing recent notes newest-first.
final class NotificationsPanel: NSView {
    private let panel = NSView()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private var heightC: NSLayoutConstraint!          // scroll height = content (capped); set after layout
    private let onDelete: (UUID) -> Void
    private let onClear: () -> Void

    init(theme: Theme, notes: [VestaNote], onDelete: @escaping (UUID) -> Void, onClear: @escaping () -> Void) {
        self.onDelete = onDelete; self.onClear = onClear
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        build(theme: theme, notes: notes)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) { NSColor.clear.setFill(); dirtyRect.fill() }   // click-catcher only

    private func build(theme: Theme, notes: [VestaNote]) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.99).cgColor
        panel.layer?.cornerRadius = 10
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        addSubview(panel)

        let header = NSTextField(labelWithString: "Notifications")
        header.font = Fonts.mono(12, medium: true)
        header.textColor = NSColor(white: 0.55, alpha: 1)
        header.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(header)

        let clear = ActionButton(symbol: "trash", pointSize: 11) { [weak self] in self?.onClear() }
        clear.contentTintColor = NSColor(white: 0.5, alpha: 1)
        clear.toolTip = "Clear all"
        clear.isHidden = notes.isEmpty
        clear.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(clear)

        var cons: [NSLayoutConstraint] = [
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            panel.widthAnchor.constraint(equalToConstant: 330),
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            clear.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            clear.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ]

        if notes.isEmpty {
            // No scroll machinery — a single label directly in the panel, aligned with the
            // header (the scroll's inner padding would otherwise offset it ~8px to the left).
            let empty = NSTextField(labelWithString: "No notifications yet")
            empty.font = Fonts.mono(12.5)
            empty.textColor = NSColor(white: 0.45, alpha: 1)
            empty.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(empty)
            cons += [
                empty.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
                empty.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
                empty.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
            ]
        } else {
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 0
            list.translatesAutoresizingMaskIntoConstraints = false
            for (i, n) in notes.enumerated() {
                let r = row(n, theme: theme)
                list.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true   // full width → × at the right edge
                if i < notes.count - 1 {
                    let d = divider()
                    list.addArrangedSubview(d)
                    d.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                }
            }

            // Flipped document so content fills from the TOP and scrolls down (NSClipView is
            // bottom-origin by default, which would leave a gap above the first row).
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(list)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.documentView = doc
            panel.addSubview(scroll)

            // Height = measured content (set in viewDidMoveToWindow), capped at 60% of the
            // window; past that the list scrolls. defaultHigh so the required cap wins when tall.
            heightC = scroll.heightAnchor.constraint(equalToConstant: 0)
            heightC.priority = .defaultHigh
            cons += [
                scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
                scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
                scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
                scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
                heightC,
                scroll.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.6),
                scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 460),   // absolute max hug
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                list.topAnchor.constraint(equalTo: doc.topAnchor),
                list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(cons)
    }

    private func row(_ n: VestaNote, theme: Theme) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let msg = NSTextField(wrappingLabelWithString: n.title.map { "\($0) — \(n.message)" } ?? n.message)
        msg.font = Fonts.mono(12.5)
        msg.textColor = NSColor(white: 0.9, alpha: 1)
        msg.translatesAutoresizingMaskIntoConstraints = false

        let time = NSTextField(labelWithString: Self.ago(n.date))
        time.font = Fonts.mono(10.5)
        time.textColor = NSColor(white: 0.4, alpha: 1)
        time.translatesAutoresizingMaskIntoConstraints = false

        let del = ActionButton(symbol: "xmark", pointSize: 9) { [weak self] in self?.onDelete(n.id) }
        del.contentTintColor = NSColor(white: 0.45, alpha: 1)
        del.toolTip = "Dismiss"
        del.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(msg); v.addSubview(time); v.addSubview(del)
        NSLayoutConstraint.activate([
            msg.topAnchor.constraint(equalTo: v.topAnchor, constant: 9),
            msg.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            msg.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -6),
            time.topAnchor.constraint(equalTo: msg.bottomAnchor, constant: 3),
            time.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            time.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -9),
            del.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            del.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            del.widthAnchor.constraint(equalToConstant: 16),
            del.heightAnchor.constraint(equalToConstant: 16),
        ])
        return v
    }

    private func divider() -> NSView {
        let d = NSView()
        d.translatesAutoresizingMaskIntoConstraints = false
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        d.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return d
    }

    /// Compact relative time: "now", "3m", "2h", "5d".
    private static func ago(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        switch s {
        case 0..<60:      return "now"
        case 60..<3600:   return "\(s / 60)m ago"
        case 3600..<86400: return "\(s / 3600)h ago"
        default:          return "\(s / 86400)d ago"
        }
    }

    // Click outside the panel (or Esc) dismisses.
    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { removeFromSuperview() }
    }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        guard window != nil else { return }
        // Size the scroll to its content now that the width is known (capped by the 0.6
        // constraint). No-op for the empty state, which has no scroll view.
        if let heightC {
            layoutSubtreeIfNeeded()
            heightC.constant = ceil(doc.fittingSize.height)
        }
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { removeFromSuperview() } else { super.keyDown(with: event) }
    }
}

/// An SF-symbol button that runs a closure — avoids target/action plumbing for the
/// panel's clear-all and per-row dismiss buttons.
private final class ActionButton: NSButton {
    private let handler: () -> Void
    init(symbol: String, pointSize: CGFloat, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Top-origin container for the scroll's document view.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }
