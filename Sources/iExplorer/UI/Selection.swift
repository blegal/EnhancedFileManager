import AppKit

/// Sélection par motif, inversion, même type : comme Total Commander, Dolphin ou Directory Opus.
extension PanelViewController {
    /// Motifs déjà saisis, le plus récent en premier.
    private static var recentPatterns: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentSelectionPatterns") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: "recentSelectionPatterns") }
    }

    @objc func selectByPattern(_ sender: Any?) { askPattern(select: true) }
    @objc func deselectByPattern(_ sender: Any?) { askPattern(select: false) }

    @objc func invertSelection(_ sender: Any?) {
        let selected = selectionIndexes
        applySelection(IndexSet(items.indices).subtracting(selected))
    }

    /// Ajoute à la sélection tous les éléments du même type que ceux déjà sélectionnés.
    @objc func selectSameType(_ sender: Any?) {
        let selected = selectedItems
        guard !selected.isEmpty else { NSSound.beep(); return }
        let kinds = Set(selected.map(Self.typeKey))
        applySelection(IndexSet(items.indices.filter { kinds.contains(Self.typeKey(items[$0])) }))
    }

    /// Dossier, ou extension en minuscules (vide pour un fichier sans extension).
    private static func typeKey(_ item: FileItem) -> String {
        item.isNavigableDirectory ? "/" : item.url.pathExtension.lowercased()
    }

    private func askPattern(select: Bool) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = select ? "Sélectionner selon un motif" : "Désélectionner selon un motif"
        alert.informativeText = "Exemples : *.pdf   ·   *.jpg; *.png   ·   rapport-202?-*   ·   *brouillon*\nPlusieurs motifs séparés par « ; ». Majuscules et minuscules confondues."
        let combo = NSComboBox(frame: NSRect(x: 0, y: 26, width: 320, height: 26))
        combo.addItems(withObjectValues: Self.recentPatterns)
        let ext = selectedItems.first.map(\.url.pathExtension) ?? ""
        combo.stringValue = Self.recentPatterns.first ?? (ext.isEmpty ? "*" : "*.\(ext)")
        let folders = NSButton(checkboxWithTitle: "Inclure les dossiers", target: nil, action: nil)
        folders.frame = NSRect(x: 0, y: 0, width: 320, height: 20)
        folders.state = .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        accessory.addSubview(combo)
        accessory.addSubview(folders)
        alert.accessoryView = accessory
        alert.addButton(withTitle: select ? "Sélectionner" : "Désélectionner")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = combo
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = combo.stringValue.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            Self.recentPatterns = [text] + Self.recentPatterns.filter { $0 != text }
            let matches = matchingIndexes(text, includeFolders: folders.state == .on)
            let current = selectionIndexes
            applySelection(select ? current.union(matches) : current.subtracting(matches))
        }
    }

    func matchingIndexes(_ text: String, includeFolders: Bool) -> IndexSet {
        let patterns = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return IndexSet(items.indices.filter { index in
            let item = items[index]
            guard includeFolders || !item.isNavigableDirectory else { return false }
            let name = item.url.lastPathComponent
            return patterns.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
        })
    }

    private func applySelection(_ rows: IndexSet) {
        setSelection(rows, scroll: false)
        selectionDidChange()
    }
}
