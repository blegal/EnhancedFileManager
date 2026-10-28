import AppKit

private extension NSToolbarItem.Identifier {
    static let back = NSToolbarItem.Identifier("back")
    static let forward = NSToolbarItem.Identifier("forward")
    static let layout = NSToolbarItem.Identifier("layout")
    static let iconTheme = NSToolbarItem.Identifier("iconTheme")
    static let colorTheme = NSToolbarItem.Identifier("colorTheme")
    static let viewMode = NSToolbarItem.Identifier("viewMode")
    static let inspector = NSToolbarItem.Identifier("inspector")
    static let git = NSToolbarItem.Identifier("git")
    static let terminal = NSToolbarItem.Identifier("terminal")
    static let newFolder = NSToolbarItem.Identifier("newFolder")
    static let trash = NSToolbarItem.Identifier("trash")
    static let quickLook = NSToolbarItem.Identifier("quickLook")
    static let hidden = NSToolbarItem.Identifier("hidden")
    static let connect = NSToolbarItem.Identifier("connect")
}

/// Zone des panneaux : dispositions 1, 2, 3 ou 4 panneaux et file des opérations.
final class PanelsViewController: NSViewController, PanelHost {
    private(set) var panels: [PanelViewController] = []
    private(set) var layout: PanelLayout = .twoColumns
    private var initialFractions: [[Double]]?
    /// Positions à appliquer dès que les vues partagées auront leur taille définitive.
    private var pendingFractions: [[Double]]?
    private var needsSplitPositions = false
    private(set) var activeIndex = 0
    var onActivePanelChange: ((PanelViewController) -> Void)?
    var onActiveSelectionChange: ((PanelViewController) -> Void)?
    var onLayoutChange: ((Int) -> Void)?

    private let container = NSView()
    private let jobsView = JobsView()
    /// Vues partagées des panneaux, de la plus extérieure à la plus intérieure.
    private var splitViews: [NSSplitView] = []
    private var gridObservers: [NSObjectProtocol] = []
    private var isSyncingGrid = false

    var activePanel: PanelViewController { panels[activeIndex] }
    var visiblePanels: [PanelViewController] { Array(panels.prefix(layout.panelCount)) }

