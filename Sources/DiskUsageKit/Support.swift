import AppKit

/// Mise en forme partagée entre EnhancedFileManager et iBaobab (complétée dans chaque application).
package enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    package static func size(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }

    package static func items(_ count: Int) -> String { count <= 1 ? "\(count) élément" : "\(count) éléments" }

    package static func availableCapacity(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
}

extension URL {
    /// Emplacement sur un serveur SFTP (sftp://utilisateur@hôte:port/chemin).
    package var isRemote: Bool { scheme == "sftp" }

    /// Chemin normalisé utilisé pour comparer des emplacements (inclut le serveur pour SFTP).
    package var normalizedPath: String {
        guard isRemote else { return standardizedFileURL.path }
        let path = standardized.path
        return "sftp://\(sftpKey)" + (path.isEmpty ? "/" : path)
    }

    /// Identifiant de connexion « utilisateur@hôte:port ».
    package var sftpKey: String {
        "\(user.map { $0 + "@" } ?? "")\(host ?? ""):\(port ?? 22)"
    }

    package func isSameLocation(as other: URL) -> Bool { normalizedPath == other.normalizedPath }

    /// Vrai si `self` est `other` ou se trouve à l'intérieur.
    package func isInside(_ other: URL) -> Bool {
        let mine = normalizedPath, theirs = other.normalizedPath
        return mine == theirs || mine.hasPrefix(theirs.hasSuffix("/") ? theirs : theirs + "/")
    }

    /// Nom affiché d'un emplacement (nom du disque pour la racine, du serveur pour SFTP).
    package var displayName: String {
        if isRemote, path == "/" || path.isEmpty { return host ?? "SFTP" }
        return path == "/" ? FileManager.default.displayName(atPath: "/") : lastPathComponent
    }
}

extension NSColor {
    /// « #RRGGBB » ou « #RRGGBBAA ».
    package convenience init(hex: String) {
        var value: UInt64 = 0
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: digits).scanHexInt64(&value)
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: hasAlpha ? CGFloat(value & 0xFF) / 255 : 1)
    }
}
