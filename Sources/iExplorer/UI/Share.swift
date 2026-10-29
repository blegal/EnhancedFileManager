import AppKit

/// « Partager » : menu système de partage (AirDrop, Mail, Messages, Notes…).
extension PanelViewController {
    func shareMenuItem(for urls: [URL]) -> NSMenuItem {
        let item = NSSharingServicePicker(items: urls).standardShareMenuItem
        item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        return item
    }

    /// Fichier › Partager… : le sélecteur s'ouvre sous l'élément sélectionné.
    @objc func shareSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, !currentURL.isRemote else { return }
        let picker = NSSharingServicePicker(items: urls)
        var anchor: NSView = focusView
        var rect = anchor.bounds
        if viewMode == .icons, let index = selectionIndexes.first,
           let item = collectionView.item(at: IndexPath(item: index, section: 0)) {
            anchor = item.view
            rect = anchor.bounds
        } else if let row = selectionIndexes.first, focusView === tableView {
            tableView.scrollRowToVisible(tableRow(forItem: row))
            rect = tableView.rect(ofRow: tableRow(forItem: row))
        }
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }
}
