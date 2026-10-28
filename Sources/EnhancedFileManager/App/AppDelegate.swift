import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowControllers: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        // Une seule fenêtre principale : on restaure la dernière session.
        openWindow(state: SessionStore.load().first)
        // Sauvegarde aussi quand l'app passe en arrière-plan (au cas où elle serait arrêtée brutalement).
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.saveSession()
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard FileOperationCenter.shared.hasActiveJobs else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Des opérations sur les fichiers sont en cours."
        alert.informativeText = "Si vous quittez maintenant, elles seront interrompues."
        alert.addButton(withTitle: "Continuer")
        alert.addButton(withTitle: "Quitter")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !windowControllers.isEmpty { saveSession() }
    }

    private func openWindow(state: WindowState?) {
        let controller = MainWindowController(state: state)
        controller.onClose = { [weak self] closed in
            guard let self else { return }
            // La dernière fenêtre fermée devient la session restaurée au prochain lancement.
            if windowControllers.count == 1 { saveSession() }
            windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(controller)
        controller.showWindow(nil)
    }

    private func saveSession() {
        SessionStore.save(windowControllers.map(\.windowState))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowControllers.first?.showWindow(nil)
        return false
    }

    @objc func toggleGit(_ sender: Any?) {
        if !GitService.isEnabled, !GitService.shared.isAvailable {
            let alert = NSAlert()
            alert.messageText = "Git n’est pas disponible."
            alert.informativeText = "Installez les outils de ligne de commande (xcode-select --install) pour afficher l’état Git."
            alert.runModal()
            (sender as? NSButton)?.state = .off
            return
        }
        GitService.isEnabled.toggle()
    }

    @objc func showFinderFavoritesDiagnostic(_ sender: Any?) {
        FinderFavorites.showDiagnostic()
    }

    @objc func setColorTheme(_ sender: NSMenuItem) {
        ColorTheme.current = ColorTheme(rawValue: sender.tag) ?? .system
    }

    @objc func setIconTheme(_ sender: NSMenuItem) {
        IconTheme.current = IconTheme(rawValue: sender.tag) ?? .system
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Preferences.showHiddenFiles.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setColorTheme(_:)) {
            menuItem.state = menuItem.tag == ColorTheme.current.rawValue ? .on : .off
        }
        if menuItem.action == #selector(setIconTheme(_:)) {
            menuItem.state = menuItem.tag == IconTheme.current.rawValue ? .on : .off
        }
        if menuItem.action == #selector(toggleGit(_:)) {
            menuItem.state = GitService.isEnabled ? .on : .off
        }
        if menuItem.action == #selector(toggleHiddenFiles(_:)) {
            menuItem.state = Preferences.showHiddenFiles ? .on : .off
        }
        return true
    }
}
