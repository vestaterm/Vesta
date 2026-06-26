import AppKit
import WebKit

// MARK: - URL normalization

enum BrowserURL {
    /// `3000` → http://localhost:3000 ; `localhost:3000` / `example.com` → add scheme.
    static func normalize(_ s: String) -> URL {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return URL(string: "http://localhost:\(n)")! }
        if t.contains("://") { return URL(string: t) ?? URL(string: "about:blank")! }
        return URL(string: "http://\(t)") ?? URL(string: "about:blank")!
    }
}

func browserSelfCheck() {
    assert(BrowserURL.normalize("3000").absoluteString == "http://localhost:3000", "bare port")
    assert(BrowserURL.normalize("localhost:8080").absoluteString == "http://localhost:8080", "host:port")
    assert(BrowserURL.normalize("https://x.com").absoluteString == "https://x.com", "full url kept")
    print("browserSelfCheck OK")
}

// MARK: - BrowserPane

/// A thin NSView hosting a WKWebView with a minimal toolbar (reload + URL field).
/// Colors are sourced from the passed Theme — no hardcoded hex.
@MainActor
final class BrowserPane: NSView {
    private(set) var webView: WKWebView!
    private var urlField: NSTextField!
    private var reloadButton: NSButton!
    private let theme: Theme

    private static let barHeight: CGFloat = 28

    init(url: URL, theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor
        buildUI()
        load(url)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build UI

    private func buildUI() {
        // Top bar
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = theme.background.withAlphaComponent(0.85).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        // Reload button
        reloadButton = NSButton(title: "↺", target: self, action: #selector(reloadPage))
        reloadButton.isBordered = false
        reloadButton.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        reloadButton.contentTintColor = theme.accent
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.toolTip = "Reload"
        bar.addSubview(reloadButton)

        // URL field
        urlField = NSTextField()
        urlField.isEditable = true
        urlField.isBordered = false
        urlField.isBezeled = false
        urlField.drawsBackground = false
        urlField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        urlField.textColor = NSColor.labelColor
        urlField.placeholderString = "about:blank"
        urlField.focusRingType = .none
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.target = self
        urlField.action = #selector(navigateToTyped)
        bar.addSubview(urlField)

        // WKWebView
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        // Allow native back/forward swipe gestures
        webView.allowsBackForwardNavigationGestures = true
        addSubview(webView)

        // Constraints
        NSLayoutConstraint.activate([
            // bar: full width at top, fixed height
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: BrowserPane.barHeight),

            // reload button: vertically centered in bar, left side
            reloadButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reloadButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            reloadButton.widthAnchor.constraint(equalToConstant: 24),

            // url field: vertically centered, fills remaining bar width
            urlField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            urlField.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 6),
            urlField.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),

            // webView: below bar, fills rest
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Public API

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
        urlField?.stringValue = url.absoluteString
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func navigateToTyped() {
        let normalized = BrowserURL.normalize(urlField.stringValue)
        load(normalized)
    }
}

// MARK: - WKNavigationDelegate

extension BrowserPane: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if let url = webView.url {
                self.urlField.stringValue = url.absoluteString
            }
        }
    }
}

// MARK: - PaneContent conformance

extension BrowserPane: PaneContent {
    func focusContent() {
        window?.makeFirstResponder(webView)
    }
}
