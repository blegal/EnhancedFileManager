import AppKit
import DiskUsageKit
import UpdateKit

/// Une fenêtre par onglet (onglets natifs) : l'accueil, puis une analyse par onglet.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [NSWindow] = []
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = true
        let home = openHome(beside: nil)
        // Barre d'onglets seulement à partir de deux onglets (le système l'affiche alors de lui-même) :
        // annule le réglage « toujours afficher » mémorisé par macOS, une fois la fenêtre à l'écran.
        DispatchQueue.main.async {
            if home.tabGroup?.isTabBarVisible == true, (home.tabbedWindows?.count ?? 1) <= 1 { home.toggleTabBar(nil) }
        }
        launched = true
        pendingURLs.forEach { openAnalysis($0, beside: home) }
        pendingURLs = []
        NSApp.activate()
        Updater.shared.checkAtLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dossier déposé sur l'icône du Dock ou ouvert avec iBaobab.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        guard launched else { pendingURLs += folders; return }
        folders.forEach { openAnalysis($0, beside: NSApp.keyWindow) }
    }

    // MARK: Onglets

    @discardableResult
    func openHome(beside existing: NSWindow?) -> NSWindow {
        let home = HomeViewController()
        home.onAnalyze = { [weak self, weak home] url in self?.openAnalysis(url, beside: home?.view.window) }
        home.onChooseFolder = { [weak self] in self?.chooseFolder(nil) }
        return show(home, title: "Accueil", beside: existing)
    }

    /// Ouvre une analyse dans un nouvel onglet ; `source` partage son arbre déjà analysé.
    @discardableResult
    func openAnalysis(_ url: URL, beside existing: NSWindow?, sharingTreeOf source: AnalysisViewController? = nil) -> NSWindow {
        let analysis = AnalysisViewController(url: url, source: source)
        analysis.onOpenInNewTab = { [weak self, weak analysis] url in
            self?.openAnalysis(url, beside: analysis?.view.window, sharingTreeOf: analysis)
        }
        return show(analysis, title: url.displayName, beside: existing)
    }

    private func show(_ controller: NSViewController, title: String, beside existing: NSWindow?) -> NSWindow {
        let window = NSWindow(contentViewController: controller)
        // Barre de titre fondue dans le contenu, sans titre : le nom n'apparaît que sur les onglets.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = title
        window.tabbingIdentifier = "iBaobab"
        window.tabbingMode = .preferred
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 420)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = MainActor.assumeIsolated { UpdateStatusButton.titlebarAccessory() }
        window.addTitlebarAccessoryViewController(accessory)
        if let existing = existing ?? windows.last {
            window.setFrame(existing.frame, display: false)
            existing.addTabbedWindow(window, ordered: .above)
        } else {
            // Fenêtre compacte au lancement ; sa taille est ensuite retenue.
            window.setContentSize(NSSize(width: 760, height: 680))
            window.center()
            window.setFrameAutosaveName("iBaobab.fenetre")
        }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        (window.contentViewController as? AnalysisViewController)?.close()
        windows.removeAll { $0 === window }
    }

    // MARK: Actions

    /// Bouton « + » de la barre d'onglets et ⌘T.
    @objc func newWindowForTab(_ sender: Any?) {
        openHome(beside: NSApp.keyWindow)
    }

    /// Affiche l'onglet d'accueil (en ouvre un s'il a été fermé).
    @objc func showHome(_ sender: Any?) {
        if let home = windows.first(where: { $0.contentViewController is HomeViewController }) {
            home.makeKeyAndOrderFront(nil)
        } else {
            openHome(beside: NSApp.keyWindow)
        }
    }

    @objc func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Analyser"
        panel.message = "Choisissez un disque ou un dossier à analyser."
        let parent = NSApp.keyWindow
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openAnalysis(url, beside: parent)
        }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Analyse de l'occupation des disques et des dossiers.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }
}
