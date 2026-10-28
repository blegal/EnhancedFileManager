import AppKit

/// Lit les favoris de la barre latérale du Finder (liste partagée « FavoriteItems »).
/// Le fichier est une archive NSKeyedArchiver contenant des signets (bookmarks).
enum FinderFavorites {
    struct Entry {
        let name: String
        let url: URL
    }

    enum Failure: Error {
        /// macOS refuse l'accès au dossier (protection de la vie privée).
        case accessDenied
        case fileNotFound([String])
        case unreadableFormat(String)

        var message: String {
            switch self {
            case .accessDenied:
                return "macOS refuse la lecture de la liste des favoris du Finder. Accordez l’« Accès complet au disque » à iExplorer dans Réglages Système › Confidentialité et sécurité, puis relancez l’app."
            case .fileNotFound(let names):
                return "Aucun fichier de favoris trouvé. Contenu du dossier : \(names.isEmpty ? "(vide)" : names.joined(separator: ", "))."
            case .unreadableFormat(let detail):
                return "Le fichier des favoris a un format inattendu (\(detail))."
            }
        }
    }

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
    }

    /// Dernier résultat, pour la barre latérale et le diagnostic.
    private(set) static var lastFailure: Failure?
    private(set) static var lastFile: String?

    static func load() -> [Entry]? {
        switch read() {
        case .success(let entries):
            lastFailure = nil
            return entries
        case .failure(let failure):
            lastFailure = failure
            return nil
        }
    }

    static func read() -> Result<[Entry], Failure> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            let code = (error as NSError).code
            return .failure(code == NSFileReadNoPermissionError || code == NSFileReadUnknownError ? .accessDenied
                            : .unreadableFormat(error.localizedDescription))
        }
        // Le suffixe change selon les versions de macOS (.sfl2, .sfl3, .sfl4…) : on prend le plus récent.
        guard let file = names.filter({ $0.hasPrefix("com.apple.LSSharedFileList.FavoriteItems.sfl") }).sorted().last else {
            return .failure(.fileNotFound(names))
        }
        lastFile = file
        let data: Data
        do {
            data = try Data(contentsOf: directory.appendingPathComponent(file))
        } catch {
            return .failure(.accessDenied)
        }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return .failure(.unreadableFormat("archive illisible"))
        }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        let items = (root as? NSDictionary)?["items"] as? [Any] ?? (root as? [Any])
        guard let items else {
            return .failure(.unreadableFormat("racine \(root.map { String(describing: type(of: $0)) } ?? "absente")"))
        }

        let entries: [Entry] = items.compactMap { element in
            guard let item = element as? NSDictionary else { return nil }
            if let visibility = item["visibility"] as? Int, visibility != 0 { return nil }
            // Selon les versions, le signet est une donnée directe ou rangé sous « Bookmark ».
            let bookmark = (item["Bookmark"] as? Data) ?? (item["bookmark"] as? Data)
            guard let bookmark else { return nil }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.isFileURL, url.isExistingDirectory else { return nil }
            let name = (item["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.displayName(atPath: url.path)
            return Entry(name: name, url: url)
        }
        return entries.isEmpty ? .failure(.unreadableFormat("aucun favori exploitable parmi \(items.count) entrées")) : .success(entries)
    }

    /// Ouvre le réglage « Accès complet au disque ».
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Fenêtre de diagnostic (menu Aide).
    static func showDiagnostic() {
        let alert = NSAlert()
        alert.messageText = "Favoris du Finder"
        switch read() {
        case .success(let entries):
            alert.informativeText = "\(entries.count) favoris lus dans \(lastFile ?? "?") :\n" + entries.map { "• \($0.name) — \($0.url.path)" }.joined(separator: "\n")
        case .failure(let failure):
            alert.alertStyle = .warning
            alert.informativeText = failure.message + (lastFile.map { "\nFichier : \($0)" } ?? "")
            if case .accessDenied = failure { alert.addButton(withTitle: "Ouvrir les Réglages"); alert.addButton(withTitle: "Fermer") }
        }
        if alert.runModal() == .alertFirstButtonReturn, alert.buttons.count > 1 { openPrivacySettings() }
    }
}
