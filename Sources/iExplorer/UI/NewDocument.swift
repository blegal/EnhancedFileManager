import AppKit

/// « Nouveau document › » : crée un fichier à partir d'un modèle puis passe en renommage.
extension PanelViewController {
    func newDocumentMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Nouveau document", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        item.submenu = NSMenu()
        Self.fillNewDocumentMenu(item.submenu!, target: self)
        return item
    }

    static func fillNewDocumentMenu(_ menu: NSMenu, target: AnyObject?) {
        let templates = DocumentTemplates.menuItems(target: target, action: #selector(newDocument(_:)))
        if templates.isEmpty {
            let empty = NSMenuItem(title: "Aucun modèle", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            templates.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Ouvrir le dossier des modèles", action: #selector(openTemplatesFolder(_:)), keyEquivalent: "")
        open.target = target
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(open)
    }

    @objc func newDocument(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? URL, !currentURL.isRemote else { return }
        do {
            let url = try FileOperationCenter.shared.create(fromTemplate: template, in: currentURL, undoManager: undoManager)
            activate()
            reload(selecting: [url]) { [weak self] in self?.renameSelection(nil) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func openTemplatesFolder(_ sender: Any?) {
        DocumentTemplates.installDefaults()
        if currentURL.isRemote { openTab(DocumentTemplates.folder) } else { navigate(to: DocumentTemplates.folder) }
    }
}
