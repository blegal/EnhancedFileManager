import AppKit

/// Vue « Occupation du disque » d'un panneau : choix de la représentation, analyse en arrière-plan,
/// graphique et, pour certaines représentations, liste synchronisée.
final class DiskUsageView: NSView {
    var onNavigate: ((URL) -> Void)?
    var onUp: (() -> Void)?
    var onExit: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    var onRevealInList: ((URL) -> Void)?
    var onTrash: ((URL) -> Void)?

    let chart = DiskChartView()
    private let list = DiskListView()
    private let content = DiskContentView()
    private let styleControl: NSSegmentedControl
    private let colorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")

    /// Arbre analysé (sa racine peut être un ancêtre du dossier affiché).
    private var tree: DiskNode?
    private var scanner: DiskScanner?
    private var progressTimer: Timer?
    private var requestedURL: URL?

    var style: DiskChartStyle = .flat {
        didSet {
            styleControl.selectedSegment = style.rawValue
            chart.style = style
            list.isHidden = !style.hasList
            list.expandable = style == .baobab
            list.reload(root: chart.root)
            content.style = style
        }
    }

    init() {
        styleControl = NSSegmentedControl(images: DiskChartStyle.allCases.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
                                          trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        for style in DiskChartStyle.allCases { styleControl.setToolTip(style.title, forSegment: style.rawValue) }
        styleControl.segmentStyle = .separated
        styleControl.controlSize = .small
        styleControl.target = self
        styleControl.action = #selector(styleChanged(_:))
        styleControl.selectedSegment = style.rawValue

        colorPopup.controlSize = .small
        colorPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        colorPopup.addItems(withTitles: DiskColorMode.allCases.map(\.title))
        colorPopup.target = self
        colorPopup.action = #selector(colorChanged(_:))
        colorPopup.toolTip = "Couleurs"

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Actualiser")
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.isBordered = false
        refreshButton.toolTip = "Analyser de nouveau"
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [styleControl, colorPopup, refreshButton, spinner, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.setCustomSpacing(4, after: refreshButton)

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        content.chart = chart
        content.list = list
        content.addSubview(chart)
        content.addSubview(list)
        list.isHidden = true
        for view in [bar, content, infoLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            infoLabel.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 5),
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        chart.onHover = { [weak self] node in
            self?.showInfo(node)
            self?.list.highlight(node)
        }
        chart.onDive = { [weak self] node in self?.onNavigate?(node.url) }
        chart.onUp = { [weak self] in self?.onUp?() }
        chart.onOpen = { [weak self] node in self?.onOpen?(node.url) }
        chart.menuProvider = { [weak self] node in self?.menu(for: node) }
        chart.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        list.onHover = { [weak self] node in
            self?.showInfo(node)
            self?.chart.highlight(node)
        }
        list.onDive = { [weak self] node in
            if node.isDirectory { self?.onNavigate?(node.url) } else if !node.isAggregate { self?.onOpen?(node.url) }
        }
        list.menuProvider = { [weak self] node in self?.menu(for: node) }
        list.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        list.colorProvider = { [weak self] node in self?.listColor(node) ?? .gray }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Analyse

    /// Affiche un dossier : réutilise l'arbre s'il le contient, sinon lance une analyse.
    func show(_ url: URL, forceRescan: Bool = false) {
        requestedURL = url
        if !forceRescan, let tree, let rootURL = tree.rootURL, url.isInside(rootURL) {
            let root = rootURL.standardizedFileURL.path, target = url.standardizedFileURL.path
            let relative = target == root ? [] : target.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/").map(String.init)
            if let node = tree.descendant(relative) {
                display(node)
                return
            }
        }
        // En remontant, le dossier déjà analysé est réutilisé tel quel.
        var reuse: [String: DiskNode] = [:]
        if !forceRescan, let tree, let rootURL = tree.rootURL, rootURL.isInside(url) { reuse[rootURL.standardizedFileURL.path] = tree }
        startScan(url, reuse: reuse)
    }

    /// Libère l'arbre (sortie du mode) et annule l'analyse en cours.
    func stop() {
        scanner?.cancel()
        scanner = nil
        progressTimer?.invalidate()
        progressTimer = nil
        tree = nil
        chart.root = nil
        list.reload(root: nil)
        spinner.stopAnimation(nil)
    }

    private func startScan(_ url: URL, reuse: [String: DiskNode]) {
        scanner?.cancel()
        let scanner = DiskScanner(reuse: reuse)
        self.scanner = scanner
        chart.root = nil
        list.reload(root: nil)
        infoLabel.stringValue = ""
        spinner.startAnimation(nil)
        let started = Date()
        let name = BreadcrumbView.displayName(url)
        statusLabel.stringValue = "Analyse de « \(name) »…"
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak scanner] _ in
            guard let self, let scanner else { return }
            let progress = scanner.progress
            statusLabel.stringValue = "Analyse de « \(name) »… \(progress.files.formatted()) fichiers · \(Format.size(progress.bytes))"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = scanner.scan(url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanner === scanner else { return }
                self.scanner = nil
                progressTimer?.invalidate()
                progressTimer = nil
                spinner.stopAnimation(nil)
                guard let result else { return }
                tree = result
                let elapsed = Date().timeIntervalSince(started)
                statusLabel.stringValue = "\(result.count.formatted()) fichiers · \(Format.size(result.size)) · analysé en \(elapsed.formatted(.number.precision(.fractionLength(1)))) s"
                show(requestedURL ?? url)
            }
        }
    }

    private func display(_ node: DiskNode) {
        chart.root = node
        list.reload(root: node)
        showInfo(nil)
    }

    /// Retire un élément mis à la corbeille et redessine.
    func remove(_ url: URL) {
        guard let current = chart.root, let tree, let rootURL = tree.rootURL, url.isInside(rootURL) else { return }
        let root = rootURL.standardizedFileURL.path
        var components = url.standardizedFileURL.path.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/").map(String.init)
        guard let last = components.popLast(), let parent = tree.descendant(components),
              let node = parent.children?.first(where: { $0.name == last }) else { return }
        node.detach()
        display(current)
    }

    // MARK: Interaction

    @objc private func styleChanged(_ sender: NSSegmentedControl) {
        style = DiskChartStyle(rawValue: sender.selectedSegment) ?? .flat
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        chart.colorMode = DiskColorMode(rawValue: sender.indexOfSelectedItem) ?? .type
        list.reloadColors()
    }

    @objc private func refresh(_ sender: Any?) {
        guard let url = requestedURL else { return }
        tree = nil
        show(url, forceRescan: true)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 51 where modifiers.isEmpty, 126 where modifiers == .command: onUp?()
        case 53 where modifiers.isEmpty: onExit?()
        default: return false
        }
        return true
    }