    init(state: WindowState?) {
        super.init(nibName: nil, bundle: nil)
        for index in 0..<4 {
            let panelState = state.flatMap { $0.panels.indices.contains(index) ? $0.panels[index] : nil }
            let panel = PanelViewController(index: index, state: panelState)
            panel.host = self
            panels.append(panel)
        }
        layout = PanelLayout(rawValue: state?.layout ?? 2) ?? .twoColumns
        initialFractions = state?.splitFractions
        activeIndex = min(max(state?.activePanel ?? 0, 0), layout.panelCount - 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        for view in [container, jobsView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            jobsView.topAnchor.constraint(equalTo: container.bottomAnchor),
            jobsView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            jobsView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            jobsView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        ThemeBackgroundView.install(.toolbar, in: root)
        view = root
        applyLayout(layout, fractions: initialFractions)
        initialFractions = nil
    }

    /// `fractions` : positions mémorisées des séparateurs (sinon répartition équitable).
    func applyLayout(_ newLayout: PanelLayout, fractions: [[Double]]? = nil) {
        layout = newLayout
        splitViews.forEach { $0.removeFromSuperview() }
        splitViews = []
        gridObservers.forEach(NotificationCenter.default.removeObserver)
        gridObservers = []
        for panel in panels {
            panel.view.removeFromSuperview()
            panel.removeFromParent()
        }

        let visible = visiblePanels
        visible.forEach(addChild)
        for panel in panels { panel.isShown = panel.index < layout.panelCount }
        let views = visible.map(\.view)
        let content: NSView
        switch layout {
        case .single: content = views[0]
        case .twoColumns, .threeColumns: content = makeSplit(vertical: true, views)
        case .twoRows: content = makeSplit(vertical: false, views)
        case .mainAndStacked: content = makeSplit(vertical: true, [views[0], makeSplit(vertical: false, [views[1], views[2]])])
        case .stackedAndMain: content = makeSplit(vertical: true, [makeSplit(vertical: false, [views[0], views[1]]), views[2]])
        case .pairAndBottom: content = makeSplit(vertical: false, [makeSplit(vertical: true, [views[0], views[1]]), views[2]])
        case .grid:
            let top = makeSplit(vertical: true, [views[0], views[1]])
            let bottom = makeSplit(vertical: true, [views[2], views[3]])
            content = makeSplit(vertical: false, [top, bottom])
            linkColumns(top, bottom)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // L'inspecteur change de largeur selon la disposition : à faire avant de répartir les panneaux.
        onLayoutChange?(layout.panelCount)
        // Les vues partagées n'ont leur taille qu'après la mise en page : positions appliquées dans viewDidLayout.
        scheduleSplitPositions(fractions)

        panels.forEach { $0.showsActiveIndicator = layout.panelCount > 1 }
        if activeIndex >= layout.panelCount { activeIndex = 0 }
        panelDidBecomeActive(activePanel)
        if view.window != nil { activePanel.activate() }
    }

    /// Vues partagées à base de cadres : le placement par programme est fiable, le glisser libre,
    /// et un redimensionnement de la fenêtre conserve les proportions.
    private func makeSplit(vertical: Bool, _ views: [NSView]) -> PanelSplitView {
        let split = PanelSplitView(vertical: vertical)
        // Parts égales dès le départ : la vue partagée redimensionne ensuite proportionnellement.
        let bounds = split.bounds
        let share = ((vertical ? bounds.width : bounds.height) - CGFloat(views.count - 1) * split.dividerThickness) / CGFloat(views.count)
        for (index, view) in views.enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.width, .height]
            let offset = CGFloat(index) * (share + split.dividerThickness)
            view.frame = vertical ? NSRect(x: offset, y: 0, width: share, height: bounds.height)
                                  : NSRect(x: 0, y: offset, width: bounds.width, height: share)
            split.addSubview(view)
        }
        splitViews.insert(split, at: 0) // les vues extérieures en premier
        return split
    }

    /// En grille 2×2, les séparateurs verticaux du haut et du bas restent alignés.
    private func linkColumns(_ a: NSSplitView, _ b: NSSplitView) {
        for (source, target) in [(a, b), (b, a)] {
            gridObservers.append(NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: source, queue: .main
            ) { [weak self] _ in
                // Seulement quand l'utilisateur fait glisser un séparateur (pas au redimensionnement de la fenêtre).
                let dragging = NSApp.currentEvent.map { [.leftMouseDragged, .leftMouseUp].contains($0.type) } ?? false
                guard let self, dragging, source.window?.inLiveResize == false, !isSyncingGrid,
                      let first = source.subviews.first, let other = target.subviews.first,
                      abs(first.frame.width - other.frame.width) > 0.5 else { return }
                isSyncingGrid = true
                target.setPosition(first.frame.width, ofDividerAt: 0)
                isSyncingGrid = false
            })
        }
    }

    /// Applique des positions de séparateurs dès que la mise en page aura donné leur taille finale aux vues.
    func scheduleSplitPositions(_ fractions: [[Double]]?) {
        pendingFractions = fractions
        needsSplitPositions = !splitViews.isEmpty
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard needsSplitPositions, let outer = splitViews.first, container.bounds.width > 0,
              abs(outer.frame.width - container.bounds.width) < 1, abs(outer.frame.height - container.bounds.height) < 1 else { return }
        needsSplitPositions = false
        let target = pendingFractions
        pendingFractions = nil
        restoreSplitFractions(target)
    }

    /// Positions actuelles des séparateurs (fractions de la longueur de chaque vue partagée).
    var splitFractions: [[Double]] {
        splitViews.map { split in
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            guard total > 0 else { return [] }
            return split.subviews.dropLast().map { view in
                Double((split.isVertical ? view.frame.maxX : view.frame.maxY) / total)
            }
        }
    }

