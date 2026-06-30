import AppKit

/// In-app self-update against GitHub Releases. Checks the latest release; if newer, downloads
/// the notarized DMG, swaps the new Vesta.app into place (move-aside-first; admin prompt only
/// when the install dir isn't user-writable), and relaunches. Progress is surfaced through the
/// sidebar badge via `onPhase`. Bundle-only — the bundle-less dev binary just opens the page.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    static let repo = "vestaterm/Vesta"

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }
    /// Self-install needs a real `.app` (the dev binary can't swap itself).
    private static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    enum Phase {
        case available(String)        // tag — click to download
        case downloading(Double)      // 0…1
        case installing
        case ready(String)            // staged + swapped — click to relaunch
        case failed
    }
    /// Drives the sidebar update badge (set by AppDelegate). nil = hide.
    var onPhase: ((Phase?) -> Void)?
    private(set) var phase: Phase?

    private var pending: (tag: String, dmg: URL)?
    private var stagedApp: URL?
    private var working = false
    private var progressObs: NSKeyValueObservation?

    private func set(_ p: Phase?) { phase = p; onPhase?(p) }

    // MARK: - Check

    func check(silent: Bool) {
        // A silent (background/periodic) check must not disturb an in-progress download/install
        // or an already-staged "relaunch" state. A loud (menu) check still runs to report status.
        if silent, working || stagedApp != nil { return }
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            var tag: String?, dmg: URL?, page = "https://github.com/\(Self.repo)/releases"
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                tag = json["tag_name"] as? String
                page = (json["html_url"] as? String) ?? page
                for a in (json["assets"] as? [[String: Any]]) ?? [] where (a["name"] as? String)?.hasSuffix(".dmg") == true {
                    dmg = (a["browser_download_url"] as? String).flatMap { URL(string: $0) }
                }
            }
            let t = tag, d = dmg, pg = page
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.present(tag: t, dmg: d, page: pg, error: err, silent: silent) } }
        }.resume()
    }

    private func present(tag: String?, dmg: URL?, page: String, error: Error?, silent: Bool) {
        if stagedApp != nil { return }                     // already downloaded; badge shows "relaunch"
        guard let tag, Self.isNewer(tag, than: Self.currentVersion) else {
            if !silent { alert("You're up to date", "Vesta \(Self.currentVersion) is the latest version.") }
            return
        }
        // No bundle (dev binary) or no DMG asset → fall back to opening the releases page.
        guard Self.isBundled, let dmg else {
            if !silent, let u = URL(string: page) { NSWorkspace.shared.open(u) }
            return
        }
        pending = (tag, dmg)
        set(.available(tag))
        if !silent {                                       // loud (menu) → offer immediately
            let a = NSAlert()
            a.messageText = "Vesta \(tag) is available"
            a.informativeText = "You're on \(Self.currentVersion). Download and install it now?"
            a.addButton(withTitle: "Download & Install")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { startDownload() }
        }
    }

    /// Sidebar badge click: relaunch if staged, else (re)start the download.
    func badgeClicked() {
        if stagedApp != nil { relaunch() } else if pending != nil { startDownload() }
    }

    // MARK: - Download + install

    func startDownload() {
        guard !working, let (tag, dmg) = pending else { return }
        working = true
        set(.downloading(0))
        let task = URLSession.shared.downloadTask(with: dmg) { [weak self] tmp, _, err in
            guard let tmp, err == nil else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail() } }; return
            }
            // The temp file is deleted when this block returns — move it out synchronously.
            let saved = FileManager.default.temporaryDirectory.appendingPathComponent("Vesta-update-\(UUID().uuidString).dmg")
            do { try FileManager.default.moveItem(at: tmp, to: saved) }
            catch { DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail() } }; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.install(dmg: saved, tag: tag) } }
        }
        progressObs = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.working == true { self?.set(.downloading(f)) } } }
        }
        task.resume()
    }

    private func install(dmg: URL, tag: String) {
        set(.installing)
        let target = Bundle.main.bundleURL
        DispatchQueue.global().async { [weak self] in
            let ok = Self.mountStageSwap(dmg: dmg, target: target)
            try? FileManager.default.removeItem(at: dmg)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                self.working = false
                self.progressObs = nil
                if ok { self.stagedApp = target; self.pending = nil; self.set(.ready(tag)) }
                else { self.fail() }
            } }
        }
    }

    /// Mount the DMG, copy out the new Vesta.app, detach, then swap it into `target`
    /// (move the old aside first, restore on failure). macOS allows moving a running bundle,
    /// so this works live; the app relaunches into the new copy afterward. Admin prompt only
    /// when the install dir isn't user-writable (e.g. /Applications). Background-thread only.
    nonisolated private static func mountStageSwap(dmg: URL, target: URL) -> Bool {
        let fm = FileManager.default
        let mnt = fm.temporaryDirectory.appendingPathComponent("vesta-mnt-\(UUID().uuidString)")
        let staged = fm.temporaryDirectory.appendingPathComponent("Vesta-new-\(UUID().uuidString).app")
        defer { _ = run("/usr/bin/hdiutil", ["detach", mnt.path, "-quiet"]); try? fm.removeItem(at: staged) }
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-mountpoint", mnt.path]) else { return false }
        let appInDmg = mnt.appendingPathComponent("Vesta.app")
        guard fm.fileExists(atPath: appInDmg.path),
              run("/usr/bin/ditto", [appInDmg.path, staged.path]) else { return false }

        let old = target.path + ".old-\(getpid())"
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let swap = "rm -rf \(q(old)); mv \(q(target.path)) \(q(old)) && /usr/bin/ditto \(q(staged.path)) \(q(target.path)); "
            + "r=$?; if [ $r -ne 0 ]; then rm -rf \(q(target.path)); mv \(q(old)) \(q(target.path)); else rm -rf \(q(old)); fi; exit $r"
        if fm.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            return run("/bin/sh", ["-c", swap])
        }
        let script = "do shell script \"\(swap.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        return NSAppleScript(source: script)?.executeAndReturnError(&err) != nil
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    func relaunch() {
        guard let app = stagedApp else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func fail() { working = false; progressObs = nil; set(.failed) }

    /// Semantic compare of dotted version strings, ignoring a leading "v".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
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

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = body
        a.addButton(withTitle: "OK"); a.runModal()
    }
}

#if DEBUG
func updaterSelfCheck() {
    assert(Updater.isNewer("0.2.0", than: "0.1.0"))
    assert(Updater.isNewer("v1.0.0", than: "0.9.9"))
    assert(Updater.isNewer("0.1.1", than: "0.1.0"))
    assert(!Updater.isNewer("0.1.0", than: "0.1.0"))
    assert(!Updater.isNewer("0.1.0", than: "0.2.0"))
    assert(Updater.isNewer("0.10.0", than: "0.9.0"))
}
#endif
