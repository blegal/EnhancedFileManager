import AppKit

/// Table des fichiers d'un panneau : relaie le focus, le clavier et le menu contextuel.
final class FileTableView: NSTableView {
    var onFocus: (() -> Void)?
    /// ⌘ + molette ou pincement : facteur de zoom demandé.
    var onZoom: ((CGFloat) -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var contextMenuProvider: (() -> NSMenu?)?
    /// Clic simple sur le nom de l'élément déjà sélectionné : renommage après un court délai, comme dans le Finder.
    var onSlowClick: ((Int) -> Void)?
    private var slowClickTimer: Timer?
    private var didDrag = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        cancelSlowClick()
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        cancelSlowClick()
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let eligible = event.clickCount == 1
            && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            && window?.firstResponder === self
            && row >= 0 && selectedRowIndexes == [row]
            && isOnName(point, row: row)
        didDrag = false
        super.mouseDown(with: event)
        guard eligible, !didDrag, selectedRowIndexes == [row] else { return }
        // Au-delà de l'intervalle du double-clic, pour qu'un double-clic ouvre sans renommer.
        let delay = max(NSEvent.doubleClickInterval, 0.5) + 0.3
        slowClickTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            slowClickTimer = nil
            guard selectedRowIndexes == [row], window?.isKeyWindow == true, window?.firstResponder === self else { return }
            onSlowClick?(row)
        }
    }

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        didDrag = true
        cancelSlowClick()
        super.draggingSession(session, willBeginAt: screenPoint)
    }

    func cancelSlowClick() {
        slowClickTimer?.invalidate()
        slowClickTimer = nil
    }

    /// Le point tombe sur le texte du nom (pas sur l'icône ni dans le vide de la colonne).
    private func isOnName(_ point: NSPoint, row: Int) -> Bool {
        let column = column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0, column == self.column(at: point),
              let field = (view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField else { return false }
        let width = min(field.bounds.width, field.attributedStringValue.size().width + 8)
        let textRect = field.convert(NSRect(x: 0, y: 0, width: width, height: field.bounds.height), to: self)
        return textRect.contains(point)
    }

    override func scrollWheel(with event: NSEvent) {
        cancelSlowClick()
        if let factor = ZoomGesture.factor(for: event) { onZoom?(factor) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) { onZoom?(1 + event.magnification) }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelSlowClick()
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, delegate?.tableView?(self, shouldSelectRow: row) == false {
            return nil
        } else if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        return contextMenuProvider?()
    }
}

/// Barre d'onglets d'un panneau (affichée seulement à partir de deux onglets).
/// Couleurs d'onglet (palette des étiquettes du Finder).
enum TabColor: Int, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray

    var title: String {
        switch self {
        case .red: "Rouge"
        case .orange: "Orange"
        case .yellow: "Jaune"
        case .green: "Vert"
        case .blue: "Bleu"
        case .purple: "Violet"
        case .gray: "Gris"
        }
    }

    /// Petit carré de couleur pour les menus (carré vide pour « Aucune couleur »).
    /// Image en couleurs réelles : une image « modèle » serait affichée en gris.
    static func swatch(_ color: TabColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let square = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2.5, yRadius: 2.5)
            if let color {
                color.color.setFill()
                square.fill()
                color.color.shadow(withLevel: 0.25)?.setStroke()
            } else {
                NSColor.secondaryLabelColor.setStroke()
            }
            square.lineWidth = 1
            square.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = color?.title ?? "Aucune couleur"
        return image
    }

    var color: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }
}

