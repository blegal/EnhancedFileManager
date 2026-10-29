import AppKit
import UniformTypeIdentifiers

/// Fenêtre « Actions par type de fichier » : liste des règles (les miennes, celles du projet courant),
/// édition du fichier .toml avec vérification immédiate et aperçu du menu sur un fichier réel.
final class FileActionsEditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private static var window: NSWindow?

    /// Ouvre (ou ramène) la fenêtre, éventuellement sur une règle et pour le dossier d'un projet.
    static func show(selecting file: URL? = nil, projectDirectory: URL? = nil) {
        if window == nil {
            let controller = FileActionsEditorController()
            let window = NSWindow(contentViewController: controller)
            window.title = "Actions par type de fichier"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 980, height: 640))
            window.contentMinSize = NSSize(width: 820, height: 520)
            window.setFrameAutosaveName("FileActionsEditor")
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        guard let window, let controller = window.contentViewController as? FileActionsEditorController else { return }
        controller.projectDirectory = projectDirectory ?? controller.projectDirectory
        controller.reloadRules(selecting: file)
        window.makeKeyAndOrderFront(nil)
    }

    private enum Row {
        case header(String)
        case rule(URL, isProject: Bool)
    }

    private var rows: [Row] = []
    private var projectDirectory: URL?
    private var currentFile: URL?
    private var isModified = false { didSet { saveButton.isEnabled = isModified } }

    private let table = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private var editor: NSTextView!
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Enregistrer", target: nil, action: nil)
    private let removeButton = NSButton()
    private var detail: NSView!

    override func loadView() {
        // Liste des règles.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Nouvelle règle")!, target: self, action: #selector(addRule(_:)))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Supprimer la règle")
        removeButton.target = self
        removeButton.action = #selector(removeRule)
        let more = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Plus")!, target: self, action: #selector(showMoreMenu(_:)))
        for button in [add, removeButton, more] { button.bezelStyle = .accessoryBarAction }
        add.toolTip = "Nouvelle règle"
        removeButton.toolTip = "Supprimer la règle sélectionnée"
        more.toolTip = "Dossier des règles, règles fournies, outils installés"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let listButtons = NSStackView(views: [add, removeButton, spacer, more])
        listButtons.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
        let sidebar = NSStackView(views: [listScroll, listButtons])
        sidebar.orientation = .vertical
        sidebar.spacing = 0
        sidebar.widthAnchor.constraint(equalToConstant: 250).isActive = true
        listButtons.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true

        // Détail : en-tête, éditeur, état, aide.
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let titles = NSStackView(views: [titleLabel, pathLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tryButton = NSButton(title: "Essayer sur un fichier…", target: self, action: #selector(tryOnFile(_:)))
        let openButton = NSButton(title: "Ouvrir dans l’éditeur", target: self, action: #selector(openInEditor))
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.isEnabled = false
        let header = NSStackView(views: [titles, tryButton, openButton, saveButton])
        header.alignment = .centerY

        let editorScroll = NSTextView.scrollableTextView()
        editor = editorScroll.documentView as? NSTextView
        editorScroll.borderType = .bezelBorder
        configure(editor)

        statusLabel.font = .systemFont(ofSize: 12)
        let help = NSTextField(wrappingLabelWithString: """
        Variables : $FILE (premier fichier)  $DIR (son dossier)  $NAME  $STEM (nom sans extension)  $EXT  $ITEM (élément d’une liste)  \
        $OTHER (dossier de l’autre panneau)  "$@" (tous les fichiers sélectionnés). \
        in = terminal | background | open ; then = reveal <fichier> | open <fichier> | output | refresh ; \
        requires = ["outil"] masque l’action si l’outil manque, missing = ["outil"] la montre seulement dans ce cas. \
        Règles d’un projet : dossier .iexplorer/actions à sa racine (à approuver avant la première exécution).
        """)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        let detailStack = NSStackView(views: [header, editorScroll, statusLabel, help])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 10
        detailStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for view in [header, editorScroll, statusLabel, help] {
            view.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -40).isActive = true
        }
        editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        editorScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        editorScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        detail = detailStack

        let separator = NSBox()
        separator.boxType = .separator
        let root = NSStackView(views: [sidebar, separator, detailStack])
        root.spacing = 0
        root.alignment = .top
        for view in [sidebar, separator, detailStack] {
            view.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        }
        root.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        view = root

        NotificationCenter.default.addObserver(forName: FileActionStore.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, !isModified else { return }
            reloadRules(selecting: currentFile)
        }
    }

    private func configure(_ editor: NSTextView) {
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.delegate = self
        // Lignes longues (commandes) : défilement horizontal plutôt que retour à la ligne.
        editor.isHorizontallyResizable = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.enclosingScrollView?.hasHorizontalScroller = true
    }

    // MARK: Liste

    private func reloadRules(selecting file: URL?) {
        let store = FileActionStore.shared
        rows = [.header("Mes règles")] + store.ruleFiles(in: FileActionStore.userFolder).map { .rule($0, isProject: false) }
        if let projectDirectory {
            for folder in store.projectFolders(for: projectDirectory) {
                let files = store.ruleFiles(in: folder)
                guard !files.isEmpty else { continue }
                let project = folder.deletingLastPathComponent().deletingLastPathComponent()
                rows.append(.header("Projet « \(project.lastPathComponent) »"))
                rows += files.map { .rule($0, isProject: true) }
            }
        }
        table.reloadData()
        let target = file ?? currentFile
        let index = rows.firstIndex { if case .rule(let url, _) = $0 { return url == target }; return false }
            ?? rows.firstIndex { if case .rule = $0 { return true }; return false }
        if let index { table.selectRowIndexes([index], byExtendingSelection: false); table.scrollRowToVisible(index) }
        loadSelection()
    }

    private var selectedFile: URL? {
        guard rows.indices.contains(table.selectedRow), case .rule(let url, _) = rows[table.selectedRow] else { return nil }
        return url
    }

    private func loadSelection() {
        guard let file = selectedFile else {
            currentFile = nil
            detail.isHidden = true
            removeButton.isEnabled = false
            return
        }
        detail.isHidden = false
        removeButton.isEnabled = true
        guard file != currentFile else { return }
        currentFile = file
        editor.string = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        editor.undoManager?.removeAllActions()
        pathLabel.stringValue = (file.path as NSString).abbreviatingWithTildeInPath
        isModified = false
        validate()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        if isModified { save() }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .rule(let url, let isProject):
            let store = FileActionStore.shared
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRule(_:)))
            checkbox.state = store.isEnabled(url) ? .on : .off
            checkbox.tag = row
            let name: String
            var detailText = ""
            var symbol = "bolt"
            switch store.load(url, isProject: isProject) {
            case .success(let rule):
                name = rule.name
                symbol = rule.icon ?? symbol
                detailText = "\(rule.actionCount)"
                if isProject, !store.isTrusted(url) { detailText = "à approuver" }
            case .failure:
                name = url.deletingPathExtension().lastPathComponent
                symbol = "exclamationmark.triangle"
                detailText = "erreur"
            }
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                                   ?? NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)!)
            icon.contentTintColor = detailText == "erreur" ? .systemOrange : .secondaryLabelColor
            let label = NSTextField(labelWithString: name)
            label.lineBreakMode = .byTruncatingTail
            label.textColor = store.isEnabled(url) ? .labelColor : .tertiaryLabelColor
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let count = NSTextField(labelWithString: detailText)
            count.textColor = detailText == "à approuver" || detailText == "erreur" ? .systemOrange : .tertiaryLabelColor
            count.font = .systemFont(ofSize: 11)
            let stack = NSStackView(views: [checkbox, icon, label, count])
            stack.spacing = 5
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return stack
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { loadSelection() }

    @objc private func toggleRule(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case .rule(let url, _) = rows[sender.tag] else { return }
        FileActionStore.shared.setEnabled(sender.state == .on, url)
    }

    // MARK: Édition

    func textDidChange(_ notification: Notification) {
        isModified = true
        validate()
    }

    /// Vérifie le texte à chaque frappe et colore commentaires, en-têtes et chaînes.
    private func validate() {
        highlight()
        guard let file = currentFile else { return }
        do {
            let rule = try FileActionRule(url: file, text: editor.string)
            titleLabel.stringValue = rule.name
            let missing = Set(rule.requires + rule.entries.flatMap(\.requires)).filter { !ShellEnvironment.has($0) }.sorted()
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "✓ \(rule.actionCount) action\(rule.actionCount > 1 ? "s" : "") · s’applique à : \(rule.matchDescription)"
                + (missing.isEmpty ? "" : "\nOutils absents (actions masquées) : " + missing.joined(separator: ", "))
        } catch {
            titleLabel.stringValue = file.deletingPathExtension().lastPathComponent
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func highlight() {
        guard let storage = editor.textStorage else { return }
        let text = storage.string as NSString
        let all = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: all)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        let patterns: [(String, NSColor)] = [
            (#"(?m)^\s*\[\[?[^\]]+\]\]?"#, .systemBlue),
            (#"(?m)^\s*[A-Za-z_][A-Za-z0-9_-]*(?=\s*=)"#, .systemPurple),
            (#"'''[\s\S]*?'''|"""[\s\S]*?"""|"(?:[^"\\\n]|\\.)*"|'[^'\n]*'"#, .systemGreen),
            (#"(?m)#[^\n'"]*$"#, .secondaryLabelColor),
        ]
        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: storage.string, range: all) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        storage.endEditing()
    }

    @objc private func save() {
        guard let file = currentFile, isModified else { return }
        do {
            try editor.string.write(to: file, atomically: true, encoding: .utf8)
            isModified = false
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: [0])
            NotificationCenter.default.post(name: FileActionStore.changed, object: nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        save()
    }

    @objc private func openInEditor() {
        guard let file = currentFile else { return }
        save()
        let app = NSWorkspace.shared.urlForApplication(toOpen: file)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        if let app { NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
    }

    // MARK: Ajout, suppression

    @objc private func addRule(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Nouvelle règle"
        alert.informativeText = "Nom de la règle et extensions concernées (séparées par des virgules) :"
        let name = NSTextField(string: "")
        name.placeholderString = "Graphviz"
        let extensions = NSTextField(string: "")
        extensions.placeholderString = "dot, gv"
        let fields = NSStackView(views: [name, extensions])
        fields.orientation = .vertical
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        name.widthAnchor.constraint(equalToConstant: 300).isActive = true
        extensions.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = fields
        alert.window.initialFirstResponder = name
        alert.addButton(withTitle: "Créer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "Nouvelle règle" : name.stringValue.trimmingCharacters(in: .whitespaces)
        let list = extensions.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }.filter { !$0.isEmpty }
        let folder = FileActionStore.userFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        var file = folder.appendingPathComponent((base.isEmpty ? "regle" : base) + ".toml")
        var suffix = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("\(base)-\(suffix).toml")
            suffix += 1
        }
        do {
            try DefaultFileActions.template(name: title, extensions: list.isEmpty ? ["txt"] : list).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        reloadRules(selecting: file)
        view.window?.makeFirstResponder(editor)
    }

    @objc private func removeRule() {
        guard let file = currentFile else { return }
        let alert = NSAlert()
        alert.messageText = "Mettre « \(file.lastPathComponent) » à la corbeille ?"
        alert.addButton(withTitle: "Mettre à la corbeille")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isModified = false
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        } catch {
            NSAlert(error: error).runModal()
        }
        currentFile = nil
        reloadRules(selecting: nil)
        NotificationCenter.default.post(name: FileActionStore.changed, object: nil)
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Afficher le dossier des règles", action: #selector(revealFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Restaurer les règles fournies", action: #selector(restoreDefaults), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Rechercher de nouveau les outils installés", action: #selector(rescanTools), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentFile ?? FileActionStore.userFolder])
    }

    /// Recrée les règles fournies qui manquent, sans toucher à celles qui existent.
    @objc private func restoreDefaults() {
        FileActionStore.shared.installDefaults(force: true)
        reloadRules(selecting: currentFile)
    }

    @objc private func rescanTools() {
        ShellEnvironment.forgetTools()
        validate()
    }

    // MARK: Aperçu

    /// Construit le menu de la règle éditée pour un fichier choisi, sans rien exécuter.
    @objc private func tryOnFile(_ sender: NSButton) {
        guard let file = currentFile else { return }
        let rule: FileActionRule
        do {
            rule = try FileActionRule(url: file, text: editor.string)
        } catch {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = rule.folderContains
        panel.allowsMultipleSelection = true
        panel.message = "Choisissez un ou plusieurs fichiers concernés par « \(rule.name) »."
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else { return }
            let selection = panel.urls
            let directory = selection[0].deletingLastPathComponent()
            let menu = NSMenu()
            if let context = rule.context(selection: selection, directory: directory) {
                for item in FileActionMenu.items(for: rule, context: context, target: self, action: #selector(previewChosen(_:))) {
                    menu.addItem(item)
                }
                if menu.items.isEmpty {
                    menu.addItem(withTitle: "Aucune action disponible (outil manquant ou nombre de fichiers)", action: nil, keyEquivalent: "")
                }
            } else {
                menu.addItem(withTitle: "La règle ne s’applique pas à cette sélection", action: nil, keyEquivalent: "")
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }

    @objc private func previewChosen(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? FileActionInvocation else { return }
        let variables = invocation.context.variables(item: invocation.item)
        let alert = NSAlert()
        alert.messageText = "Aperçu : « \(sender.title) »"
        alert.informativeText = "Commande exécutée dans \(invocation.context.directory.path) :\n\n"
            + PanelViewController.terminalCommand(invocation.entry.run, variables: variables, files: invocation.context.files)
        alert.runModal()
    }
}
