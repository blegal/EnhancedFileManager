import AppKit
import Quartz

final class TabState {
    var url: URL
    var back: [URL] = []
    var forward: [URL] = []
    var selection: [URL] = []
    var color: TabColor?

    init(url: URL) { self.url = url.isRemote ? url.standardized : url.standardizedFileURL }
}

enum PanelViewMode: Int {
    case icons, list, details, columns
}

protocol PanelHost: AnyObject {
    func panelDidBecomeActive(_ panel: PanelViewController)
    func panelDidChangeDirectory(_ panel: PanelViewController)
    func panelSelectionDidChange(_ panel: PanelViewController)
    func panel(_ panel: PanelViewController, focusNextBackwards backwards: Bool)
    /// Les autres panneaux visibles, dans l'ordre (le premier est la cible par défaut de F5/F6).
    func targetPanels(for panel: PanelViewController) -> [PanelViewController]
}

private extension NSUserInterfaceItemIdentifier {
    static let name = NSUserInterfaceItemIdentifier("name")
    static let size = NSUserInterfaceItemIdentifier("size")
    static let date = NSUserInterfaceItemIdentifier("date")
    static let kind = NSUserInterfaceItemIdentifier("kind")
    static let nameCell = NSUserInterfaceItemIdentifier("nameCell")
    static let textCell = NSUserInterfaceItemIdentifier("textCell")
}

/// Un panneau de navigation : onglets, fil d'Ariane, liste des fichiers.
final class PanelViewController: NSViewController {
    let index: Int
    weak var host: PanelHost?

    private(set) var tabs: [TabState]
    private(set) var selectedTabIndex: Int
    /// Éléments affichés (après filtre de recherche) et contenu complet du dossier.
    var items: [FileItem] = []
    var allItems: [FileItem] = []

    // Recherche (⌘F)
    let searchBar = PanelSearchBar()
    var searchBarHeight: NSLayoutConstraint!
    var searchQuery: NSMetadataQuery?
    var isShowingSearchResults = false
    var searchResultsTruncated = false
    var searchGeneration = 0

    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    let collectionView = FileCollectionView()
    // Vue en colonnes
    let browser = FileBrowser()
    var browserCache: [String: [FileItem]] = [:]
    var isSyncingBrowser = false
    private let gridScrollView = NSScrollView()
    // Occupation du disque (⌘5)
    let diskUsageView = DiskUsageView()
    var isShowingDiskUsage = false
    private let sizeSlider = NSSlider(value: 96, minValue: 32, maxValue: 256, target: nil, action: nil)
    private(set) var viewMode: PanelViewMode
    private(set) var iconSize: CGFloat
    private(set) var listScale: CGFloat
    private let tabBar = TabBarView()
    let breadcrumb = BreadcrumbView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let accentLine = NSView()
    private var tabBarHeight: NSLayoutConstraint!

    let watcher = DirectoryWatcher()
    private var loadGeneration = 0
    private var loadError: String?
    var freeSpace: String?
    private var cutPaths: Set<String> = []
    private var renamingRow: Int?
    private var reloadDeferred = false
    var sortDescriptor = NSSortDescriptor(key: "name", ascending: true)

    // Tailles de dossiers calculées à la demande (par chemin), valables pour le dossier affiché.
    var folderSizes: [String: Int64] = [:]
    var computingFolders: Set<String> = []
    var folderSizeGeneration = 0

    // Git
    private let gitLabel = NSTextField(labelWithString: "")
    private var gitStatus: GitRepositoryStatus?
    private var gitRelativeDirectory = ""
    private var gitSummaries: [String: GitSummary] = [:]
    private var gitGeneration = 0
    private var gitWatcher: RepositoryWatcher?

    var isActive = false { didSet { if oldValue != isActive { updateActiveAppearance() } } }
    /// Faux pour les panneaux masqués par la disposition : ni surveillance du dossier ni Git.
    var isShown = true {
        didSet {
            guard oldValue != isShown, isViewLoaded else { return }
            if isShown { showCurrentTab() } else { watcher.stop(); gitWatcher = nil; gitGeneration += 1 }
        }
    }
    /// Masque le liseré d'accent quand un seul panneau est visible.
    var showsActiveIndicator = true { didSet { updateActiveAppearance() } }

    var tab: TabState { tabs[selectedTabIndex] }
    var currentURL: URL { tab.url }
    var state: PanelState {
        // Les onglets SFTP ne sont pas restaurés (ils demanderaient une connexion au lancement).
        let local = tabs.filter { !$0.url.isRemote }
        return PanelState(tabs: local.map(\.url.path), selectedTab: local.firstIndex { $0 === tab } ?? 0,
                          viewMode: viewMode.rawValue, iconSize: Double(iconSize),
                          sortKey: sortDescriptor.key, sortAscending: sortDescriptor.ascending, listScale: Double(listScale),
                          tabColors: local.map { $0.color?.rawValue ?? -1 })
    }

    /// Indices sélectionnés, quel que soit le mode d'affichage.
    var selectionIndexes: IndexSet {
        switch viewMode {
        case .icons: IndexSet(collectionView.selectionIndexPaths.map(\.item))
        case .columns: browserSelection
        case .list, .details: tableView.selectedRowIndexes
        }
    }

    /// La vue qui reçoit le clavier dans le mode courant.
    var focusView: NSView {
        if isShowingDiskUsage { return diskUsageView.focusView }
        return switch viewMode {
        case .icons: collectionView
        case .columns: browser
        case .list, .details: tableView
        }
    }

