import AppKit

/// Une commande shell définie par l'utilisateur, avec variables et raccourci.
struct CustomAction: Codable, Equatable {
    enum Mode: Int, Codable { case terminal, background }

    var id = UUID()
    var name = "Nouvelle action"
    var command = "echo %sélection"
    var mode = Mode.background
    var confirm = false
    /// Raccourci : une touche (lettre / chiffre) et des modificateurs (⌘ ⌥ ⌃ ⇧).
    var key = ""
    var modifiers: UInt = NSEvent.ModifierFlags([.command, .control]).rawValue

    static let changed = Notification.Name("CustomActionsChanged")
    private static let storageKey = "customActions"

    static var all: [CustomAction] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey) else { return examples }
            return (try? JSONDecoder().decode([CustomAction].self, from: data)) ?? examples
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storageKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Exemples proposés au premier lancement.
    static let examples: [CustomAction] = [
        CustomAction(name: "Compiler ce .tex (latexmk)", command: "latexmk -pdf -interaction=nonstopmode %fichier", mode: .terminal),
        CustomAction(name: "Ouvrir dans Visual Studio Code", command: "open -a \"Visual Studio Code\" %sélection", mode: .background),
        CustomAction(name: "rsync vers un serveur", command: "rsync -av --progress %sélection utilisateur@serveur:/chemin/", mode: .terminal, confirm: true),
    ]

    static let variablesHelp = """
    %chemin     dossier du panneau actif
    %autre      dossier de l’autre panneau
    %sélection  éléments sélectionnés
    %fichier    premier élément (%nom, %base, %ext)
    """

    /// Commande avec les variables remplacées par des valeurs protégées pour le shell.
    func expanded(folder: URL, selection: [URL], otherFolder: URL?) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let first = selection.first
        let name = first?.lastPathComponent ?? ""
        let values: [(String, String)] = [
            ("%sélection", selection.map { quote($0.path) }.joined(separator: " ")),
            ("%selection", selection.map { quote($0.path) }.joined(separator: " ")),
            ("%fichier", first.map { quote($0.path) } ?? ""),
            ("%chemin", quote(folder.path)),
            ("%dossier", quote(folder.path)),
            ("%autre", otherFolder.map { quote($0.path) } ?? ""),
            ("%base", quote((name as NSString).deletingPathExtension)),
            ("%nom", quote(name)),
            ("%ext", quote((name as NSString).pathExtension)),
        ]
        return values.reduce(command) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    var shortcutDescription: String {
        guard !key.isEmpty else { return "" }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
            (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key.uppercased()
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: name, action: #selector(PanelViewController.runCustomAction(_:)), keyEquivalent: key.lowercased())
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: modifiers)
        item.representedObject = id.uuidString
        item.image = NSImage(systemSymbolName: mode == .terminal ? "terminal" : "gearshape", accessibilityDescription: nil)
        return item
    }
}

// MARK: - Exécution

extension PanelViewController {
    @objc func runCustomAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let action = CustomAction.all.first(where: { $0.id.uuidString == id }) else { return }
        guard !currentURL.isRemote else {
            presentMessage("Les actions personnalisées s’exécutent sur des dossiers locaux.")
            return
        }
        let other = host?.targetPanels(for: self).first?.currentURL
        let command = action.expanded(folder: currentURL, selection: selectedURLs, otherFolder: other?.isFileURL == true ? other : nil)
        if action.confirm {
            let alert = NSAlert()
            alert.messageText = "Exécuter « \(action.name) » ?"
            alert.informativeText = command
            alert.addButton(withTitle: "Exécuter")
            alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        switch action.mode {
        case .terminal:
            (view.window?.windowController as? MainWindowController)?.runInTerminal(command, in: currentURL)
        case .background:
            runInBackground(command, title: action.name)
        }
    }

    private func runInBackground(_ command: String, title: String) {
        let folder = currentURL
        let job = FileJob(title: title)
        job.setStatus(command)
        FileOperationCenter.shared.addJob(job)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = folder
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        job.setCancelAction { process.terminate() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var text = ""
            do {
                try process.run()
                text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
            } catch {
                text = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                FileOperationCenter.shared.removeJob(job)
                guard let self, !job.isCancelled else { return }
                let failed = process.terminationStatus != 0
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if failed || !trimmed.isEmpty {
                    presentMessage((failed ? "« \(title) » a échoué (code \(process.terminationStatus))." : "« \(title) » terminé.")
                                   + (trimmed.isEmpty ? "" : "\n\n" + String(trimmed.suffix(1500))), warning: failed)
                }
                reload()
            }
        }
    }

