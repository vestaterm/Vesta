import AppKit

/// A compact yes/no dialog (the UI behind `vesta.confirm`): a dim scrim over the window
/// with the question and two buttons — no filter field, no list. ←/→ or Tab switches,
/// Enter confirms the highlighted choice, Y/N pick directly, Esc/scrim-click cancels (No).
final class ConfirmOverlay: NSView {
    private let theme: Theme
    private let onChoose: (Bool) -> Void   // also called with false on cancel
    private var yes = true                  // highlighted choice
    private let yesBtn = NSTextField(labelWithString: "Yes")
    private let noBtn = NSTextField(labelWithString: "No")
    private let yesPad = NSView()
    private let noPad = NSView()
    private let panel = NSView()
    private var done = false                 // one-shot guard (avoids a double callback/unref)

    init(theme: Theme, message: String, onChoose: @escaping (Bool) -> Void) {
        self.theme = theme
        self.onChoose = onChoose
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        build(message: message)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill(); dirtyRect.fill()
    }

    private func build(message: String) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        installGlass(panel, tint: NSColor(white: 0.10, alpha: 1))   // glass moment: blur + dark tint
        panel.layer?.cornerRadius = 9
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
        addSubview(panel)

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor(white: 0.95, alpha: 1)
        label.isEditable = false; label.isSelectable = false; label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false

        func makeBtn(_ field: NSTextField, _ pad: NSView, _ yesValue: Bool) {
            field.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
            field.alignment = .center
            field.translatesAutoresizingMaskIntoConstraints = false
            pad.wantsLayer = true
            pad.layer?.cornerRadius = 6
            pad.layer?.borderWidth = 1
            pad.translatesAutoresizingMaskIntoConstraints = false
            pad.addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: pad.topAnchor, constant: 6),
                field.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -6),
                field.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 22),
                field.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -22),
            ])
            let click = NSClickGestureRecognizer(target: self, action: yesValue ? #selector(clickYes) : #selector(clickNo))
            pad.addGestureRecognizer(click)
        }
        makeBtn(yesBtn, yesPad, true)
        makeBtn(noBtn, noPad, false)

        let row = NSStackView(views: [yesPad, noPad])
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(label)
        panel.addSubview(row)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 120),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            row.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
        ])
    }

    private func restyle() {
        for (pad, field, on) in [(yesPad, yesBtn, yes), (noPad, noBtn, !yes)] {
            pad.layer?.backgroundColor = (on ? theme.accent.withAlphaComponent(0.20) : .clear).cgColor
            pad.layer?.borderColor = (on ? theme.accent.withAlphaComponent(0.6) : NSColor(white: 1, alpha: 0.14)).cgColor
            field.textColor = on ? NSColor(white: 1, alpha: 1) : NSColor(white: 0.7, alpha: 1)
        }
    }

    private func fire(_ v: Bool) { guard !done else { return }; done = true; onChoose(v) }
    @objc private func clickYes() { fire(true) }
    @objc private func clickNo() { fire(false) }
    override func mouseDown(with event: NSEvent) {
        // Only a click on the bare scrim cancels. A click that bubbles up from a button's
        // padding keeps its in-panel location, so it doesn't cancel (the gesture handles it).
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { fire(false) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124, 48:                       // ←, →, Tab → toggle
            yes.toggle(); restyle()
        case 36, 76:                             // Return / Enter → confirm highlighted
            fire(yes)
        case 53:                                 // Esc → cancel (No)
            fire(false)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "y": fire(true)
            case "n": fire(false)
            default: super.keyDown(with: event)
            }
        }
    }
}
