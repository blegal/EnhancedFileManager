import AppKit

/// Dossiers dépliables dans les vues en liste, comme dans le Finder : le contenu d'un dossier s'insère
/// sous lui, en retrait, dans `items`. Le reste du panneau (sélection, opérations, Git) n'y voit que des éléments.
extension PanelViewController {
    /// Pas de dépliage en recherche, en vue à plat, regroupé, ni sur un serveur.
    var canExpandFolders: Bool {
        (viewMode == .list || viewMode == .details) && !isShowingSearchResults && !isSearching
            && !isFlatView && grouping == .none && !currentURL.isRemote && !isShowingDiskUsage
    }

    func isExpanded(_ item: FileItem) -> Bool {
        item.isNavigableDirectory && expandedPaths.contains(item.url.normalizedPath)
    }

    /// Insère sous chaque dossier déplié son contenu trié (et ainsi de suite pour les sous-dossiers dépliés).
    static func expandTree(_ list: [FileItem], expanded: Set<String>, showHidden: Bool,
                           by descriptor: NSSortDescriptor, depth: Int = 0) -> [FileItem] {
        guard !expanded.isEmpty else { return list }
        var result: [FileItem] = []
        for item in list {
            item.depth = depth
            result.append(item)
            guard item.isNavigableDirectory, expanded.contains(item.url.normalizedPath),
                  let children = try? FileItem.contents(of: item.url, showHidden: showHidden) else { continue }
            result += expandTree(sorted(children, by: descriptor), expanded: expanded, showHidden: showHidden,
                                 by: descriptor, depth: depth + 1)
        }
        return result
    }

    /// Indices des descendants affichés d'un élément (les lignes suivantes plus en retrait).
    private func descendantRange(of index: Int) -> Range<Int> {
        let depth = items[index].depth
        var end = index + 1
        while end < items.count, items[end].depth > depth { end += 1 }
        return index + 1..<end
    }

    func expandItem(at index: Int) {
        guard canExpandFolders, items.indices.contains(index) else { return }
        let item = items[index]
        guard item.isNavigableDirectory, !isExpanded(item) else { return }
        expandedPaths.insert(item.url.normalizedPath)
        let children = (try? FileItem.contents(of: item.url, showHidden: Preferences.showHiddenFiles)) ?? []
        for child in children where child.isNavigableDirectory { child.folderSize = folderSizes[child.url.normalizedPath] }
        let rows = Self.expandTree(Self.sorted(children, by: sortDescriptor), expanded: expandedPaths,
                                   showHidden: Preferences.showHiddenFiles, by: sortDescriptor, depth: item.depth + 1)
        items.insert(contentsOf: rows, at: index + 1)
        allItems = items
        tableView.insertRows(at: IndexSet(integersIn: index + 1..<index + 1 + rows.count), withAnimation: .slideDown)
        outlineDidChange(row: index)
    }

    func collapseItem(at index: Int) {
        guard items.indices.contains(index), isExpanded(items[index]) else { return }
        expandedPaths.remove(items[index].url.normalizedPath)
        let range = descendantRange(of: index)
        // Une sélection cachée par le repli passe au dossier replié, comme dans le Finder.
        let hidesSelection = tableView.selectedRowIndexes.contains { range.contains($0) }
        items.removeSubrange(range)
        allItems = items
        tableView.removeRows(at: IndexSet(integersIn: range), withAnimation: .slideUp)
        if hidesSelection { tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true) }
        outlineDidChange(row: index)
    }

    private func outlineDidChange(row: Int) {
        let name = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        if name >= 0 { tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: name)) }
        collectionView.reloadData()
        watchExpandedFolders()
        selectionDidChange()
        refreshGit()
    }

    @objc func toggleDisclosure(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard items.indices.contains(row) else { return }
        if isExpanded(items[row]) { collapseItem(at: row) } else { expandItem(at: row) }
    }

    /// → déplie les dossiers sélectionnés ; ← les replie, ou remonte au dossier parent dans l'arbre.
    func handleOutlineKey(expand: Bool) -> Bool {
        guard canExpandFolders else { return false }
        let selection = tableView.selectedRowIndexes
        guard !selection.isEmpty else { return false }
        if expand {
            // De la dernière à la première ligne, pour que les insertions ne décalent pas les suivantes.
            for row in selection.reversed() { expandItem(at: row) }
        } else if selection.count == 1, let row = selection.first, !isExpanded(items[row]) {
            let depth = items[row].depth
            guard depth > 0, let parent = items[..<row].lastIndex(where: { $0.depth < depth }) else { NSSound.beep(); return true }
            tableView.selectRowIndexes(IndexSet(integer: parent), byExtendingSelection: false)
            tableView.scrollRowToVisible(parent)
        } else {
            for row in selection.reversed() { collapseItem(at: row) }
        }
        return true
    }

    /// Recharge aussi le panneau quand le contenu d'un dossier déplié change.
    func watchExpandedFolders() {
        let visible = Set(items.filter(isExpanded).map(\.url.normalizedPath))
        for path in outlineWatchers.keys where !visible.contains(path) { outlineWatchers[path] = nil }
        for path in visible where outlineWatchers[path] == nil {
            let watcher = DirectoryWatcher()
            watcher.onChange = { [weak self] in self?.reload() }
            watcher.watch(URL(fileURLWithPath: path))
            outlineWatchers[path] = watcher
        }
    }

    /// Au changement de dossier, tout est replié.
    func resetOutline() {
        expandedPaths = []
        outlineWatchers = [:]
    }
}
