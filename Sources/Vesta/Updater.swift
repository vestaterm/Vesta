import AppKit

/// Lightweight update check against GitHub Releases. On launch (silent) and from
/// the menu (loud), fetch the latest release tag and, if it's newer than the
/// running version, offer to open the download page.
///
/// ponytail: notify-and-open, not self-replacing. Real silent background updates
/// want Sparkle 2 — but that needs Developer ID signing + a hosted appcast +
/// EdDSA keys, none of which exist yet. Upgrade to Sparkle when the app is signed.
enum Updater {
    static let repo = "notnaki/Vesta"

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    /// `silent`: launch check — only speak up if an update exists. Loud check
    /// (menu) also reports "up to date" and network errors.
    static func check(silent: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, err in
            let result: (tag: String, page: String)?
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                result = (tag, (json["html_url"] as? String) ?? "https://github.com/\(repo)/releases")
            } else {
                result = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { present(result, error: err, silent: silent) }
            }
        }.resume()
    }

    @MainActor private static func present(_ r: (tag: String, page: String)?, error: Error?, silent: Bool) {
        guard let r else {
            if !silent { alert("Couldn't check for updates", error?.localizedDescription ?? "No releases found.") }
            return
        }
        if isNewer(r.tag, than: currentVersion) {
            let a = NSAlert()
            a.messageText = "Vesta \(r.tag) is available"
            a.informativeText = "You're on \(currentVersion). Open the download page?"
            a.addButton(withTitle: "Download")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn, let u = URL(string: r.page) {
                NSWorkspace.shared.open(u)
            }
        } else if !silent {
            alert("You're up to date", "Vesta \(currentVersion) is the latest version.")
        }
    }

    /// Semantic compare of dotted version strings, ignoring a leading "v".
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    @MainActor private static func alert(_ title: String, _ body: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = body
        a.addButton(withTitle: "OK"); a.runModal()
    }
}

#if DEBUG
// ponytail: one runnable check for the version comparator (the only real logic).
func updaterSelfCheck() {
    assert(Updater.isNewer("0.2.0", than: "0.1.0"))
    assert(Updater.isNewer("v1.0.0", than: "0.9.9"))
    assert(Updater.isNewer("0.1.1", than: "0.1.0"))
    assert(!Updater.isNewer("0.1.0", than: "0.1.0"))
    assert(!Updater.isNewer("0.1.0", than: "0.2.0"))
    assert(Updater.isNewer("0.10.0", than: "0.9.0"))   // numeric, not lexical
}
#endif