    var selectedItems: [FileItem] { selectionIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil } }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    init(index: Int, state: PanelState?) {
        self.index = index
        let colors = state?.tabColors ?? []
        let restored: [TabState] = (state?.tabs ?? []).enumerated().compactMap { index, path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard url.isExistingDirectory else { return nil }
            let tab = TabState(url: url)
            tab.color = colors.indices.contains(index) ? TabColor(rawValue: colors[index]) : nil
            return tab
        }
        tabs = restored.isEmpty ? [TabState(url: FileManager.default.homeDirectoryForCurrentUser)] : restored
        selectedTabIndex = min(max(0, state?.selectedTab ?? 0), tabs.count - 1)
        viewMode = state?.viewMode.flatMap(PanelViewMode.init(rawValue:)) ?? .details
        iconSize = CGFloat(state?.iconSize ?? 80)
        listScale = CGFloat(state?.listScale ?? 1)
        if let key = state?.sortKey { sortDescriptor = NSSortDescriptor(key: key, ascending: state?.sortAscending ?? true) }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Vue

    override func loadView() {
        let root = NSView()

        accentLine.wantsLayer = true

        breadcrumb.onNavigate = { [weak self] url in self?.navigate(to: url) }
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = Theme.secondaryText
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titles = NSStackView(views: [breadcrumb, infoLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.setHuggingPriority(.defaultLow, for: .horizontal)

        sizeSlider.controlSize = .small
        sizeSlider.target = self
        sizeSlider.action = #selector(iconSizeChanged(_:))
        sizeSlider.toolTip = "Taille des icônes"
        sizeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        gitLabel.font = .systemFont(ofSize: 11, weight: .medium)
        gitLabel.lineBreakMode = .byTruncatingTail
        // Le fil d'Ariane se tronque avant l'indicateur Git.
        gitLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gitLabel.isHidden = true
        let header = NSStackView(views: [titles, gitLabel, sizeSlider])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        configureGrid()
        gridScrollView.documentView = collectionView
        gridScrollView.hasVerticalScroller = true
        gridScrollView.autohidesScrollers = true
        gridScrollView.borderType = .noBorder
        gridScrollView.drawsBackground = false

        let separator = NSBox()
        separator.boxType = .separator

        searchBar.isHidden = true
        configureBrowser()
        diskUsageView.isHidden = true
        for view in [accentLine, tabBar, header, searchBar, separator, scrollView, gridScrollView, browser, diskUsageView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        searchBarHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            accentLine.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            accentLine.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            accentLine.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            accentLine.heightAnchor.constraint(equalToConstant: 2.5),

            tabBar.topAnchor.constraint(equalTo: accentLine.bottomAnchor, constant: 2),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBarHeight,

            header.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            searchBar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            searchBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchBarHeight,

            separator.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            gridScrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            gridScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gridScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            browser.topAnchor.constraint(equalTo: separator.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            diskUsageView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            diskUsageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            diskUsageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            diskUsageView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // Fonds du thème de couleurs : bande de barre d'outils, en-tête, liste.
        ThemeBackgroundView.install(.toolbar, in: root, bottom: root.safeAreaLayoutGuide.topAnchor)
        ThemeBackgroundView.install(.header, in: root, top: root.safeAreaLayoutGuide.topAnchor, bottom: separator.bottomAnchor)
        ThemeBackgroundView.install(.panel, in: root, top: separator.bottomAnchor)
        view = root
    }

    private func configureTable() {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat)] = [
            (.name, "Nom", 260, 120), (.size, "Taille", 72, 50), (.date, "Modifié le", 128, 70), (.kind, "Type", 110, 50),
        ]
        for (identifier, title, width, minWidth) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier.rawValue, ascending: true)
            if identifier == .size { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        tableView.style = .inset
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 10, height: 0)
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.sortDescriptors = [sortDescriptor]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.onFocus = { [weak self] in self?.activate(focusTable: false) }
        tableView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        tableView.onZoom = { [weak self] factor in self?.zoom(by: factor) }
        tableView.contextMenuProvider = { [weak self] in self?.contextMenu() }
    }

    private func configureGrid() {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView.collectionViewLayout = layout
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collectionView.onFocus = { [weak self] in
            self?.activate(focusTable: false)
            self?.collectionView.refreshSelectionStyle()
        }
        collectionView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        collectionView.onZoom = { [weak self] factor in self?.zoom(by: factor) }
        collectionView.contextMenuProvider = { [weak self] in self?.contextMenu() }
        collectionView.onDoubleClick = { [weak self] in self?.openSelection(nil) }
    }

    // MARK: Modes d'affichage

    /// Bascule entre icônes, liste et liste détaillée en conservant la sélection.
    func setViewMode(_ mode: PanelViewMode) {
        if mode == .columns, currentURL.isRemote { NSSound.beep(); return }
        let hadFocus = view.window?.firstResponder === focusView
        let selection = selectionIndexes
        if isShowingDiskUsage {
            isShowingDiskUsage = false
            diskUsageView.stop()
        }
        viewMode = mode
        applyViewMode()
        if mode == .columns { syncBrowserToCurrentFolder() }
        reloadViews()
        setSelection(selection, scroll: true)
        if hadFocus || isActive { view.window?.makeFirstResponder(focusView) }
        host?.panelDidChangeDirectory(self)
    }

    func applyViewMode() {
        scrollView.isHidden = isShowingDiskUsage || viewMode == .icons || viewMode == .columns
        gridScrollView.isHidden = isShowingDiskUsage || viewMode != .icons
        browser.isHidden = isShowingDiskUsage || viewMode != .columns
        diskUsageView.isHidden = !isShowingDiskUsage
        sizeSlider.isHidden = isShowingDiskUsage || viewMode != .icons
        sizeSlider.doubleValue = Double(iconSize)
        let compact = viewMode == .list
        for column in tableView.tableColumns where column.identifier != .name { column.isHidden = compact }
        tableView.rowHeight = ((compact ? 22 : 24) * listScale).rounded()
        updateGridItemSize()
    }

    private func updateGridItemSize() {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        layout.itemSize = NSSize(width: iconSize + 40, height: iconSize + 50)
    }

    @objc private func iconSizeChanged(_ sender: NSSlider) {
        setIconSize(CGFloat(sender.doubleValue))
    }

    func setIconSize(_ size: CGFloat) {
        let newSize = min(max(size.rounded(), 32), 256)
        guard newSize != iconSize || sizeSlider.doubleValue != Double(newSize) else { return }
        iconSize = newSize
        sizeSlider.doubleValue = Double(iconSize)
        updateGridItemSize()
        // Seules les vignettes visibles sont reconfigurées (la mise en page suit seule).
        collectionView.reloadItems(at: collectionView.indexPathsForVisibleItems())
    }

    /// Zoom des listes : hauteur des lignes, taille du texte et des icônes.
    func setListScale(_ scale: CGFloat) {
        let newScale = min(max((scale * 20).rounded() / 20, 0.75), 2)
        guard newScale != listScale else { return }
        listScale = newScale
        let compact = viewMode == .list
        tableView.rowHeight = ((compact ? 22 : 24) * listScale).rounded()
        tableView.reloadData()
    }

    /// ⌘ + molette, pincement, ⌘+ / ⌘− : agrandit ou réduit selon le mode d'affichage.
    func zoom(by factor: CGFloat) {
        if viewMode == .icons { setIconSize(iconSize * factor) } else { setListScale(listScale * factor) }
    }

    @objc func resetZoom(_ sender: Any?) {
        if viewMode == .icons { setIconSize(80) } else { setListScale(1) }
    }

    /// La sélection des colonnes a changé de dossier : met à jour le panneau sans recharger les colonnes.
    func followBrowserFolder() {
        watcher.watch(currentURL)
        breadcrumb.show(currentURL)
        updateTabBar()
        RecentFolders.record(currentURL)
        folderSizeGeneration += 1
        folderSizes = [:]
        computingFolders = []
        freeSpace = Format.freeSpace(at: currentURL)
        host?.panelDidChangeDirectory(self)
    }

    @objc func showAsIcons(_ sender: Any?) { setViewMode(.icons) }
    @objc func showAsList(_ sender: Any?) { setViewMode(.list) }
    @objc func showAsDetails(_ sender: Any?) { setViewMode(.details) }
    @objc func increaseIconSize(_ sender: Any?) { zoom(by: viewMode == .icons ? 1.25 : 1.1) }
    @objc func decreaseIconSize(_ sender: Any?) { zoom(by: viewMode == .icons ? 1 / 1.25 : 1 / 1.1) }

    @objc func sortBy(_ sender: NSMenuItem) {
        let keys = ["name", "size", "date", "kind"]
        guard keys.indices.contains(sender.tag) else { return }
        let key = keys[sender.tag]
        let ascending = sortDescriptor.key == key ? !sortDescriptor.ascending : (key == "name" || key == "kind")
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        if viewMode == .icons { tableView(tableView, sortDescriptorsDidChange: []) }
    }

    func reloadViews() {
        tableView.reloadData()
        collectionView.reloadData()
        reloadBrowserColumn()
    }

    func setSelection(_ rows: IndexSet, scroll: Bool) {
        let valid = rows.filteredIndexSet { items.indices.contains($0) }
        tableView.selectRowIndexes(valid, byExtendingSelection: false)
        collectionView.selectionIndexPaths = Set(valid.map { IndexPath(item: $0, section: 0) })
        selectInBrowser(valid)
        if let first = valid.first {
            tableView.scrollRowToVisible(first)
            collectionView.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .nearestHorizontalEdge)
        } else if scroll, !items.isEmpty {
            tableView.scrollRowToVisible(0)
            collectionView.scroll(.zero)
        }
        selectionDidChange()
    }

    func selectionDidChange() {
        updateInfo()
        refreshQuickLook()
        host?.panelSelectionDidChange(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.onSelect = { [weak self] index in self?.selectTab(index); self?.activate() }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onSetColor = { [weak self] index, color in self?.setTabColor(color, at: index) }
        tabBar.onAdd = { [weak self] in self?.newTab(nil) }
        searchBar.onChange = { [weak self] text, scope in self?.searchChanged(text, scope: scope) }
        searchBar.onClose = { [weak self] in self?.endSearch() }
        searchBar.onMoveDown = { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(focusView)
            if selectionIndexes.isEmpty, !items.isEmpty { setSelection([0], scroll: true) }
        }
        watcher.onChange = { [weak self] in self?.reload() }
        configureDiskUsage()

        let center = NotificationCenter.default
        center.addObserver(forName: Preferences.showHiddenChanged, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        center.addObserver(forName: IconTheme.changed, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        center.addObserver(forName: GitService.enabledChanged, object: nil, queue: .main) { [weak self] _ in self?.refreshGit() }
        center.addObserver(forName: ColorTheme.changed, object: nil, queue: .main) { [weak self] _ in self?.themeDidChange() }
        center.addObserver(forName: FileClipboard.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            cutPaths = FileClipboard.cutPaths
            let selection = selectionIndexes
            reloadViews()
            setSelection(selection, scroll: false)
        }
        applyViewMode()
        updateActiveAppearance()
        showCurrentTab()
    }

    private func updateActiveAppearance() {
        guard isViewLoaded else { return }
        let visible = isActive && showsActiveIndicator
        accentLine.layer?.cornerRadius = 1.25
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            accentLine.layer?.backgroundColor = visible ? Theme.accent.cgColor : NSColor.clear.cgColor
        }
        breadcrumb.isActive = isActive || !showsActiveIndicator
        updateTabBar()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Les colonnes suivent la largeur du panneau (pas de défilement horizontal).
        let width = scrollView.contentSize.width
        if width > 0, abs(tableView.frame.width - width) > 0.5 {
            tableView.frame.size.width = width
            tableView.sizeToFit()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateActiveAppearance()
    }

    // MARK: Activation

    func activate(focusTable: Bool = true) {
        host?.panelDidBecomeActive(self)
        if focusTable, view.window?.firstResponder !== focusView {
            view.window?.makeFirstResponder(focusView)
        }
    }

    // MARK: Chargement

    private func showCurrentTab() {
        if isSearching { endSearch(reloadListing: false) }
        // Pas de vue en colonnes sur un serveur SFTP.
        if viewMode == .columns, currentURL.isRemote { viewMode = .details; applyViewMode() }
        if viewMode == .columns { syncBrowserToCurrentFolder() }
        if isShown { RecentFolders.record(currentURL) }
        folderSizeGeneration += 1
        folderSizes = [:]
        computingFolders = []
        if currentURL.isRemote || !isShown { watcher.stop() } else { watcher.watch(currentURL) }
        breadcrumb.show(currentURL)
        updateTabBar()
        reload(selecting: tab.selection, scrollToSelection: true)
        if isShowingDiskUsage { showDiskUsage() }
        host?.panelDidChangeDirectory(self)
    }

    func updateTabBar() {
        let multiple = tabs.count > 1
        tabBar.isHidden = !multiple
        tabBarHeight.constant = multiple ? 28 : 0
        if multiple {
            tabBar.update(tabs: tabs.map { (BreadcrumbView.displayName($0.url), $0.url.path, $0.color) },
                          selected: selectedTabIndex, active: isActive)
        }
    }

    /// Recharge le dossier courant en arrière-plan en conservant (ou imposant) la sélection.
    func reload(selecting urls: [URL]? = nil, scrollToSelection: Bool = false, fallbackRow: Int? = nil, completion: (() -> Void)? = nil) {
        if renamingRow != nil { reloadDeferred = true; return }
        // Les résultats d'une recherche restent affichés jusqu'à sa fermeture.
        if isShowingSearchResults { completion?(); return }
        let url = currentURL
        let showHidden = Preferences.showHiddenFiles
        let wanted = urls ?? selectedURLs
        let descriptor = sortDescriptor
        loadGeneration += 1
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            // Lecture et tri hors du fil principal.
            let result = Result { Self.sorted(try FileItem.contents(at: url, showHidden: showHidden), by: descriptor) }
            let free = url.isRemote ? url.host.map { "connecté à \($0)" } : Format.freeSpace(at: url)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == loadGeneration, url.isSameLocation(as: currentURL) else { return }
                apply(result, freeSpace: free, selecting: wanted, scroll: scrollToSelection, fallbackRow: fallbackRow)
                completion?()
            }
        }
    }

    private func apply(_ result: Result<[FileItem], Error>, freeSpace: String?, selecting wanted: [URL], scroll: Bool, fallbackRow: Int?) {
        switch result {
        case .success(let list):
            allItems = list
            for item in list where item.isNavigableDirectory { item.folderSize = folderSizes[item.url.normalizedPath] }
            let filter = isSearching && searchBar.scope == .folder ? Self.nameMatcher(for: searchBar.field.stringValue.trimmingCharacters(in: .whitespaces)) : nil
            items = filter.map { match in list.filter { item in match(item.name) { item.finderTags } } } ?? list
            loadError = nil
        case .failure(let error):
            if !currentURL.isRemote, !currentURL.isExistingDirectory {
                // Le dossier a disparu (suppression, éjection) : on remonte au parent existant.
                var parent = currentURL
                while !parent.isExistingDirectory && parent.path != "/" { parent = parent.deletingLastPathComponent() }
                tab.url = parent.standardizedFileURL
                showCurrentTab()
                return
            }
            items = []
            allItems = []
            loadError = (error as NSError).code == NSFileReadNoPermissionError
                ? "Accès refusé" : error.localizedDescription
            if currentURL.isRemote {
                NotificationCenter.default.post(name: SFTPManager.sessionsChanged, object: nil)
            }
        }
        self.freeSpace = freeSpace
        cutPaths = FileClipboard.cutPaths
        reloadViews()

        let paths = Set(wanted.map(\.normalizedPath))
        var rows = IndexSet(items.indices.filter { paths.contains(items[$0].url.normalizedPath) })
        if rows.isEmpty, let fallbackRow, !items.isEmpty { rows = [min(fallbackRow, items.count - 1)] }
        setSelection(rows, scroll: scroll)
        refreshGit()
    }

    static func sorted(_ list: [FileItem], by descriptor: NSSortDescriptor) -> [FileItem] {
        let key = descriptor.key ?? "name"
        let ascending = descriptor.ascending
        return list.sorted { a, b in
            if a.isNavigableDirectory != b.isNavigableDirectory { return a.isNavigableDirectory }
            var result: ComparisonResult
            switch key {
            case "size": result = Self.compare(a.effectiveSize ?? -1, b.effectiveSize ?? -1)
            case "date": result = Self.compare(a.modificationDate ?? .distantPast, b.modificationDate ?? .distantPast)
            case "kind": result = a.kind.localizedStandardCompare(b.kind)
            default: result = .orderedSame
            }
            if result == .orderedSame { result = a.name.localizedStandardCompare(b.name) }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    func updateInfo() {
        if let loadError {
            infoLabel.stringValue = "⚠︎ \(loadError)"
            return
        }
        let selection = selectedItems
        var text: String
        if isShowingSearchResults {
            text = items.count <= 1 ? "\(items.count) résultat" : "\(items.count) résultats"
            if searchResultsTruncated { text += " (limité à 2 000)" }
            if !selection.isEmpty { text += " — \(selection.count) sélectionné\(selection.count > 1 ? "s" : "")" }
            infoLabel.stringValue = text
            return
        }
        if selection.isEmpty {
            text = Format.items(items.count)
        } else {
            let bytes = selection.compactMap(\.effectiveSize).reduce(0, +)
            text = "\(selection.count) sur \(items.count) sélectionné\(selection.count > 1 ? "s" : "") (\(Format.size(bytes)))"
        }
        if let freeSpace { text += ", \(freeSpace)" }
        infoLabel.stringValue = text
    }

    // MARK: Thème de couleurs

    private func themeDidChange() {
        updateActiveAppearance()
        breadcrumb.show(currentURL)
        let selection = selectionIndexes
        reloadViews()
        setSelection(selection, scroll: false)
        tableView.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }

    // MARK: Git

    /// Recalcule l'état Git du dossier courant et des dépôts qu'il contient (en arrière-plan).
    private func refreshGit() {
        gitGeneration += 1
        let generation = gitGeneration
        guard GitService.isEnabled, !currentURL.isRemote, isShown else {
            if gitStatus != nil || !gitSummaries.isEmpty || gitWatcher != nil {
                gitStatus = nil
                gitSummaries = [:]
                gitWatcher = nil
                redrawGit()
            }
            return
        }
        let url = currentURL
        let folders = items.filter(\.isNavigableDirectory).map(\.url)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let service = GitService.shared
            guard service.isAvailable else { return }
            let root = service.repositoryRoot(for: url)
            let status = root.flatMap { service.status(ofRepository: $0) }
            let current = url.resolvingSymlinksInPath().standardizedFileURL.path
            let relative = root.map { current == $0.path ? "" : String(current.dropFirst($0.path.count + 1)) } ?? ""
            let repositories = folders.filter(GitService.isRepository)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == gitGeneration else { return }
                gitStatus = status
                gitRelativeDirectory = relative
                // Un seul flux FSEvents : la racine du dépôt, ou le dossier courant s'il contient des dépôts.
                let watched = root ?? (repositories.isEmpty ? nil : url)
                if gitWatcher?.root.path != watched?.path {
                    gitWatcher = watched.map { RepositoryWatcher(root: $0) { [weak self] paths in self?.gitPathsChanged(paths) } }
                }
                redrawGit()
                service.summaries(of: repositories) { [weak self] summaries in
                    guard let self, generation == gitGeneration else { return }
                    gitSummaries = summaries
                    redrawGit()
                }
            }
        }
    }

    /// Dans un dossier qui contient des dépôts, seuls les dépôts touchés sont recalculés.
    private func gitPathsChanged(_ paths: [String]) {
        guard gitStatus == nil, !gitSummaries.isEmpty else { refreshGit(); return }
        let repositories = items.filter(\.isNavigableDirectory).map(\.url).filter { url in
            gitSummaries[url.standardizedFileURL.path] != nil || GitService.isRepository(url)
        }
        let touched = repositories.filter { repository in
            let root = repository.resolvingSymlinksInPath().path + "/"
            return paths.contains { $0.hasPrefix(root) || $0 + "/" == root }
        }
        guard !touched.isEmpty else { return }
        let generation = gitGeneration
        GitService.shared.summaries(of: touched) { [weak self] summaries in
            guard let self, generation == gitGeneration else { return }
            gitSummaries.merge(summaries) { _, new in new }
            redrawGit()
        }
    }

    private func gitState(for item: FileItem) -> GitFileState? {
        guard let gitStatus, item.name != ".git" else { return nil }
        let path = gitRelativeDirectory.isEmpty ? item.name : gitRelativeDirectory + "/" + item.name
        return gitStatus.state(forRelativePath: path, isDirectory: item.isNavigableDirectory)
    }

    /// Indicateur d'un dossier dépôt : ● modifications, ↑ à pousser, ↓ à tirer (✓ s'il est à jour).
    private func repositoryBadge(for item: FileItem) -> NSAttributedString? {
        guard item.isNavigableDirectory, let summary = gitSummaries[item.url.standardizedFileURL.path] else { return nil }
        return Self.badge(for: summary, includeBranch: false)
    }

    static func badge(for summary: GitSummary, includeBranch: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let text = NSMutableAttributedString()
        func add(_ string: String, _ color: NSColor) {
            if text.length > 0 { text.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        if includeBranch, let branch = summary.branch { add("⎇ \(branch)", .secondaryLabelColor) }
        if summary.changes > 0 { add("● \(summary.changes)", GitFileState.modified.color) }
        if summary.ahead > 0 { add("↑\(summary.ahead)", .systemBlue) }
        if summary.behind > 0 { add("↓\(summary.behind)", .systemPurple) }
        if summary.isClean { add("✓", GitFileState.added.color) }
        if includeBranch, !summary.hasUpstream { add("sans branche distante", .tertiaryLabelColor) }
        return text
    }

    private func redrawGit() {
        if let summary = gitStatus?.summary {
            gitLabel.attributedStringValue = Self.badge(for: summary, includeBranch: true)
            gitLabel.toolTip = "Dépôt Git : \(gitStatus?.root.path ?? "")\n● fichiers modifiés · ↑ commits à pousser · ↓ commits à tirer (depuis le dernier fetch)"
            gitLabel.isHidden = false
        } else {
            gitLabel.isHidden = true
        }
        let selection = selectionIndexes
        // Seules les lignes visibles sont redessinées ; les autres le seront en défilant.
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.length > 0 {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                 columnIndexes: IndexSet(integer: max(0, tableView.column(withIdentifier: .name))))
        }
        if viewMode == .icons {
            collectionView.reloadData()
            collectionView.selectionIndexPaths = Set(selection.map { IndexPath(item: $0, section: 0) })
        }
    }

    // MARK: Navigation

    func navigate(to url: URL, select: URL? = nil) {
        let url = url.isRemote ? url.standardized : url.standardizedFileURL
        if url.isSameLocation(as: currentURL) {
            if let select { reload(selecting: [select]) }
            return
        }
        tab.back.append(currentURL)
        if tab.back.count > 200 { tab.back.removeFirst() }
        tab.forward.removeAll()
        tab.url = url
        tab.selection = select.map { [$0] } ?? []
        showCurrentTab()
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = tab.back.popLast() else { return }
        tab.forward.append(currentURL)
        tab.selection = [currentURL]
        tab.url = previous
        showCurrentTab()
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = tab.forward.popLast() else { return }
        tab.back.append(currentURL)
        tab.selection = []
        tab.url = next
        showCurrentTab()
    }

    @objc func goUp(_ sender: Any?) {
        guard currentURL.path != "/", !currentURL.path.isEmpty else { return }
        navigate(to: currentURL.deletingLastPathComponent(), select: currentURL)
    }

    @objc func goHome(_ sender: Any?) { navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
    @objc func goDesktop(_ sender: Any?) { go(to: .desktopDirectory) }
    @objc func goDocuments(_ sender: Any?) { go(to: .documentDirectory) }
    @objc func goDownloads(_ sender: Any?) { go(to: .downloadsDirectory) }
    @objc func goApplications(_ sender: Any?) { navigate(to: URL(fileURLWithPath: "/Applications")) }
    @objc func goComputer(_ sender: Any?) { navigate(to: URL(fileURLWithPath: "/Volumes")) }

    private func go(to directory: FileManager.SearchPathDirectory) {
        if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first { navigate(to: url) }
    }

    @objc func goToFolder(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Aller au dossier"
        alert.informativeText = "Saisissez un chemin (« ~ » désigne votre dossier de départ)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = currentURL.isRemote ? currentURL.path : (currentURL.path as NSString).abbreviatingWithTildeInPath
        alert.accessoryView = field
        alert.addButton(withTitle: "Aller")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("sftp://"), let url = URL(string: text) {
                navigate(to: url)
                return
            }
            if currentURL.isRemote, !text.hasPrefix("~") {
                let base = currentURL.path.hasSuffix("/") ? currentURL.path : currentURL.path + "/"
                let path = text.hasPrefix("/") ? text : base + text
                navigate(to: SFTPEndpoint(url: currentURL)!.url(path: (path as NSString).standardizingPath))
                return
            }
            let path = (text as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path, relativeTo: currentURL.isRemote ? nil : currentURL).absoluteURL.standardizedFileURL
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue { navigate(to: url) } else { navigate(to: url.deletingLastPathComponent(), select: url) }
            } else {
                NSSound.beep()
            }
        }
    }

    @objc func refresh(_ sender: Any?) { reload() }

    @objc func syncOtherPanel(_ sender: Any?) {
        host?.targetPanels(for: self).first?.navigate(to: currentURL)
    }

    // MARK: Onglets

    @objc func newTab(_ sender: Any?) { openTab(currentURL) }

    func openTab(_ url: URL) {
        tab.selection = selectedURLs
        tabs.insert(TabState(url: url), at: selectedTabIndex + 1)
        selectedTabIndex += 1
        showCurrentTab()
        activate()
    }

    @objc func closeTab(_ sender: Any?) { closeTab(at: selectedTabIndex) }

    func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        let wasCurrent = index == selectedTabIndex
        tabs.remove(at: index)
        if index < selectedTabIndex || selectedTabIndex >= tabs.count { selectedTabIndex -= 1 }
        if wasCurrent { showCurrentTab() } else { updateTabBar() }
    }

    func selectTab(_ index: Int) {
        guard index != selectedTabIndex, tabs.indices.contains(index) else { return }
        tab.selection = selectedURLs
        selectedTabIndex = index
        showCurrentTab()
    }

    func setTabColor(_ color: TabColor?, at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].color = color
        updateTabBar()
    }

    @objc func nextTab(_ sender: Any?) { selectTab((selectedTabIndex + 1) % tabs.count) }
    @objc func previousTab(_ sender: Any?) { selectTab((selectedTabIndex + tabs.count - 1) % tabs.count) }

    // MARK: Ouverture

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        openSelection(nil)
    }

    @objc func openSelection(_ sender: Any?) {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        if currentURL.isRemote {
            openRemote(selection)
            return
        }
        if let folder = selection.first(where: \.isNavigableDirectory), selection.count == 1 {
            navigate(to: folder.url)
            return
        }
        let files = selection.filter { !$0.isNavigableDirectory }.map(\.url)
        for url in files { NSWorkspace.shared.open(url) }
        for folder in selection.filter(\.isNavigableDirectory) { openTab(folder.url) }
    }

    /// Dossiers : navigation ; liens symboliques : vérifiés sur le serveur ; fichiers : téléchargés puis ouverts.
    private func openRemote(_ selection: [FileItem]) {
        if selection.count == 1, selection[0].isDirectory {
            navigate(to: selection[0].url)
            return
        }
        let links = selection.filter(\.isSymlink)
        let files = selection.filter { !$0.isDirectory && !$0.isSymlink }.map(\.url)
        if !files.isEmpty { FileOperationCenter.shared.openRemote(files) }
        guard !links.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = links.map { link in
                (link.url, (try? SFTPManager.shared.session(for: link.url).isDirectory(link.url.path)) ?? false)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let folders = resolved.filter(\.1).map(\.0)
                let others = resolved.filter { !$0.1 }.map(\.0)
                if folders.count == 1, selection.count == 1 { navigate(to: folders[0]) } else { folders.forEach(openTab) }
                if !others.isEmpty { FileOperationCenter.shared.openRemote(others) }
            }
        }
    }

    @objc func openInNewTab(_ sender: Any?) {
        let folders = selectedItems.filter(\.isNavigableDirectory)
        if folders.isEmpty { newTab(nil) } else { folders.forEach { openTab($0.url) } }
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let item = selectedItems.first, item.isPackage else { return }
        navigate(to: item.url)
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = selectedURLs
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [currentURL] : urls)
    }

    @objc func openInTerminal(_ sender: Any?) {
        let folder = selectedItems.count == 1 && selectedItems[0].isNavigableDirectory ? selectedItems[0].url : currentURL
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func addToFavorites(_ sender: Any?) {
        let folders = selectedItems.filter(\.isNavigableDirectory).map(\.url)
        let additions = folders.isEmpty ? [currentURL] : folders
        var favorites = Preferences.customFavorites
        for url in additions where !favorites.contains(where: { $0.isSameLocation(as: url) }) { favorites.append(url) }
        Preferences.customFavorites = favorites
    }

    // MARK: Presse-papiers

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileClipboard.write(urls, cut: false)
    }

    @objc func cut(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileClipboard.write(urls, cut: true)
    }

    @objc func paste(_ sender: Any?) {
        let urls = FileClipboard.fileURLs()
        guard !urls.isEmpty else { return }
        let isCut = FileClipboard.isCut
        transfer(isCut ? .move : .copy, urls, to: currentURL)
        if isCut { FileClipboard.didPasteCut() }
    }

    /// ⌥⌘V : déplace ici les fichiers copiés (comme le Finder).
    @objc func pasteMove(_ sender: Any?) {
        let urls = FileClipboard.fileURLs()
        guard !urls.isEmpty else { return }
        transfer(.move, urls, to: currentURL)
        FileClipboard.didPasteCut()
    }

    @objc func copyPath(_ sender: Any?) {
        let urls = selectedURLs
        let targets = urls.isEmpty ? [currentURL] : urls
        if currentURL.isRemote {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(targets.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        } else {
            FileClipboard.writePaths(targets)
        }
    }

    @objc func duplicate(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        transfer(.copy, urls, to: currentURL)
    }

    private func transfer(_ kind: TransferKind, _ urls: [URL], to destination: URL) {
        FileOperationCenter.shared.transfer(kind, sources: urls, to: destination, undoManager: undoManager) { [weak self] created in
            guard let self, destination.isSameLocation(as: currentURL), !created.isEmpty else { return }
            reload(selecting: created)
        }
    }

    // MARK: Vers un autre panneau (F5 / F6)

    @objc func copyToOtherPanel(_ sender: Any?) { transferToPanel(.copy, sender) }
    @objc func moveToOtherPanel(_ sender: Any?) { transferToPanel(.move, sender) }

    private func transferToPanel(_ kind: TransferKind, _ sender: Any?) {
        let explicit = (sender as? NSMenuItem)?.representedObject as? PanelViewController
        guard let target = explicit ?? host?.targetPanels(for: self).first else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let destination = target.currentURL
        FileOperationCenter.shared.transfer(kind, sources: urls, to: destination, undoManager: undoManager) { [weak target] created in
            guard let target, destination.isSameLocation(as: target.currentURL) else { return }
            target.reload(selecting: created)
        }
    }

    // MARK: Création, renommage, corbeille

    @objc func newFolder(_ sender: Any?) {
        if currentURL.isRemote {
            FileOperationCenter.shared.createRemoteFolder(in: currentURL) { [weak self] result in
                switch result {
                case .success(let url): self?.reload(selecting: [url]) { self?.renameSelection(nil) }
                case .failure(let error): self?.presentErrorSheet(error)
                }
            }
            return
        }
        do {
            let url = try FileOperationCenter.shared.createFolder(in: currentURL, undoManager: undoManager)
            activate()
            reload(selecting: [url]) { [weak self] in self?.renameSelection(nil) }
        } catch {
            presentErrorSheet(error)
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let firstRow = selectionIndexes.first ?? 0
        if currentURL.isRemote {
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = urls.count == 1 ? "Supprimer « \(urls[0].lastPathComponent) » du serveur ?" : "Supprimer \(urls.count) éléments du serveur ?"
            alert.informativeText = "Il n’y a pas de corbeille en SFTP : la suppression est définitive."
            alert.addButton(withTitle: "Supprimer").hasDestructiveAction = true
            alert.addButton(withTitle: "Annuler")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                FileOperationCenter.shared.deleteRemote(urls) { self?.reload(selecting: [], fallbackRow: firstRow) }
            }
            return
        }
        FileOperationCenter.shared.trash(urls, undoManager: undoManager)
        reload(selecting: [], fallbackRow: firstRow)
    }

    @objc func renameSelection(_ sender: Any?) {
        if selectionIndexes.count > 1 { batchRename(sender); return }
        guard selectionIndexes.count == 1, let row = selectionIndexes.first else { return }
        if viewMode == .icons { renameWithSheet(items[row]); return }
        let column = tableView.column(withIdentifier: .name)
        tableView.scrollRowToVisible(row)
        guard column >= 0,
              let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renamingRow = row
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.delegate = self
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let item = items[row]
            let ext = (item.name as NSString).pathExtension
            let base = item.isNavigableDirectory || ext.isEmpty ? item.name : (item.name as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    private func finishRename(_ field: NSTextField, commit: Bool) {
        guard let row = renamingRow else { return }
        renamingRow = nil
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.delegate = nil
        guard items.indices.contains(row) else { return }
        let item = items[row]
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.stringValue = item.name
        view.window?.makeFirstResponder(focusView)
        if commit, !newName.isEmpty, newName != item.name, item.url.isRemote {
            FileOperationCenter.shared.renameRemote(item.url, to: newName) { [weak self] result in
                switch result {
                case .success(let url): self?.reload(selecting: [url])
                case .failure(let error): self?.presentErrorSheet(error); self?.reload()
                }
            }
            reloadDeferred = false
            return
        }
        if commit, !newName.isEmpty, newName != item.name {
            do {
                let renamed = try FileOperationCenter.shared.rename(item.url, to: newName, undoManager: undoManager)
                reload(selecting: [renamed])
                return
            } catch {
                presentErrorSheet(error)
            }
        }
        if reloadDeferred {
            reloadDeferred = false
            reload()
        }
    }

    private func renameWithSheet(_ item: FileItem) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Renommer « \(item.name) »"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Renommer")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.url.isRemote {
                FileOperationCenter.shared.renameRemote(item.url, to: newName) { [weak self] result in
                    switch result {
                    case .success(let url): self?.reload(selecting: [url])
                    case .failure(let error): self?.presentErrorSheet(error)
                    }
                }
                return
            }
            do {
                let renamed = try FileOperationCenter.shared.rename(item.url, to: newName, undoManager: undoManager)
                reload(selecting: [renamed])
            } catch {
                presentErrorSheet(error)
            }
        }
    }

    private func presentErrorSheet(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Archives

    @objc func compressSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, !currentURL.isRemote else { return }
        let format = ArchiveFormat(rawValue: (sender as? NSMenuItem)?.tag ?? 0) ?? .zip
        FileOperationCenter.shared.compress(urls, format: format, undoManager: undoManager) { [weak self] archive in
            if let archive { self?.reload(selecting: [archive]) }
        }
    }

    @objc func extractHere(_ sender: Any?) { extract(into: self) }

    @objc func extractToOtherPanel(_ sender: Any?) {
        guard let target = host?.targetPanels(for: self).first else { return }
        extract(into: target)
    }

    private func extract(into panel: PanelViewController) {
        let archives = selectedURLs.filter(FileOperationCenter.isArchive)
        guard !archives.isEmpty, !currentURL.isRemote, !panel.currentURL.isRemote else { return }
        let destination = panel.currentURL
        for archive in archives {
            FileOperationCenter.shared.extract(archive, into: destination, undoManager: undoManager) { [weak panel] folder in
                guard let folder, let panel, destination.isSameLocation(as: panel.currentURL) else { return }
                panel.reload(selecting: [folder])
            }
        }
    }

    // MARK: Aperçu (Quick Look)

    @objc func quickLook(_ sender: Any?) {
        if currentURL.isRemote { NSSound.beep(); return }
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    private func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, (panel.dataSource as AnyObject?) === self else { return }
        panel.reloadData()
    }

    // MARK: Clavier

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty: // Retour / Entrée
            openSelection(nil)
        case 51 where modifiers.isEmpty: // Effacement arrière
            goUp(nil)
        case 48 where modifiers.isEmpty || modifiers == .shift: // Tab
            host?.panel(self, focusNextBackwards: modifiers == .shift)
        case 53 where modifiers.isEmpty && isSearching: // Échap ferme la recherche
            endSearch()
        case 49 where modifiers == .option: // ⌥Espace : taille des dossiers sélectionnés
            computeSelectedFolderSizes(nil)
        case 49 where modifiers == [.option, .shift]: // ⇧⌥Espace : tous les dossiers
            computeAllFolderSizes(nil)
        case 49 where modifiers.isEmpty: // Espace
            quickLook(nil)
        default:
            return false
        }
        return true
    }

    // MARK: Menu contextuel

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let selection = selectedItems
        func add(_ title: String, _ action: Selector, _ symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }

        if !selection.isEmpty {
            add("Ouvrir", #selector(openSelection(_:)), "arrow.up.forward.app")
            if selection.contains(where: \.isNavigableDirectory) {
                add("Ouvrir dans un nouvel onglet", #selector(openInNewTab(_:)), "plus.square.on.square")
            }
            if selection.count == 1, selection[0].isNavigableDirectory, !currentURL.isRemote {
                add("Analyser l’espace disque", #selector(analyzeDiskUsage(_:)), "chart.pie")
            }
            if selection.count == 1, selection[0].isPackage {
                add("Afficher le contenu du paquet", #selector(showPackageContents(_:)), "shippingbox")
            }
            if let first = selection.first, !first.isNavigableDirectory, !first.url.isRemote {
                menu.addItem(openWithMenu(for: first.url))
            }
            if !currentURL.isRemote { add("Coup d’œil", #selector(quickLook(_:)), "eye") }
            menu.addItem(.separator())
            add("Couper", #selector(cut(_:)), "scissors")
            add("Copier", #selector(copy(_:)), "doc.on.doc")
        }
        if FileClipboard.hasFiles { add("Coller", #selector(paste(_:)), "doc.on.clipboard") }
        if !selection.isEmpty {
            add("Dupliquer", #selector(duplicate(_:)), "plus.rectangle.on.rectangle")
            let targets = host?.targetPanels(for: self) ?? []
            if !targets.isEmpty {
                menu.addItem(panelSubmenu("Copier vers", #selector(copyToOtherPanel(_:)), targets, "arrow.right.doc.on.clipboard"))
                menu.addItem(panelSubmenu("Déplacer vers", #selector(moveToOtherPanel(_:)), targets, "arrow.right.square"))
            }
            if !currentURL.isRemote {
                menu.addItem(.separator())
                menu.addItem(tagsMenuItem())
                if let actions = customActionsMenuItem() { menu.addItem(actions) }
                let name = selection.count == 1 ? "« \(selection[0].name) »" : "\(selection.count) éléments"
                add("Compresser \(name)", #selector(compressSelection(_:)), "archivebox")
                let formats = NSMenuItem(title: "Compresser au format", action: nil, keyEquivalent: "")
                formats.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
                formats.submenu = NSMenu()
                for format in ArchiveFormat.allCases {
                    let entry = NSMenuItem(title: "." + format.fileExtension, action: #selector(compressSelection(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
                    entry.tag = format.rawValue
                    formats.submenu?.addItem(entry)
                }
                menu.addItem(formats)
                if selection.contains(where: { FileOperationCenter.isArchive($0.url) }) {
                    add("Décompresser ici", #selector(extractHere(_:)), "archivebox.circle")
                    if !(host?.targetPanels(for: self).isEmpty ?? true) {
                        add("Décompresser vers l’autre panneau", #selector(extractToOtherPanel(_:)), "arrow.right.circle")
                    }
                }
            }
            menu.addItem(.separator())
            if selection.count == 1 { add("Renommer", #selector(renameSelection(_:)), "pencil") }
            if selection.count > 1 { add("Renommer par lot…", #selector(batchRename(_:)), "pencil.and.list.clipboard") }
            add(currentURL.isRemote ? "Supprimer du serveur…" : "Placer dans la corbeille", #selector(moveToTrash(_:)), "trash")
        }
        menu.addItem(.separator())
        add("Nouveau dossier", #selector(newFolder(_:)), "folder.badge.plus")
        if !currentURL.isRemote { add("Ajouter aux favoris", #selector(addToFavorites(_:)), "star") }
        add("Copier le chemin", #selector(copyPath(_:)), "link")
        if !currentURL.isRemote {
            add("Afficher dans le Finder", #selector(revealInFinder(_:)), "macwindow")
            add("Ouvrir dans le Terminal", #selector(openInTerminal(_:)), "terminal")
            if selection.isEmpty { add("Occupation du disque", #selector(toggleDiskUsage(_:)), "chart.pie") }
        }
        return menu
    }

    private func openWithMenu(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: "Ouvrir avec", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        let submenu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let defaultApp {
            apps.removeAll { $0.isSameLocation(as: defaultApp) }
            apps.insert(defaultApp, at: 0)
        }
        for (index, app) in apps.prefix(20).enumerated() {
            var title = FileManager.default.displayName(atPath: app.path)
            if index == 0, defaultApp != nil { title += " (par défaut)" }
            let entry = NSMenuItem(title: title, action: #selector(openWithApplication(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            submenu.addItem(entry)
            if index == 0, defaultApp != nil, apps.count > 1 { submenu.addItem(.separator()) }
        }
        item.submenu = submenu
        return item
    }

    private func panelSubmenu(_ title: String, _ action: Selector, _ targets: [PanelViewController], _ symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let submenu = NSMenu()
        for target in targets {
            let entry = NSMenuItem(title: "Panneau \(target.index + 1) — \(BreadcrumbView.displayName(target.currentURL))", action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = target
            entry.toolTip = target.currentURL.path
            let icon = target.currentURL.isRemote ? NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)! : NSWorkspace.shared.icon(forFile: target.currentURL.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }
}

// MARK: - Validation des menus

extension PanelViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasSelection = !selectionIndexes.isEmpty
        let localOnly: [Selector?] = [#selector(revealInFinder(_:)), #selector(openInTerminal(_:)), #selector(addToFavorites(_:)),
                                      #selector(runCustomAction(_:)),
                                      #selector(compressSelection(_:)), #selector(extractHere(_:)), #selector(extractToOtherPanel(_:)),
                                      #selector(quickLook(_:)), #selector(showPackageContents(_:))]
        if currentURL.isRemote, localOnly.contains(menuItem.action) { return false }
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(duplicate(_:)), #selector(moveToTrash(_:)),
             #selector(openSelection(_:)), #selector(quickLook(_:)):
            return hasSelection
        case #selector(compressSelection(_:)):
            return hasSelection
        case #selector(extractHere(_:)):
            return selectedURLs.contains(where: FileOperationCenter.isArchive)
        case #selector(extractToOtherPanel(_:)):
            return selectedURLs.contains(where: FileOperationCenter.isArchive) && !(host?.targetPanels(for: self).isEmpty ?? true)
        case #selector(copyToOtherPanel(_:)), #selector(moveToOtherPanel(_:)):
            return hasSelection && !(host?.targetPanels(for: self).isEmpty ?? true)
        case #selector(syncOtherPanel(_:)), #selector(compareWithOtherPanel(_:)):
            return !(host?.targetPanels(for: self).isEmpty ?? true)
        case #selector(renameSelection(_:)):
            return !selectionIndexes.isEmpty
        case #selector(batchRename(_:)):
            return !selectionIndexes.isEmpty
        case #selector(showAsIcons(_:)), #selector(showAsList(_:)), #selector(showAsDetails(_:)), #selector(showAsColumns(_:)):
            let mode: PanelViewMode = menuItem.action == #selector(showAsIcons(_:)) ? .icons
                : menuItem.action == #selector(showAsList(_:)) ? .list
                : menuItem.action == #selector(showAsColumns(_:)) ? .columns : .details
            if mode == .columns, currentURL.isRemote { return false }
            menuItem.state = mode == viewMode && !isShowingDiskUsage ? .on : .off
            return true
        case #selector(toggleDiskUsage(_:)):
            menuItem.state = isShowingDiskUsage ? .on : .off
            return !currentURL.isRemote
        case #selector(analyzeDiskUsage(_:)):
            return !currentURL.isRemote
        case #selector(increaseIconSize(_:)), #selector(decreaseIconSize(_:)), #selector(resetZoom(_:)):
            return true
        case #selector(sortBy(_:)):
            let keys = ["name", "size", "date", "kind"]
            menuItem.state = keys.indices.contains(menuItem.tag) && keys[menuItem.tag] == sortDescriptor.key ? .on : .off
            return true
        case #selector(paste(_:)), #selector(pasteMove(_:)):
            return FileClipboard.hasFiles
        case #selector(goBack(_:)): return !tab.back.isEmpty
        case #selector(goForward(_:)): return !tab.forward.isEmpty
        case #selector(goUp(_:)): return currentURL.path != "/"
        case #selector(closeTab(_:)), #selector(nextTab(_:)), #selector(previousTab(_:)): return tabs.count > 1
        default: return true
        }
    }
}

// MARK: - Table

extension PanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, items.indices.contains(row) else { return nil }
        let item = items[row]
        let dimmed = item.isHidden || cutPaths.contains(item.url.normalizedPath)

        if identifier == .name {
            let cell = tableView.makeView(withIdentifier: .nameCell, owner: self) as? NameCellView ?? makeNameCell()
            cell.apply(scale: listScale)
            cell.textField?.stringValue = item.name
            cell.imageView?.image = item.icon
            cell.alphaValue = dimmed ? 0.5 : 1
            let state = gitState(for: item)
            if renamingRow != row {
                cell.normalTextColor = state?.color ?? Theme.text
                cell.applyTextColor()
            }
            cell.tagDots.attributedStringValue = item.url.isFileURL ? FinderTags.dots(for: item.finderTags) : NSAttributedString()
            if let badge = repositoryBadge(for: item) {
                cell.badge.attributedStringValue = badge
            } else if let state, !state.letter.isEmpty {
                // Fichier : son état ; dossier : l'état le plus important de son contenu.
                cell.badge.attributedStringValue = NSAttributedString(string: state.letter, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: state.color,
                ])
            } else {
                cell.badge.stringValue = ""
            }
            return cell
        }

        let cell = tableView.makeView(withIdentifier: .textCell, owner: self) as? ThemedCellView ?? makeTextCell()
        let field = cell.textField!
        let textSize = (12 * listScale).rounded()
        if field.font?.pointSize != textSize { field.font = .monospacedDigitSystemFont(ofSize: textSize, weight: .regular) }
        switch identifier {
        case .size:
            field.stringValue = item.isNavigableDirectory ? folderSizeText(for: item) : (item.size.map(Format.size) ?? "—")
            field.alignment = .right
        case .date:
            field.stringValue = item.modificationDate.map { Format.dateFormatter.string(from: $0) } ?? ""
            field.alignment = .left
        default:
            // Dans les résultats de recherche, la colonne indique le dossier de chaque élément.
            field.stringValue = isShowingSearchResults ? searchLocation(of: item) : (item.isNavigableDirectory ? "Dossier" : item.kind)
            field.alignment = .left
        }
        field.toolTip = isShowingSearchResults ? item.url.deletingLastPathComponent().path : nil
        cell.alphaValue = dimmed ? 0.5 : 1
        return cell
    }

    private func makeNameCell() -> NameCellView {
        let cell = NameCellView()
        cell.identifier = .nameCell
        let image = NSImageView()
        cell.iconWidth = image.widthAnchor.constraint(equalToConstant: 18)
        cell.iconHeight = image.heightAnchor.constraint(equalToConstant: 18)
        image.imageScaling = .scaleProportionallyUpOrDown
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = false
        let badge = cell.badge
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dots = cell.tagDots
        dots.setContentHuggingPriority(.required, for: .horizontal)
        dots.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [image, field, dots, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            cell.iconWidth,
            cell.iconHeight,
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dots.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            dots.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: dots.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.imageView = image
        cell.textField = field
        return cell
    }

    private func makeTextCell() -> ThemedCellView {
        let cell = ThemedCellView()
        cell.normalTextColor = Theme.secondaryText
        cell.identifier = .textCell
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.textColor = Theme.secondaryText
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = field
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        sortDescriptor = descriptor
        let selection = selectedURLs
        if isShowingSearchResults {
            items = Self.sorted(items, by: sortDescriptor)
        } else {
            allItems = Self.sorted(allItems, by: sortDescriptor)
            let filter = isSearching && searchBar.scope == .folder ? Self.nameMatcher(for: searchBar.field.stringValue.trimmingCharacters(in: .whitespaces)) : nil
            items = filter.map { match in allItems.filter { item in match(item.name) { item.finderTags } } } ?? allItems
        }
        reloadViews()
        let paths = Set(selection.map(\.normalizedPath))
        setSelection(IndexSet(items.indices.filter { paths.contains(items[$0].url.normalizedPath) }), scroll: false)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard viewMode != .icons else { return }
        selectionDidChange()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier == .name ? items[row].name : nil
    }

    // Glisser-déposer

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        items[row].url as NSURL
    }

    fileprivate func dropDestination(row: Int, operation: NSTableView.DropOperation, sources: [URL]) -> URL {
        if operation == .on, items.indices.contains(row), items[row].isNavigableDirectory,
           !sources.contains(where: { $0.isSameLocation(as: items[row].url) }) {
            return items[row].url
        }
        return currentURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let sources = FileClipboard.fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty else { return [] }
        let destination = dropDestination(row: row, operation: dropOperation, sources: sources)
        if destination.isSameLocation(as: currentURL) { tableView.setDropRow(-1, dropOperation: .on) }
        return validatedOperation(info, sources: sources, destination: destination)
    }

    fileprivate func validatedOperation(_ info: NSDraggingInfo, sources: [URL], destination: URL) -> NSDragOperation {
        if sources.contains(where: { destination.isInside($0) }) { return [] }
        let operation = FileOperationCenter.dropOperation(for: info, sources: sources, destination: destination)
        if operation == .move, sources.allSatisfy({ $0.deletingLastPathComponent().isSameLocation(as: destination) }) { return [] }
        return operation
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        performDrop(info, row: row, operation: dropOperation)
    }

    fileprivate func performDrop(_ info: NSDraggingInfo, row: Int, operation dropOperation: NSTableView.DropOperation) -> Bool {
        let sources = FileClipboard.fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty else { return false }
        let destination = dropDestination(row: row, operation: dropOperation, sources: sources)
        let operation = FileOperationCenter.dropOperation(for: info, sources: sources, destination: destination)
        guard !operation.isEmpty else { return false }
        activate()
        transfer(operation == .copy ? .copy : .move, sources, to: destination)
        return true
    }
}

// MARK: - Renommage sur place

extension PanelViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField else { return false }
        finishRename(field, commit: false)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        finishRename(field, commit: true)
    }
}

// MARK: - Quick Look

extension PanelViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        focusView.keyDown(with: event)
        return true
    }
}

// MARK: - Grille d'icônes

extension PanelViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
        if let thumbnail = cell as? ThumbnailItem, items.indices.contains(indexPath.item) {
            let item = items[indexPath.item]
            thumbnail.configure(with: item, size: iconSize, dimmed: item.isHidden || cutPaths.contains(item.url.normalizedPath),
                                gitColor: gitState(for: item)?.color, badge: repositoryBadge(for: item))
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if viewMode == .icons { selectionDidChange() }
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if viewMode == .icons { selectionDidChange() }
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items.indices.contains(indexPath.item) ? items[indexPath.item].url as NSURL : nil
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let sources = FileClipboard.fileURLs(from: draggingInfo.draggingPasteboard)
        guard !sources.isEmpty else { return [] }
        let row = (proposedDropIndexPath.pointee as IndexPath).item
        let operation: NSTableView.DropOperation = proposedDropOperation.pointee == .on ? .on : .above
        let destination = dropDestination(row: row, operation: operation, sources: sources)
        if destination.isSameLocation(as: currentURL), proposedDropOperation.pointee == .on {
            proposedDropOperation.pointee = .before
        }
        return validatedOperation(draggingInfo, sources: sources, destination: destination)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let operation: NSTableView.DropOperation = dropOperation == .on ? .on : .above
        return performDrop(draggingInfo, row: indexPath.item, operation: operation)
    }
}

/// Cellule « Nom » : icône, nom et indicateur Git à droite.
final class NameCellView: ThemedCellView {
    let badge = NSTextField(labelWithString: "")
    /// Pastilles des tags du Finder.
    let tagDots = NSTextField(labelWithString: "")
    var iconWidth: NSLayoutConstraint!
    var iconHeight: NSLayoutConstraint!
    private var scale: CGFloat = 1

    /// Taille du texte et de l'icône selon le zoom de la liste.
    func apply(scale newScale: CGFloat) {
        guard newScale != scale else { return }
        scale = newScale
        iconWidth.constant = (18 * scale).rounded()
        iconHeight.constant = (18 * scale).rounded()
        textField?.font = .systemFont(ofSize: (13 * scale).rounded())
    }
}

/// Cellule dont le texte prend la couleur du thème, et repasse en clair sur une sélection pleine.
class ThemedCellView: NSTableCellView {
    var normalTextColor: NSColor = Theme.text

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColor() }
    }

    func applyTextColor() {
        textField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : normalTextColor
    }
}
