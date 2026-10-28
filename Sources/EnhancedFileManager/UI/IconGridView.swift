import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Grille d'icônes d'un panneau : mêmes relais que `FileTableView` (focus, clavier, menu).
final class FileCollectionView: NSCollectionView {
    var onFocus: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var contextMenuProvider: (() -> NSMenu?)?
    var onDoubleClick: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let factor = ZoomGesture.factor(for: event) { onZoom?(factor) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) { onZoom?(1 + event.magnification) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { refreshSelectionStyle() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = indexPathForItem(at: point)
        super.mouseDown(with: event)
        if event.clickCount == 2, hit != nil { onDoubleClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
                delegate?.collectionView?(self, didSelectItemsAt: [indexPath])
            }
        } else if !selectionIndexPaths.isEmpty {
            let previous = selectionIndexPaths
            selectionIndexPaths = []
            delegate?.collectionView?(self, didDeselectItemsAt: previous)
        }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        return contextMenuProvider?()
    }

    /// Met à jour l'accentuation de la sélection (active / inactive).
    func refreshSelectionStyle() {
        for case let item as ThumbnailItem in visibleItems() { item.refreshAppearance() }
    }
}

/// Une vignette : image (miniature QuickLook ou icône) et nom.
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    private let imageBackground = NSView()
    private let thumbnail = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var representedPath = ""
    private var gitColor: NSColor?

    override var isSelected: Bool { didSet { refreshAppearance() } }

    override func loadView() {
        let root = NSView()
        imageBackground.wantsLayer = true
        imageBackground.layer?.cornerRadius = 8
        imageBackground.layer?.cornerCurve = .continuous
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 4

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.drawsBackground = false
        for view in [imageBackground, thumbnail, label, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageBackground.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            imageBackground.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            imageBackground.widthAnchor.constraint(equalTo: imageBackground.heightAnchor),
            imageBackground.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -4),
            thumbnail.topAnchor.constraint(equalTo: imageBackground.topAnchor, constant: 6),
            thumbnail.leadingAnchor.constraint(equalTo: imageBackground.leadingAnchor, constant: 6),
            thumbnail.trailingAnchor.constraint(equalTo: imageBackground.trailingAnchor, constant: -6),
            thumbnail.bottomAnchor.constraint(equalTo: imageBackground.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -2),
            label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            label.heightAnchor.constraint(lessThanOrEqualToConstant: 32),
            label.topAnchor.constraint(equalTo: root.bottomAnchor, constant: -34),
            badge.trailingAnchor.constraint(equalTo: imageBackground.trailingAnchor, constant: 4),
            badge.bottomAnchor.constraint(equalTo: imageBackground.bottomAnchor, constant: 2),
        ])
        view = root
    }

    func configure(with file: FileItem, size: CGFloat, dimmed: Bool, gitColor: NSColor? = nil, badge repository: NSAttributedString? = nil) {
        self.gitColor = gitColor
        badge.attributedStringValue = repository ?? NSAttributedString()
        badge.isHidden = repository == nil
        representedPath = file.url.normalizedPath
        label.stringValue = file.name
        label.preferredMaxLayoutWidth = size + 36
        view.alphaValue = dimmed ? 0.5 : 1
        thumbnail.image = file.icon
        refreshAppearance()

        guard !file.url.isRemote, !file.isNavigableDirectory else { return }
        let path = representedPath
        ThumbnailCache.shared.thumbnail(for: file.url, size: size, scale: view.window?.backingScaleFactor ?? 2) { [weak self] image in
            guard let self, representedPath == path, let image else { return }
            thumbnail.image = image
        }
    }

    func refreshAppearance() {
        guard isViewLoaded else { return }
        let emphasized = collectionView?.window?.firstResponder === collectionView && collectionView?.window?.isKeyWindow == true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            imageBackground.layer?.backgroundColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
            let pill: NSColor = emphasized ? Theme.accent : Theme.inactiveSelection
            label.layer?.backgroundColor = isSelected ? pill.cgColor : NSColor.clear.cgColor
        }
        label.textColor = isSelected && emphasized ? .white : (gitColor ?? Theme.text)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        }
    }
}

/// Cache des miniatures QuickLook (générées en arrière-plan).
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    /// Limité en octets (≈ 64 Mo de pixels décompressés), libéré automatiquement en cas de pression mémoire.
    init() { cache.totalCostLimit = 64 * 1024 * 1024 }

    func thumbnail(for url: URL, size: CGFloat, scale: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)|\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { completion(cached); return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                if let image {
                    let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? Int(size * size * scale * scale)
                    self?.cache.setObject(image, forKey: key, cost: max(pixels, 1) * 4)
                }
                completion(image)
            }
        }
    }
}
