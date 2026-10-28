import AppKit

/// Règles de renommage par lot, appliquées dans l'ordre : remplacement, casse, préfixe / suffixe.
struct BatchRenameRules {
    enum CaseMode: Int { case unchanged, lower, upper, capitalized }

    var find = ""
    var replace = ""
    var useRegex = false
    var ignoreCase = true
    var caseMode = CaseMode.unchanged
    /// Préfixe et suffixe ; jetons : {n} numéro, {date} date de modification, {nom} nom d'origine.
    var prefix = ""
    var suffix = ""
    var start = 1
    var step = 1
    var digits = 2
    var includeExtension = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Nouveau nom de l'élément n° `index` (0, 1, 2…) ; `nil` si l'expression régulière est invalide.
    func newName(for item: FileItem, index: Int) -> String? {
        let ext = item.isNavigableDirectory || includeExtension ? "" : (item.name as NSString).pathExtension
        var base = ext.isEmpty ? item.name : (item.name as NSString).deletingPathExtension

        if !find.isEmpty {
            if useRegex {
                guard let regex = try? NSRegularExpression(pattern: find, options: ignoreCase ? [.caseInsensitive] : []) else { return nil }
                base = regex.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: replace)
            } else {
                base = base.replacingOccurrences(of: find, with: replace, options: ignoreCase ? [.caseInsensitive] : [])
            }
        }
        switch caseMode {
        case .unchanged: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .capitalized: base = base.capitalized
        }
        let number = String(format: "%0\(max(1, digits))d", start + index * step)
        let date = item.modificationDate.map(Self.dateFormatter.string(from:)) ?? ""
        func expand(_ template: String) -> String {
            template.replacingOccurrences(of: "{n}", with: number)
                .replacingOccurrences(of: "{date}", with: date)
                .replacingOccurrences(of: "{nom}", with: item.name)
        }
        base = expand(prefix) + base + expand(suffix)
        return ext.isEmpty ? base : base + "." + ext
    }
}

