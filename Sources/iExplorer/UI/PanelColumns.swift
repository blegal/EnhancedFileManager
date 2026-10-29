import AppKit

/// Vue en colonnes (à la Finder) d'un panneau, fondée sur NSBrowser.
/// Le panneau suit la sélection : son dossier courant est celui de la colonne sélectionnée.
final class FileBrowser: NSBrowser, NSMenuDelegate {
    var keyHandler: ((NSEvent) -> Bool)?
    var contextMenuProvider: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let menu = NSMenu()
        menu.delegate = self
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Retour, Espace, Tab… non traités par la colonne remontent jusqu'ici.
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Le clic droit sélectionne d'abord la ligne cliquée, comme dans le Finder.
        if clickedRow >= 0, clickedColumn >= 0, !(selectedRowIndexes(inColumn: clickedColumn)?.contains(clickedRow) ?? false) {
            selectRow(clickedRow, inColumn: clickedColumn)
            sendAction()
        }
        guard let source = contextMenuProvider?() else { return }
        for item in source.items {
            source.removeItem(item)
            menu.addItem(item)
        }
    }
}

extension PanelViewController: NSBrowserDelegate {
    func configureBrowser() {
        // Cellules avec icône (sinon le navigateur utilise de simples cellules de texte).
        browser.cellPrototype = NSBrowserCell()
        browser.delegate = self
        browser.target = self
        browser.action = #selector(browserSelectionChanged(_:))
        browser.doubleAction = #selector(browserDoubleClicked(_:))
        browser.sendsActionOnArrowKeys = true
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 180
        browser.setDefaultColumnWidth(220)
        browser.takesTitleFromPreviousColumn = false
        browser.isTitled = false
        browser.backgroundColor = .clear
        browser.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        browser.contextMenuProvider = { [weak self] in self?.contextMenu() }
        browser.registerForDraggedTypes([.fileURL])
        browser.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        browser.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
    }

