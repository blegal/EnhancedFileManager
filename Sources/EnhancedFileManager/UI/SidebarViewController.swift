import AppKit

final class SidebarItem {
    enum Kind { case section, location, volume, connect, server, finderAccess }

    let kind: Kind
    let title: String
    let symbol: String?
    let tint: NSColor?
    let url: URL?
    var detail: String?
    var isEjectable = false
    var isCustomFavorite = false
    var connection: ServerConnection?
    var sftpEndpoint: SFTPEndpoint?
    var children: [SidebarItem] = []

    init(kind: Kind, title: String, symbol: String? = nil, tint: NSColor? = nil, url: URL? = nil) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.url = url
    }
}

/// Barre latérale : Favoris, Appareils, Réseau.
final class SidebarViewController: NSViewController {
    var onNavigate: ((URL) -> Void)?
    /// `nil` : ouvrir le panneau de nouvelle connexion.
    var onConnect: ((ServerConnection?) -> Void)?
    var onEditConnection: ((ServerConnection) -> Void)?

    private let outlineView = NSOutlineView()
    private var sections: [SidebarItem] = []

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 0
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let root = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        ThemeBackgroundView.install(.sidebar, in: root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        }
        NotificationCenter.default.addObserver(forName: Preferences.favoritesChanged, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        NotificationCenter.default.addObserver(forName: SFTPManager.sessionsChanged, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        NotificationCenter.default.addObserver(forName: ColorTheme.changed, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        // Les favoris du Finder peuvent changer pendant que l'app est en arrière-plan.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    func rebuild() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func dir(_ d: FileManager.SearchPathDirectory) -> URL? { fm.urls(for: d, in: .userDomainMask).first }

        let favorites = SidebarItem(kind: .section, title: "Favoris")
        let defaults: [(String, String, NSColor, URL?)] = [
            (home.lastPathComponent, "house", .systemOrange, home),
            ("Bureau", "menubar.dock.rectangle", .systemBlue, dir(.desktopDirectory)),
            ("Documents", "doc.text", .systemBlue, dir(.documentDirectory)),
            ("Téléchargements", "arrow.down.circle", .systemGreen, dir(.downloadsDirectory)),
            ("Applications", "square.grid.2x2", .systemPurple, URL(fileURLWithPath: "/Applications")),
            ("Images", "photo", .systemPink, dir(.picturesDirectory)),
            ("Musique", "music.note", .systemRed, dir(.musicDirectory)),
            ("Vidéos", "film", .systemIndigo, dir(.moviesDirectory)),
        ]
        // Les favoris du Finder s'ils sont lisibles, sinon la liste par défaut.
        let known = defaults.compactMap { entry in entry.3.map { ($0.standardizedFileURL.path, entry) } }
        let style = Dictionary(known, uniquingKeysWith: { first, _ in first })
        if let finder = FinderFavorites.load(), !finder.isEmpty {
            favorites.children = finder.map { entry in
                let match = style[entry.url.standardizedFileURL.path]
                let isICloud = entry.url.path.contains("Mobile Documents/com~apple~CloudDocs")
                return SidebarItem(kind: .location, title: match?.0 ?? entry.name,
                                   symbol: match?.1 ?? (isICloud ? "icloud" : "folder"),
                                   tint: match?.2 ?? (isICloud ? .systemCyan : .systemTeal), url: entry.url)
            }
        } else {
            favorites.children = defaults.compactMap { title, symbol, tint, url in
                guard let url, url.isExistingDirectory else { return nil }
                return SidebarItem(kind: .location, title: title, symbol: symbol, tint: tint, url: url)
            }
        }
        if case .accessDenied? = FinderFavorites.lastFailure {
            // Les favoris du Finder sont protégés : on propose d'ouvrir le bon réglage.
            let hint = SidebarItem(kind: .finderAccess, title: "Afficher les favoris du Finder…", symbol: "lock.open", tint: .secondaryLabelColor)
            favorites.children.append(hint)
        }
        for url in Preferences.customFavorites where url.isExistingDirectory
            && !favorites.children.contains(where: { $0.url?.isSameLocation(as: url) == true }) {
            let item = SidebarItem(kind: .location, title: url.lastPathComponent, symbol: "folder", tint: .systemTeal, url: url)
            item.isCustomFavorite = true
            favorites.children.append(item)
        }

        let devices = SidebarItem(kind: .section, title: "Appareils")
        let network = SidebarItem(kind: .section, title: "Réseau")
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        for url in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isLocal = values?.volumeIsLocal ?? true
            let symbol = !isLocal ? "server.rack" : (values?.volumeIsInternal == true ? "internaldrive" : "externaldrive")
            let item = SidebarItem(kind: .volume, title: values?.volumeLocalizedName ?? url.lastPathComponent,
                                   symbol: symbol, tint: isLocal ? .systemGray : .systemTeal, url: url)
            item.detail = Format.availableCapacity(at: url).map(Format.size)
            item.isEjectable = !isLocal || values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
            (isLocal ? devices : network).children.append(item)
        }
        // Connexions enregistrées, puis sessions SFTP ouvertes sans favori.
        let sessions = SFTPManager.shared.connectedSessions
        let connections = SavedConnections.all
        for connection in connections {
            let item = SidebarItem(kind: .server, title: connection.displayName, symbol: connection.kind.symbol, tint: connection.tint)
            item.connection = connection
            if connection.kind == .sftp, sessions.contains(where: { $0.endpoint.key == connection.sftpEndpoint.key }) {
                item.sftpEndpoint = connection.sftpEndpoint
                item.isEjectable = true
            } else {
                item.detail = connection.kind.rawValue.uppercased()
            }
            network.children.append(item)
        }
        for session in sessions where !connections.contains(where: { $0.kind == .sftp && $0.sftpEndpoint.key == session.endpoint.key }) {
            let item = SidebarItem(kind: .volume, title: session.endpoint.host, symbol: "lock.fill", tint: .systemBlue,
                                   url: session.endpoint.url(path: session.homeDirectory ?? "/"))
            item.sftpEndpoint = session.endpoint
            item.isEjectable = true
            network.children.append(item)
        }
        network.children.append(SidebarItem(kind: .connect, title: "Se connecter au serveur…", symbol: "plus.circle", tint: .secondaryLabelColor))

        sections = [favorites, devices, network]
        outlineView.reloadData()
        sections.forEach { outlineView.expandItem($0) }
    }

    /// Met en surbrillance l'entrée correspondant au dossier du panneau actif.
    func highlight(_ url: URL) {
        for section in sections {
            for item in section.children where item.url.map({ $0.isSameLocation(as: url) }) == true {
                let row = outlineView.row(forItem: item)
                if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? SidebarItem else { return }
        switch item.kind {
        case .location, .volume: if let url = item.url { onNavigate?(url) }
        case .connect: onConnect?(nil)
        case .finderAccess: FinderFavorites.showDiagnostic()
        case .server: onConnect?(item.connection)
        case .section: break
        }
    }

    @objc private func eject(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        if let endpoint = item.sftpEndpoint {
            SFTPManager.shared.disconnect(endpoint)
            return
        }
        guard let url = item.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Preferences.customFavorites.removeAll { $0.isSameLocation(as: url) }
    }

    @objc private func connectSaved(_ sender: NSMenuItem) {
        guard let connection = (sender.representedObject as? ConnectionBox)?.connection else { return }
        onConnect?(connection)
    }

    @objc private func editConnection(_ sender: NSMenuItem) {
        guard let connection = (sender.representedObject as? ConnectionBox)?.connection else { return }
        onEditConnection?(connection)
    }

    @objc private func deleteConnection(_ sender: NSMenuItem) {
        guard let connection = (sender.representedObject as? ConnectionBox)?.connection else { return }
        let alert = NSAlert()
        alert.messageText = "Supprimer la connexion « \(connection.displayName) » ?"
        alert.informativeText = "Le mot de passe enregistré dans le trousseau sera aussi supprimé."
        alert.addButton(withTitle: "Supprimer").hasDestructiveAction = true
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Keychain.delete(connection.keychainAccount)
        SavedConnections.remove(connection)
    }

    @objc private func revealItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarItem)?.children.count ?? sections.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarItem)?.children[index] ?? sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.kind == .section
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.kind == .section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        let kind = (item as? SidebarItem)?.kind
        return kind == .location || kind == .volume
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = ThemedRowView()
        row.isSidebar = true
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        if item.kind == .section {
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: item.title)
            field.font = .systemFont(ofSize: 11, weight: .semibold)
            field.textColor = Theme.secondaryText
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        return SidebarCell(item: item, target: self, ejectAction: #selector(eject(_:)))
    }

    // Déposer des fichiers sur un favori ou un volume.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard index == NSOutlineViewDropOnItemIndex, let destination = (item as? SidebarItem)?.url else { return [] }
        let sources = FileClipboard.fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty, !sources.contains(where: { destination.isInside($0) }) else { return [] }
        return FileOperationCenter.dropOperation(for: info, sources: sources, destination: destination)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let destination = (item as? SidebarItem)?.url else { return false }
        let sources = FileClipboard.fileURLs(from: info.draggingPasteboard)
        let operation = FileOperationCenter.dropOperation(for: info, sources: sources, destination: destination)
        guard !sources.isEmpty, !operation.isEmpty else { return false }
        FileOperationCenter.shared.transfer(operation == .copy ? .copy : .move, sources: sources, to: destination,
                                            undoManager: view.window?.undoManager)
        return true
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? SidebarItem else { return }
        if let url = item.url, url.isFileURL {
            let open = NSMenuItem(title: "Afficher dans le Finder", action: #selector(revealItem(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = url
            menu.addItem(open)
        }
        if item.isCustomFavorite, let url = item.url {
            let remove = NSMenuItem(title: "Retirer des favoris", action: #selector(removeFavorite(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = url
            menu.addItem(remove)
        }
        if let connection = item.connection {
            for (title, action) in [("Se connecter", #selector(connectSaved(_:))), ("Modifier…", #selector(editConnection(_:))),
                                    ("Supprimer…", #selector(deleteConnection(_:)))] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                entry.representedObject = ConnectionBox(connection)
                menu.addItem(entry)
            }
        }
        if let endpoint = item.sftpEndpoint {
            let entry = NSMenuItem(title: "Se déconnecter", action: #selector(disconnect(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = endpoint.key
            menu.addItem(entry)
        }
    }
}

private final class SidebarCell: NSTableCellView {
    init(item: SidebarItem, target: AnyObject, ejectAction: Selector) {
        super.init(frame: .zero)
        let icon = NSImageView()
        if let symbol = item.symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            icon.contentTintColor = item.tint
        }
        let field = NSTextField(labelWithString: item.title)
        field.font = .systemFont(ofSize: 13)
        field.textColor = Theme.text
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let trailing = NSStackView()
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.orientation = .horizontal
        trailing.spacing = 4
        if let detail = item.detail {
            let label = NSTextField(labelWithString: detail)
            label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            label.textColor = .tertiaryLabelColor
            trailing.addArrangedSubview(label)
        }
        if item.isEjectable {
            let eject = NSButton(image: NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Éjecter")!, target: target, action: ejectAction)
            eject.isBordered = false
            eject.symbolConfiguration = .init(pointSize: 10, weight: .regular)
            eject.contentTintColor = .secondaryLabelColor
            eject.toolTip = "Éjecter"
            trailing.addArrangedSubview(eject)
        }

        for view in [icon, field, trailing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = field
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ConnectionBox: NSObject {
    let connection: ServerConnection
    init(_ connection: ServerConnection) { self.connection = connection }
}

extension SidebarViewController {
    @objc fileprivate func disconnect(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let session = SFTPManager.shared.connectedSessions.first(where: { $0.endpoint.key == key }) else { return }
        SFTPManager.shared.disconnect(session.endpoint)
    }
}