    /// Restaure des positions mémorisées (sinon répartit équitablement), des vues extérieures aux intérieures.
    func restoreSplitFractions(_ fractions: [[Double]]?) {
        guard let fractions, fractions.count == splitViews.count else { equalize(); return }
        for (split, values) in zip(splitViews, fractions) {
            split.adjustSubviews()
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            for (index, fraction) in values.enumerated() where index < split.subviews.count - 1 {
                split.setPosition(CGFloat(fraction) * total, ofDividerAt: index)
            }
        }
    }

    /// Répartit l'espace équitablement entre les panneaux.
    func equalize() {
        for split in splitViews {
            split.adjustSubviews()
            let count = split.subviews.count
            guard count > 1 else { continue }
            let length = (split.isVertical ? split.bounds.width : split.bounds.height) - CGFloat(count - 1) * split.dividerThickness
            for index in 0..<(count - 1) {
                split.setPosition(length * CGFloat(index + 1) / CGFloat(count) + CGFloat(index) * split.dividerThickness, ofDividerAt: index)
            }
        }
    }

    // MARK: PanelHost

    func panelDidBecomeActive(_ panel: PanelViewController) {
        activeIndex = panel.index
        for other in panels { other.isActive = other === panel }
        onActivePanelChange?(panel)
    }

    func panelDidChangeDirectory(_ panel: PanelViewController) {
        if panel.index == activeIndex { onActivePanelChange?(panel) }
    }

    func panelSelectionDidChange(_ panel: PanelViewController) {
        if panel.index == activeIndex { onActiveSelectionChange?(panel) }
    }

    func panel(_ panel: PanelViewController, focusNextBackwards backwards: Bool) {
        let visible = visiblePanels
        guard visible.count > 1, let position = visible.firstIndex(where: { $0 === panel }) else { return }
        let next = (position + (backwards ? visible.count - 1 : 1)) % visible.count
        visible[next].activate()
    }