    func presentMessage(_ text: String, warning: Bool = false) {
        let alert = NSAlert()
        alert.alertStyle = warning ? .warning : .informational
        let parts = text.components(separatedBy: "\n\n")
        alert.messageText = parts[0]
        if parts.count > 1 { alert.informativeText = parts.dropFirst().joined(separator: "\n\n") }
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Sous-menu « Actions » du clic droit.
    func customActionsMenuItem() -> NSMenuItem? {
        let actions = CustomAction.all
        guard !actions.isEmpty, !currentURL.isRemote else { return nil }
        let item = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        let menu = NSMenu()
        for action in actions {
            let entry = action.menuItem()
            entry.target = self
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }
}

// MARK: - Gestion des actions

/// Fenêtre « Actions personnalisées » : liste, édition, ajout, suppression.
final class CustomActionsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private var actions = CustomAction.all
    private let table = NSTableView()
    private let nameField = NSTextField()
    private let commandView = NSTextView()
    private let modePopup = NSPopUpButton()
    private let keyField = NSTextField()
    private let modifierButtons: [(NSEvent.ModifierFlags, NSButton)] = [
        (.control, NSButton(checkboxWithTitle: "⌃", target: nil, action: nil)),
        (.option, NSButton(checkboxWithTitle: "⌥", target: nil, action: nil)),
        (.shift, NSButton(checkboxWithTitle: "⇧", target: nil, action: nil)),
        (.command, NSButton(checkboxWithTitle: "⌘", target: nil, action: nil)),
    ]
    private let confirmBox = NSButton(checkboxWithTitle: "Demander confirmation avant d’exécuter", target: nil, action: nil)
    private var editor: NSView!

    override func loadView() {
        let title = NSTextField(labelWithString: "Actions personnalisées")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Action"
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Ajouter")!, target: self, action: #selector(addAction))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Supprimer")!, target: self, action: #selector(removeAction))
        for button in [add, remove] { button.bezelStyle = .accessoryBarAction }
        let listButtons = NSStackView(views: [add, remove])
        let list = NSStackView(views: [scroll, listButtons])
        list.orientation = .vertical
        list.alignment = .leading

        nameField.delegate = self
        let commandScroll = NSScrollView()
        commandScroll.documentView = commandView
        commandScroll.hasVerticalScroller = true
        commandScroll.borderType = .bezelBorder
        commandView.isRichText = false
        commandView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandView.isAutomaticQuoteSubstitutionEnabled = false
        commandView.isAutomaticDashSubstitutionEnabled = false
        commandView.delegate = self
        commandView.autoresizingMask = [.width]
        commandView.isVerticallyResizable = true
        commandView.textContainer?.widthTracksTextView = true
        commandScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        commandScroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        modePopup.addItems(withTitles: ["Dans le terminal intégré", "En arrière-plan (résultat affiché à la fin)"])
        modePopup.target = self
        modePopup.action = #selector(fieldChanged)
        keyField.placeholderString = "touche"
        keyField.delegate = self
        keyField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for (_, button) in modifierButtons { button.target = self; button.action = #selector(fieldChanged) }
        confirmBox.target = self
        confirmBox.action = #selector(fieldChanged)
        let shortcut = NSStackView(views: modifierButtons.map(\.1) + [keyField])
        let help = NSTextField(labelWithString: CustomAction.variablesHelp)
        help.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        help.textColor = .secondaryLabelColor

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.textColor = .secondaryLabelColor
            return field
        }
        let grid = NSGridView(views: [
            [label("Nom"), nameField],
            [label("Commande"), commandScroll],
            [NSGridCell.emptyContentView, help],
            [label("Exécution"), modePopup],
            [label("Raccourci"), shortcut],
            [NSGridCell.emptyContentView, confirmBox],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        editor = grid

        let close = NSButton(title: "Terminé", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\r"
        let body = NSStackView(views: [list, grid])
        body.alignment = .top
        body.spacing = 16
        let root = NSStackView(views: [title, body, close])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        list.heightAnchor.constraint(equalTo: grid.heightAnchor).isActive = true
        nameField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        root.frame = NSRect(x: 0, y: 0, width: 760, height: 440)
        view = root
        table.reloadData()
        if !actions.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        loadSelection()
    }

    private var selectedIndex: Int? { actions.indices.contains(table.selectedRow) ? table.selectedRow : nil }

    private func loadSelection() {
        guard let index = selectedIndex else {
            editor.isHidden = true
            return
        }
        editor.isHidden = false
        let action = actions[index]
        nameField.stringValue = action.name
        commandView.string = action.command
        modePopup.selectItem(at: action.mode.rawValue)
        keyField.stringValue = action.key
        let flags = NSEvent.ModifierFlags(rawValue: action.modifiers)
        for (flag, button) in modifierButtons { button.state = flags.contains(flag) ? .on : .off }
        confirmBox.state = action.confirm ? .on : .off
    }

    private func store() {
        guard let index = selectedIndex else { return }
        actions[index].name = nameField.stringValue
        actions[index].command = commandView.string
        actions[index].mode = CustomAction.Mode(rawValue: modePopup.indexOfSelectedItem) ?? .background
        actions[index].key = String(keyField.stringValue.prefix(1))
        actions[index].modifiers = modifierButtons.filter { $0.1.state == .on }.reduce(NSEvent.ModifierFlags()) { $0.union($1.0) }.rawValue
        actions[index].confirm = confirmBox.state == .on
        CustomAction.all = actions
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
    }

    @objc private func fieldChanged() { store() }
    func controlTextDidChange(_ notification: Notification) { store() }
    func textDidChange(_ notification: Notification) { store() }

    @objc private func addAction() {
        actions.append(CustomAction())
        CustomAction.all = actions
        table.reloadData()
        table.selectRowIndexes([actions.count - 1], byExtendingSelection: false)
        view.window?.makeFirstResponder(nameField)
    }

    @objc private func removeAction() {
        guard let index = selectedIndex else { return }
        actions.remove(at: index)
        CustomAction.all = actions
        table.reloadData()
        if !actions.isEmpty { table.selectRowIndexes([min(index, actions.count - 1)], byExtendingSelection: false) }
        loadSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = actions[row]
        let field = NSTextField(labelWithString: action.name + (action.key.isEmpty ? "" : "   " + action.shortcutDescription))
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { loadSelection() }

    @objc private func closeWindow() {
        if let window = view.window, let parent = window.sheetParent { parent.endSheet(window) } else { view.window?.close() }
    }
}
