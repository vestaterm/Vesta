import AppKit

/// Builds the app's main menu bar. A bundle-less SPM binary gets no default
/// menus, so Vesta/Edit/View/Window/Help are constructed by hand. App-level items
/// (Hide/Quit/Minimize/copy/paste) use the standard responder-chain selectors;
/// About/Settings/Help/Toggle Sidebar target the AppDelegate.
@MainActor
func makeMainMenu(target: AppDelegate) -> NSMenu {
    let main = NSMenu()

    // ── Vesta (app menu) ──────────────────────────────────────────────────────
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let app = NSMenu()
    appItem.submenu = app
    app.addItem(withTitle: "About Vesta", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        .target = target
    app.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
        .target = target
    app.addItem(.separator())
    app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        .target = target
    app.addItem(withTitle: "Open Config File", action: #selector(AppDelegate.openConfigFile), keyEquivalent: "")
        .target = target
    app.addItem(withTitle: "Import ghostty config…", action: #selector(AppDelegate.importGhosttyConfig), keyEquivalent: "")
        .target = target
    app.addItem(.separator())
    let mkDefault = app.addItem(withTitle: "Make Vesta the Default Terminal", action: #selector(AppDelegate.makeDefaultTerminal), keyEquivalent: "")
    mkDefault.target = target
    mkDefault.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)  // ghostty-style
    app.addItem(.separator())
    app.addItem(withTitle: "Hide Vesta", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit Vesta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    // ── File ───────────────────────────────────────────────────────────────────
    let fileItem = NSMenuItem()
    main.addItem(fileItem)
    let file = NSMenu(title: "File")
    fileItem.submenu = file
    file.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindowMenu), keyEquivalent: "n")
        .target = target

    // ── Edit (responder chain: works in text fields; terminal uses ghostty) ───
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    editItem.submenu = edit
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    // ── View ─────────────────────────────────────────────────────────────────
    let viewItem = NSMenuItem()
    main.addItem(viewItem)
    let view = NSMenu(title: "View")
    viewItem.submenu = view
    view.addItem(withTitle: "Toggle Sidebar", action: #selector(AppDelegate.toggleSidebarMenu), keyEquivalent: "b")
        .target = target
    // No key equivalent: explicit kill must not be confused with ⌘W (which detaches).
    view.addItem(withTitle: "Kill Session", action: #selector(AppDelegate.killSessionMenu), keyEquivalent: "")
        .target = target
    let fsItem = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fsItem.keyEquivalentModifierMask = [.command, .control]

    // ── Window ───────────────────────────────────────────────────────────────
    let windowItem = NSMenuItem()
    main.addItem(windowItem)
    let window = NSMenu(title: "Window")
    windowItem.submenu = window
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    NSApp.windowsMenu = window

    // ── Help ─────────────────────────────────────────────────────────────────
    let helpItem = NSMenuItem()
    main.addItem(helpItem)
    let help = NSMenu(title: "Help")
    helpItem.submenu = help
    help.addItem(withTitle: "Vesta Help", action: #selector(AppDelegate.showHelp), keyEquivalent: "?")
        .target = target
    NSApp.helpMenu = help

    return main
}
