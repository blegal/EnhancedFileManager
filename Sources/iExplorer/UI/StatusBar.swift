import AppKit

/// Barre d'état en bas de chaque panneau : contenu et sélection à gauche, zoom du panneau à droite.
final class PanelStatusBar: NSView {
    static let visibilityChanged = Notification.Name("StatusBarVisibilityChanged")

    static var isVisible: Bool {
        get { UserDefaults.standard.object(forKey: "statusBarVisible") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "statusBarVisible")
            NotificationCenter.default.post(name: visibilityChanged, object: nil)
        }
    }

    weak var panel: PanelViewController?

    private let icon = NSImageView()
    private let info = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 100, minValue: 40, maxValue: 320, target: nil, action: nil)
    private let percent = NSTextField(labelWithString: "100 %")
    private var zoomControls: [NSControl] = []
    private var height: NSLayoutConstraint!
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let separator = NSBox()
        separator.boxType = .separator

        icon.imageScaling = .scaleProportionallyUpOrDown
        info.font = .systemFont(ofSize: 11)
        info.textColor = Theme.secondaryText
        info.lineBreakMode = .byTruncatingMiddle
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            button.isBordered = false
            button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            button.contentTintColor = Theme.secondaryText
            button.toolTip = tip
            return button
        }
        let smaller = button("minus.magnifyingglass", "Réduire (⌘−)", #selector(zoomOut))
        let larger = button("plus.magnifyingglass", "Agrandir (⌘+)", #selector(zoomIn))
        let reset = button("arrow.counterclockwise", "Taille par défaut (⌘0)", #selector(resetZoom))
        slider.controlSize = .mini
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.toolTip = "Zoom du panneau : taille des icônes ou des lignes (⌘ + molette, pincement)"
        slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percent.textColor = Theme.secondaryText
        percent.alignment = .right
        percent.widthAnchor.constraint(equalToConstant: 38).isActive = true
        zoomControls = [smaller, slider, larger, reset]

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [icon, info, spacer, smaller, slider, larger, percent, reset])
        stack.spacing = 6
        stack.setCustomSpacing(4, after: icon)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)

        for view in [separator, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        height = heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            height,
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        ThemeBackgroundView.install(.header, in: self)
        clipsToBounds = true
        applyVisibility()
        observer = NotificationCenter.default.addObserver(forName: Self.visibilityChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyVisibility()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func applyVisibility() {
        height.constant = Self.isVisible ? 24 : 0
        isHidden = !Self.isVisible
    }

    func refresh() {
        guard let panel else { return }
        let selection = panel.selectedItems
        let single = selection.count == 1 && !panel.isShowingDiskUsage ? selection[0] : nil
        icon.image = single?.icon
        icon.isHidden = single == nil
        info.stringValue = panel.statusDescription
        info.toolTip = single.map { $0.url.isFileURL ? $0.url.path : $0.url.absoluteString } ?? info.stringValue

        let range = panel.zoomRange
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = panel.zoomPercent
        percent.stringValue = "\(Int(panel.zoomPercent.rounded())) %"
        let enabled = panel.canZoom
        zoomControls.forEach { $0.isEnabled = enabled }
        percent.textColor = enabled ? Theme.secondaryText : .tertiaryLabelColor
    }

    @objc private func sliderChanged() { panel?.setZoomPercent(slider.doubleValue) }
    @objc private func zoomIn() { panel?.increaseIconSize(nil) }
    @objc private func zoomOut() { panel?.decreaseIconSize(nil) }
    @objc private func resetZoom() { panel?.resetZoom(nil) }
}

extension PanelViewController {
    func postStatusChange() { statusBar.refresh() }

    /// Le zoom agit sur les icônes et les listes (pas sur les colonnes ni l'occupation du disque).
    var canZoom: Bool { !isShowingDiskUsage && viewMode != .columns }

    /// Zoom en pourcentage de la taille par défaut (icônes de 80 points, lignes à l'échelle 1).
    var zoomPercent: Double {
        viewMode == .icons ? Double(iconSize) / 80 * 100 : Double(listScale) * 100
    }

    var zoomRange: ClosedRange<Double> { viewMode == .icons ? 40...320 : 75...200 }

    func setZoomPercent(_ percent: Double) {
        if viewMode == .icons { setIconSize(CGFloat(percent / 100 * 80)) } else { setListScale(CGFloat(percent / 100)) }
    }

    /// Texte de la barre d'état : le détail d'un élément sélectionné seul, sinon le résumé du panneau.
    var statusDescription: String {
        if isShowingDiskUsage { return "Occupation du disque — \(BreadcrumbView.displayName(currentURL))" }
        let selection = selectedItems
        guard selection.count == 1, !infoText.hasPrefix("⚠︎") else { return infoText }
        let item = selection[0]
        var parts = [item.name, item.kind]
        if let size = item.effectiveSize { parts.append(Format.size(size)) }
        if let date = item.modificationDate { parts.append("modifié le " + Format.dateFormatter.string(from: date)) }
        if item.isSymlink { parts.append("alias") }
        return parts.joined(separator: " — ")
    }

    /// « 2 dossiers, 3 fichiers ».
    static func describeKinds(_ selection: [FileItem]) -> String {
        let folders = selection.filter(\.isNavigableDirectory).count
        let files = selection.count - folders
        var counts: [String] = []
        if folders > 0 { counts.append(folders == 1 ? "1 dossier" : "\(folders) dossiers") }
        if files > 0 { counts.append(files == 1 ? "1 fichier" : "\(files) fichiers") }
        return counts.joined(separator: ", ")
    }

    @objc func toggleStatusBar(_ sender: Any?) { PanelStatusBar.isVisible.toggle() }
}
