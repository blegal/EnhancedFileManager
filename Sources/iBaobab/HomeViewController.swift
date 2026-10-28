import AppKit
import DiskUsageKit

/// Onglet « Accueil » : volumes montés, dossiers usuels, choix d'un dossier ou glisser-déposer.
final class HomeViewController: NSViewController {
    var onAnalyze: ((URL) -> Void)?
    var onChooseFolder: (() -> Void)?

    private let volumesStack = NSStackView()
    private var observers: [NSObjectProtocol] = []

    deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    override func loadView() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
        root.onDrop = { [weak self] url in self?.onAnalyze?(url) }

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: "Que voulez-vous analyser ?")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Choisissez un disque ou un dossier : chaque analyse s'ouvre dans un nouvel onglet.")
        subtitle.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4
        let header = NSStackView(views: [icon, titles])
        header.spacing = 16

        volumesStack.orientation = .vertical
        volumesStack.alignment = .leading
        volumesStack.spacing = 8

        // Tuiles des dossiers usuels, cinq par ligne.
        let folders = NSStackView()
        folders.orientation = .vertical
        folders.alignment = .leading
        folders.spacing = 8
        let tiles = Self.usualFolders().map { url in
            let name = url == FileManager.default.homeDirectoryForCurrentUser ? "Accueil" : FileManager.default.displayName(atPath: url.path)
            let tile = CardView(icon: NSWorkspace.shared.icon(forFile: url.path), title: name, compact: true)
            tile.toolTip = url.path
            tile.onClick = { [weak self] in self?.onAnalyze?(url) }
            tile.widthAnchor.constraint(equalToConstant: 168).isActive = true
            return tile
        }
        for start in stride(from: 0, to: tiles.count, by: 5) {
            let row = NSStackView(views: Array(tiles[start..<min(start + 5, tiles.count)]))
            row.spacing = 8
            folders.addArrangedSubview(row)
        }

        let choose = NSButton(title: "Choisir un dossier…", target: self, action: #selector(chooseFolder(_:)))
        choose.bezelStyle = .push
        choose.controlSize = .large
        let hint = NSTextField(labelWithString: "ou glissez un dossier dans cette fenêtre.")
        hint.textColor = .secondaryLabelColor
        let chooseRow = NSStackView(views: [choose, hint])
        chooseRow.spacing = 12

        let content = NSStackView(views: [header, section("Disques"), volumesStack, section("Dossiers"), folders, chooseRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.setCustomSpacing(28, after: header)
        content.setCustomSpacing(24, after: volumesStack)
        content.setCustomSpacing(24, after: folders)
        content.edgeInsets = NSEdgeInsets(top: 32, left: 40, bottom: 32, right: 40)
        content.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 960),
            volumesStack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -80),
        ])
        view = root
        reloadVolumes()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reloadVolumes() })
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // L'espace libre a pu changer depuis la dernière visite.
        reloadVolumes()
    }

    @objc private func chooseFolder(_ sender: Any?) { onChooseFolder?() }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: Volumes

    private static let volumeKeys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                       .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey, .volumeIsRemovableKey]

    private func reloadVolumes() {
        volumesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.volumeKeys, options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(Self.volumeKeys)) else { continue }
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Format.availableCapacity(at: url) ?? Int64(values.volumeAvailableCapacity ?? 0)
            let name = values.volumeLocalizedName ?? url.displayName
            let card = CardView(icon: NSWorkspace.shared.icon(forFile: url.path), title: name, compact: false)
            var details = total > 0 ? ["\(Format.size(free)) disponibles sur \(Format.size(total))"] : []
            if let format = values.volumeLocalizedFormatDescription { details.append(format) }
            if values.volumeIsRemovable == true { details.append("amovible") } else if values.volumeIsInternal == false { details.append("externe") }
            card.detail = details.joined(separator: "  ·  ")
            card.fraction = total > 0 ? Double(total - free) / Double(total) : nil
            card.toolTip = url.path
            card.onClick = { [weak self] in self?.onAnalyze?(url) }
            card.translatesAutoresizingMaskIntoConstraints = false
            volumesStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: volumesStack.widthAnchor).isActive = true
        }
    }

    // MARK: Dossiers usuels

    private static func usualFolders() -> [URL] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let directories: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory,
                                                              .picturesDirectory, .musicDirectory, .moviesDirectory]
        var urls = [home] + directories.compactMap { manager.urls(for: $0, in: .userDomainMask).first }
        urls += [home.appendingPathComponent("Library"), URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users")]
        return urls.filter { var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue }
    }
}

// MARK: - Cartes

/// Carte cliquable : icône, titre, détail et barre d'occupation facultatifs ; surlignée au survol.
final class CardView: NSView {
    var onClick: (() -> Void)?
    var detail = "" { didSet { detailLabel.stringValue = detail; detailLabel.isHidden = detail.isEmpty } }
    var fraction: Double? { didSet { bar.fraction = fraction ?? 0; bar.isHidden = fraction == nil } }

    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = OccupancyBar()
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(icon: NSImage, title: String, compact: Bool) {
        super.init(frame: .zero)
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        let side: CGFloat = compact ? 32 : 44
        image.widthAnchor.constraint(equalToConstant: side).isActive = true
        image.heightAnchor.constraint(equalToConstant: side).isActive = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: compact ? .regular : .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isHidden = true
        bar.isHidden = true
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let texts = NSStackView(views: [titleLabel, bar, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 5
        bar.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.isHidden = compact
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        image.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [image, texts, chevron])
        row.distribution = .fill
        row.spacing = compact ? 8 : 14
        row.edgeInsets = compact ? NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10) : NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: side + row.edgeInsets.top + row.edgeInsets.bottom),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(pressed ? 0.12 : hovered ? 0.08 : 0.04).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}

/// Barre d'occupation d'un volume : accentuée, orange au-delà de 80 %, rouge au-delà de 90 %.
private final class OccupancyBar: NSView {
    var fraction = 0.0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let color: NSColor = fraction > 0.9 ? .systemRed : fraction > 0.8 ? .systemOrange : .controlAccentColor
        color.setFill()
        let width = max(bounds.height, bounds.width * CGFloat(min(1, max(0, fraction))))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Vue racine de l'accueil : accepte le dépôt d'un dossier (contour accentué pendant le glisser).
private final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var isTargeted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func folder(in info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargeted = folder(in: sender) != nil
        return isTargeted ? .generic : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        guard let url = folder(in: sender) else { return false }
        onDrop?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isTargeted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 12, yRadius: 12)
        path.lineWidth = 3
        path.setLineDash([10, 6], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
