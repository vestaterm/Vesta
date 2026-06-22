import AppKit

let argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "selfcheck" {
    // Pure-logic checks only. PaneTree/Tabs/Chrome spawn real ghostty surfaces,
    // which need a live app + run loop — exercised by actually launching the app.
    _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck()
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
        let projects = loadProjects(ghostty.settings)
        let startCwd = projects.first?.path

        workspace = Workspace(theme: theme, cwd: startCwd)
        controller = HaloWindowController(
            theme: theme, content: workspace.container,
            projects: projects,
            onSelectProject: { [weak self] p in self?.workspace.newTab(cwd: p.path) })

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
            case "d":  self.workspace.activeTree.splitFocused(shift ? .horizontal : .vertical, cwd: self.workspace.activeTree.focusedCwd); return nil
            case "w":  shift ? self.workspace.closeTab() : self.workspace.activeTree.closeFocused(); return nil
            case "b":  self.controller.toggleSidebar(); return nil
            case "]":  self.workspace.activeTree.focusNext(); return nil
            case "t":  self.workspace.newTab(cwd: self.workspace.activeTree.focusedCwd); return nil
            case "}":  self.workspace.nextTab(); return nil
            case "{":  self.workspace.prevTab(); return nil
            case "1","2","3","4","5","6","7","8","9":
                if let n = Int(e.charactersIgnoringModifiers ?? "") { self.workspace.selectTab(n - 1) }
                return nil
            default:   return e
            }
        }
    }
}

/// Projects come from `halo-projects = ~/a, ~/b` in the ghostty config; if unset,
/// the launch directory is the one project.
func loadProjects(_ settings: [String: String]) -> [Project] {
    let raw = settings["halo-projects"]?
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    let paths = raw.isEmpty ? [FileManager.default.currentDirectoryPath] : raw.map { ($0 as NSString).expandingTildeInPath }
    return paths.map { Project(name: ($0 as NSString).lastPathComponent, path: $0) }
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
