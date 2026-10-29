import AppKit

/// « Regrouper par » : sections par type, date de modification ou taille dans les vues en liste.
enum PanelGrouping: Int, CaseIterable {
    case none, kind, date, size

    var title: String {
        switch self {
        case .none: "Aucun"
        case .kind: "Type"
        case .date: "Date de modification"
        case .size: "Taille"
        }
    }
}

/// Ligne de la table quand les éléments sont regroupés : un en-tête de groupe ou un élément de `items`.
enum GroupRow {
    case header(title: String, count: Int)
    case item(Int)
}

extension NSUserInterfaceItemIdentifier {
    static let groupHeader = NSUserInterfaceItemIdentifier("groupHeader")
}

extension PanelViewController {
    var isGrouped: Bool { !groupRows.isEmpty }

    /// Réordonne `items` par groupe, en gardant le tri dans chaque groupe, et prépare les lignes de la table.
    /// Sans effet sur un ordre déjà groupé : on peut l'appeler à chaque rechargement.
    func rebuildGroups() {
        groupRows = []
        itemRows = []
        guard grouping != .none, !items.isEmpty, viewMode == .list || viewMode == .details else { return }
        let keys = items.map { Self.groupKey(for: $0, grouping: grouping) }
        let order = items.indices.sorted { a, b in
            if keys[a].rank != keys[b].rank { return keys[a].rank < keys[b].rank }
            if keys[a].title != keys[b].title { return keys[a].title.localizedStandardCompare(keys[b].title) == .orderedAscending }
            return a < b
        }
        items = order.map { items[$0] }
        let titles = order.map { keys[$0].title }
        var rows: [GroupRow] = []
        var positions = [Int](repeating: 0, count: items.count)
        var start = 0
        while start < items.count {
            var end = start
            while end < items.count, titles[end] == titles[start] { end += 1 }
            rows.append(.header(title: titles[start], count: end - start))
            for index in start..<end {
                positions[index] = rows.count
                rows.append(.item(index))
            }
            start = end
        }
        groupRows = rows
        itemRows = positions
    }

    /// Élément affiché à une ligne de la table (nil pour un en-tête de groupe).
    func itemIndex(forRow row: Int) -> Int? {
        guard isGrouped else { return items.indices.contains(row) ? row : nil }
        guard groupRows.indices.contains(row), case .item(let index) = groupRows[row] else { return nil }
        return index
    }

    func tableRow(forItem index: Int) -> Int {
        isGrouped && itemRows.indices.contains(index) ? itemRows[index] : index
    }

    func tableRows(forItems indexes: IndexSet) -> IndexSet {
        isGrouped ? IndexSet(indexes.map(tableRow(forItem:))) : indexes
    }

    func isGroupHeader(_ row: Int) -> Bool {
        guard isGrouped, groupRows.indices.contains(row), case .header = groupRows[row] else { return false }
        return true
    }

    @objc func groupBy(_ sender: NSMenuItem) {
        guard let value = PanelGrouping(rawValue: sender.tag) else { return }
        setGrouping(value)
    }

    func setGrouping(_ value: PanelGrouping) {
        guard value != grouping else { return }
        let selection = selectedURLs
        grouping = value
        if value == .none {
            // Retour à l'ordre du tri seul.
            items = isShowingSearchResults ? items : Self.sorted(items, by: sortDescriptor)
        }
        reloadViews()
        let paths = Set(selection.map(\.normalizedPath))
        setSelection(IndexSet(items.indices.filter { paths.contains(items[$0].url.normalizedPath) }), scroll: false)
    }

    func groupingMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Regrouper par", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        item.submenu = NSMenu()
        for value in PanelGrouping.allCases {
            let entry = NSMenuItem(title: value.title, action: #selector(groupBy(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = value.rawValue
            entry.state = value == grouping ? .on : .off
            item.submenu?.addItem(entry)
            if value == .none { item.submenu?.addItem(.separator()) }
        }
        return item
    }

    func groupHeaderView(_ title: String, count: Int) -> NSView {
        let cell = tableView.makeView(withIdentifier: .groupHeader, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = .groupHeader
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = field
            return cell
        }()
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.text,
        ])
        text.append(NSAttributedString(string: "  \(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.secondaryText,
        ]))
        cell.textField?.attributedStringValue = text
        return cell
    }

    /// Groupe d'un élément : `rank` ordonne les groupes, `title` les nomme (et départage les rangs égaux).
    static func groupKey(for item: FileItem, grouping: PanelGrouping) -> (rank: Double, title: String) {
        switch grouping {
        case .none:
            return (0, "")
        case .kind:
            return item.isNavigableDirectory ? (0, "Dossiers") : (1, item.kind)
        case .size:
            guard let size = item.effectiveSize else { return (6, "Dossiers") }
            switch size {
            case 1_000_000_000...: return (0, "Plus de 1 Go")
            case 100_000_000...: return (1, "100 Mo à 1 Go")
            case 1_000_000...: return (2, "1 à 100 Mo")
            case 100_000...: return (3, "100 Ko à 1 Mo")
            case 1...: return (4, "Moins de 100 Ko")
            default: return (5, "Vides")
            }
        case .date:
            guard let date = item.modificationDate else { return (.infinity, "Date inconnue") }
            let (start, title) = dateBucket(for: date)
            return (-start.timeIntervalSinceReferenceDate, title)
        }
    }

    /// Aujourd'hui, Hier, 7 et 30 derniers jours, puis le mois (cette année) ou l'année.
    private static func dateBucket(for date: Date) -> (start: Date, title: String) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today)! }
        if date >= today { return (today, "Aujourd’hui") }
        if date >= daysAgo(1) { return (daysAgo(1), "Hier") }
        if date >= daysAgo(6) { return (daysAgo(6), "7 derniers jours") }
        if date >= daysAgo(29) { return (daysAgo(29), "30 derniers jours") }
        if calendar.isDate(date, equalTo: today, toGranularity: .year) {
            let month = calendar.dateInterval(of: .month, for: date)!.start
            return (month, monthFormatter.string(from: date).capitalized(with: Locale(identifier: "fr_FR")))
        }
        let year = calendar.dateInterval(of: .year, for: date)!.start
        return (year, String(calendar.component(.year, from: date)))
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "LLLL"
        return formatter
    }()
}