    func targetPanels(for panel: PanelViewController) -> [PanelViewController] {
        let visible = visiblePanels
        guard let position = visible.firstIndex(where: { $0 === panel }) else { return [] }
        return (1..<visible.count).map { visible[(position + $0) % visible.count] }
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    var onClose: ((MainWindowController) -> Void)?

    private let splitController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let panelsController: PanelsViewController
    private let sidebarItem: NSSplitViewItem
    private let inspector = InspectorViewController()
    private let inspectorItem: NSSplitViewItem
    private weak var layoutItem: NSMenuToolbarItem?
    private weak var viewModeControl: NSSegmentedControl?
    private weak var gitButton: NSButton?
    private weak var terminalButton: NSButton?
    private let workSplit = NSSplitViewController()
    private let terminalController = TerminalPanelController()
    private let terminalItem: NSSplitViewItem
    private let restoredState: WindowState?

    var activePanel: PanelViewController { panelsController.activePanel }

    init(state: WindowState?) {
        panelsController = PanelsViewController(state: state)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = state?.sidebarCollapsed ?? false
        restoredState = state
        // Zone centrale : panneaux en haut, terminal rabattable en bas.
        workSplit.splitView.isVertical = false
        workSplit.splitView.dividerStyle = .thin
        let panelsItem = NSSplitViewItem(viewController: panelsController)
        panelsItem.minimumThickness = 200
        panelsItem.holdingPriority = .defaultLow
        terminalItem = NSSplitViewItem(viewController: terminalController)
        terminalItem.canCollapse = true
        terminalItem.minimumThickness = 90
        terminalItem.holdingPriority = .defaultLow + 10
        terminalItem.isCollapsed = !(state?.terminalVisible ?? false)
        workSplit.addSplitViewItem(panelsItem)
        workSplit.addSplitViewItem(terminalItem)
        let contentItem = NSSplitViewItem(viewController: workSplit)
        contentItem.minimumThickness = 300
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 290
        inspectorItem.preferredThicknessFraction = 0.24
        inspectorItem.maximumThickness = 420
        inspectorItem.canCollapse = true
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.addSplitViewItem(inspectorItem)
        splitController.splitView.autosaveName = "MainSplit"

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 720, height: 420)
        window.tabbingMode = .disallowed
        window.titleVisibility = .visible
        window.contentViewController = splitController
        super.init(window: window)
        window.delegate = self

        if let frame = state?.frame {
            window.setFrame(NSRectFromString(frame), display: false)
        } else {
            window.setContentSize(NSSize(width: 1320, height: 800))
            window.center()
        }

        let toolbar = NSToolbar(identifier: "MainToolbar.v4")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        sidebar.onNavigate = { [weak self] url in
            guard let panel = self?.activePanel else { return }
            panel.navigate(to: url)
            panel.activate()
        }
        sidebar.onConnect = { [weak self] connection in
            if let connection { self?.open(connection) } else { self?.showConnectionPanel(nil) }
        }
        sidebar.onEditConnection = { [weak self] connection in self?.showConnectionPanel(connection) }
        panelsController.onActivePanelChange = { [weak self] panel in self?.activePanelChanged(panel) }
        panelsController.onActiveSelectionChange = { [weak self] panel in self?.updateInspector(panel) }
        panelsController.onLayoutChange = { [weak self] layout in self?.updateInspectorVisibility(layout: layout, animated: false) }
        updateInspectorVisibility(layout: panelsController.layout.panelCount, animated: false)
        NotificationCenter.default.addObserver(forName: IconTheme.changed, object: nil, queue: .main) { [weak self] _ in
            self?.updateIconThemeMenu()
        }
        NotificationCenter.default.addObserver(forName: ColorTheme.changed, object: nil, queue: .main) { [weak self] _ in
            (self?.window?.toolbar?.items.first { $0.itemIdentifier == .colorTheme } as? NSMenuToolbarItem)?.menu = ColorTheme.menu()
        }
        activePanelChanged(activePanel)
        window.initialFirstResponder = activePanel.tableView
        NotificationCenter.default.addObserver(forName: GitService.enabledChanged, object: nil, queue: .main) { [weak self] _ in
            self?.gitButton?.state = GitService.isEnabled ? .on : .off
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var windowState: WindowState {
        WindowState(layout: panelsController.layout.rawValue, activePanel: panelsController.activeIndex,
                    panels: panelsController.panels.map(\.state),
                    frame: window.map { NSStringFromRect($0.frame) },
                    sidebarCollapsed: sidebarItem.isCollapsed,
                    splitFractions: panelsController.splitFractions,
                    terminalVisible: !terminalItem.isCollapsed,
                    terminalHeight: Double(terminalController.view.frame.height))
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // La fenêtre a maintenant sa taille mémorisée : on peut placer les séparateurs.
        panelsController.scheduleSplitPositions(restoredState?.splitFractions)
        if !terminalItem.isCollapsed, let height = restoredState?.terminalHeight, height > 0 {
            workSplit.view.layoutSubtreeIfNeeded()
            workSplit.splitView.setPosition(workSplit.splitView.bounds.height - CGFloat(height) - workSplit.splitView.dividerThickness, ofDividerAt: 0)
        }
        activePanel.activate()
    }

    // MARK: Terminal

    @objc func toggleTerminal(_ sender: Any?) {
        let show = terminalItem.isCollapsed
        terminalController.panelDirectory = activePanel.currentURL.isFileURL ? activePanel.currentURL : nil
        terminalItem.isCollapsed = !show
        terminalButton?.state = show ? .on : .off
        if show {
            // Hauteur d'ouverture confortable (un tiers de la zone) si la précédente était trop petite.
            workSplit.view.layoutSubtreeIfNeeded()
            let split = workSplit.splitView
            if terminalController.view.frame.height < 160 {
                split.setPosition(split.bounds.height * 0.66, ofDividerAt: 0)
            }
        }
        if show { DispatchQueue.main.async { self.terminalController.focus() } } else { activePanel.activate() }
    }

    private func activePanelChanged(_ panel: PanelViewController) {
        window?.title = BreadcrumbView.displayName(panel.currentURL)
        window?.representedURL = nil
        sidebar.highlight(panel.currentURL)
        layoutItem?.image = panelsController.layout.icon()
        viewModeControl?.selectedSegment = panel.viewMode.rawValue
        updateInspector(panel)
        terminalController.activePanelDidChange(to: panel.currentURL)
    }

    // MARK: Inspecteur (mode étendu)

    /// Préférence d'affichage de l'inspecteur, distincte pour le panneau unique (affiché par défaut)
    /// et les dispositions à plusieurs panneaux (masqué par défaut).
    private func inspectorPreferenceKey(layout: Int) -> String { layout == 1 ? "inspector.single" : "inspector.multi" }

    private func updateInspectorVisibility(layout: Int, animated: Bool) {
        let defaults = UserDefaults.standard
        let key = inspectorPreferenceKey(layout: layout)
        let visible = defaults.object(forKey: key) as? Bool ?? (layout == 1)
        guard inspectorItem.isCollapsed == visible else { return }
        if animated { inspectorItem.animator().isCollapsed = !visible } else { inspectorItem.isCollapsed = !visible }
        if visible { updateInspector(activePanel) }
    }

    @objc func toggleInspectorPane(_ sender: Any?) {
        let key = inspectorPreferenceKey(layout: panelsController.layout.panelCount)
        UserDefaults.standard.set(inspectorItem.isCollapsed, forKey: key)
        updateInspectorVisibility(layout: panelsController.layout.panelCount, animated: true)
    }

    private func updateInspector(_ panel: PanelViewController) {
        guard !inspectorItem.isCollapsed, panel === activePanel else { return }
        inspector.show(selection: panel.selectedItems, folder: panel.currentURL)
    }

    @objc func setViewModeFromToolbar(_ sender: NSSegmentedControl) {
        guard let mode = PanelViewMode(rawValue: sender.selectedSegment) else { return }
        activePanel.setViewMode(mode)
    }

    func windowWillClose(_ notification: Notification) { onClose?(self) }

    /// Les actions de fichiers non traitées par le répondeur courant vont au panneau actif.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if activePanel.responds(to: action) { return activePanel }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: Actions de fenêtre

    @objc func setLayout(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let layout = PanelLayout(rawValue: item.tag) else { return }
        panelsController.applyLayout(layout)
        layoutItem?.image = layout.icon()
    }

    /// Menu des dispositions (barre d'outils et menu Présentation).
    static func layoutMenu() -> NSMenu {
        let menu = NSMenu(title: "Disposition")
        for (index, layout) in PanelLayout.ordered.enumerated() {
            let item = NSMenuItem(title: layout.title, action: #selector(setLayout(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = layout.rawValue
            item.image = layout.icon()
            menu.addItem(item)
        }
        return menu
    }

    private func updateIconThemeMenu() {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .iconTheme }) as? NSMenuToolbarItem else { return }
        item.menu = Self.iconThemeMenu()
    }

    /// Menu des thèmes d'icônes, chacun illustré par son icône de dossier.
    static func iconThemeMenu() -> NSMenu {
        let menu = NSMenu(title: "Thème d’icônes")
        for theme in IconTheme.allCases {
            let item = NSMenuItem(title: theme.title, action: #selector(AppDelegate.setIconTheme(_:)), keyEquivalent: "")
            item.tag = theme.rawValue
            item.state = theme == IconTheme.current ? .on : .off
            item.image = theme == .system ? NSWorkspace.shared.icon(for: .folder)
                                          : IconThemeRenderer.image(theme: theme, kind: .folder, label: nil)
            item.image?.size = NSSize(width: 18, height: 18)
            menu.addItem(item)
            if theme == .system { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc func equalizePanels(_ sender: Any?) { panelsController.equalize() }

    @objc func focusNextPanel(_ sender: Any?) { panelsController.panel(activePanel, focusNextBackwards: false) }

    @objc func connectToServer(_ sender: Any?) { showConnectionPanel(nil) }

    /// Panneau de connexion (nouvelle connexion ou modification d'une connexion enregistrée).
    private func showConnectionPanel(_ connection: ServerConnection?) {
        guard let window else { return }
        let controller = ConnectionPanelController(connection: connection)
        let sheet = NSWindow(contentViewController: controller)
        controller.onConnect = { [weak self] connection, password, remember in
            self?.open(connection, password: password, remember: remember)
        }
        window.beginSheet(sheet)
    }

    private func open(_ connection: ServerConnection, password: String? = nil, remember: Bool = true) {
        let panel = activePanel
        ConnectionService.connect(connection, password: password, remember: remember) { [weak self] result in
            switch result {
            case .success(let url):
                panel.navigate(to: url)
                panel.activate()
            case .failure(let error):
                guard let window = self?.window else { return }
                let alert = NSAlert(error: error)
                alert.messageText = "Impossible de se connecter à « \(connection.displayName) »."
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setLayout(_:)) {
            menuItem.state = menuItem.tag == panelsController.layout.rawValue ? .on : .off
        }
        if menuItem.action == #selector(toggleTerminal(_:)) {
            menuItem.title = terminalItem.isCollapsed ? "Afficher le terminal" : "Masquer le terminal"
        }
        if menuItem.action == #selector(toggleInspectorPane(_:)) {
            menuItem.title = inspectorItem.isCollapsed ? "Afficher l’inspecteur" : "Masquer l’inspecteur"
        }
        if menuItem.action == #selector(focusNextPanel(_:)) || menuItem.action == #selector(equalizePanels(_:)) {
            return panelsController.layout.panelCount > 1
        }
        return true
    }

    // MARK: Barre d'outils

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace,
         .viewMode, .layout, .iconTheme, .colorTheme, .space, .newFolder, .quickLook, .trash, .space, .git, .terminal, .hidden, .connect, .inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector, navigational: Bool = false) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.isBordered = true
            item.isNavigational = navigational
            return item
        }
        switch identifier {
        case .back: return button("Précédent", "chevron.left", #selector(PanelViewController.goBack(_:)), navigational: true)
        case .forward: return button("Suivant", "chevron.right", #selector(PanelViewController.goForward(_:)), navigational: true)
        case .newFolder: return button("Nouveau dossier", "folder.badge.plus", #selector(PanelViewController.newFolder(_:)))
        case .quickLook: return button("Coup d’œil", "eye", #selector(PanelViewController.quickLook(_:)))
        case .trash: return button("Corbeille", "trash", #selector(PanelViewController.moveToTrash(_:)))
        case .hidden: return button("Fichiers cachés", "eye.slash", #selector(AppDelegate.toggleHiddenFiles(_:)))
        case .connect: return button("Se connecter au serveur", "network", #selector(connectToServer(_:)))
        case .inspector: return button("Inspecteur", "sidebar.right", #selector(toggleInspectorPane(_:)))
        case .git, .terminal:
            // Boutons à bascule : leur état (activé / désactivé) est visible dans la barre.
            let isGit = identifier == .git
            let toggle = NSButton(image: NSImage(systemSymbolName: isGit ? "arrow.triangle.branch" : "apple.terminal",
                                                 accessibilityDescription: isGit ? "État Git" : "Terminal")!,
                                  target: isGit ? nil : self,
                                  action: isGit ? #selector(AppDelegate.toggleGit(_:)) : #selector(toggleTerminal(_:)))
            toggle.setButtonType(.pushOnPushOff)
            toggle.bezelStyle = .toolbar
            toggle.state = (isGit ? GitService.isEnabled : !terminalItem.isCollapsed) ? .on : .off
            toggle.toolTip = isGit ? "Afficher l’état Git (couleurs, push / pull en attente) — consomme du temps processeur" : "Afficher ou masquer le terminal (⌃`)"
            if isGit { gitButton = toggle } else { terminalButton = toggle }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = toggle
            item.label = isGit ? "Git" : "Terminal"
            return item
        case .viewMode:
            let symbols = ["square.grid.2x2", "list.bullet", "list.bullet.rectangle"]
            let labels = ["Icônes (⌘1)", "Liste (⌘2)", "Liste détaillée (⌘3)"]
            let control = NSSegmentedControl(images: symbols.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil)! },
                                             trackingMode: .selectOne, target: self, action: #selector(setViewModeFromToolbar(_:)))
            for (index, label) in labels.enumerated() { control.setToolTip(label, forSegment: index) }
            control.selectedSegment = activePanel.viewMode.rawValue
            viewModeControl = control
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = "Présentation"
            return item
        case .layout:
            // Un seul bouton : un clic déroule toutes les dispositions.
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.menu = Self.layoutMenu()
            item.image = panelsController.layout.icon()
            item.label = "Disposition"
            item.toolTip = "Disposition des panneaux"
            item.showsIndicator = true
            layoutItem = item
            return item
        case .colorTheme:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.menu = ColorTheme.menu()
            item.image = NSImage(systemSymbolName: "swatchpalette", accessibilityDescription: "Thème de couleurs")
                ?? NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Thème de couleurs")
            item.label = "Thème de couleurs"
            item.toolTip = "Thème de couleurs"
            item.showsIndicator = true
            return item
        case .iconTheme:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.menu = Self.iconThemeMenu()
            item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Thème d’icônes")
            item.label = "Thème d’icônes"
            item.toolTip = "Thème d’icônes"
            item.showsIndicator = true
            return item
        default:
            return nil
        }
    }
}

/// Liste des copies / déplacements en cours, en bas de la fenêtre.
final class JobsView: NSView {
    private let stack = NSStackView()
    private var rows: [ObjectIdentifier: JobRowView] = [:]
    private var timer: Timer?
    private var collapsed: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        let separator = NSBox()
        separator.boxType = .separator
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)
        for view in [separator, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        collapsed = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
        ])
        NotificationCenter.default.addObserver(forName: FileOperationCenter.jobsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        let jobs = FileOperationCenter.shared.jobs
        let ids = Set(jobs.map(ObjectIdentifier.init))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for job in jobs where rows[ObjectIdentifier(job)] == nil {
            let row = JobRowView(job: job)
            rows[ObjectIdentifier(job)] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        isHidden = jobs.isEmpty
        collapsed.isActive = jobs.isEmpty
        if jobs.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.rows.values.forEach { $0.update() }
            }
        }
        rows.values.forEach { $0.update() }
    }
}

private final class JobRowView: NSView {
    private let job: FileJob
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()

    init(job: FileJob) {
        self.job = job
        super.init(frame: .zero)
        title.stringValue = job.title
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        let cancel = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Annuler")!,
                              target: self, action: #selector(cancelJob))
        cancel.isBordered = false
        cancel.contentTintColor = .secondaryLabelColor
        cancel.toolTip = "Annuler"

        for view in [title, detail, progress, cancel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -8),
            progress.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -8),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
            cancel.trailingAnchor.constraint(equalTo: trailingAnchor),
            cancel.centerYAnchor.constraint(equalTo: progress.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update() {
        let snapshot = job.snapshot
        if snapshot.total > 0 {
            if progress.isIndeterminate { progress.stopAnimation(nil); progress.isIndeterminate = false }
            progress.doubleValue = min(1, Double(snapshot.done) / Double(snapshot.total))
            let amount = job.countsItems
                ? "\(snapshot.done) sur \(Format.items(Int(snapshot.total)))"
                : "\(Format.size(snapshot.done)) sur \(Format.size(snapshot.total))"
            detail.stringValue = "\(amount) — \(snapshot.status)"
        } else {
            if !progress.isIndeterminate { progress.isIndeterminate = true }
            progress.startAnimation(nil)
            detail.stringValue = snapshot.status
        }
    }

    @objc private func cancelJob() { job.cancel() }
}

/// Vue partagée entre panneaux : tailles minimales et redimensionnement proportionnel.
final class PanelSplitView: NSSplitView {
    // NSSplitView relaie respondsToSelector: à son délégué : il ne peut pas être son propre délégué.
    private let limits: SplitLimits

    init(vertical: Bool) {
        limits = SplitLimits(minimum: vertical ? 240 : 160)
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        isVertical = vertical
        dividerStyle = .thin
        delegate = limits
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class SplitLimits: NSObject, NSSplitViewDelegate {
    let minimum: CGFloat

    init(minimum: CGFloat) { self.minimum = minimum }

    private func start(_ view: NSView, _ split: NSSplitView) -> CGFloat { split.isVertical ? view.frame.minX : view.frame.minY }
    private func end(_ view: NSView, _ split: NSSplitView) -> CGFloat { split.isVertical ? view.frame.maxX : view.frame.maxY }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, start(splitView.subviews[index], splitView) + minimum)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, end(splitView.subviews[index + 1], splitView) - minimum)
    }
}
