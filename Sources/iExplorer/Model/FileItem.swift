import AppKit
import UniformTypeIdentifiers

/// Une entrée de dossier affichée dans un panneau.
final class FileItem: NSObject {
    /// Propriétés lues en une fois avec la liste du dossier (le type et l'icône sont calculés à la demande).
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey,
    ]

    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymlink: Bool
    let size: Int64?
    let modificationDate: Date?
    private let remoteKind: String?
    /// Taille d'un dossier, une fois calculée à la demande (⌥Espace).
    var folderSize: Int64?
    /// Tags du Finder, lus à la demande (seulement pour les lignes affichées).
    lazy var finderTags: [FinderTag] = FinderTags.read(url)
    var tags: [String] { finderTags.map(\.name) }

    /// Taille du fichier, ou du dossier si elle a été calculée.
    var effectiveSize: Int64? { size ?? folderSize }

    /// Description du type (« Document PDF »…), mise en cache par extension.
    var kind: String { remoteKind ?? IconCache.kind(forExtension: url.pathExtension, isDirectory: isDirectory, isPackage: isPackage) }

    /// Un dossier dans lequel on entre (les paquets comme les .app s'ouvrent).
    var isNavigableDirectory: Bool { isDirectory && !isPackage }

    /// Icône partagée entre fichiers du même type (une image par type plutôt qu'une par fichier).
    lazy var icon: NSImage = {
        if let themed = IconTheme.current.icon(for: self) { return themed }
        return IconCache.icon(for: self)
    }()

    /// Entrée d'un dossier distant (SFTP).
    init(remote url: URL, entry: SFTPEntry) {
        self.url = url
        name = entry.name
        isSymlink = entry.isSymlink
        isDirectory = entry.isDirectory
        isPackage = false
        isHidden = entry.name.hasPrefix(".")
        size = entry.isDirectory ? nil : entry.size
        modificationDate = entry.date
        remoteKind = entry.isDirectory ? "Dossier" : entry.isSymlink ? "Lien symbolique" : nil
        super.init()
    }

    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        isSymlink = values?.isSymbolicLink ?? false
        var directory = values?.isDirectory ?? false
        var package = values?.isPackage ?? false
        if isSymlink {
            let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            directory = target?.isDirectory ?? false
            package = target?.isPackage ?? false
        }
        isDirectory = directory
        isPackage = package
        isHidden = values?.isHidden ?? name.hasPrefix(".")
        size = directory ? nil : Int64(values?.fileSize ?? 0)
        modificationDate = values?.contentModificationDate
        remoteKind = nil
        super.init()
    }

    static func contents(of directory: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return urls.map(FileItem.init)
    }
}

extension Format {
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func freeSpace(at url: URL) -> String? {
        availableCapacity(at: url).map { "\(size($0)) disponibles" }
    }
}

extension URL {
    var isExistingDirectory: Bool {
        guard isFileURL else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Caches partagés des icônes et des descriptions de type.
enum IconCache {
    private static let lock = NSLock()
    private static var typeIcons: [String: NSImage] = [:]
    private static var kinds: [String: String] = [:]
    /// Icônes propres (applications, paquets, dossiers personnalisés), limitées en nombre.
    private static let customIcons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    private static let specialFolders: Set<String> = {
        let fm = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory, .picturesDirectory,
                                                              .musicDirectory, .moviesDirectory, .applicationDirectory, .libraryDirectory]
        var paths = Set(directories.compactMap { fm.urls(for: $0, in: .userDomainMask).first?.path })
        paths.formUnion(["/Applications", "/System", "/Library", "/Users", fm.homeDirectoryForCurrentUser.path,
                         fm.homeDirectoryForCurrentUser.appendingPathComponent("Public").path])
        return paths
    }()

    static func icon(for item: FileItem) -> NSImage {
        let url = item.url
        if !url.isRemote, item.isPackage || (item.isNavigableDirectory && hasOwnIcon(url)) {
            let key = url.path as NSString
            if let cached = customIcons.object(forKey: key) { return cached }
            let image = NSWorkspace.shared.icon(forFile: url.path)
            customIcons.setObject(image, forKey: key)
            return image
        }
        let type: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: url.pathExtension) ?? .data)
        return lock.withLock {
            if let cached = typeIcons[type.identifier] { return cached }
            let image = NSWorkspace.shared.icon(for: type)
            typeIcons[type.identifier] = image
            return image
        }
    }

    /// Dossiers système à icône dédiée, ou dossiers avec une icône personnalisée (fichier « Icon\r »).
    private static func hasOwnIcon(_ url: URL) -> Bool {
        specialFolders.contains(url.path) || access(url.path + "/Icon\r", F_OK) == 0
    }

    static func kind(forExtension ext: String, isDirectory: Bool, isPackage: Bool) -> String {
        if isDirectory && !isPackage { return "Dossier" }
        let key = ext.lowercased()
        return lock.withLock {
            if let cached = kinds[key] { return cached }
            let description = UTType(filenameExtension: key)?.localizedDescription ?? (key.isEmpty ? "Document" : "Document \(key.uppercased())")
            kinds[key] = description
            return description
        }
    }
}
