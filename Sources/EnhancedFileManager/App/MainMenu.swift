import AppKit

enum MainMenu {
    private typealias Panel = PanelViewController

    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "Enhanced File Manager"

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            return item
        }
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func functionKey(_ key: Int) -> String { String(Character(UnicodeScalar(UInt32(key))!)) }
        let separator = { NSMenuItem.separator() }

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu

        submenu(appName, [
            item("À propos de \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            separator(),
            services,
            separator(),
            item("Masquer \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Masquer les autres", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Tout afficher", #selector(NSApplication.unhideAllApplications(_:))),
            separator(),
            item("Quitter \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])

        submenu("Fichier", [
            item("Nouvel onglet", #selector(Panel.newTab(_:)), "t"),
            item("Nouveau dossier", #selector(Panel.newFolder(_:)), "n", [.command, .shift]),
            separator(),
            item("Ouvrir", #selector(Panel.openSelection(_:)), "o"),
            item("Ouvrir dans un nouvel onglet", #selector(Panel.openInNewTab(_:)), "o", [.command, .shift]),
            item("Coup d’œil", #selector(Panel.quickLook(_:)), "y"),
            item("Afficher dans le Finder", #selector(Panel.revealInFinder(_:)), "r", [.command, .shift]),
            item("Ouvrir dans le Terminal", #selector(Panel.openInTerminal(_:)), "t", [.command, .option]),
            item("Ajouter aux favoris", #selector(Panel.addToFavorites(_:)), "t", [.command, .control]),
            separator(),
            item("Renommer", #selector(Panel.renameSelection(_:)), functionKey(NSF2FunctionKey), []),
            item("Copier vers l’autre panneau", #selector(Panel.copyToOtherPanel(_:)), functionKey(NSF5FunctionKey), []),
            item("Déplacer vers l’autre panneau", #selector(Panel.moveToOtherPanel(_:)), functionKey(NSF6FunctionKey), []),
            item("Placer dans la corbeille", #selector(Panel.moveToTrash(_:)), "\u{8}"),
            separator(),
            item("Compresser", #selector(Panel.compressSelection(_:)), "k", [.command, .option]),
            item("Décompresser ici", #selector(Panel.extractHere(_:)), "e", [.command, .option]),
            item("Décompresser vers l’autre panneau", #selector(Panel.extractToOtherPanel(_:)), "e", [.command, .option, .shift]),
            separator(),
            item("Se connecter au serveur…", #selector(MainWindowController.connectToServer(_:)), "k"),
            separator(),
            item("Fermer l’onglet", #selector(Panel.closeTab(_:)), "w"),
            item("Fermer la fenêtre", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])

        submenu("Édition", [
            item("Annuler", Selector(("undo:")), "z"),
            item("Rétablir", Selector(("redo:")), "z", [.command, .shift]),
            separator(),
            item("Couper", #selector(Panel.cut(_:)), "x"),
            item("Copier", #selector(Panel.copy(_:)), "c"),
            item("Coller", #selector(Panel.paste(_:)), "v"),
            item("Déplacer l’élément ici", #selector(Panel.pasteMove(_:)), "v", [.command, .option]),
            item("Dupliquer", #selector(Panel.duplicate(_:)), "d"),
            item("Copier le chemin", #selector(Panel.copyPath(_:)), "c", [.command, .option]),
            separator(),
            item("Tout sélectionner", #selector(NSResponder.selectAll(_:)), "a"),
            separator(),
            item("Rechercher…", #selector(Panel.showSearch(_:)), "f"),
        ])

        let sortMenu = NSMenuItem(title: "Trier par", action: nil, keyEquivalent: "")
        sortMenu.submenu = NSMenu(title: "Trier par")
        for (index, title) in ["Nom", "Taille", "Date de modification", "Type"].enumerated() {
            sortMenu.submenu?.addItem(item(title, #selector(Panel.sortBy(_:)), "\(index + 1)", [.command, .control, .option], tag: index))
        }

        let themeMenu = NSMenuItem(title: "Thème d’icônes", action: nil, keyEquivalent: "")
        themeMenu.submenu = NSMenu(title: "Thème d’icônes")
        for theme in IconTheme.allCases {
            themeMenu.submenu?.addItem(item(theme.title, #selector(AppDelegate.setIconTheme(_:)), tag: theme.rawValue))
            if theme == .system { themeMenu.submenu?.addItem(.separator()) }
        }

        let layoutMenuItem = NSMenuItem(title: "Disposition", action: nil, keyEquivalent: "")
        layoutMenuItem.submenu = MainWindowController.layoutMenu()

        let colorThemeMenu = NSMenuItem(title: "Thème de couleurs", action: nil, keyEquivalent: "")
        colorThemeMenu.submenu = ColorTheme.menu()

        submenu("Présentation", [
            item("Icônes", #selector(Panel.showAsIcons(_:)), "1"),
            item("Liste", #selector(Panel.showAsList(_:)), "2"),
            item("Liste détaillée", #selector(Panel.showAsDetails(_:)), "3"),
            item("Agrandir", #selector(Panel.increaseIconSize(_:)), "+"),
            item("Réduire", #selector(Panel.decreaseIconSize(_:)), "-"),
            item("Taille par défaut", #selector(Panel.resetZoom(_:)), "0"),
            sortMenu,
            themeMenu,
            colorThemeMenu,
            separator(),
            layoutMenuItem,
            item("Répartir les panneaux équitablement", #selector(MainWindowController.equalizePanels(_:)), "=", [.command, .option]),
            item("Panneau suivant", #selector(MainWindowController.focusNextPanel(_:))),
            separator(),
            item("Onglet suivant", #selector(Panel.nextTab(_:)), "\t", .control),
            item("Onglet précédent", #selector(Panel.previousTab(_:)), "\t", [.control, .shift]),
            separator(),
            item("Afficher les fichiers cachés", #selector(AppDelegate.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item("Actualiser", #selector(Panel.refresh(_:)), "r"),
            separator(),
            item("Afficher l’inspecteur", #selector(MainWindowController.toggleInspectorPane(_:)), "i", [.command, .option]),
            item("Afficher le terminal", #selector(MainWindowController.toggleTerminal(_:)), "`", .control),
            item("État Git dans les panneaux", #selector(AppDelegate.toggleGit(_:)), "g", [.command, .control]),
            item("Afficher/masquer la barre latérale", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Plein écran", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        submenu("Aller", [
            item("Précédent", #selector(Panel.goBack(_:)), "["),
            item("Suivant", #selector(Panel.goForward(_:)), "]"),
            item("Dossier parent", #selector(Panel.goUp(_:)), functionKey(NSUpArrowFunctionKey)),
            item("Ouvrir", #selector(Panel.openSelection(_:)), functionKey(NSDownArrowFunctionKey)),
            separator(),
            item("Ordinateur", #selector(Panel.goComputer(_:)), "c", [.command, .shift]),
            item("Départ", #selector(Panel.goHome(_:)), "h", [.command, .shift]),
            item("Bureau", #selector(Panel.goDesktop(_:)), "d", [.command, .shift]),
            item("Documents", #selector(Panel.goDocuments(_:)), "o", [.command, .shift, .option]),
            item("Téléchargements", #selector(Panel.goDownloads(_:)), "l", [.command, .option]),
            item("Applications", #selector(Panel.goApplications(_:)), "a", [.command, .shift]),
            separator(),
            item("Même dossier dans l’autre panneau", #selector(Panel.syncOtherPanel(_:)), "=", .command),
            item("Aller au dossier…", #selector(Panel.goToFolder(_:)), "g", [.command, .shift]),
        ])

        let window = submenu("Fenêtre", [
            item("Placer dans le Dock", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Réduire/agrandir", #selector(NSWindow.performZoom(_:))),
            separator(),
            item("Tout ramener au premier plan", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window

        let help = submenu("Aide", [
            item("Diagnostic des favoris du Finder…", #selector(AppDelegate.showFinderFavoritesDiagnostic(_:))),
        ])
        NSApp.helpMenu = help

        return main
    }
}
