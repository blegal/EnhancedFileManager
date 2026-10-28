import AppKit
import QuickLookThumbnailing

/// Inspecteur (colonne de droite) : aperçu, informations générales et permissions
/// de la sélection du panneau actif, ou du dossier courant si rien n'est sélectionné.
final class InspectorViewController: NSViewController {
    private let stack = NSStackView()
    private let preview = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var generalGrid = NSGridView()
    private let permissionsBox = NSStackView()
    private var permissionsGrid = NSGridView()
    private var generalHeader: NSView!
    private var permissionsHeader: NSView!
    private var shownURL: URL?
    private var generation = 0

    override func loadView() {
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 10
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.isSelectable = true
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = Theme.secondaryText

        generalHeader = sectionHeader("Général")
        permissionsHeader = sectionHeader("Permissions")
        for grid in [generalGrid, permissionsGrid] {
            grid.rowSpacing = 7
            grid.columnSpacing = 8
        }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 20, right: 16)
        for view in [preview, titleLabel, subtitleLabel, generalHeader!, generalGrid, permissionsHeader!, permissionsGrid] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(14, after: preview)
        stack.setCustomSpacing(16, after: subtitleLabel)
        stack.setCustomSpacing(18, after: generalGrid)

        let document = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            preview.heightAnchor.constraint(equalToConstant: 190),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
        ])
        for header in [generalHeader!, permissionsHeader!] {
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        let root = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        ThemeBackgroundView.install(.toolbar, in: root, bottom: root.safeAreaLayoutGuide.topAnchor)
        ThemeBackgroundView.install(.inspector, in: root, top: root.safeAreaLayoutGuide.topAnchor)
        view = root
    }

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let line = NSBox()
        line.boxType = .separator
        let header = NSStackView(views: [label, line])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        line.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        return header
    }

    // MARK: Affichage

    /// Affiche la sélection du panneau (ou son dossier si la sélection est vide).
    func show(selection: [FileItem], folder: URL) {
        guard isViewLoaded else { return }
        generation += 1
        if selection.count > 1 {
            showMultiple(selection)
            return
        }
        let url = selection.first?.url ?? folder
        shownURL = url
        let item = selection.first ?? FileItem(url: url)
        titleLabel.stringValue = url.path == "/" ? BreadcrumbView.displayName(url) : item.name
        let icon = item.icon
        icon.size = NSSize(width: 256, height: 256)
        preview.image = icon
        if !url.isRemote, !item.isNavigableDirectory { loadPreview(for: url) }

        if url.isRemote {
            subtitleLabel.stringValue = item.isNavigableDirectory ? "Dossier" : [item.kind, item.size.map(Format.size)].compactMap { $0 }.joined(separator: " — ")
            fillGeneral([("Chemin", url.path), ("Serveur", url.host ?? ""),
                         ("Modifié", item.modificationDate.map { Format.dateFormatter.string(from: $0) } ?? "—")])
            setPermissionsVisible(false)
            return
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey,
                                                         .fileSizeKey, .localizedTypeDescriptionKey, .isHiddenKey])
        let sizeText = item.size.map { "\(Format.size($0)) (\($0.formatted()) octets)" }
        subtitleLabel.stringValue = [item.isNavigableDirectory ? "Dossier" : values?.localizedTypeDescription,
                                     item.size.map(Format.size)].compactMap { $0 }.joined(separator: " — ")
        let ext = url.pathExtension
        var rows: [(String, String)] = [
            ("Chemin", url.deletingLastPathComponent().path),
            ("Taille", sizeText ?? "Calcul…"),
            ("Modifié", date(values?.contentModificationDate)),
            ("Créé", date(values?.creationDate)),
            ("Ajouté", date(values?.addedToDirectoryDate)),
        ]
        if !ext.isEmpty, !item.isNavigableDirectory { rows.append(("Extension", ext)) }
        rows.append(("Masqué", (values?.isHidden ?? false) ? "Oui" : "Non"))
        fillGeneral(rows)
        showPermissions(for: url)
        if item.isNavigableDirectory { computeFolderSize(url) }
    }

    private func showMultiple(_ items: [FileItem]) {
        shownURL = nil
        let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        preview.image = image
        preview.contentTintColor = .secondaryLabelColor
        titleLabel.stringValue = "\(items.count) éléments"
        let bytes = items.compactMap(\.size).reduce(0, +)
        let folders = items.filter(\.isNavigableDirectory).count
        subtitleLabel.stringValue = folders > 0 ? "\(folders) dossier(s), \(items.count - folders) fichier(s)" : Format.size(bytes)
        fillGeneral([("Taille des fichiers", Format.size(bytes))])
        setPermissionsVisible(false)
    }

    private func date(_ value: Date?) -> String { value.map { Format.dateFormatter.string(from: $0) } ?? "—" }

    private func loadPreview(for url: URL) {
        let current = generation
        let scale = view.window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 512, height: 380), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.preview.image = image
            }
        }
    }

    private func computeFolderSize(_ url: URL) {
        let current = generation
        // Attend que la sélection soit stable (navigation au clavier) avant de parcourir le dossier.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard self?.generation == current else { return }
            var total: Int64 = 0
            var count = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            while let child = enumerator?.nextObject() as? URL {
                if self?.generation != current { return }
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isDirectory != true {
                    total += Int64(values?.fileSize ?? 0)
                    count += 1
                }
            }
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.updateGeneral("Taille", "\(Format.size(total)) (\(Format.items(count)))")
            }
        }
    }

    // MARK: Grilles

    /// Remplace une grille par une nouvelle (NSGridView ne retire pas les vues de ses lignes supprimées).
    private func replaceGrid(_ old: NSGridView) -> NSGridView {
        let grid = NSGridView()
        grid.rowSpacing = 7
        grid.columnSpacing = 8
        if let index = stack.arrangedSubviews.firstIndex(of: old) {
            old.removeFromSuperview()
            stack.insertArrangedSubview(grid, at: index)
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        return grid
    }

    private func fillGeneral(_ rows: [(String, String)]) {
        generalGrid = replaceGrid(generalGrid)
        for (title, value) in rows {
            let key = NSTextField(labelWithString: title)
            key.font = .systemFont(ofSize: 12)
            key.textColor = .secondaryLabelColor
            let field = NSTextField(labelWithString: value)
            field.font = .systemFont(ofSize: 12)
            field.alignment = .right
            field.lineBreakMode = .byTruncatingMiddle
            field.isSelectable = true
            field.toolTip = value
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            generalGrid.addRow(with: [key, field])
        }
        if generalGrid.numberOfColumns == 2 {
            generalGrid.column(at: 1).xPlacement = .trailing
            generalGrid.column(at: 0).width = 80
        }
        generalHeader.isHidden = rows.isEmpty
    }

    private func updateGeneral(_ title: String, _ value: String) {
        for row in 0..<generalGrid.numberOfRows {
            if (generalGrid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField)?.stringValue == title {
                (generalGrid.cell(atColumnIndex: 1, rowIndex: row).contentView as? NSTextField)?.stringValue = value
            }
        }
    }

    private func setPermissionsVisible(_ visible: Bool) {
        permissionsHeader.isHidden = !visible
        permissionsGrid.isHidden = !visible
    }

    private func showPermissions(for url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            setPermissionsVisible(false)
            return
        }
        permissionsGrid = replaceGrid(permissionsGrid)
        setPermissionsVisible(true)

        func label(_ text: String, secondary: Bool = true) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            return field
        }
        permissionsGrid.addRow(with: [NSGridCell.emptyContentView, label("R"), label("W"), label("X")])
        let rows = [("Propriétaire", 6), ("Groupe", 3), ("Autres", 0)]
        for (title, shift) in rows {
            var cells: [NSView] = [label(title)]
            for bit in [4, 2, 1] {
                let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(togglePermission(_:)))
                checkbox.state = mode & (bit << shift) != 0 ? .on : .off
                checkbox.tag = bit << shift
                checkbox.isEnabled = FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
                    || (attributes[.ownerAccountName] as? String) == NSUserName()
                cells.append(checkbox)
            }
            permissionsGrid.addRow(with: cells)
        }
        let octal = String(mode & 0o777, radix: 8)
        permissionsGrid.addRow(with: [label("Octal"), label("\(symbolic(mode))  \(octal)", secondary: false)])
        permissionsGrid.addRow(with: [label("Propriétaire"), label(attributes[.ownerAccountName] as? String ?? "—", secondary: false)])
        permissionsGrid.addRow(with: [label("Groupe"), label(attributes[.groupOwnerAccountName] as? String ?? "—", secondary: false)])
        let locked = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleLocked(_:)))
        locked.state = (attributes[.immutable] as? Bool) == true ? .on : .off
        permissionsGrid.addRow(with: [label("Verrouillé"), locked])
        for row in permissionsGrid.numberOfRows - 4..<permissionsGrid.numberOfRows {
            permissionsGrid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: row, length: 1))
            permissionsGrid.cell(atColumnIndex: 1, rowIndex: row).xPlacement = .leading
        }
        permissionsGrid.column(at: 0).width = 90
        for column in 1...3 {
            permissionsGrid.column(at: column).xPlacement = .center
            permissionsGrid.column(at: column).width = 30
        }
    }

    private func symbolic(_ mode: Int) -> String {
        let flags = ["r", "w", "x"]
        return (0..<9).map { index in mode & (1 << (8 - index)) != 0 ? flags[index % 3] : "-" }.joined()
    }

    @objc private func togglePermission(_ sender: NSButton) {
        guard let url = shownURL,
              let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber else { return }
        let updated = sender.state == .on ? mode.intValue | sender.tag : mode.intValue & ~sender.tag
        do {
            try FileManager.default.setAttributes([.posixPermissions: updated], ofItemAtPath: url.path)
        } catch {
            NSAlert(error: error).runModal()
        }
        showPermissions(for: url)
    }

    @objc private func toggleLocked(_ sender: NSButton) {
        guard let url = shownURL else { return }
        do {
            try FileManager.default.setAttributes([.immutable: sender.state == .on], ofItemAtPath: url.path)
        } catch {
            NSAlert(error: error).runModal()
        }
        showPermissions(for: url)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
