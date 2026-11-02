import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DictationController!
    private var statusItem: StatusItemController!
    private var hud: HUDController!
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        controller = DictationController()
        settingsWindow = SettingsWindowController(controller: controller)
        statusItem = StatusItemController(controller: controller) { [weak self] in self?.settingsWindow.show() }
        hud = HUDController(controller: controller)

        // First run, or something essential is missing: open Settings so it can be fixed.
        if KeychainStore.loadAPIKey() == nil || !Permissions.accessibilityTrusted || Permissions.microphone != .authorized {
            settingsWindow.show(tab: KeychainStore.loadAPIKey() == nil ? .openAI : .general)
        }
    }

    /// Opening the app again (Finder, Spotlight) shows Settings — the way back if the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    /// Menu bar apps have no visible menu bar, but text fields still route ⌘C/⌘V/⌘A/⌘Z through
    /// the main menu's key equivalents. Without an Edit menu, paste does nothing in Settings.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu?.addItem(withTitle: "Quit Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.cancel()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
