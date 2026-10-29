import AppKit

/// Vue à plat : tous les fichiers de l'arborescence dans une seule liste (comme Ctrl+B dans Total Commander).
/// Le dossier de chaque fichier s'affiche dans la colonne Type ; on la quitte en changeant de dossier.
extension FileItem {
    static let flatLimit = 10_000

    /// Fichiers sous `directory`, sans les dossiers (les paquets comptent comme des fichiers), 10 000 au plus.
    static func flatContents(of directory: URL, showHidden: Bool) -> [FileItem] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: resourceKeys,
                                                        options: options, errorHandler: { _, _ in true })
        var found: [FileItem] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true { continue }
            found.append(FileItem(url: url))
            if found.count >= flatLimit { break }
        }
        return found
    }
}

extension PanelViewController {
    var canShowFlatView: Bool { !currentURL.isRemote && viewMode != .columns && !isShowingSearchResults }

    @objc func toggleFlatView(_ sender: Any?) {
        guard isFlatView || canShowFlatView else { return }
        isFlatView.toggle()
        reload(scrollToSelection: true)
    }

    func flatViewMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Vue à plat", action: #selector(toggleFlatView(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: nil)
        item.state = isFlatView ? .on : .off
        return item
    }
}
