import AppKit

/// Raccourcis clavier personnalisés : chaque commande du menu principal peut recevoir un autre raccourci
/// (ou aucun). Ils sont rangés par chemin de menu (« Fichier › Renommer ») et appliqués au démarrage.
enum KeyboardShortcuts {
    struct Shortcut: Equatable {
        var key: String
        var modifiers: NSEvent.ModifierFlags

        static let none = Shortcut(key: "", modifiers: [])

        var stored: String { "\(modifiers.rawValue)|\(key)" }

        init(key: String, modifiers: NSEvent.ModifierFlags) {
            self.key = key
            self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
        }

        init?(stored: String) {
            guard let bar = stored.firstIndex(of: "|"), let raw = UInt(stored[..<bar]) else { return nil }
            self.init(key: String(stored[stored.index(after: bar)...]), modifiers: NSEvent.ModifierFlags(rawValue: raw))
        }

        /// « ⌃⌥⇧⌘K », « F5 », « ⌘⌫ ».
        var display: String {
            guard !key.isEmpty else { return "" }
            var text = ""
            if modifiers.contains(.control) { text += "⌃" }
            if modifiers.contains(.option) { text += "⌥" }
            if modifiers.contains(.shift) { text += "⇧" }
            if modifiers.contains(.command) { text += "⌘" }
            return text + Self.keyName(key)
        }

        private static func keyName(_ key: String) -> String {
            guard let scalar = key.unicodeScalars.first else { return "" }
            let value = Int(scalar.value)
            if value >= NSF1FunctionKey, value <= NSF35FunctionKey { return "F\(value - NSF1FunctionKey + 1)" }
            switch value {
            case NSUpArrowFunctionKey: return "↑"
            case NSDownArrowFunctionKey: return "↓"
            case NSLeftArrowFunctionKey: return "←"
            case NSRightArrowFunctionKey: return "→"
            case NSDeleteFunctionKey: return "⌦"
            case NSHomeFunctionKey: return "↖"
            case NSEndFunctionKey: return "↘"
            case NSPageUpFunctionKey: return "⇞"
            case NSPageDownFunctionKey: return "⇟"
            case 8, 127: return "⌫"
            case 9: return "⇥"
            case 13, 3: return "↩"
            case 27: return "Échap"
            case 32: return "Espace"
            default: return key.uppercased()
            }
        }
    }

    struct Command {
        let path: String
        let item: NSMenuItem
        let original: Shortcut
    }

    private static let key = "keyboardShortcuts"
    /// Raccourcis d'origine, relevés avant d'appliquer les personnalisations.
    private static var originals: [String: Shortcut] = [:]

    static var overrides: [String: Shortcut] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]).compactMapValues(Shortcut.init(stored:)) }
        set { UserDefaults.standard.set(newValue.mapValues(\.stored), forKey: key) }
    }

    /// Commandes du menu principal (hors menus construits à la volée), avec leur chemin.
    static func commands(in menu: NSMenu? = NSApp.mainMenu, prefix: String = "") -> [Command] {
        guard let menu else { return [] }
        var result: [Command] = []
        for item in menu.items where !item.isSeparatorItem && !item.isSectionHeader {
            let path = prefix.isEmpty ? item.title : prefix + " › " + item.title
            if let submenu = item.submenu {
                // Les sous-menus remplis par un délégué changent à chaque ouverture : on les laisse.
                if submenu.delegate == nil, item.title != "Services" { result += commands(in: submenu, prefix: path) }
            } else if item.action != nil {
                let current = Shortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                result.append(Command(path: path, item: item, original: originals[path] ?? current))
            }
        }
        return result
    }

    /// Au démarrage, après la construction du menu.
    static func apply() {
        let saved = overrides
        let all = commands()
        for command in all where originals[command.path] == nil { originals[command.path] = command.original }
        for command in all where saved[command.path] == nil { set(command.original, on: command.item) }
        for command in all { if let shortcut = saved[command.path] { set(shortcut, on: command.item, freeingIn: all) } }
    }

    static func set(_ shortcut: Shortcut, on item: NSMenuItem) {
        item.keyEquivalent = shortcut.key
        item.keyEquivalentModifierMask = shortcut.modifiers
    }

    /// Le menu garde un raccourci déjà pris et ignore le nouveau : on retire d'abord la combinaison aux autres commandes.
    static func set(_ shortcut: Shortcut, on item: NSMenuItem, freeingIn commands: [Command]) {
        if !shortcut.key.isEmpty {
            for other in commands where other.item !== item
                && Shortcut(key: other.item.keyEquivalent, modifiers: other.item.keyEquivalentModifierMask) == shortcut {
                set(.none, on: other.item)
            }
        }
        set(shortcut, on: item)
    }

    static func update(_ command: Command, to shortcut: Shortcut?) {
        var saved = overrides
        let value = shortcut ?? command.original
        saved[command.path] = value == command.original ? nil : value
        overrides = saved
        set(value, on: command.item, freeingIn: commands())
    }
}

