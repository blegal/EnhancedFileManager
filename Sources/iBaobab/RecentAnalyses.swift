import Foundation

/// Historique des analyses (préférences) : dossier, taille totale et date, le plus récent en tête.
enum RecentAnalyses {
    struct Entry {
        let url: URL
        let size: Int64
        let date: Date
    }

    static let changed = Notification.Name("RecentAnalysesChanged")
    private static let key = "recentAnalyses"
    private static let limit = 8

    static var entries: [Entry] {
        let list = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let path = item["path"] as? String, let size = item["size"] as? Int64, let date = item["date"] as? Date else { return nil }
            return Entry(url: URL(fileURLWithPath: path, isDirectory: true), size: size, date: date)
        }
    }

    static func add(_ url: URL, size: Int64) {
        let path = url.standardizedFileURL.path
        var list = entries.filter { $0.url.path != path }
        list.insert(Entry(url: URL(fileURLWithPath: path, isDirectory: true), size: size, date: Date()), at: 0)
        save(Array(list.prefix(limit)))
    }

    static func remove(_ url: URL) {
        save(entries.filter { $0.url.path != url.path })
    }

    static func clear() { save([]) }

    private static func save(_ list: [Entry]) {
        UserDefaults.standard.set(list.map { ["path": $0.url.path, "size": $0.size, "date": $0.date] as [String: Any] }, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
