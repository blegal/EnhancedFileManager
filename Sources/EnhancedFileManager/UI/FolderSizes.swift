import AppKit

/// Calcul de la taille des dossiers à la demande (⌥Espace), en arrière-plan.
enum FolderSizeCalculator {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    /// Taille logique totale du contenu ; `isCancelled` est consulté régulièrement.
    static func size(of url: URL, isCancelled: @escaping () -> Bool) -> Int64? {
        if url.isRemote {
            guard let session = try? SFTPManager.shared.session(for: url) else { return nil }
            func walk(_ path: String) -> Int64 {
                guard !isCancelled(), let listing = try? session.list(path) else { return 0 }
                return listing.entries.reduce(0) { total, entry in total + (entry.isDirectory ? walk(entry.path) : entry.size) }
            }
            return walk(url.path)
        }
        var total: Int64 = 0
        var visited = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                        options: [], errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            visited += 1
            if visited % 1000 == 0, isCancelled() { return nil }
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    static func enqueue(_ work: @escaping () -> Void) { queue.addOperation(work) }
}

extension PanelViewController {
    /// ⌥Espace : taille des dossiers sélectionnés.
    @objc func computeSelectedFolderSizes(_ sender: Any?) {
        computeFolderSizes(selectedItems.filter(\.isNavigableDirectory))
    }

    /// ⇧⌥Espace : taille de tous les dossiers affichés.
    @objc func computeAllFolderSizes(_ sender: Any?) {
        computeFolderSizes(items.filter(\.isNavigableDirectory))
    }

    private func computeFolderSizes(_ folders: [FileItem]) {
        let pending = folders.filter { folderSizes[$0.url.normalizedPath] == nil && !computingFolders.contains($0.url.normalizedPath) }
        guard !pending.isEmpty else { return }
        let generation = folderSizeGeneration
        for folder in pending {
            let key = folder.url.normalizedPath
            computingFolders.insert(key)
            let url = folder.url
            FolderSizeCalculator.enqueue { [weak self] in
                let size = FolderSizeCalculator.size(of: url) { [weak self] in
                    // Annulé si le panneau a changé de dossier entre-temps.
                    DispatchQueue.main.sync { self?.folderSizeGeneration != generation }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == folderSizeGeneration else { return }
                    computingFolders.remove(key)
                    if let size { folderSizes[key] = size }
                    applyFolderSizes()
                }
            }
        }
        applyFolderSizes()
    }

    /// Reporte les tailles connues sur les éléments, retrie si besoin et rafraîchit l'affichage.
    func applyFolderSizes() {
        for item in allItems where item.isNavigableDirectory {
            item.folderSize = folderSizes[item.url.normalizedPath]
        }
        if sortDescriptor.key == "size" {
            let selection = selectedURLs
            allItems = Self.sorted(allItems, by: sortDescriptor)
            if !isShowingSearchResults {
                let filter = isSearching && searchBar.scope == .folder ? Self.nameMatcher(for: searchBar.field.stringValue.trimmingCharacters(in: .whitespaces)) : nil
                items = filter.map { match in allItems.filter { item in match(item.name) { item.finderTags } } } ?? allItems
            }
            reloadViews()
            let paths = Set(selection.map(\.normalizedPath))
            setSelection(IndexSet(items.indices.filter { paths.contains(items[$0].url.normalizedPath) }), scroll: false)
        } else {
            let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
            if column >= 0, !items.isEmpty {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<items.count), columnIndexes: [column])
            }
        }
        updateInfo()
    }

    /// Texte de la colonne Taille pour un dossier.
    func folderSizeText(for item: FileItem) -> String {
        if let size = item.folderSize { return Format.size(size) }
        return computingFolders.contains(item.url.normalizedPath) ? "calcul…" : "—"
    }
}
