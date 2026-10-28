import AppKit

/// Un élément d'une arborescence comparée (chemin relatif à la racine).
struct TreeEntry {
    let isDirectory: Bool
    let size: Int64
    let date: Date?
    /// Les listes SFTP ne donnent l'heure qu'à la minute près.
    var minutePrecision = false
}

/// Résultat de la comparaison d'un chemin relatif.
struct CompareRow {
    enum State { case onlyLeft, onlyRight, leftNewer, rightNewer, different, identical }
    enum Action { case toRight, toLeft, skip, deleteRight, deleteLeft }

    let path: String
    let left: TreeEntry?
    let right: TreeEntry?
    let state: State
    var action: Action
}

enum TreeComparer {
    /// Liste récursive (ou non) d'un dossier local ou SFTP. Un dossier présent d'un seul côté
    /// n'est pas parcouru : il sera copié d'un bloc.
    static func list(_ root: URL, recursive: Bool, showHidden: Bool) throws -> [String: TreeEntry] {
        var result: [String: TreeEntry] = [:]
        if root.isRemote {
            let session = try SFTPManager.shared.session(for: root)
            func walk(_ path: String, prefix: String) throws {
                for entry in try session.list(path).entries where showHidden || !entry.name.hasPrefix(".") {
                    let relative = prefix + entry.name
                    result[relative] = TreeEntry(isDirectory: entry.isDirectory, size: entry.size, date: entry.date, minutePrecision: true)
                    if recursive, entry.isDirectory { try walk(entry.path, prefix: relative + "/") }
                }
            }
            try walk(root.path, prefix: "")
            return result
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options, errorHandler: { _, _ in true })
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            result[String(path.dropFirst(base.count + 1))] = TreeEntry(isDirectory: isFolder, size: Int64(values?.fileSize ?? 0),
                                                                        date: values?.contentModificationDate)
        }
        return result
    }

    static func compare(left: [String: TreeEntry], right: [String: TreeEntry]) -> [CompareRow] {
        var rows: [CompareRow] = []
        let paths = Set(left.keys).union(right.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var collapsed: [String] = []
        for path in paths {
            // Contenu d'un dossier présent d'un seul côté : représenté par le dossier lui-même.
            if collapsed.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            let l = left[path], r = right[path]
            let state: CompareRow.State
            switch (l, r) {
            case (let l?, nil):
                state = .onlyLeft
                if l.isDirectory { collapsed.append(path) }
            case (nil, let r?):
                state = .onlyRight
                if r.isDirectory { collapsed.append(path) }
            case (let l?, let r?):
                if l.isDirectory && r.isDirectory { continue } // les dossiers communs ne sont pas des lignes
                // Comparaison à la minute près si un côté est distant, sinon avec 2 s de tolérance.
                let coarse = l.minutePrecision || r.minutePrecision
                func rounded(_ date: Date?) -> TimeInterval {
                    let time = (date ?? .distantPast).timeIntervalSinceReferenceDate
                    return coarse ? (time / 60).rounded(.down) * 60 : time
                }
                let delta = rounded(l.date) - rounded(r.date)
                let tolerance: TimeInterval = coarse ? 0 : 2
                if l.size == r.size && abs(delta) <= tolerance { state = .identical }
                else if delta > tolerance { state = .leftNewer }
                else if -delta > tolerance { state = .rightNewer }
                else { state = .different }
            case (nil, nil):
                continue
            }
            rows.append(CompareRow(path: path, left: l, right: r, state: state, action: .skip))
        }
        return rows
    }
}

