import AppKit

let argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "selfcheck" {
    // Pure-logic checks only. PaneTree/Chrome spawn real ghostty surfaces,
    // which need a live app + run loop — exercised by actually launching the app.
    // workspaceSelfCheck tests the Proj/SidebarProject data model without ghostty.
    _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck(); workspaceSelfCheck()
    // chromeSelfCheck creates AppKit objects (HaloWindowController → HaloConfig.shared →
    // GhosttyApp.shared). GhosttyApp.shared calls NSApp.isActive; NSApp is nil until
    // NSApplication.shared is first touched. Touch it here so GhosttyApp.shared doesn't crash.
    _ = NSApplication.shared
    MainActor.assumeIsolated { chromeSelfCheck() }
    print("all self-checks ok"); exit(0)
}
if let verb = argv.first, verb == "help" || verb == "--help" || verb == "-h" {
    printUsage(); exit(0)
}
if let verb = argv.first, controlVerbs.contains(verb) {
    exit(runControlCLI(argv))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: HaloWindowController!
    var workspace: Workspace!
    var server: ControlServer!
    var theme = Theme()

    func applicationDidFinishLaunching(_ note: Notification) {
        Fonts.register()                             // bundle Geist/Martian Mono before building UI
        let ghostty = GhosttyApp.shared             // inits libghostty (init/config/app) — native config sync
        theme = ghostty.theme                        // colors from the real ghostty config

        // Workspace starts with home project at ~; config projects appended below.
        workspace = Workspace(theme: theme)
        loadProjects(ghostty.settings, into: workspace)

        // Wire HaloWindowController with the five session-management closures.
        // Each closure calls the matching Workspace op then refresh() to keep the
        // sidebar snapshot in sync. No Workspace.on* stubs needed — Chrome calls
        // these directly on user action.
        controller = HaloWindowController(
            theme: theme, content: workspace.container,
            onSelectSession: { [weak self] p, s in
                self?.workspace.selectSession(p, s); self?.refresh()
            },
            onCloseSession: { [weak self] p, s in
                self?.workspace.closeSession(p, s);  self?.refresh()
            },
            onNewSession: { [weak self] p in
                self?.workspace.newSession(p);       self?.refresh()
            },
            onToggleExpand: { [weak self] p in
                self?.workspace.toggleExpand(p);     self?.refresh()
            },
            onNewProject: { [weak self] in
                self?.workspace.newProject();         self?.refresh()
            })

        workspace.onChange = { [weak self] in self?.refresh() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        server = ControlServer(workspace: workspace)
        server.start()

        installKeybinds()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Update titlebar dir + sidebar footer (git) for the focused pane. Git runs
    /// off-main so the shell-outs never block the UI.
    private func refresh() {
        let cwd = workspace.activeTree.focusedCwd ?? FileManager.default.currentDirectoryPath
        controller.setDir("halo / \(abbreviateHome(cwd))")
        // Rebuild the sidebar from the live snapshot on every change.
        controller.setProjects(workspace.snapshot())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let g = Git.status(cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.controller.setStatus("normal" + (g.map { " · \($0)" } ?? ""))
                }
            }
        }
    }

    // ponytail: hard-coded keybinds. make them config-driven when asked.
    private func installKeybinds() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.modifierFlags.contains(.command) else { return e }
            let shift = e.modifierFlags.contains(.shift)
            switch e.charactersIgnoringModifiers {
            // Split panes (unchanged)
            case "d":  self.workspace.activeTree.splitFocused(shift ? .horizontal : .vertical, cwd: self.workspace.activeTree.focusedCwd); return nil
            // ⌘W: close focused pane; ⌘⇧W: close active session
            case "w":
                if shift {
                    self.workspace.closeSession(self.workspace.activeP, self.workspace.activeS)
                } else {
                    self.workspace.activeTree.closeFocused()
                }
                return nil
            // ⌘B: toggle sidebar
            case "b":  self.controller.toggleSidebar(); return nil
            // ⌘]: focus next pane within the active session
            case "]":  self.workspace.activeTree.focusNext(); return nil
            // ⌘T: new session in the active project (cwd = ~)
            case "t":  self.workspace.newSession(self.workspace.activeP); return nil
            // ⌘}/⌘{: cycle sessions within the active project
            case "}":  self.workspace.nextSession(); return nil
            case "{":  self.workspace.prevSession(); return nil
            // ⌘1–9: select session n in the active project
            case "1","2","3","4","5","6","7","8","9":
                if let n = Int(e.charactersIgnoringModifiers ?? "") {
                    self.workspace.selectSessionInActiveProject(n)
                }
                return nil
            default:   return e
            }
        }
    }
}

/// Append config projects from `halo-projects = ~/a, ~/b` into the workspace.
/// The home project (index 0) is already created by Workspace.init; config
/// projects are appended as collapsed + empty (lazy).
@MainActor
func loadProjects(_ settings: [String: String], into workspace: Workspace) {
    let raw = settings["halo-projects"]?
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    let home = NSHomeDirectory()
    for raw in raw {
        let path = (raw as NSString).expandingTildeInPath
        guard path != home else { continue }   // don't duplicate the home project
        let name = (path as NSString).lastPathComponent
        workspace.appendProject(name: name, path: path)
    }
}


func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
