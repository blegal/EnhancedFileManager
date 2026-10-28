import AppKit

/// Portée de la recherche d'un panneau.
enum SearchScope: Int {
    /// Filtre instantané du dossier affiché.
    case folder
    /// Noms de fichiers dans tous les sous-dossiers (parcours du disque).
    case subfolders
    /// Contenu des fichiers (index Spotlight).
    case content
}

/// Barre de recherche d'un panneau (⌘F) : champ, portée, indicateur d'activité.
final class PanelSearchBar: NSView, NSSearchFieldDelegate {
    var onChange: ((String, SearchScope) -> Void)?
    var onClose: (() -> Void)?
    var onMoveDown: (() -> Void)?

    let field = NSSearchField()
    private let scopeControl = NSSegmentedControl(labels: ["Ce dossier", "Sous-dossiers", "Contenu"], trackingMode: .selectOne, target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    var scope: SearchScope { SearchScope(rawValue: scopeControl.selectedSegment) ?? .folder }

    /// Les recherches disque et Spotlight ne s'appliquent pas aux serveurs SFTP.
    var allowsDeepSearch = true {
        didSet {
            scopeControl.setEnabled(allowsDeepSearch, forSegment: 1)
            scopeControl.setEnabled(allowsDeepSearch, forSegment: 2)
            if !allowsDeepSearch { scopeControl.selectedSegment = 0 }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Rechercher (ex. rapport, *.pdf)"
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        scopeControl.controlSize = .small
        scopeControl.selectedSegment = 0
        scopeControl.target = self
        scopeControl.action = #selector(changed)
        scopeControl.setToolTip("Filtrer le dossier affiché", forSegment: 0)
        scopeControl.setToolTip("Chercher par nom dans tous les sous-dossiers", forSegment: 1)
        scopeControl.setToolTip("Chercher dans le contenu des fichiers (Spotlight)", forSegment: 2)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Fermer la recherche")!,
                             target: self, action: #selector(closeSearch))
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor

        let stack = NSStackView(views: [field, scopeControl, spinner, close])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func changed() { onChange?(field.stringValue, scope) }
    @objc private func closeSearch() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            onMoveDown?()
            return true
        default:
            return false
        }
    }
}

// MARK: - Recherche dans un panneau

extension PanelViewController {
    var isSearching: Bool { !searchBar.isHidden }

    @objc func showSearch(_ sender: Any?) {
        if searchBar.isHidden {
            searchBar.allowsDeepSearch = !currentURL.isRemote
            searchBar.isHidden = false
            searchBarHeight.constant = 34
        }
        activate(focusTable: false)
        view.window?.makeFirstResponder(searchBar.field)
    }

    /// Ferme la recherche et revient au contenu du dossier.
    func endSearch(reloadListing: Bool = true) {
        guard isSearching else { return }
        searchGeneration += 1
        searchBar.setBusy(false)
        searchBar.field.stringValue = ""
        searchBar.isHidden = true
        searchBarHeight.constant = 0
        let wasShowingResults = isShowingSearchResults
        isShowingSearchResults = false
        searchQuery?.stop()
        searchQuery = nil
        if wasShowingResults, reloadListing { reload() } else { applyFilter() }
        view.window?.makeFirstResponder(focusView)
    }

    func searchChanged(_ text: String, scope: SearchScope) {
        searchGeneration += 1
        searchQuery?.stop()
        searchQuery = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch scope {
        case .folder:
            searchBar.setBusy(false)
            if isShowingSearchResults {
                isShowingSearchResults = false
                reload()
            } else {
                applyFilter()
            }
        case .subfolders, .content:
            guard !trimmed.isEmpty else {
                searchBar.setBusy(false)
                if isShowingSearchResults { isShowingSearchResults = false; reload() }
                return
            }
            // Petite attente pendant la frappe avant de lancer une recherche coûteuse.
            let generation = searchGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, generation == searchGeneration else { return }
                if scope == .subfolders { searchSubfolders(trimmed, generation: generation) } else { searchContent(trimmed, generation: generation) }
            }
        }
    }

    /// Filtre instantané du dossier affiché (nom contenant le texte, ou motif « *.pdf »).
    func applyFilter() {
        let text = isSearching && searchBar.scope == .folder ? searchBar.field.stringValue.trimmingCharacters(in: .whitespaces) : ""
        let matcher = Self.nameMatcher(for: text)
        let selection = selectedURLs
        items = matcher.map { match in allItems.filter { item in match(item.name) { item.finderTags } } } ?? allItems
        reloadViews()
        let paths = Set(selection.map(\.normalizedPath))
        setSelection(IndexSet(items.indices.filter { paths.contains(items[$0].url.normalizedPath) }), scroll: false)
    }