final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onSetColor: ((Int, TabColor?) -> Void)?
    private var isActivePanel = false

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        // La barre d'onglets ne doit jamais imposer sa largeur au panneau (séparateurs libres).
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Nouvel onglet")!, target: self, action: #selector(addTab))
        add.isBordered = false
        add.contentTintColor = .secondaryLabelColor
        add.toolTip = "Nouvel onglet (⌘T)"
        add.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(add)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            add.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 6),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            add.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(tabs: [(title: String, path: String, color: TabColor?)], selected: Int, active: Bool) {
        isActivePanel = active
        needsDisplay = true
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let item = TabItemView(title: tab.title)
            item.toolTip = tab.path
            item.tabColor = tab.color
            item.isSelected = index == selected
            item.isActivePanel = active
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            item.onSetColor = { [weak self] color in self?.onSetColor?(index, color) }
            stack.addArrangedSubview(item)
        }
    }

    /// Fond de la zone des onglets : teinté par l'accent (plus marqué sur le panneau actif).
    override func draw(_ dirtyRect: NSRect) {
        Theme.accent.withAlphaComponent(isActivePanel ? 0.10 : 0.05).setFill()
        bounds.fill(using: .sourceOver)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func addTab() { onAdd?() }
}

private final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onSetColor: ((TabColor?) -> Void)?
    var tabColor: TabColor? { didSet { refresh() } }
    private let colorBar = NSView()
    var isSelected = false { didSet { refresh() } }
    var isActivePanel = false { didSet { refresh() } }

    private let label: NSTextField
    private let closeButton: NSButton
    private var hovering = false { didSet { refresh() } }

    init(title: String) {
        label = NSTextField(labelWithString: title)
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer l’onglet")!, target: nil, action: nil)
        closeButton.toolTip = "Fermer l’onglet (⌘W)"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        closeButton.isBordered = false
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        colorBar.wantsLayer = true
        colorBar.layer?.cornerRadius = 1.5
        colorBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(colorBar)
        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            colorBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            colorBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            colorBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            colorBar.heightAnchor.constraint(equalToConstant: 3),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func otherMouseDown(with event: NSEvent) { onClose?() }

    /// Clic droit : couleur de l'onglet.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let none = NSMenuItem(title: "Aucune couleur", action: #selector(pickColor(_:)), keyEquivalent: "")
        none.target = self
        none.tag = -1
        none.state = tabColor == nil ? .on : .off
        none.image = TabColor.swatch(nil)
        menu.addItem(none)
        menu.addItem(.separator())
        for color in TabColor.allCases {
            let item = NSMenuItem(title: color.title, action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = color.rawValue
            item.state = tabColor == color ? .on : .off
            item.image = TabColor.swatch(color)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Fermer l’onglet", action: #selector(closeTab), keyEquivalent: "")
        close.target = self
        close.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        menu.addItem(close)
        return menu
    }

    @objc private func pickColor(_ sender: NSMenuItem) { onSetColor?(TabColor(rawValue: sender.tag)) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    @objc private func closeTab() { onClose?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        closeButton.isHidden = !hovering
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Onglet coloré : sa couleur teinte le fond et souligne l'onglet ; sinon l'accent du thème.
            let tint = tabColor?.color ?? (isActivePanel ? Theme.accent : NSColor.labelColor)
            let color: NSColor
            if isSelected {
                color = tint.withAlphaComponent(tabColor != nil ? 0.30 : (isActivePanel ? 0.16 : 0.08))
            } else if let tabColor {
                color = tabColor.color.withAlphaComponent(hovering ? 0.20 : 0.12)
            } else {
                color = hovering ? NSColor.labelColor.withAlphaComponent(0.05) : .clear
            }
            layer?.backgroundColor = color.cgColor
            colorBar.layer?.backgroundColor = (tabColor?.color ?? .clear).cgColor
        }
    }
}

/// Fil d'Ariane : maison (ou disque) › dossier › sous-dossier, chaque élément cliquable.
final class BreadcrumbView: NSView {
    var onNavigate: ((URL) -> Void)?
    var isActive = true { didSet { if oldValue != isActive { rebuild() } } }

    private let stack = NSStackView()
    private var url: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ url: URL) {
        self.url = url
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var components: [URL] = []
        var cursor = url.standardizedFileURL
        // Dans une archive dépliée, on montre le chemin de l'archive plutôt que celui du cache.
        var target: (URL) -> URL = { $0 }
        if let (archive, root) = ArchiveBrowser.archive(containing: url) {
            let archivePath = archive.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            cursor = URL(fileURLWithPath: archivePath + cursor.path.dropFirst(rootPath.count))
            target = { $0.path.hasPrefix(archivePath) ? URL(fileURLWithPath: rootPath + $0.path.dropFirst(archivePath.count)) : $0 }
        }
        let rootURL: URL
        let rootSymbol: String
        if url.isRemote, let endpoint = SFTPEndpoint(url: url) {
            rootURL = endpoint.url(path: "/")
            rootSymbol = "server.rack"
            cursor = url.standardized
        } else if cursor.isInside(home) {
            rootURL = home
            rootSymbol = "house.fill"
        } else {
            rootURL = Self.volumeRoot(of: cursor)
            rootSymbol = rootURL.path == "/" ? "internaldrive.fill" : "externaldrive.fill"
        }
        while !cursor.isSameLocation(as: rootURL) && cursor.path != "/" && !cursor.path.isEmpty {
            components.insert(cursor, at: 0)
            cursor = url.isRemote ? cursor.deletingLastPathComponent().standardized : cursor.deletingLastPathComponent().standardizedFileURL
        }

        let textColor: NSColor = isActive ? Theme.text : Theme.secondaryText
        let rootButton = makeButton(title: nil, symbol: rootSymbol, url: rootURL, color: textColor)
        rootButton.toolTip = rootURL.path
        stack.addArrangedSubview(rootButton)
        if components.isEmpty {
            stack.addArrangedSubview(makeButton(title: Self.displayName(rootURL), symbol: nil, url: rootURL, color: textColor))
        }
        for (index, component) in components.enumerated() {
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
            chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            chevron.contentTintColor = .tertiaryLabelColor
            stack.addArrangedSubview(chevron)
            let button = makeButton(title: Self.displayName(component), symbol: nil, url: target(component), color: textColor)
            stack.addArrangedSubview(button)
            // Les éléments les plus anciens disparaissent en premier si la place manque.
            let priority = NSStackView.VisibilityPriority(rawValue: Float(500 + index * 10))
            stack.setVisibilityPriority(index == components.count - 1 ? .mustHold : priority, for: button)
            stack.setVisibilityPriority(index == components.count - 1 ? .mustHold : priority, for: chevron)
        }
    }

    private func makeButton(title: String?, symbol: String?, url: URL, color: NSColor) -> NSButton {
        let button = NSButton(title: title ?? "", target: self, action: #selector(clicked(_:)))
        button.isBordered = false
        button.identifier = NSUserInterfaceItemIdentifier(url.isRemote ? url.absoluteString : url.path)
        button.toolTip = url.isRemote ? url.absoluteString : url.path
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: Self.displayName(url))
            button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            button.imagePosition = .imageOnly
            button.contentTintColor = isActive ? Theme.accent : Theme.secondaryText
        } else {
            button.attributedTitle = NSAttributedString(string: title ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: color,
            ])
            button.lineBreakMode = .byTruncatingMiddle
        }
        return button
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if path.hasPrefix("sftp://"), let url = URL(string: path) { onNavigate?(url); return }
        onNavigate?(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func displayName(_ url: URL) -> String { url.displayName }

    static func volumeRoot(of url: URL) -> URL {
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
        return volume?.standardizedFileURL ?? URL(fileURLWithPath: "/")
    }
}

/// Conversion de ⌘ + molette en facteur de zoom (molette crantée ou trackpad).
enum ZoomGesture {
    static func factor(for event: NSEvent) -> CGFloat? {
        guard event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 else { return nil }
        let delta = event.scrollingDeltaY
        return event.hasPreciseScrollingDeltas ? 1 + delta * 0.006 : pow(1.1, delta > 0 ? 1 : -1)
    }
}
