import AppKit
import VestaMux

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
        // Reject corrupted downloads before swapping: `codesign --verify` checks the bundle's
        // file hashes even for ad-hoc signatures. Skip only if codesign itself is missing.
        if fm.fileExists(atPath: "/usr/bin/codesign"),
           !run("/usr/bin/codesign", ["--verify", "--deep", staged.path]) { return false }

        // Hand the daemon over BEFORE the bundle swap — this ordering is the whole point.
        //
        // The daemon refuses an upgrade to a binary whose CONTENT matches the one at its own
        // exec-time path. Once we swap, that path holds the new vestad, so asking afterwards
        // means asking it to upgrade to a copy of what it already reads there: refused, every
        // launch, forever. Right now the path still holds the OLD bytes, so the compare
        // differs and the handoff (--resume) goes through with every shell kept.
        //
        // A daemon predating that refuse check, or one already wedged, just declines and we
        // carry on — the swap must never be blocked by this.
        handOffDaemon(stagedApp: staged)

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

    /// Upgrade the running vestad to the incoming build, in place, keeping its shells.
    ///
    /// The new vestad is copied OUT of the staged bundle to a stable path first, because the
    /// staged copy is deleted the moment mountStageSwap returns — exec'ing from it would leave
    /// the daemon running an unlinked inode (exactly the state that made this bug so hard to
    /// see). `vestad-current` sits beside the socket and outlives the update.
    ///
    /// Best-effort throughout: any failure leaves the old daemon serving and the app update
    /// proceeds regardless. The worst case is the status quo — a stale daemon.
    // ponytail: one stable filename, not content-addressed. Replacing it via rename() leaves a
    // running daemon on the unlinked inode, which is harmless — it hashed its identity at its
    // own startup — and saves pruning a pile of vestad-<sha> files nobody reads.
    nonisolated private static func handOffDaemon(stagedApp: URL) {
        let fm = FileManager.default
        let incoming = stagedApp.appendingPathComponent("Contents/MacOS/vestad")
        guard fm.isExecutableFile(atPath: incoming.path) else { return }
        let stable = MuxPaths.base + "/vestad-current"

        // Stage under a temp name and rename() into place. A partially-written binary at the
        // real path is the one outcome here that could cost shells: execv succeeding on a
        // truncated-but-loadable image gets SIGKILLed AFTER the daemon has already closed its
        // listener and cleared CLOEXEC on the pty masters, so every shell takes the SIGHUP.
        // (execv FAILING is safe — performUpgrade's step 7 rebinds and keeps serving.) rename()
        // is atomic, so a concurrent updater can never expose a half-copy.
        let tmp = stable + ".tmp-\(getpid())"
        try? fm.removeItem(atPath: tmp)
        guard (try? fm.copyItem(atPath: incoming.path, toPath: tmp)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        // This is the first time vestad is ever exec'd from OUTSIDE the app bundle. copyItem
        // carries xattrs along, and a quarantined image can be killed after load — same fatal
        // window as above. The bytes came out of a bundle we just codesign --verify'd, and the
        // signature is embedded in the Mach-O, so it survives the copy; only the xattr is a
        // problem. Best effort: `xattr -d` fails harmlessly when the attribute isn't there.
        _ = run("/usr/bin/xattr", ["-d", "com.apple.quarantine", tmp])
        guard rename(tmp, stable) == 0 else { try? fm.removeItem(atPath: tmp); return }

        // Report the outcome. This whole bug class stayed invisible for days precisely because
        // a refused upgrade went unlogged — vestad's own stderr is /dev/null.
        switch MuxClient.upgradeDaemon(to: stable) {
        case .success:            NSLog("[vesta] session daemon handed off to the incoming build")
        case let .failure(reason): NSLog("[vesta] session daemon kept the previous version: \(reason)")
        case .unreachable:        NSLog("[vesta] session daemon unreachable — no handoff (a fresh one will be the new binary)")
        }
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    /// Set for the duration of a relaunch attempt. Without it a second badge click fires a
    /// second openApplication — and since both children carry VESTA_UPDATE_RELAUNCH, neither
    /// takes the "an instance is already running, exit" shortcut. Two fresh instances result,
    /// both restoring the same windows.json and both taking over the control socket: exactly
    /// the two-Vestas-in-the-dock this path exists to prevent. The badge stays `.ready` and
    /// clickable throughout, so an ordinary impatient double click reaches it.
    private var relaunching = false

    func relaunch() {
        guard let app = stagedApp, !relaunching else { return }
        relaunching = true
        let delegate = NSApp.delegate as? AppDelegate
        // Flush the CURRENT layout before the new instance launches and restores from it.
        // scheduleSave coalesces on a 0.6s timer, so without this the incoming app can restore
        // a layout that is up to that stale — a window opened or closed just before clicking
        // install would not be in the file yet.
        delegate?.saveWindows()
        // Relaunch AFTER this process is gone, never alongside it. Launching first made the
        // replacement a SECOND simultaneous instance of the app, and the Dock gives a second
        // instance its own tile — so an update left a Vesta sitting beside the pinned one, with
        // the pinned tile idle, until the user quit it and reopened from the pin. Nothing about
        // the app was wrong; it was simply never the instance the pin was bound to.
        //
        // A detached helper waits for our pid to disappear and then opens the app, so the
        // replacement starts as the only instance and takes the pinned tile. It also removes the
        // need for the VESTA_UPDATE_RELAUNCH gate on this path: by the time `open` runs, the
        // control socket has no listener, so the bare-argv shortcut in main.swift falls through
        // to a normal GUI launch on its own.
        // ponytail: /bin/sh polling kill -0, not a bundled relaunch tool. The helper is orphaned
        // to launchd when we exit, which is exactly the lifetime we need, and it retries `open`
        // rather than leaving the user with no app if the first attempt loses a race with quit.
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; "
            + "for i in 1 2 3; do /usr/bin/open \(q(app.path)) && exit 0; sleep 1; done; exit 1"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        do {
            try helper.run()
        } catch {
            // Could not even start the helper — stay alive and usable rather than quitting into
            // nothing, clear the guard so the badge can be retried, and report somewhere that
            // survives: showToast falls back to stderr, which is /dev/null in a bundled app.
            relaunching = false
            NSLog("[vesta] relaunch failed: could not start the relaunch helper (\(error.localizedDescription))")
            delegate?.showToast("update installed, but relaunch failed — quit and reopen Vesta")
            return
        }
        // Set the flag immediately before terminating, not earlier: it suppresses the quit
        // confirm and the terminate-time save, and a real Cmd-Q arriving while we were still
        // setting up would otherwise have quietly skipped both.
        delegate?.relaunchingForUpdate = true
        NSApp.terminate(nil)
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