    private func listColor(_ node: DiskNode) -> NSColor {
        // La liste reprend les couleurs du graphique (branche : teinte de l'ancêtre de premier niveau).
        chart.shapes.last(where: { $0.node === node })?.color ?? (chart.colorMode == .age ? DiskColorMode.ageColor(node.modified) : node.category.color)
    }

    private func showInfo(_ node: DiskNode?) {
        guard let node = node ?? chart.root else { infoLabel.stringValue = ""; return }
        var parts = [node.name + (node.isDirectory ? "/" : ""), Format.size(node.size)]
        if let parent = node.parent, node !== chart.root, parent.size > 0 {
            parts.append("\(DiskChartView.percent(Double(node.size) / Double(parent.size))) de « \(parent.name) »")
        }
        if node.isDirectory || node.isAggregate {
            parts.append(node.count <= 1 ? "\(node.count) fichier" : "\(node.count.formatted()) fichiers")
            let main = DiskCategory.allCases.map { ($0, node.size(of: $0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3)
            if node.size > 0, !main.isEmpty {
                parts.append(main.map { "\($0.0.title) \(DiskChartView.percent(Double($0.1) / Double(node.size)))" }.joined(separator: ", "))
            }
        }
        if node.modified > 0 {
            parts.append("modifié le " + Date(timeIntervalSinceReferenceDate: node.modified).formatted(date: .abbreviated, time: .omitted))
        }
        infoLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    private func menu(for node: DiskNode) -> NSMenu? {
        guard !node.isAggregate else { return nil }
        let menu = NSMenu()
        let url = node.url
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        if node.isDirectory, node !== chart.root {
            add("Explorer « \(node.name) »", "arrow.down.right.circle") { [weak self] in self?.onNavigate?(url) }
        }
        add("Ouvrir", "arrow.up.forward.app") { [weak self] in self?.onOpen?(url) }
        add("Afficher dans la liste", "list.bullet") { [weak self] in self?.onRevealInList?(url) }
        add("Afficher dans le Finder", "macwindow") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        if node !== chart.root, node.parent != nil {
            menu.addItem(.separator())
            add("Placer dans la corbeille", "trash") { [weak self] in self?.onTrash?(url) }
        }
        return menu
    }
}

/// Zone du graphique : seul, ou à côté (au-dessus si étroit) de la liste.
private final class DiskContentView: NSView {
    weak var chart: NSView?
    weak var list: NSView?
    var style = DiskChartStyle.flat { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        guard let chart, let list else { return }
        switch style {
        case .donut, .baobab:
            let donut = style == .donut
            if bounds.width >= (donut ? 560 : 640) {
                let chartWidth = donut ? min(bounds.height, bounds.width * 0.45) : (bounds.width * 0.46).rounded()
                let listWidth = bounds.width - chartWidth - 12
                chart.frame = CGRect(x: donut ? 0 : listWidth + 12, y: 0, width: chartWidth, height: bounds.height)
                list.frame = CGRect(x: donut ? chartWidth + 12 : 0, y: 0, width: listWidth, height: bounds.height)
            } else {
                let side = min(bounds.width, bounds.height * 0.42)
                chart.frame = CGRect(x: 0, y: bounds.height - side, width: bounds.width, height: side)
                list.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - side - 8)
            }
        default:
            chart.frame = bounds
        }
    }
}

/// Élément de menu qui exécute une fermeture.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run(_ sender: Any?) { handler() }
}

// MARK: - Liste (vues « Anneau et liste » et « Liste et soleil »)

/// Liste triée par taille : nom, barre d'utilisation, taille, nombre d'éléments ; dépliable en arborescence.
final class DiskListView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onHover: ((DiskNode?) -> Void)?
    var onDive: ((DiskNode) -> Void)?
    var menuProvider: ((DiskNode) -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?
    var colorProvider: ((DiskNode) -> NSColor)?
    var expandable = false

    private let outline = DiskOutlineView()
    private var root: DiskNode?
    private var isSyncing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let columns: [(String, String, CGFloat)] = [("name", "Nom", 220), ("usage", "Utilisation", 96), ("size", "Taille", 82), ("count", "Éléments", 60)]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "name" ? 100 : 50
            if identifier == "size" || identifier == "count" { column.headerCell.alignment = .right }
            outline.addTableColumn(column)
            if identifier == "name" { outline.outlineTableColumn = column }
        }
        outline.style = .inset
        outline.rowHeight = 22
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.onHover = { [weak self] row in
            guard let self else { return }
            onHover?(row >= 0 ? outline.item(atRow: row) as? DiskNode : nil)
        }
        outline.menuProvider = { [weak self] row in
            guard let self, row >= 0, let node = outline.item(atRow: row) as? DiskNode else { return nil }
            return menuProvider?(node)
        }
        outline.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        documentView = outline
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if abs(outline.frame.width - contentSize.width) > 0.5 {
            outline.frame.size.width = contentSize.width
            outline.sizeToFit()
        }
    }

    func reload(root: DiskNode?) {
        self.root = root
        outline.reloadData()
    }

    func reloadColors() {
        let rows = outline.rows(in: outline.visibleRect)
        guard rows.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<NSMaxRange(rows)), columnIndexes: [0])
    }

    /// Sélectionne la ligne du nœud (ou de son ancêtre visible le plus proche) sans la déplier.
    func highlight(_ node: DiskNode?) {
        guard !isHidden else { return }
        var candidate = node
        while let current = candidate, outline.row(forItem: current) < 0 { candidate = current.parent }
        isSyncing = true
        if let candidate, candidate !== root {
            let row = outline.row(forItem: candidate)
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
        isSyncing = false
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? DiskNode else { return }
        onDive?(node)
    }

    // MARK: Source de données

    private func kids(_ item: Any?) -> [DiskNode] {
        guard let node = (item as? DiskNode) ?? (item == nil ? root : nil) else { return [] }
        return node.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item != nil, !expandable { return 0 }
        return kids(item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { kids(item)[index] }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        expandable && !((item as? DiskNode)?.children?.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DiskNode, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let parentSize = Double(max(node.parent?.size ?? node.size, 1))
        switch identifier {
        case "usage":
            let bar = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("usageCell"), owner: nil) as? UsageBarView) ?? {
                let view = UsageBarView()
                view.identifier = NSUserInterfaceItemIdentifier("usageCell")
                return view
            }()
            bar.fraction = Double(node.size) / parentSize
            return bar
        default:
            let cellIdentifier = NSUserInterfaceItemIdentifier(identifier + "Cell")
            let cell = (outlineView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView) ?? makeCell(cellIdentifier, withDot: identifier == "name")
            switch identifier {
            case "name":
                cell.textField?.stringValue = node.name
                cell.textField?.textColor = node.isAggregate ? .secondaryLabelColor : .labelColor
                cell.imageView?.image = Self.dot(colorProvider?(node) ?? node.category.color)
            case "size":
                cell.textField?.stringValue = Format.size(node.size)
            default:
                cell.textField?.stringValue = node.isDirectory || node.isAggregate ? node.count.formatted() : "—"
            }
            return cell
        }
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, withDot: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = withDot ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.alignment = withDot ? .natural : .right
        field.textColor = withDot ? .labelColor : .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        var constraints = [field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                           field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
        if withDot {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                            image.widthAnchor.constraint(equalToConstant: 10), image.heightAnchor.constraint(equalToConstant: 10),
                            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// Table qui signale la ligne survolée et délègue le clavier et le menu contextuel.
private final class DiskOutlineView: NSOutlineView {
    var onHover: ((Int) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?
    private var hoveredRow = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row != hoveredRow else { return }
        hoveredRow = row
        onHover?(row)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
        onHover?(-1)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Barre d'utilisation façon Baobab : rouge à 100 %, jaune au-delà de 30 %, verte en dessous.
private final class UsageBarView: NSView {
    var fraction = 0.0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let text = DiskChartView.percent(fraction)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        let textWidth: CGFloat = bounds.width > 90 ? 40 : 0
        let track = CGRect(x: 1, y: (bounds.height - 9) / 2, width: max(10, bounds.width - textWidth - 6), height: 9)
        let fill = fraction >= 0.995 ? NSColor(hex: "#D64541") : fraction >= 0.3 ? NSColor(hex: "#E3B23C") : NSColor(hex: "#4CAF50")
        fill.setFill()
        CGRect(x: track.minX, y: track.minY, width: max(1, track.width * CGFloat(min(1, fraction))), height: track.height).fill()
        NSColor.secondaryLabelColor.setStroke()
        let border = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        border.lineWidth = 1
        border.stroke()
        if textWidth > 0 {
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: bounds.width - size.width - 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
    }
}