/// Fenêtre « Raccourcis clavier… » : double-clic (ou Retour) sur une commande, puis la combinaison voulue.
final class KeyboardShortcutsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static var shared: KeyboardShortcutsWindowController?

    private var all: [KeyboardShortcuts.Command] = []
    private var shown: [KeyboardShortcuts.Command] = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private let hint = NSTextField(labelWithString: "")
    private var recordingRow: Int?
    private var monitor: Any?

    static func show() {
        let controller = shared ?? KeyboardShortcutsWindowController()
        shared = controller
        controller.reloadCommands()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Raccourcis clavier"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Rechercher une commande ou un raccourci"
        search.delegate = self
        for (identifier, title, width) in [("command", "Commande", 400.0), ("shortcut", "Raccourci", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(startRecording)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.stringValue = "Double-clic sur une commande, puis tapez la combinaison. ⌫ : aucun raccourci, Échap : annuler."
        let reset = NSButton(title: "Rétablir celui-ci", target: self, action: #selector(resetSelected))
        let resetAll = NSButton(title: "Tout rétablir…", target: self, action: #selector(resetAll))
        let buttons = NSStackView(views: [hint, NSView(), reset, resetAll])
        let stack = NSStackView(views: [search, scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    private func reloadCommands() {
        all = KeyboardShortcuts.commands()
        filter()
    }

    private func filter() {
        let text = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = text.isEmpty ? all : all.filter {
            $0.path.lowercased().contains(text) || current($0).display.lowercased().contains(text)
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    private func current(_ command: KeyboardShortcuts.Command) -> KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(key: command.item.keyEquivalent, modifiers: command.item.keyEquivalentModifierMask)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = shown[row]
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        if tableColumn?.identifier.rawValue == "command" {
            field.stringValue = command.path
        } else if recordingRow == row {
            field.stringValue = "Tapez la combinaison…"
            field.textColor = .controlAccentColor
        } else {
            let shortcut = current(command)
            field.stringValue = shortcut.display.isEmpty ? "—" : shortcut.display
            field.font = shortcut != command.original ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
            field.toolTip = shortcut != command.original ? "Modifié (d’origine : \(command.original.display.isEmpty ? "aucun" : command.original.display))" : nil
        }
        return field
    }

    @objc private func startRecording() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard shown.indices.contains(row) else { return }
        stopRecording()
        recordingRow = row
        table.reloadData(forRowIndexes: [row], columnIndexes: [1])
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        guard let row = recordingRow, shown.indices.contains(row) else { stopRecording(); return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()
        if event.keyCode == 53, modifiers.isEmpty { stopRecording(); return } // Échap
        if event.keyCode == 51, modifiers.isEmpty { // ⌫ : aucun raccourci
            assign(.none, row: row)
            return
        }
        guard let scalar = characters.unicodeScalars.first else { return }
        let isFunctionKey = (NSF1FunctionKey...NSF35FunctionKey).contains(Int(scalar.value))
        // Sans modificateur, seules les touches de fonction font de bons raccourcis.
        guard !modifiers.isEmpty || isFunctionKey else { NSSound.beep(); return }
        let key = event.keyCode == 51 ? "\u{8}" : characters
        assign(KeyboardShortcuts.Shortcut(key: key, modifiers: modifiers), row: row)
    }

    private func assign(_ shortcut: KeyboardShortcuts.Shortcut, row: Int) {
        let command = shown[row]
        if !shortcut.key.isEmpty, let other = all.first(where: { $0.item !== command.item && current($0) == shortcut }) {
            let alert = NSAlert()
            alert.messageText = "\(shortcut.display) est déjà utilisé par « \(other.path) »"
            alert.informativeText = "Le raccourci sera retiré de cette commande."
            alert.addButton(withTitle: "Réattribuer")
            alert.addButton(withTitle: "Annuler")
            stopRecording()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            KeyboardShortcuts.update(other, to: .none)
        }
        KeyboardShortcuts.update(command, to: shortcut)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingRow = nil
        table.reloadData()
    }

    @objc private func resetSelected() {
        let row = table.selectedRow
        guard shown.indices.contains(row) else { return }
        KeyboardShortcuts.update(shown[row], to: nil)
        table.reloadData()
    }

    @objc private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Rétablir tous les raccourcis d’origine ?"
        alert.addButton(withTitle: "Rétablir")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for command in all { KeyboardShortcuts.update(command, to: nil) }
        table.reloadData()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { startRecording() } else { super.keyDown(with: event) }
    }
}

extension AppDelegate {
    @objc func showKeyboardShortcuts(_ sender: Any?) { KeyboardShortcutsWindowController.show() }
}
