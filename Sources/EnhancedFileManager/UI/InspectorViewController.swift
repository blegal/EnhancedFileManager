import AppKit
import QuickLookThumbnailing

/// Inspecteur (colonne de droite) : aperçu, informations générales et permissions
/// de la sélection du panneau actif, ou du dossier courant si rien n'est sélectionné.
final class InspectorViewController: NSViewController {
    private let stack = NSStackView()
    /// Aperçu riche (code, PDF, vidéo…) ; son image sert d'icône / miniature par défaut.
    private let previewPane = PreviewPane()
    private var preview: NSImageView { previewPane.imageView }
    private let gitSection = GitInspectorSection()
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
        for view in [previewPane, titleLabel, subtitleLabel, generalHeader!, generalGrid, permissionsHeader!, permissionsGrid, gitSection] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(18, after: permissionsGrid)
        stack.setCustomSpacing(14, after: previewPane)
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
            previewPane.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            gitSection.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
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
        gitSection.show(url.isRemote ? nil : url)
        let item = selection.first ?? FileItem(url: url)
        titleLabel.stringValue = url.path == "/" ? BreadcrumbView.displayName(url) : item.name
        let icon = item.icon
        icon.size = NSSize(width: 256, height: 256)
        preview.contentTintColor = nil
        // Aperçu riche si le type s'y prête, sinon icône puis miniature.
        if url.isRemote || item.isNavigableDirectory || item.isPackage || !previewPane.show(url) {
            previewPane.showImage(icon)
            if !url.isRemote, !item.isNavigableDirectory { loadPreview(for: url) }
        }

        if url.isRemote {
            subtitleLabel.stringValue = item.isNavigableDirectory ? "Dossier" : [item.kind, item.size.map(Format.size)].compactMap { $0 }.joined(separator: " — ")
            fillGeneral([("Chemin", url.path), ("Serveur", url.host ?? ""),
                         ("Modifié", item.modificationDate.map { Format.dateFormatter.string(from: $0) } ?? "—")])
            showRemotePermissions(for: url)
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
        let tags = FinderTags.read(url)
        if !tags.isEmpty { rows.append(("Tags", tags.map(\.name).joined(separator: ", "))) }
        fillGeneral(rows)
        showPermissions(for: url)
        if item.isNavigableDirectory { computeFolderSize(url) }
    }

    private func showMultiple(_ items: [FileItem]) {
        shownURL = nil
        gitSection.show(nil)
        let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        previewPane.showImage(image)
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

    // MARK: Permissions

    /// Permissions affichées : locales (FileManager) ou distantes (sftp).
    private struct Permissions {
        var mode: Int
        var owner: String
        var group: String
        var ownerID: String
        var groupID: String
        /// Indicateur « verrouillé » (local seulement).
        var immutable: Bool?
        var isDirectory: Bool
    }

    private var shownPermissions: Permissions?

    private func showPermissions(for url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            setPermissionsVisible(false)
            return
        }
        fillPermissions(Permissions(mode: mode & 0o7777,
                                    owner: attributes[.ownerAccountName] as? String ?? "—",
                                    group: attributes[.groupOwnerAccountName] as? String ?? "—",
                                    ownerID: (attributes[.ownerAccountID] as? NSNumber)?.stringValue ?? "",
                                    groupID: (attributes[.groupOwnerAccountID] as? NSNumber)?.stringValue ?? "",
                                    immutable: (attributes[.immutable] as? Bool) == true,
                                    isDirectory: (attributes[.type] as? FileAttributeType) == .typeDirectory), url: url)
    }