    /// Filtre d'un texte de recherche : nom contenant le texte, motif « *.pdf », ou tag (« tag:Rouge » / « #Rouge »).
    /// `nil` quand il n'y a rien à filtrer. Les tags ne sont lus que si la recherche porte sur eux.
    static func nameMatcher(for text: String) -> ((String, () -> [FinderTag]) -> Bool)? {
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("tag:") || lower.hasPrefix("#") {
            let tag = String(text.drop(while: { $0 != ":" && $0 != "#" }).dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty else { return nil }
            return { _, tags in tags().contains { $0.matches(tag) } }
        }
        if text.contains("*") || text.contains("?") {
            let predicate = NSPredicate(format: "SELF LIKE[cd] %@", text)
            return { name, _ in predicate.evaluate(with: name) }
        }
        return { name, _ in name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Recherche par nom dans les sous-dossiers (parcours du disque, en arrière-plan, 2 000 résultats au plus).
    private func searchSubfolders(_ text: String, generation: Int) {
        guard let match = Self.nameMatcher(for: text) else { return }
        let root = currentURL
        let showHidden = Preferences.showHiddenFiles
        searchBar.setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [URL] = []
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: FileItem.resourceKeys,
                                                            options: options, errorHandler: { _, _ in true })
            var visited = 0
            while let url = enumerator?.nextObject() as? URL {
                visited += 1
                if visited % 500 == 0, self?.searchGeneration != generation { return }
                if match(url.lastPathComponent, { FinderTags.read(url) }) {
                    found.append(url)
                    if found.count >= 2000 { break }
                }
            }
            let results = found.map(FileItem.init)
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration else { return }
                self.showSearchResults(results, truncated: found.count >= 2000)
            }
        }
    }

    /// Recherche dans le contenu des fichiers via l'index Spotlight.
    private func searchContent(_ text: String, generation: Int) {
        let escaped = text.replacingOccurrences(of: "\"", with: "")
        let lower = escaped.lowercased()
        if lower.hasPrefix("tag:") || lower.hasPrefix("#") {
            let tag = String(escaped.drop(while: { $0 != ":" && $0 != "#" }).dropFirst()).trimmingCharacters(in: .whitespaces)
            runSpotlight(NSPredicate(format: "kMDItemUserTags ==[cd] %@", tag), scopes: [currentURL], generation: generation)
        } else {
            runSpotlight(NSPredicate(format: "(kMDItemTextContent CONTAINS[cd] %@) OR (kMDItemFSName CONTAINS[cd] %@)", escaped, escaped),
                         scopes: [currentURL], generation: generation)
        }
    }

    /// Tous les fichiers portant un tag, dans le dossier personnel.
    func searchTagEverywhere(_ tag: String) {
        searchGeneration += 1
        runSpotlight(NSPredicate(format: "kMDItemUserTags ==[cd] %@", tag), scopes: [NSMetadataQueryUserHomeScope], generation: searchGeneration)
    }

    private func runSpotlight(_ predicate: NSPredicate, scopes: [Any], generation: Int) {
        searchQuery?.stop()
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes
        query.operationQueue = .main
        searchBar.setBusy(true)
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            observer.map(NotificationCenter.default.removeObserver)
            guard let self, generation == searchGeneration else { return }
            query.disableUpdates()
            let paths = (query.results as? [NSMetadataItem] ?? []).prefix(2000).compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            query.stop()
            DispatchQueue.global(qos: .userInitiated).async {
                let results = paths.map { FileItem(url: URL(fileURLWithPath: $0)) }
                DispatchQueue.main.async {
                    guard generation == self.searchGeneration else { return }
                    self.showSearchResults(results, truncated: paths.count >= 2000)
                }
            }
        }
        searchQuery = query
        if !query.start() {
            searchBar.setBusy(false)
            NSSound.beep()
        }
    }

    private func showSearchResults(_ results: [FileItem], truncated: Bool) {
        searchBar.setBusy(false)
        isShowingSearchResults = true
        searchResultsTruncated = truncated
        items = results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        reloadViews()
        setSelection([], scroll: true)
    }

    /// Dossier d'un résultat, relatif au dossier de recherche (affiché dans la colonne Type).
    func searchLocation(of item: FileItem) -> String {
        // Chemins résolus : les résultats peuvent passer par un lien (/tmp → /private/tmp).
        let parent = item.url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let root = currentURL.resolvingSymlinksInPath().path
        if parent == root { return "./" }
        return parent.hasPrefix(root + "/") ? String(parent.dropFirst(root.count + 1)) : (parent as NSString).abbreviatingWithTildeInPath
    }
}