/// Fenêtre de renommage par lot avec aperçu en direct.
final class BatchRenameController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onApply: (([(FileItem, String)]) -> Void)?

    private let files: [FileItem]
    private let siblings: Set<String>
    private var rules = BatchRenameRules()
    private var preview: [(item: FileItem, name: String?, conflict: Bool)] = []

    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let regexBox = NSButton(checkboxWithTitle: "Expression régulière", target: nil, action: nil)
    private let caseBox = NSButton(checkboxWithTitle: "Ignorer la casse", target: nil, action: nil)
    private let casePopup = NSPopUpButton()
    private let prefixField = NSTextField()
    private let suffixField = NSTextField()
    private let startField = NSTextField()
    private let stepField = NSTextField()
    private let digitsField = NSTextField()
    private let extensionBox = NSButton(checkboxWithTitle: "Inclure l’extension", target: nil, action: nil)
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "Renommer", target: nil, action: nil)

    /// `siblings` : noms déjà présents dans le dossier (pour signaler les conflits).
    init(files: [FileItem], siblings: Set<String>) {
        self.files = files
        self.siblings = siblings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Renommer \(files.count) éléments")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        for field in [findField, replaceField, prefixField, suffixField, startField, stepField, digitsField] {
            field.delegate = self
        }
        findField.placeholderString = "Texte à rechercher"
        replaceField.placeholderString = "Remplacer par ($1 pour un groupe)"
        prefixField.placeholderString = "ex. {date}_ ou Photo-{n}-"
        suffixField.placeholderString = "ex. _v{n}"
        startField.stringValue = "1"
        stepField.stringValue = "1"
        digitsField.stringValue = "2"
        for field in [startField, stepField, digitsField] { field.widthAnchor.constraint(equalToConstant: 50).isActive = true }
        for field in [findField, replaceField, prefixField, suffixField] { field.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true }
        casePopup.addItems(withTitles: ["Casse inchangée", "minuscules", "MAJUSCULES", "Première Lettre En Majuscule"])
        caseBox.state = .on
        for control in [regexBox, caseBox, extensionBox] as [NSButton] { control.target = self; control.action = #selector(changed) }
        casePopup.target = self
        casePopup.action = #selector(changed)

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.textColor = .secondaryLabelColor
            return field
        }
        let numbering = NSStackView(views: [label("Départ"), startField, label("Pas"), stepField, label("Chiffres"), digitsField])
        numbering.spacing = 6
        let options = NSStackView(views: [regexBox, caseBox])
        options.spacing = 14
        let grid = NSGridView(views: [
            [label("Rechercher"), findField],
            [label("Remplacer par"), replaceField],
            [NSGridCell.emptyContentView, options],
            [label("Casse"), casePopup],
            [label("Préfixe"), prefixField],
            [label("Suffixe"), suffixField],
            [label("Numéro {n}"), numbering],
            [NSGridCell.emptyContentView, extensionBox],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        for (identifier, title) in [("old", "Nom actuel"), ("new", "Nouveau nom")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = 260
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        summary.textColor = .secondaryLabelColor
        summary.font = .systemFont(ofSize: 11)
        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [summary, spacer, cancel, applyButton])

        let root = NSStackView(views: [title, grid, scroll, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true
        buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
        view = root
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }
    @objc private func changed() { refresh() }

    private func refresh() {
        rules.find = findField.stringValue
        rules.replace = replaceField.stringValue
        rules.useRegex = regexBox.state == .on
        rules.ignoreCase = caseBox.state == .on
        rules.caseMode = BatchRenameRules.CaseMode(rawValue: casePopup.indexOfSelectedItem) ?? .unchanged
        rules.prefix = prefixField.stringValue
        rules.suffix = suffixField.stringValue
        rules.start = Int(startField.stringValue) ?? 1
        rules.step = Int(stepField.stringValue) ?? 1
        rules.digits = min(max(Int(digitsField.stringValue) ?? 2, 1), 8)
        rules.includeExtension = extensionBox.state == .on

        let names = files.enumerated().map { rules.newName(for: $1, index: $0) }
        // Conflits : nom vide ou invalide, doublon dans le lot, ou nom déjà pris par un fichier hors du lot.
        var counts: [String: Int] = [:]
        names.compactMap { $0?.lowercased() }.forEach { counts[$0, default: 0] += 1 }
        let renamed = Set(files.map { $0.name.lowercased() })
        preview = zip(files, names).map { item, name in
            guard let name, !name.isEmpty, !name.contains("/") else { return (item, name, true) }
            let key = name.lowercased()
            let taken = siblings.contains(key) && !renamed.contains(key)
            return (item, name, counts[key, default: 0] > 1 || taken)
        }
        table.reloadData()
        let conflicts = preview.filter(\.conflict).count
        let changes = preview.filter { !$0.conflict && $0.name != $0.item.name }.count
        summary.stringValue = conflicts > 0 ? "\(conflicts) conflit(s) à corriger" : "\(changes) élément(s) seront renommés"
        summary.textColor = conflicts > 0 ? .systemRed : .secondaryLabelColor
        applyButton.isEnabled = conflicts == 0 && changes > 0
    }

    func numberOfRows(in tableView: NSTableView) -> Int { preview.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = preview[row]
        let isNew = tableColumn?.identifier.rawValue == "new"
        let field = NSTextField(labelWithString: isNew ? (entry.name ?? "expression invalide") : entry.item.name)
        field.lineBreakMode = .byTruncatingMiddle
        if isNew {
            field.textColor = entry.conflict ? .systemRed : (entry.name == entry.item.name ? .secondaryLabelColor : .labelColor)
            field.font = .systemFont(ofSize: 13, weight: entry.name == entry.item.name ? .regular : .medium)
        }
        return field
    }

    @objc private func apply() {
        let changes = preview.compactMap { entry -> (FileItem, String)? in
            guard let name = entry.name, name != entry.item.name else { return nil }
            return (entry.item, name)
        }
        close()
        onApply?(changes)
    }

    @objc private func cancel() { close() }

    private func close() {
        if let window = view.window, let parent = window.sheetParent { parent.endSheet(window) }
    }
}

// MARK: - Exécution

extension FileOperationCenter {
    /// Renomme un lot en deux temps (noms provisoires puis définitifs) pour permettre les permutations ;
    /// une seule opération à annuler.
    func batchRename(_ changes: [(URL, String)], undoManager: UndoManager?) -> [URL] {
        let fm = FileManager.default
        var staged: [(original: URL, temporary: URL, target: URL)] = []
        for (url, name) in changes {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".efm-renommage-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: url, to: temporary)
                staged.append((url, temporary, url.deletingLastPathComponent().appendingPathComponent(name)))
            } catch {
                showError("« \(url.lastPathComponent) » : \(error.localizedDescription)")
            }
        }
        var done: [(from: URL, to: URL)] = []
        for entry in staged {
            do {
                try fm.moveItem(at: entry.temporary, to: entry.target)
                done.append((entry.original, entry.target))
            } catch {
                try? fm.moveItem(at: entry.temporary, to: entry.original)
                showError("« \(entry.original.lastPathComponent) » : \(error.localizedDescription)")
            }
        }
        if !done.isEmpty, let undoManager {
            undoManager.registerUndo(withTarget: self) { center in
                _ = center.batchRename(done.map { ($0.to, $0.from.lastPathComponent) }, undoManager: undoManager)
            }
            undoManager.setActionName("Renommage par lot")
        }
        return done.map(\.to)
    }

    /// Version SFTP (sans annulation) : en deux temps aussi, côté serveur.
    func batchRenameRemote(_ changes: [(URL, String)], completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var renamed: [URL] = []
            var errors: [String] = []
            guard let first = changes.first?.0, let session = try? SFTPManager.shared.session(for: first) else { return }
            var staged: [(URL, String, URL)] = []
            for (url, name) in changes {
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".efm-renommage-\(UUID().uuidString)")
                do { try session.rename(url.path, to: temporary.path); staged.append((url, name, temporary)) } catch { errors.append(error.localizedDescription) }
            }
            for (url, name, temporary) in staged {
                let target = url.deletingLastPathComponent().appendingPathComponent(name)
                do { try session.rename(temporary.path, to: target.path); renamed.append(target) } catch {
                    try? session.rename(temporary.path, to: url.path)
                    errors.append(error.localizedDescription)
                }
            }
            DispatchQueue.main.async {
                if !errors.isEmpty { self.showError("Certains éléments n’ont pas été renommés.\n" + errors.joined(separator: "\n")) }
                completion(renamed)
            }
        }
    }
}

extension PanelViewController {
    @objc func batchRename(_ sender: Any?) {
        let selection = selectedItems
        guard selection.count > 0, let window = view.window else { return }
        let controller = BatchRenameController(files: selection, siblings: Set(allItems.map { $0.name.lowercased() }))
        controller.onApply = { [weak self] changes in
            guard let self, !changes.isEmpty else { return }
            let pairs = changes.map { ($0.0.url, $0.1) }
            if currentURL.isRemote {
                FileOperationCenter.shared.batchRenameRemote(pairs) { [weak self] renamed in self?.reload(selecting: renamed) }
            } else {
                let renamed = FileOperationCenter.shared.batchRename(pairs, undoManager: undoManager)
                reload(selecting: renamed)
            }
        }
        window.beginSheet(NSWindow(contentViewController: controller))
    }
}
