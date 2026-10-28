import AppKit

/// Rangées d'icônes en tête du menu contextuel (menus « palette » de macOS) :
/// actions courantes et couleurs de tags, comme dans le Finder.
extension PanelViewController {
    /// Actions courantes en icônes (le nom apparaît en bulle d'aide).
    func quickActionsPalette(for selection: [FileItem]) -> NSMenuItem {
        var entries: [(String, String, Selector)] = []
        if !selection.isEmpty {
            entries += [("Couper", "scissors", #selector(cut(_:))), ("Copier", "doc.on.doc", #selector(copy(_:)))]
        }
        if FileClipboard.hasFiles { entries.append(("Coller", "doc.on.clipboard", #selector(paste(_:)))) }
        if !selection.isEmpty {
            entries.append(("Dupliquer", "plus.rectangle.on.rectangle", #selector(duplicate(_:))))
            entries.append(selection.count == 1 ? ("Renommer", "pencil", #selector(renameSelection(_:)))
                                                : ("Renommer par lot…", "pencil.and.list.clipboard", #selector(batchRename(_:))))
            if !currentURL.isRemote { entries.append(("Coup d’œil", "eye", #selector(quickLook(_:)))) }
            entries.append((currentURL.isRemote ? "Supprimer du serveur…" : "Placer dans la corbeille", "trash", #selector(moveToTrash(_:))))
        } else {
            entries.append(("Nouveau dossier", "folder.badge.plus", #selector(newFolder(_:))))
            entries.append(("Copier le chemin", "link", #selector(copyPath(_:))))
        }
        let palette = NSMenu(title: "Actions")
        palette.presentationStyle = .palette
        for (title, symbol, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.toolTip = title
            palette.addItem(item)
        }
        return holder(for: palette, title: "Actions")
    }

    /// Pastilles des sept couleurs de tags ; cochées si toute la sélection porte la couleur.
    func tagsPalette(for selection: [FileItem]) -> NSMenuItem {
        let palette = NSMenu(title: "Tags")
        palette.presentationStyle = .palette
        palette.selectionMode = .selectAny
        for standard in FinderTags.standard {
            let item = NSMenuItem(title: standard.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
            item.target = self
            item.tag = standard.index
            item.image = Self.tagDot(standard.color)
            item.toolTip = standard.name
            let count = selection.filter { $0.finderTags.contains { $0.colorIndex == standard.index } }.count
            item.state = count > 0 && count == selection.count ? .on : .off
            palette.addItem(item)
        }
        return holder(for: palette, title: "Tags")
    }

    private func holder(for palette: NSMenu, title: String) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = palette
        return holder
    }

    private static func tagDot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            color.setFill()
            dot.fill()
            color.shadow(withLevel: 0.25)?.setStroke()
            dot.lineWidth = 1
            dot.stroke()
            return true
        }
        return image
    }
}