/// Fenêtre de comparaison et de synchronisation de deux dossiers.
final class CompareController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode: Int { case bidirectional, mirrorToRight, mirrorToLeft }

    var onFinished: (() -> Void)?

    private let leftRoot: URL
    private let rightRoot: URL
    private var rows: [CompareRow] = []
    private var visibleRows: [Int] = []
    private var generation = 0

    private let recursiveBox = NSButton(checkboxWithTitle: "Sous-dossiers", target: nil, action: nil)
    private let hideIdenticalBox = NSButton(checkboxWithTitle: "Masquer les identiques", target: nil, action: nil)
    private let deleteBox = NSButton(checkboxWithTitle: "Supprimer les éléments absents de la source", target: nil, action: nil)
    private let modePopup = NSPopUpButton()
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "Comparaison…")
    private let spinner = NSProgressIndicator()
    private let syncButton = NSButton(title: "Synchroniser", target: nil, action: nil)

    init(left: URL, right: URL) {
        leftRoot = left
        rightRoot = right
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func display(_ url: URL) -> String {
        url.isRemote ? url.absoluteString : (url.path as NSString).abbreviatingWithTildeInPath
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Comparer et synchroniser")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let paths = NSTextField(labelWithString: "Gauche : \(Self.display(leftRoot))\nDroite : \(Self.display(rightRoot))")
        paths.textColor = .secondaryLabelColor
        paths.font = .systemFont(ofSize: 11)
        paths.lineBreakMode = .byTruncatingMiddle
        paths.maximumNumberOfLines = 2
        paths.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        recursiveBox.state = .on
        hideIdenticalBox.state = .on
        for box in [recursiveBox, hideIdenticalBox, deleteBox] { box.target = self }
        recursiveBox.action = #selector(compare)
        hideIdenticalBox.action = #selector(filterChanged)
        deleteBox.action = #selector(modeChanged)
        modePopup.addItems(withTitles: ["Dans les deux sens (le plus récent gagne)", "Miroir : gauche → droite", "Miroir : droite → gauche"])
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        let options = NSStackView(views: [modePopup, recursiveBox, hideIdenticalBox])
        options.spacing = 14

        let columns: [(String, String, CGFloat)] = [("path", "Élément", 300), ("left", "Gauche", 150), ("action", "Action", 60), ("right", "Droite", 150)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            if id == "action" { column.headerCell.alignment = .center }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.action = #selector(tableClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        let hint = NSTextField(labelWithString: "Cliquez sur une action pour la changer : → copier vers la droite, ← vers la gauche, ✕ ignorer.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        let close = NSButton(title: "Fermer", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        syncButton.target = self
        syncButton.action = #selector(synchronize)
        syncButton.keyEquivalent = "\r"
        syncButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spinner, summary, spacer, close, syncButton])

        let root = NSStackView(views: [title, paths, options, deleteBox, scroll, hint, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true
        buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 760).isActive = true
        paths.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -44).isActive = true
        view = root
        modeChanged()
        compare()
    }

    private var mode: Mode { Mode(rawValue: modePopup.indexOfSelectedItem) ?? .bidirectional }

    @objc private func compare() {
        generation += 1
        let current = generation
        let recursive = recursiveBox.state == .on
        let showHidden = Preferences.showHiddenFiles
        spinner.startAnimation(nil)
        summary.stringValue = "Comparaison…"
        syncButton.isEnabled = false
        let leftRoot = leftRoot, rightRoot = rightRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> [CompareRow] in
                let left = try TreeComparer.list(leftRoot, recursive: recursive, showHidden: showHidden)
                let right = try TreeComparer.list(rightRoot, recursive: recursive, showHidden: showHidden)
                return TreeComparer.compare(left: left, right: right)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, current == generation else { return }
                spinner.stopAnimation(nil)
                switch result {
                case .success(let rows):
                    self.rows = rows
                    applyDefaultActions()
                case .failure(let error):
                    summary.stringValue = "Comparaison impossible : \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func modeChanged() {
        deleteBox.isEnabled = mode != .bidirectional
        if mode == .bidirectional { deleteBox.state = .off }
        applyDefaultActions()
    }

    /// Action proposée pour chaque ligne selon le mode.
    private func applyDefaultActions() {
        let delete = deleteBox.state == .on
        for index in rows.indices {
            let state = rows[index].state
            switch mode {
            case .bidirectional:
                rows[index].action = switch state {
                case .onlyLeft, .leftNewer: .toRight
                case .onlyRight, .rightNewer: .toLeft
                case .different, .identical: .skip
                }
            case .mirrorToRight:
                rows[index].action = switch state {
                case .onlyRight: delete ? .deleteRight : .skip
                case .identical: .skip
                default: .toRight
                }
            case .mirrorToLeft:
                rows[index].action = switch state {
                case .onlyLeft: delete ? .deleteLeft : .skip
                case .identical: .skip
                default: .toLeft
                }
            }
        }
        filterChanged()
    }

    @objc private func filterChanged() {
        let hide = hideIdenticalBox.state == .on
        visibleRows = rows.indices.filter { !hide || rows[$0].state != .identical }
        table.reloadData()
        updateSummary()
    }

    private func updateSummary() {
        let pending = rows.filter { $0.action != .skip }
        let identical = rows.filter { $0.state == .identical }.count
        if rows.isEmpty {
            summary.stringValue = "Les deux dossiers sont vides."
        } else if pending.isEmpty {
            summary.stringValue = identical == rows.count ? "Les deux côtés sont identiques (\(identical) éléments)." : "Aucune action sélectionnée."
        } else {
            let right = pending.filter { $0.action == .toRight }.count, left = pending.filter { $0.action == .toLeft }.count
            let deletions = pending.filter { $0.action == .deleteLeft || $0.action == .deleteRight }.count
            var parts: [String] = []
            if right > 0 { parts.append("\(right) → droite") }
            if left > 0 { parts.append("\(left) ← gauche") }
            if deletions > 0 { parts.append("\(deletions) suppression(s)") }
            summary.stringValue = parts.joined(separator: ", ") + " — \(identical) identique(s)"
        }
        syncButton.isEnabled = !pending.isEmpty
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[visibleRows[row]]
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: 12)
        func describe(_ side: TreeEntry?) -> String {
            guard let side else { return "—" }
            if side.isDirectory { return "dossier" }
            return "\(Format.size(side.size)) · \(side.date.map { Format.dateFormatter.string(from: $0) } ?? "")"
        }
        let newer: NSColor = .systemGreen
        switch tableColumn?.identifier.rawValue {
        case "path":
            field.stringValue = entry.path + ((entry.left?.isDirectory ?? entry.right?.isDirectory ?? false) ? "/" : "")
            field.toolTip = field.stringValue
        case "left":
            field.stringValue = describe(entry.left)
            field.textColor = entry.state == .leftNewer || entry.state == .onlyLeft ? newer : .secondaryLabelColor
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        case "right":
            field.stringValue = describe(entry.right)
            field.textColor = entry.state == .rightNewer || entry.state == .onlyRight ? newer : .secondaryLabelColor
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        default:
            field.alignment = .center
            field.font = .systemFont(ofSize: 15, weight: .bold)
            switch entry.action {
            case .toRight: field.stringValue = "→"; field.textColor = .systemBlue
            case .toLeft: field.stringValue = "←"; field.textColor = .systemBlue
            case .skip: field.stringValue = entry.state == .identical ? "=" : (entry.state == .different ? "≠" : "✕")
                        field.textColor = entry.state == .different ? .systemOrange : .tertiaryLabelColor
            case .deleteRight, .deleteLeft: field.stringValue = "🗑"; field.textColor = .systemRed
            }
            field.toolTip = Self.describe(entry.state)
        }
        return field
    }

    private static func describe(_ state: CompareRow.State) -> String {
        switch state {
        case .onlyLeft: "Seulement à gauche"
        case .onlyRight: "Seulement à droite"
        case .leftNewer: "Plus récent à gauche"
        case .rightNewer: "Plus récent à droite"
        case .different: "Différent (même date)"
        case .identical: "Identique"
        }
    }

    /// Clic sur la colonne Action : fait défiler les actions possibles.
    @objc private func tableClicked() {
        guard table.clickedRow >= 0, table.clickedColumn == table.column(withIdentifier: NSUserInterfaceItemIdentifier("action")) else { return }
        let index = visibleRows[table.clickedRow]
        let entry = rows[index]
        var cycle: [CompareRow.Action] = [.skip]
        if entry.left != nil { cycle.append(.toRight) }
        if entry.right != nil { cycle.append(.toLeft) }
        if entry.left == nil { cycle.append(.deleteRight) }
        if entry.right == nil { cycle.append(.deleteLeft) }
        let position = cycle.firstIndex(of: entry.action) ?? 0
        rows[index].action = cycle[(position + 1) % cycle.count]
        table.reloadData(forRowIndexes: [table.clickedRow], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        updateSummary()
    }

    // MARK: Synchronisation

    @objc private func synchronize() {
        let pending = rows.filter { $0.action != .skip }
        let deletions = pending.filter { $0.action == .deleteLeft || $0.action == .deleteRight }
        if !deletions.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Supprimer \(deletions.count) élément(s) ?"
            alert.informativeText = "En local, ils sont placés dans la corbeille ; sur un serveur SFTP, la suppression est définitive."
            alert.addButton(withTitle: "Synchroniser").hasDestructiveAction = true
            alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        FileOperationCenter.shared.synchronize(pending, left: leftRoot, right: rightRoot) { [weak self] in
            self?.onFinished?()
        }
        closeWindow()
    }

    @objc private func closeWindow() {
        generation += 1
        if let window = view.window, let parent = window.sheetParent { parent.endSheet(window) }
    }
}

