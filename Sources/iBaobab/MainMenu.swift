import AppKit
import DiskUsageKit
import UpdateKit

/// Barre de menus d'iBaobab (actions envoyées au premier répondeur).
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "iBaobab")
        app.addItem(withTitle: "À propos d'iBaobab", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Rechercher les mises à jour…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
            .target = MainActor.assumeIsolated { Updater.shared }
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Masquer iBaobab", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Masquer les autres", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Tout afficher", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quitter iBaobab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "Fichier")
        file.addItem(withTitle: "Nouvel onglet", action: #selector(AppDelegate.newWindowForTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Analyser un dossier…", action: #selector(AppDelegate.chooseFolder(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Analyser de nouveau", action: #selector(AnalysisViewController.rescan(_:)), keyEquivalent: "r")
        file.addItem(withTitle: "Afficher dans le Finder", action: #selector(AnalysisViewController.revealInFinder(_:)), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .option]
        file.addItem(.separator())
        file.addItem(withTitle: "Fermer l'onglet", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(main, "Édition")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let present = submenu(main, "Présentation")
        for style in DiskChartStyle.allCases {
            let item = present.addItem(withTitle: style.title, action: #selector(AnalysisViewController.selectStyle(_:)), keyEquivalent: "\(style.rawValue + 1)")
            item.tag = style.rawValue
        }
        present.addItem(.separator())
        present.addItem(withTitle: "Afficher la barre d'onglets", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        present.addItem(withTitle: "Afficher tous les onglets", action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: "\\")
            .keyEquivalentModifierMask = [.command, .shift]
        present.addItem(withTitle: "Plein écran", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let go = submenu(main, "Aller")
        go.addItem(withTitle: "Précédent", action: #selector(AnalysisViewController.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: "Suivant", action: #selector(AnalysisViewController.goForward(_:)), keyEquivalent: "]")
        go.addItem(withTitle: "Dossier parent", action: #selector(AnalysisViewController.goUp(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        go.addItem(.separator())
        go.addItem(withTitle: "Accueil", action: #selector(AppDelegate.showHome(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .shift]

        let window = submenu(main, "Fenêtre")
        window.addItem(withTitle: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Tout ramener au premier plan", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}
