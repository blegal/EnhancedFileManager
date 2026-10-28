import AppKit

/// Un tag du Finder : nom et numéro de couleur (0 = sans couleur, 1 gris … 7 orange).
struct FinderTag: Equatable {
    let name: String
    let colorIndex: Int

    var color: NSColor? { FinderTags.color(index: colorIndex) }

    /// Correspond à une recherche « tag:… » par son nom ou par le nom de sa couleur.
    func matches(_ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if name.range(of: query, options: options) != nil { return true }
        guard let standard = FinderTags.standard.first(where: { $0.index == colorIndex }) else { return false }
        return standard.name.range(of: query, options: options) != nil
    }
}

/// Tags du Finder, lus et écrits dans l'attribut étendu de Finder (nom + couleur), indépendamment de la langue.
enum FinderTags {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Tags de couleur standard (numéros 1 à 7), avec leur nom dans la langue de l'utilisateur.
    static let standard: [(name: String, index: Int, color: NSColor)] = {
        let colors = NSWorkspace.shared.fileLabelColors
        let french = ["Gris", "Vert", "Violet", "Bleu", "Jaune", "Rouge", "Orange"]
        let isFrench = Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
        let names = isFrench ? [""] + french : NSWorkspace.shared.fileLabels
        return (1..<min(8, colors.count, names.count)).map { (names[$0], $0, colors[$0]) }
    }()

    static func color(index: Int) -> NSColor? {
        standard.first { $0.index == index }?.color
    }

    static func read(_ url: URL) -> [FinderTag] {
        guard url.isFileURL else { return [] }
        let path = url.path
        let length = getxattr(path, attribute, nil, 0, 0, 0)
        guard length > 0 else { return [] }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, length, 0, 0) }
        guard read > 0, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return FinderTag(name: String(parts[0]), colorIndex: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
    }

    static func write(_ tags: [FinderTag], to url: URL) throws {
        let path = url.path
        if tags.isEmpty {
            removexattr(path, attribute, 0)
            return
        }
        let list = tags.map { $0.colorIndex > 0 ? "\($0.name)\n\($0.colorIndex)" : $0.name }
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, 0) }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    /// Pastilles colorées (texte attribué).
    static func dots(for tags: [FinderTag], size: CGFloat = 10) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for tag in tags.prefix(5) {
            let known = tag.color
            text.append(NSAttributedString(string: known == nil ? "◯" : "●", attributes: [
                .foregroundColor: known ?? NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: size),
            ]))
        }
        return text
    }
}

extension PanelViewController {
    /// Sous-menu « Tags » du menu contextuel.
    func tagsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let menu = NSMenu()
        let selection = selectedItems.filter { !$0.url.isRemote }
        for standard in FinderTags.standard {
            let entry = NSMenuItem(title: standard.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = standard.index
            let count = selection.filter { $0.finderTags.contains { $0.colorIndex == standard.index } }.count
            entry.state = count == 0 ? .off : (count == selection.count ? .on : .mixed)
            entry.image = TabColor.swatch(color: standard.color)
            menu.addItem(entry)
        }
        // Tags sans couleur déjà présents sur la sélection.
        let custom = Set(selection.flatMap(\.finderTags).filter { $0.colorIndex == 0 }.map(\.name)).sorted()
        if !custom.isEmpty { menu.addItem(.separator()) }
        for name in custom {
            let entry = NSMenuItem(title: name, action: #selector(toggleCustomTag(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = name
            entry.state = selection.allSatisfy { $0.tags.contains(name) } ? .on : .mixed
            entry.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Ajouter un tag…", action: #selector(addCustomTag(_:)), keyEquivalent: "")
        other.target = self
        other.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        menu.addItem(other)
        let clear = NSMenuItem(title: "Retirer tous les tags", action: #selector(clearTags(_:)), keyEquivalent: "")
        clear.target = self
        clear.image = NSImage(systemSymbolName: "tag.slash", accessibilityDescription: nil)
        menu.addItem(clear)
        item.submenu = menu
        return item
    }

    /// Tag de couleur standard (n° dans `sender.tag`) : ajouté à toute la sélection, ou retiré s'il y est déjà partout.
    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let standard = FinderTags.standard.first(where: { $0.index == sender.tag }) else { return }
        let selection = selectedItems.filter { !$0.url.isRemote }
        let add = !selection.allSatisfy { $0.finderTags.contains { $0.colorIndex == standard.index } }
        updateTags(of: selection, actionName: add ? "Ajouter le tag" : "Retirer le tag") { tags in
            let others = tags.filter { $0.colorIndex != standard.index }
            return add ? others + [FinderTag(name: standard.name, colorIndex: standard.index)] : others
        }
    }

    @objc func toggleCustomTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let selection = selectedItems.filter { !$0.url.isRemote }
        let add = !selection.allSatisfy { $0.tags.contains(name) }
        updateTags(of: selection, actionName: add ? "Ajouter le tag" : "Retirer le tag") { tags in
            let others = tags.filter { $0.name != name }
            return add ? others + [FinderTag(name: name, colorIndex: 0)] : others
        }
    }

    @objc func addCustomTag(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Ajouter un tag"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Nom du tag"
        alert.accessoryView = field
        alert.addButton(withTitle: "Ajouter")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        let selection = selectedItems.filter { !$0.url.isRemote }
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            // Un nom de couleur standard prend sa couleur.
            let index = FinderTags.standard.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.index ?? 0
            self?.updateTags(of: selection, actionName: "Ajouter le tag") { tags in
                tags.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } ? tags : tags + [FinderTag(name: name, colorIndex: index)]
            }
        }
    }

    @objc func clearTags(_ sender: Any?) {
        updateTags(of: selectedItems.filter { !$0.url.isRemote }, actionName: "Retirer les tags") { _ in [] }
    }

    /// Applique une transformation aux tags d'éléments, avec annulation.
    private func updateTags(of items: [FileItem], actionName: String, _ transform: ([FinderTag]) -> [FinderTag]) {
        var previous: [(URL, [FinderTag])] = []
        for item in items {
            let before = FinderTags.read(item.url)
            do {
                try FinderTags.write(transform(before), to: item.url)
                previous.append((item.url, before))
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if !previous.isEmpty, let undoManager {
            undoManager.registerUndo(withTarget: self) { panel in
                for (url, tags) in previous { try? FinderTags.write(tags, to: url) }
                panel.reload()
            }
            undoManager.setActionName(actionName)
        }
        reload()
    }

    /// Affiche tous les fichiers portant un tag (Spotlight, dans le dossier personnel).
    func showFiles(taggedWith tag: String) {
        endSearch(reloadListing: false)
        showSearch(nil)
        searchBar.field.stringValue = "tag:\(tag)"
        searchTagEverywhere(tag)
    }
}

extension TabColor {
    /// Carré de couleur quelconque (tags du Finder).
    static func swatch(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            circle.fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