// MARK: - Exécution

extension FileOperationCenter {
    /// Applique les actions d'une comparaison en tâche de fond, en conservant les dates de modification.
    func synchronize(_ actions: [CompareRow], left: URL, right: URL, completion: @escaping () -> Void) {
        let job = FileJob(title: "Synchronisation de « \(left.lastPathComponent) » et « \(right.lastPathComponent) »")
        job.countsItems = true
        job.setTotal(Int64(actions.count))
        addJob(job)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var sessions: [String: SFTPSession] = [:]
            func session(_ url: URL) throws -> SFTPSession {
                if let existing = sessions[url.sftpKey] { return existing }
                let session = try SFTPManager.shared.dedicatedSession(for: url)
                try session.connect()
                sessions[url.sftpKey] = session
                return session
            }
            let staging = fm.temporaryDirectory.appendingPathComponent("efm-sync-\(UUID().uuidString)")
            defer {
                sessions.values.forEach { $0.close() }
                try? fm.removeItem(at: staging)
            }
            func exists(_ url: URL) -> Bool {
                guard url.isRemote else { return fm.fileExists(atPath: url.path) }
                let entries = (try? session(url).list(url.deletingLastPathComponent().path).entries) ?? []
                return entries.contains { $0.name == url.lastPathComponent }
            }
            func remove(_ url: URL) throws {
                if url.isRemote { try session(url).removeRecursively(url.path) } else { try fm.trashItem(at: url, resultingItemURL: nil) }
            }
            func makeParent(of url: URL) throws {
                let parent = url.deletingLastPathComponent()
                if parent.isRemote {
                    // mkdir -p côté serveur, dossier par dossier.
                    let remote = try session(parent)
                    var path = ""
                    for component in parent.path.split(separator: "/") {
                        path += "/" + component
                        if !remote.isDirectory(path) { try remote.makeDirectory(path) }
                    }
                } else {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }
            }
            func copy(_ source: URL, to target: URL) throws {
                if exists(target) { try remove(target) }
                try makeParent(of: target)
                switch (source.isRemote, target.isRemote) {
                case (false, false):
                    try fm.copyItem(at: source, to: target)
                case (false, true):
                    try session(target).run("put -rp \(SFTPSession.escape(source.path)) \(SFTPSession.escape(target.path))", timeout: 24 * 3600)
                case (true, false):
                    try session(source).run("get -rp \(SFTPSession.escape(source.path)) \(SFTPSession.escape(target.path))", timeout: 24 * 3600)
                case (true, true):
                    let local = staging.appendingPathComponent(UUID().uuidString).appendingPathComponent(source.lastPathComponent)
                    try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try session(source).run("get -rp \(SFTPSession.escape(source.path)) \(SFTPSession.escape(local.path))", timeout: 24 * 3600)
                    try session(target).run("put -rp \(SFTPSession.escape(local.path)) \(SFTPSession.escape(target.path))", timeout: 24 * 3600)
                }
            }
            var failures: [String] = []
            for (index, row) in actions.enumerated() where !job.isCancelled {
                job.setStatus(row.path)
                let leftURL = left.appendingPathComponent(row.path), rightURL = right.appendingPathComponent(row.path)
                do {
                    switch row.action {
                    case .toRight: try copy(leftURL, to: rightURL)
                    case .toLeft: try copy(rightURL, to: leftURL)
                    case .deleteRight: try remove(rightURL)
                    case .deleteLeft: try remove(leftURL)
                    case .skip: break
                    }
                } catch {
                    failures.append("\(row.path) : \(error.localizedDescription)")
                }
                job.setDone(Int64(index + 1))
            }
            DispatchQueue.main.async {
                self.removeJob(job)
                if !failures.isEmpty {
                    self.showError("Synchronisation terminée avec \(failures.count) erreur(s).\n" + failures.prefix(10).joined(separator: "\n"))
                }
                completion()
            }
        }
    }
}

extension PanelViewController {
    @objc func compareWithOtherPanel(_ sender: Any?) {
        guard let other = host?.targetPanels(for: self).first, let window = view.window else { NSSound.beep(); return }
        // « Gauche » est le panneau d'indice le plus petit (sa position à l'écran).
        let (left, right) = index < other.index ? (self, other) : (other, self)
        let controller = CompareController(left: left.currentURL, right: right.currentURL)
        controller.onFinished = { [weak self, weak other] in
            self?.reload()
            other?.reload()
        }
        window.beginSheet(NSWindow(contentViewController: controller))
    }
}
