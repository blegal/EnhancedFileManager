import AppKit
import UpdateKit

enum MainMenu {
    /// Menu « Actions » : actions personnalisées (avec leurs raccourcis) et gestion.
    static func fillActionsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for action in CustomAction.all { menu.addItem(action.menuItem()) }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let manage = NSMenuItem(title: "Gérer les actions…", action: #selector(AppDelegate.manageCustomActions(_:)), keyEquivalent: "")
        manage.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        menu.addItem(manage)
        let byType = NSMenuItem(title: "Actions par type de fichier…", action: #selector(AppDelegate.manageFileActions(_:)), keyEquivalent: "")
        byType.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
        menu.addItem(byType)
    }

    /// Fournit le sous-menu « Dossiers récents » (gardé en vie pour toute la durée de l'app).
    /// Fichier › Créer un lien : symbolique ou physique, ici ou dans l'autre panneau.
    private static func linkMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Créer un lien")
        for (title, action, key, modifiers) in [("Lien symbolique ici", #selector(Panel.symlinkHere(_:)), "l", NSEvent.ModifierFlags([.command, .control])),
                                                ("Lien symbolique dans l’autre panneau", #selector(Panel.symlinkInOtherPanel(_:)), String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!)), [.control]),
                                                ("Lien physique ici", #selector(Panel.hardLinkHere(_:)), "", []),
                                                ("Lien physique dans l’autre panneau", #selector(Panel.hardLinkInOtherPanel(_:)), "", [])] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            menu.addItem(entry)
        }
        let item = NSMenuItem(title: "Créer un lien", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static let recentProvider = HistoryMenuProvider(kind: .recent) { nil }

    private typealias Panel = PanelViewController

    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "iExplorer"

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

        let updates = item("Rechercher les mises à jour…", #selector(Updater.checkForUpdates(_:)))
        updates.target = MainActor.assumeIsolated { Updater.shared }

        submenu(appName, [
            item("À propos de \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            updates,
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
            {
                let item = NSMenuItem(title: "Nouveau document", action: nil, keyEquivalent: "")
                item.submenu = NSMenu(title: "Nouveau document")
                item.submenu?.delegate = NewDocumentMenuDelegate.shared
                return item
            }(),
            separator(),
            item("Ouvrir", #selector(Panel.openSelection(_:)), "o"),
            item("Ouvrir dans un nouvel onglet", #selector(Panel.openInNewTab(_:)), "o", [.command, .shift]),
            item("Coup d’œil", #selector(Panel.quickLook(_:)), "y"),
            item("Afficher dans le Finder", #selector(Panel.revealInFinder(_:)), "r", [.command, .shift]),
            item("Ouvrir dans le Terminal", #selector(Panel.openInTerminal(_:)), "t", [.command, .option]),
            item("Ajouter aux favoris", #selector(Panel.addToFavorites(_:)), "t", [.command, .control]),
            item("Partager…", #selector(Panel.shareSelection(_:))),
            item("Sommes de contrôle…", #selector(Panel.showChecksums(_:)), "k", [.command, .control]),
            separator(),
            item("Renommer", #selector(Panel.renameSelection(_:)), functionKey(NSF2FunctionKey), []),
            item("Renommer par lot…", #selector(Panel.batchRename(_:)), "r", [.command, .control]),
            item("Copier vers l’autre panneau", #selector(Panel.copyToOtherPanel(_:)), functionKey(NSF5FunctionKey), []),
            item("Déplacer vers l’autre panneau", #selector(Panel.moveToOtherPanel(_:)), functionKey(NSF6FunctionKey), []),
            linkMenuItem(),
            item("Placer dans la corbeille", #selector(Panel.moveToTrash(_:)), "\u{8}"),
            item("Vérifier les copies", #selector(AppDelegate.toggleVerifyCopies(_:))),
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
            item("Sélectionner selon un motif…", #selector(Panel.selectByPattern(_:)), "a", [.command, .option]),
            item("Désélectionner selon un motif…", #selector(Panel.deselectByPattern(_:)), "a", [.command, .option, .shift]),
            item("Inverser la sélection", #selector(Panel.invertSelection(_:)), "i", [.command, .control]),
            item("Sélectionner les éléments du même type", #selector(Panel.selectSameType(_:))),
            separator(),
            item("Rechercher…", #selector(Panel.showSearch(_:)), "f"),
            item("Filtrer ce dossier…", #selector(Panel.showFilter(_:)), "f", [.command, .option]),
            separator(),
            item("Touches de Total Commander (F3 à F8, + − *)", #selector(AppDelegate.toggleCommanderKeys(_:))),
        ])

        let sortMenu = NSMenuItem(title: "Trier par", action: nil, keyEquivalent: "")
        sortMenu.submenu = NSMenu(title: "Trier par")
        for (index, title) in ["Nom", "Taille", "Date de modification", "Type"].enumerated() {
            sortMenu.submenu?.addItem(item(title, #selector(Panel.sortBy(_:)), "\(index + 1)", [.command, .control, .option], tag: index))
        }

        let groupMenu = NSMenuItem(title: "Regrouper par", action: nil, keyEquivalent: "")
        groupMenu.submenu = NSMenu(title: "Regrouper par")
        for value in PanelGrouping.allCases {
            groupMenu.submenu?.addItem(item(value.title, #selector(Panel.groupBy(_:)), tag: value.rawValue))
            if value == .none { groupMenu.submenu?.addItem(.separator()) }
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
            item("Colonnes", #selector(Panel.showAsColumns(_:)), "4"),
            item("Occupation du disque", #selector(Panel.toggleDiskUsage(_:)), "5"),
            item("Agrandir", #selector(Panel.increaseIconSize(_:)), "+"),
            item("Réduire", #selector(Panel.decreaseIconSize(_:)), "-"),
            item("Taille par défaut", #selector(Panel.resetZoom(_:)), "0"),
            item("Masquer la barre d’état", #selector(Panel.toggleStatusBar(_:)), "/"),
            sortMenu,
            groupMenu,
            item("Vue à plat", #selector(Panel.toggleFlatView(_:)), "b", [.command, .control]),
            item("Calculer la taille des dossiers sélectionnés", #selector(Panel.computeSelectedFolderSizes(_:)), " ", .option),
            item("Calculer la taille de tous les dossiers", #selector(Panel.computeAllFolderSizes(_:)), " ", [.option, .shift]),
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

        let recentItem = NSMenuItem(title: "Historique", action: nil, keyEquivalent: "")
        recentItem.submenu = NSMenu(title: "Historique")
        recentItem.submenu?.delegate = recentProvider

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
            item("Navigation synchronisée", #selector(MainWindowController.toggleSyncNavigation(_:)), "y", [.command, .control]),
            item("Comparer et synchroniser les panneaux…", #selector(Panel.compareWithOtherPanel(_:)), "c", [.command, .control]),
            item("Aller au dossier…", #selector(Panel.goToFolder(_:)), "g", [.command, .shift]),
            recentItem,
        ])

        let actions = submenu("Actions", [])
        fillActionsMenu(actions)

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
