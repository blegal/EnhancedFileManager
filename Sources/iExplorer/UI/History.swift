import AppKit

/// Historique des dossiers ouverts (tous panneaux confondus, 50 au plus, le plus récent en premier).
enum RecentFolders {
    static let changed = Notification.Name("RecentFoldersChanged")
    private static let key = "recentFolders"
    private static let limit = 50

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func record(_ url: URL) {
        guard url.isFileURL else { return }
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard paths.first != url.path else { return }
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        save(Array(paths.prefix(limit)))
    }

    static func remove(_ url: URL) {
        save((UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != url.path })
    }

    static func clear() { save([]) }

    private static func save(_ paths: [String]) {
        UserDefaults.standard.set(paths, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Élément de menu pour un dossier : nom, icône et chemin en info-bulle.
func folderMenuItem(_ url: URL, action: Selector, tag: Int = 0) -> NSMenuItem {
    let item = NSMenuItem(title: BreadcrumbView.displayName(url), action: action, keyEquivalent: "")
    item.representedObject = url
    item.tag = tag
    item.toolTip = url.isRemote ? url.absoluteString : url.path
    let icon = url.isRemote ? NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)! : NSWorkspace.shared.icon(forFile: url.path)
    icon.size = NSSize(width: 16, height: 16)
    item.image = icon
    return item
}

extension PanelViewController {
    var backHistory: [URL] { tab.back }
    var forwardHistory: [URL] { tab.forward }

    /// Recule de `sender.tag` étapes (1 = précédent immédiat).
    @objc func goBackInHistory(_ sender: NSMenuItem) {
        for _ in 0..<max(1, sender.tag) where !tab.back.isEmpty { goBack(nil) }
    }

    @objc func goForwardInHistory(_ sender: NSMenuItem) {
        for _ in 0..<max(1, sender.tag) where !tab.forward.isEmpty { goForward(nil) }
    }

    @objc func openRecentFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if url.isExistingDirectory { navigate(to: url) } else { NSSound.beep() }
    }
}

/// Construit à la volée les menus d'historique (appui long sur précédent / suivant) et des dossiers récents.
final class HistoryMenuProvider: NSObject, NSMenuDelegate {
    enum Kind { case back, forward, recent }

    let kind: Kind
    var panel: () -> PanelViewController?

    init(kind: Kind, panel: @escaping () -> PanelViewController?) {
        self.kind = kind
        self.panel = panel
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch kind {
        case .back, .forward:
            guard let panel = panel() else { return }
            let history = kind == .back ? panel.backHistory : panel.forwardHistory
            let action = kind == .back ? #selector(PanelViewController.goBackInHistory(_:)) : #selector(PanelViewController.goForwardInHistory(_:))
            // Le plus proche en premier.
            for (offset, url) in history.reversed().prefix(25).enumerated() {
                let item = folderMenuItem(url, action: action, tag: offset + 1)
                item.target = panel
                menu.addItem(item)
            }
            if history.isEmpty {
                menu.addItem(NSMenuItem(title: "Aucun historique", action: nil, keyEquivalent: ""))
            }
        case .recent:
            let recents = Array(RecentFolders.all.filter(\.isExistingDirectory).prefix(30))
            for url in recents {
                menu.addItem(folderMenuItem(url, action: #selector(PanelViewController.openRecentFolder(_:))))
            }
            if recents.isEmpty {
                menu.addItem(NSMenuItem(title: "Historique vide", action: nil, keyEquivalent: ""))
            } else {
                menu.addItem(.separator())
                let clear = NSMenuItem(title: "Effacer l’historique", action: #selector(AppDelegate.clearRecentFolders(_:)), keyEquivalent: "")
                clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                menu.addItem(clear)
            }
        }
    }
}
