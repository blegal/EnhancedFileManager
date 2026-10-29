import AppKit

/// Modèles de documents (« Nouveau document › ») : chaque fichier du dossier des modèles devient une entrée,
/// chaque sous-dossier un sous-menu, comme le dossier Modèles de GNOME ou de KDE.
enum DocumentTemplates {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iExplorer/Modèles", isDirectory: true)
    }

    /// Modèles fournis, écrits une seule fois : un dossier vidé par l'utilisateur reste vide.
    private static let defaults: [(name: String, content: String, executable: Bool)] = [
        ("Document texte.txt", "", false),
        ("Document Markdown.md", "# Titre\n\n", false),
        ("Document Typst.typ", "#set page(paper: \"a4\")\n#set text(lang: \"fr\")\n\n= Titre\n\n", false),
        ("Document LaTeX.tex", """
            \\documentclass[a4paper,11pt]{article}
            \\usepackage[french]{babel}

            \\title{Titre}
            \\author{}

            \\begin{document}
            \\maketitle

            \\end{document}

            """, false),
        ("Page HTML.html", """
            <!doctype html>
            <html lang="fr">
            <head>
              <meta charset="utf-8">
              <title>Titre</title>
            </head>
            <body>

            </body>
            </html>

            """, false),
        ("Makefile", ".PHONY: all clean\n\nall:\n\t@echo \"À compléter\"\n\nclean:\n\trm -f *.o\n", false),
        ("Script shell.sh", "#!/bin/zsh\nset -euo pipefail\n\n", true),
        ("Script Python.py", "#!/usr/bin/env python3\n\n\ndef main():\n    pass\n\n\nif __name__ == \"__main__\":\n    main()\n", true),
        ("Tableau CSV.csv", "colonne 1,colonne 2\n", false),
    ]

    static func installDefaults() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for template in defaults {
            let url = folder.appendingPathComponent(template.name)
            try? template.content.write(to: url, atomically: true, encoding: .utf8)
            if template.executable { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
    }

    /// Contenu visible d'un dossier de modèles, dossiers d'abord, par ordre alphabétique.
    static func entries(in directory: URL = folder) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.sorted {
            let (a, b) = ($0.isExistingDirectory, $1.isExistingDirectory)
            return a != b ? a : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Entrées du menu : un modèle par fichier (titre sans extension), un sous-menu par dossier.
    static func menuItems(target: AnyObject?, action: Selector, in directory: URL = folder) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for url in entries(in: directory) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            if url.isExistingDirectory, !NSWorkspace.shared.isFilePackage(atPath: url.path) {
                let item = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
                item.image = icon
                item.submenu = NSMenu()
                menuItems(target: target, action: action, in: url).forEach(item.submenu!.addItem)
                items.append(item)
                continue
            }
            let name = url.lastPathComponent
            let title = name.hasPrefix(".") ? name : (name as NSString).deletingPathExtension
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.image = icon
            item.representedObject = url
            item.toolTip = name
            items.append(item)
        }
        return items
    }
}

extension FileOperationCenter {
    /// Copie d'un modèle dans `directory`, sous son nom (« Makefile 2 » s'il existe déjà) ; annulable.
    func create(fromTemplate template: URL, in directory: URL, undoManager: UndoManager?) throws -> URL {
        let url = uniqueURL(for: directory.appendingPathComponent(template.lastPathComponent), suffix: "")
        try FileManager.default.copyItem(at: template, to: url)
        undoManager?.registerUndo(withTarget: self) { $0.trash([url], undoManager: undoManager, actionName: "Nouveau document") }
        undoManager?.setActionName("Nouveau document")
        return url
    }
}

/// Sous-menu « Nouveau document » de la barre de menus, reconstruit à chaque ouverture ;
/// ses entrées passent par la chaîne des répondeurs jusqu'au panneau actif.
final class NewDocumentMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = NewDocumentMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        PanelViewController.fillNewDocumentMenu(menu, target: nil)
    }
}
