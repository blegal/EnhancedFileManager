import AppKit

enum Preferences {
    static let showHiddenChanged = Notification.Name("ShowHiddenFilesChanged")
    static let favoritesChanged = Notification.Name("FavoritesChanged")

    private static let defaults = UserDefaults.standard

    /// Relire et comparer chaque copie à l'original.
    static var verifyCopies: Bool {
        get { defaults.bool(forKey: "verifyCopies") }
        set { defaults.set(newValue, forKey: "verifyCopies") }
    }

    /// Navigation synchronisée : les autres panneaux suivent les déplacements relatifs du panneau actif.
    static var syncNavigation: Bool {
        get { defaults.bool(forKey: "syncNavigation") }
        set { defaults.set(newValue, forKey: "syncNavigation") }
    }

    static var showHiddenFiles: Bool {
        get { defaults.bool(forKey: "showHiddenFiles") }
        set {
            defaults.set(newValue, forKey: "showHiddenFiles")
            NotificationCenter.default.post(name: showHiddenChanged, object: nil)
        }
    }

    /// Dossiers ajoutés avant que la section Favoris devienne entièrement modifiable (repris une fois).
    static var customFavorites: [URL] {
        (defaults.stringArray(forKey: "customFavorites") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Section Favoris de la barre latérale, dans l'ordre ; nil tant qu'elle n'a pas été initialisée.
    static var sidebarFavorites: [URL]? {
        get { defaults.stringArray(forKey: "sidebarFavorites")?.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set {
            defaults.set(newValue?.map(\.path), forKey: "sidebarFavorites")
            NotificationCenter.default.post(name: favoritesChanged, object: nil)
        }
    }

    /// Ajoute des dossiers aux favoris (à la fin, ou à une position), sans doublon.
    static func addFavorites(_ urls: [URL], at index: Int? = nil) {
        var favorites = sidebarFavorites ?? []
        let additions = urls.filter { url in !favorites.contains { $0.isSameLocation(as: url) } }
        guard !additions.isEmpty else { return }
        favorites.insert(contentsOf: additions, at: min(index ?? favorites.count, favorites.count))
        sidebarFavorites = favorites
    }

    static func removeFavorite(_ url: URL) {
        sidebarFavorites = (sidebarFavorites ?? []).filter { !$0.isSameLocation(as: url) }
    }

    /// Déplace un favori (réorganisation par glisser-déposer).
    static func moveFavorite(_ url: URL, to index: Int) {
        var favorites = sidebarFavorites ?? []
        guard let from = favorites.firstIndex(where: { $0.isSameLocation(as: url) }) else { return }
        let moved = favorites.remove(at: from)
        favorites.insert(moved, at: min(from < index ? index - 1 : index, favorites.count))
        sidebarFavorites = favorites
    }

    static var recentServers: [String] {
        get { defaults.stringArray(forKey: "recentServers") ?? [] }
        set {
            defaults.set(Array(newValue.prefix(10)), forKey: "recentServers")
            NotificationCenter.default.post(name: favoritesChanged, object: nil)
        }
    }
}

/// Le presse-papiers fichiers, partagé avec le Finder (URL de fichiers).
/// « Couper » est un état interne : les fichiers sont déplacés au moment du collage.
enum FileClipboard {
    static let changed = Notification.Name("FileClipboardChanged")

    private static var cutChangeCount: Int?
    private static let readOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    static func write(_ urls: [URL], cut: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        cutChangeCount = cut ? pasteboard.changeCount : nil
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func writePaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        cutChangeCount = nil
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static var isCut: Bool { cutChangeCount != nil && cutChangeCount == NSPasteboard.general.changeCount }

    static var hasFiles: Bool { !fileURLs().isEmpty }

    static func fileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        // Fichiers locaux et emplacements SFTP de l'app.
        ((pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL]) ?? []).filter { $0.isFileURL || $0.isRemote }
    }

    /// Chemins actuellement « coupés », pour les afficher atténués.
    static var cutPaths: Set<String> { isCut ? Set(fileURLs().map(\.normalizedPath)) : [] }

    static func didPasteCut() {
        NSPasteboard.general.clearContents()
        cutChangeCount = nil
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

// MARK: - Session (restauration des fenêtres, panneaux et onglets)

struct PanelState: Codable {
    var tabs: [String]
    var selectedTab: Int
    var viewMode: Int?
    var iconSize: Double?
    var sortKey: String?
    var sortAscending: Bool?
    /// Zoom des listes (1 = taille normale).
    var listScale: Double?
    /// Couleur de chaque onglet (indice dans `TabColor`, -1 = aucune), alignée sur `tabs`.
    var tabColors: [Int]?
}

struct WindowState: Codable {
    var layout: Int
    var activePanel: Int
    var panels: [PanelState]
    var frame: String?
    var sidebarCollapsed: Bool?
    /// Positions des séparateurs entre panneaux (fractions), par vue partagée.
    var splitFractions: [[Double]]?
    var terminalVisible: Bool?
    var terminalHeight: Double?
}

enum SessionStore {
    private static let key = "session.windows"

    static func load() -> [WindowState] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WindowState].self, from: data)) ?? []
    }

    static func save(_ windows: [WindowState]) {
        guard let data = try? JSONEncoder().encode(windows) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