    /// Permissions d'un élément SFTP, lues en arrière-plan.
    private func showRemotePermissions(for url: URL) {
        setPermissionsVisible(false)
        let current = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let attributes = try? SFTPManager.shared.session(for: url).attributes(url.path)
            DispatchQueue.main.async { [weak self] in
                guard let self, current == generation, let attributes else { return }
                let entry = attributes.entry
                fillPermissions(Permissions(mode: entry.permissions, owner: attributes.ownerName, group: attributes.groupName,
                                            ownerID: entry.owner, groupID: entry.group, immutable: nil, isDirectory: entry.isDirectory), url: url)
            }
        }
    }

    private func fillPermissions(_ info: Permissions, url: URL) {
        shownPermissions = info
        permissionsGrid = replaceGrid(permissionsGrid)
        setPermissionsVisible(true)

        func label(_ text: String, secondary: Bool = true) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            return field
        }
        permissionsGrid.addRow(with: [NSGridCell.emptyContentView, label("R"), label("W"), label("X")])
        for (title, shift) in [("Propriétaire", 6), ("Groupe", 3), ("Autres", 0)] {
            var cells: [NSView] = [label(title)]
            for bit in [4, 2, 1] {
                let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(togglePermission(_:)))
                checkbox.state = info.mode & (bit << shift) != 0 ? .on : .off
                checkbox.tag = bit << shift
                cells.append(checkbox)
            }
            permissionsGrid.addRow(with: cells)
        }
        let firstMerged = permissionsGrid.numberOfRows

        // Mode octal modifiable (ex. 755), avec sa forme symbolique.
        let octal = NSTextField(string: String(info.mode & 0o777, radix: 8))
        octal.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        octal.target = self
        octal.action = #selector(applyOctal(_:))
        octal.toolTip = "Mode en octal (ex. 644, 755) — Retour pour appliquer"
        octal.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let symbolicLabel = label(symbolic(info.mode), secondary: false)
        symbolicLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        permissionsGrid.addRow(with: [label("Octal"), row(octal, symbolicLabel)])

        if url.isRemote {
            // sftp n'accepte que des identifiants numériques pour chown / chgrp.
            permissionsGrid.addRow(with: [label("Propriétaire"), row(idField(info.ownerID, action: #selector(applyRemoteOwner(_:))), label(info.owner))])
            permissionsGrid.addRow(with: [label("Groupe"), row(idField(info.groupID, action: #selector(applyRemoteGroup(_:))), label(info.group))])
        } else {
            permissionsGrid.addRow(with: [label("Propriétaire"), popup(Self.localUsers(), selected: info.owner, action: #selector(changeOwner(_:)))])
            permissionsGrid.addRow(with: [label("Groupe"), popup(Self.localGroups(), selected: info.group, action: #selector(changeGroup(_:)))])
        }
        if let immutable = info.immutable {
            let locked = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleLocked(_:)))
            locked.state = immutable ? .on : .off
            permissionsGrid.addRow(with: [label("Verrouillé"), locked])
        }
        if info.isDirectory {
            let button = NSButton(title: "Appliquer aux éléments inclus…", target: self, action: #selector(applyToEnclosed(_:)))
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            permissionsGrid.addRow(with: [NSGridCell.emptyContentView, button])
        }
        for row in firstMerged..<permissionsGrid.numberOfRows {
            permissionsGrid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: row, length: 1))
            permissionsGrid.cell(atColumnIndex: 1, rowIndex: row).xPlacement = .leading
        }
        permissionsGrid.column(at: 0).width = 90
        for column in 1...3 {
            permissionsGrid.column(at: column).xPlacement = .center
            permissionsGrid.column(at: column).width = 30
        }
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private func idField(_ value: String, action: Selector) -> NSTextField {
        let field = NSTextField(string: value)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.target = self
        field.action = action
        field.toolTip = "Identifiant numérique — Retour pour appliquer"
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return field
    }

    private func popup(_ names: [String], selected: String, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        popup.addItems(withTitles: names.contains(selected) ? names : [selected] + names)
        popup.selectItem(withTitle: selected)
        popup.target = self
        popup.action = action
        return popup
    }

    /// Comptes locaux (root et utilisateurs, sans les comptes système « _ »).
    private static func localUsers() -> [String] {
        var names: [String] = []
        setpwent()
        while let entry = getpwent() {
            let name = String(cString: entry.pointee.pw_name)
            if (entry.pointee.pw_uid == 0 || entry.pointee.pw_uid >= 500) && !name.hasPrefix("_") && entry.pointee.pw_uid != 4_294_967_294 { names.append(name) }
        }
        endpwent()
        return Array(Set(names)).sorted()
    }

    private static func localGroups() -> [String] {
        var names: [String] = []
        setgrent()
        while let entry = getgrent() {
            let name = String(cString: entry.pointee.gr_name)
            if !name.hasPrefix("_"), !name.hasPrefix("com.apple.") { names.append(name) }
        }
        endgrent()
        return Array(Set(names)).sorted()
    }

    private func symbolic(_ mode: Int) -> String {
        let flags = ["r", "w", "x"]
        return (0..<9).map { index in mode & (1 << (8 - index)) != 0 ? flags[index % 3] : "-" }.joined()
    }

    // MARK: Modification des permissions

    private enum PermissionChange {
        case mode(Int), owner(String), group(String)
    }

    @objc private func togglePermission(_ sender: NSButton) {
        guard let info = shownPermissions else { return }
        apply(.mode(sender.state == .on ? info.mode | sender.tag : info.mode & ~sender.tag))
    }

    @objc private func applyOctal(_ sender: NSTextField) {
        guard let info = shownPermissions else { return }
        guard let value = Int(sender.stringValue.trimmingCharacters(in: .whitespaces), radix: 8), (0...0o777).contains(value) else {
            NSSound.beep()
            sender.stringValue = String(info.mode & 0o777, radix: 8)
            return
        }
        apply(.mode((info.mode & ~0o777) | value))
    }

    @objc private func changeOwner(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem, name != shownPermissions?.owner else { return }
        apply(.owner(name))
    }

    @objc private func changeGroup(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem, name != shownPermissions?.group else { return }
        apply(.group(name))
    }

    @objc private func applyRemoteOwner(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.allSatisfy(\.isNumber), value != shownPermissions?.ownerID else { return }
        apply(.owner(value))
    }

    @objc private func applyRemoteGroup(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.allSatisfy(\.isNumber), value != shownPermissions?.groupID else { return }
        apply(.group(value))
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

    /// Applique le mode, le propriétaire et le groupe du dossier à tout son contenu (comme le Finder).
    @objc private func applyToEnclosed(_ sender: NSButton) {
        guard let url = shownURL, let info = shownPermissions else { return }
        let alert = NSAlert()
        alert.messageText = "Appliquer les permissions de « \(url.lastPathComponent) » à tous les éléments inclus ?"
        alert.informativeText = "Mode \(symbolic(info.mode)) (\(String(info.mode & 0o777, radix: 8))), propriétaire \(info.owner), groupe \(info.group). Cette opération ne peut pas être annulée."
        alert.addButton(withTitle: "Appliquer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let changes: [PermissionChange] = url.isRemote ? [.mode(info.mode), .owner(info.ownerID), .group(info.groupID)]
                                                       : [.mode(info.mode), .owner(info.owner), .group(info.group)]
        apply(changes, recursive: true)
    }

    private func apply(_ change: PermissionChange) { apply([change], recursive: false) }

    private func apply(_ changes: [PermissionChange], recursive: Bool) {
        guard let url = shownURL else { return }
        if url.isRemote {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try Self.applyRemote(changes, to: url, recursive: recursive) }
                DispatchQueue.main.async { [weak self] in
                    if case .failure(let error) = result { NSAlert(error: error).runModal() }
                    if self?.shownURL == url { self?.showRemotePermissions(for: url) }
                }
            }
            return
        }
        let failures = Self.applyLocal(changes, to: url, recursive: recursive)
        if !failures.isEmpty {
            // Fichiers d'un autre compte : on propose de recommencer avec les droits d'administrateur.
            let alert = NSAlert()
            alert.messageText = "Modification refusée pour \(failures.count == 1 ? "« \(failures[0].lastPathComponent) »" : "\(failures.count) éléments")."
            alert.informativeText = "Vous pouvez réessayer avec les droits d'administrateur (macOS demandera votre mot de passe)."
            alert.addButton(withTitle: "Réessayer en administrateur")
            alert.addButton(withTitle: "Annuler")
            if alert.runModal() == .alertFirstButtonReturn { Self.applyAsAdministrator(changes, to: url, recursive: recursive) }
        }
        showPermissions(for: url)
    }

    /// Modifications locales ; renvoie les éléments refusés.
    private static func applyLocal(_ changes: [PermissionChange], to url: URL, recursive: Bool) -> [URL] {
        var targets = [url]
        if recursive, let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: []) {
            for case let child as URL in enumerator { targets.append(child) }
        }
        var failures: [URL] = []
        for target in targets {
            var attributes: [FileAttributeKey: Any] = [:]
            for change in changes {
                switch change {
                case .mode(let mode): attributes[.posixPermissions] = mode
                case .owner(let name): attributes[.ownerAccountName] = name
                case .group(let name): attributes[.groupOwnerAccountName] = name
                }
            }
            do { try FileManager.default.setAttributes(attributes, ofItemAtPath: target.path) } catch { failures.append(target) }
        }
        return failures
    }

    private static func applyAsAdministrator(_ changes: [PermissionChange], to url: URL, recursive: Bool) {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let flag = recursive ? "-R " : ""
        let commands = changes.map { change -> String in
            switch change {
            case .mode(let mode): "/bin/chmod \(flag)\(String(mode, radix: 8)) \(quoted(url.path))"
            case .owner(let name): "/usr/sbin/chown \(flag)\(quoted(name)) \(quoted(url.path))"
            case .group(let name): "/usr/bin/chgrp \(flag)\(quoted(name)) \(quoted(url.path))"
            }
        }
        let shell = commands.joined(separator: " && ").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(shell)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            let alert = NSAlert()
            alert.messageText = "La modification a échoué."
            alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? ""
            alert.runModal()
        }
    }

    private static func applyRemote(_ changes: [PermissionChange], to url: URL, recursive: Bool) throws {
        let session = try SFTPManager.shared.session(for: url)
        func visit(_ path: String, isDirectory: Bool) throws {
            for change in changes {
                switch change {
                case .mode(let mode): try session.changeMode(mode & 0o7777, of: path)
                case .owner(let uid): try session.changeOwner(uid, of: path)
                case .group(let gid): try session.changeGroup(gid, of: path)
                }
            }
            guard recursive, isDirectory else { return }
            for entry in try session.list(path).entries where !entry.isSymlink {
                try visit(entry.path, isDirectory: entry.isDirectory)
            }
        }
        try visit(url.path, isDirectory: recursive && session.isDirectory(url.path))
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