    /// Racine des colonnes : le dossier personnel si on y est, sinon la racine du volume.
    var browserRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        return currentURL.isInside(home) ? home : BreadcrumbView.volumeRoot(of: currentURL)
    }

    /// Contenu (trié, mis en cache) d'un dossier affiché en colonne.
    func browserListing(_ url: URL) -> [FileItem] {
        let key = url.standardizedFileURL.path
        if let cached = browserCache[key] { return cached }
        var listing = Self.sorted((try? FileItem.contents(of: url, showHidden: Preferences.showHiddenFiles)) ?? [], by: sortDescriptor)
        // Un dossier masqué (ex. /private) qui mène au dossier courant doit rester visible pour garder le chemin.
        let current = currentURL.standardizedFileURL.path
        if current.hasPrefix(key == "/" ? "/" : key + "/"), current != key,
           let next = current.dropFirst(key == "/" ? 1 : key.count + 1).split(separator: "/").first,
           !listing.contains(where: { $0.name == next }) {
            listing.append(FileItem(url: url.appendingPathComponent(String(next))))
            listing = Self.sorted(listing, by: sortDescriptor)
        }
        browserCache[key] = listing
        return listing
    }

    private func fileItem(_ item: Any?) -> FileItem? { item as? FileItem }

    // MARK: NSBrowserDelegate (API par éléments)

    func rootItem(for browser: NSBrowser) -> Any? { FileItem(url: browserRoot) }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let folder = fileItem(item) else { return 0 }
        return browserListing(folder.url).count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        browserListing(fileItem(item)!.url)[index]
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        !(fileItem(item)?.isNavigableDirectory ?? false)
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        fileItem(item)?.name
    }

    func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let item = browser.item(atRow: row, inColumn: column) as? FileItem else { return }
        let icon = item.icon.copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        if let cell = cell as? NSBrowserCell {
            cell.image = icon
            return
        }
        // Cellules de texte (macOS récents) : l'icône est insérée dans le texte, avant le nom.
        guard let cell = cell as? NSCell else { return }
        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        let text = NSMutableAttributedString(attachment: attachment)
        // Couleur Git du nom, lettre d'état et pastilles de tags, comme dans la liste.
        let state = item.url.isFileURL ? gitState(at: item.url, isDirectory: item.isNavigableDirectory) : nil
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        if let color = state?.color { attributes[.foregroundColor] = color }
        text.append(NSAttributedString(string: "  " + item.name, attributes: attributes))
        if let state, !state.letter.isEmpty {
            text.append(NSAttributedString(string: "  " + state.letter, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: state.color]))
        }
        if item.url.isFileURL, !item.finderTags.isEmpty {
            text.append(NSAttributedString(string: "  "))
            text.append(FinderTags.dots(for: item.finderTags, size: 9))
        }
        // Sans style de paragraphe, un texte avec icône trop long pour la colonne n'est pas tronqué mais effacé.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        cell.lineBreakMode = .byTruncatingMiddle
        cell.attributedStringValue = text
    }

    /// Redessine les colonnes (état Git, tags) sans les recharger.
    func refreshBrowserDecorations() {
        var stack: [NSView] = [browser]
        while let view = stack.popLast() {
            view.needsDisplay = true
            stack += view.subviews
        }
    }

    // MARK: Glisser-déposer

    func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool { true }

    func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
        let urls = rowIndexes.compactMap { (browser.item(atRow: $0, inColumn: column) as? FileItem)?.url as NSURL? }
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls)
    }

    /// Dossier de dépôt : la ligne survolée si c'est un dossier, sinon le dossier de la colonne.
    private func browserDropDestination(row: Int, column: Int, operation: NSBrowser.DropOperation) -> URL? {
        if operation == .on, row >= 0, let item = browser.item(atRow: row, inColumn: column) as? FileItem, item.isNavigableDirectory {
            return item.url
        }
        return (browser.parentForItems(inColumn: column) as? FileItem)?.url
    }

    func browser(_ browser: NSBrowser, validateDrop info: NSDraggingInfo, proposedRow row: UnsafeMutablePointer<Int>,
                 column: UnsafeMutablePointer<Int>, dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>) -> NSDragOperation {
        let sources = FileClipboard.fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty, let destination = browserDropDestination(row: row.pointee, column: column.pointee, operation: dropOperation.pointee),
              !sources.contains(where: { $0.isSameLocation(as: destination) }) else { return [] }
        let target = row.pointee >= 0 ? browser.item(atRow: row.pointee, inColumn: column.pointee) as? FileItem : nil
        if dropOperation.pointee == .above || target?.isNavigableDirectory != true {
            // Dépôt dans le dossier de la colonne (toute la colonne est mise en évidence).
            row.pointee = -1
            dropOperation.pointee = .on
        }
        return validatedOperation(info, sources: sources, destination: destination)
    }

    func browser(_ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int, dropOperation: NSBrowser.DropOperation) -> Bool {
        let sources = FileClipboard.fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty, let destination = browserDropDestination(row: row, column: column, operation: dropOperation) else { return false }
        let operation = FileOperationCenter.dropOperation(for: info, sources: sources, destination: destination)
        guard !operation.isEmpty else { return false }
        activate(focusTable: false)
        transfer(operation == .copy ? .copy : .move, sources, to: destination)
        return true
    }

    // MARK: Synchronisation avec le panneau

    /// Place les colonnes sur le dossier courant du panneau (navigation par le fil d'Ariane, l'historique…).
    func syncBrowserToCurrentFolder() {
        guard viewMode == .columns, !currentURL.isRemote else { return }
        browserCache.removeAll()
        let root = browserRoot.standardizedFileURL.path
        let current = currentURL.standardizedFileURL.path
        let relative = current == root ? "" : String(current.dropFirst(root == "/" ? 1 : root.count + 1))
        isSyncingBrowser = true
        browser.loadColumnZero()
        // Sélectionne chaque dossier du chemin, colonne par colonne (chaque sélection charge la colonne suivante).
        var folder = URL(fileURLWithPath: root)
        for (column, component) in relative.split(separator: "/").enumerated() {
            let listing = browserListing(folder)
            guard let row = listing.firstIndex(where: { $0.name == component }) else { break }
            browser.selectRow(row, inColumn: column)
            // La colonne du contenu n'est pas toujours créée par la sélection seule.
            if browser.lastColumn == column { browser.addColumn() }
            folder = folder.appendingPathComponent(String(component))
        }
        isSyncingBrowser = false
        browser.scrollColumnToVisible(browser.lastColumn)
    }

    /// La sélection des colonnes devient celle du panneau.
    @objc func browserSelectionChanged(_ sender: Any?) {
        guard !isSyncingBrowser else { return }
        activate(focusTable: false)
        let column = browser.selectedColumn
        guard column >= 0, let parent = browser.parentForItems(inColumn: column) as? FileItem else { return }
        let parentURL = parent.url.standardizedFileURL
        if !parentURL.isSameLocation(as: currentURL) {
            // Changement de dossier sans recharger les colonnes (elles sont déjà à jour).
            let old = currentURL
            tab.back.append(currentURL)
            tab.forward.removeAll()
            tab.url = parentURL
            followBrowserFolder()
            host?.panel(self, didMoveFrom: old, to: parentURL)
        }
        items = browserListing(parentURL)
        allItems = items
        selectionDidChange()
    }

    @objc private func browserDoubleClicked(_ sender: Any?) {
        guard let item = selectedItems.first, !item.isNavigableDirectory else { return }
        openSelection(nil)
    }

    var browserSelection: IndexSet {
        let column = browser.selectedColumn
        guard column >= 0 else { return [] }
        return browser.selectedRowIndexes(inColumn: column) ?? []
    }

    func selectInBrowser(_ rows: IndexSet) {
        guard viewMode == .columns else { return }
        let column = max(0, browser.lastColumn)
        isSyncingBrowser = true
        browser.selectRowIndexes(rows, inColumn: column)
        isSyncingBrowser = false
    }

    /// Le contenu du dossier courant a changé (surveillance, opération) : rafraîchit sa colonne.
    func reloadBrowserColumn() {
        guard viewMode == .columns else { return }
        let key = currentURL.standardizedFileURL.path
        browserCache[key] = items
        let column = browser.lastColumn
        guard column >= 0 else { return }
        let selection = browser.selectedRowIndexes(inColumn: column)
        isSyncingBrowser = true
        browser.reloadColumn(column)
        if let selection { browser.selectRowIndexes(selection, inColumn: column) }
        isSyncingBrowser = false
    }

    @objc func showAsColumns(_ sender: Any?) { setViewMode(.columns) }
}
