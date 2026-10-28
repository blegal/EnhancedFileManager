import AppKit
import UniformTypeIdentifiers

/// Catégorie de fichier utilisée pour colorer les vues d'occupation du disque.
enum DiskCategory: Int, CaseIterable {
    case images, video, audio, documents, code, data, archives, other

    var title: String {
        switch self {
        case .images: "Images"
        case .video: "Vidéo"
        case .audio: "Audio"
        case .documents: "Documents"
        case .code: "Code"
        case .data: "Données"
        case .archives: "Archives"
        case .other: "Autres"
        }
    }

    var color: NSColor { Self.colors[rawValue] }

    private static let colors = ["#3A9D5D", "#D6504B", "#9466CF", "#3A7BD5", "#E3872D", "#169FA6", "#C4579B", "#8D9097"].map(NSColor.init(hex:))

    private static let table: [String: DiskCategory] = {
        var table: [String: DiskCategory] = [:]
        let groups: [(DiskCategory, String)] = [
            (.images, "jpg jpeg png heic heif gif tiff tif bmp webp svg cr2 cr3 nef arw dng raw psd ico icns"),
            (.video, "mov mp4 m4v mkv avi webm mts mpg mpeg wmv flv"),
            (.audio, "m4a wav mp3 flac aac aif aiff ogg opus caf alac"),
            (.documents, "pdf doc docx tex md txt rtf pages key numbers pptx ppt xlsx xls odt ods odp bib epub html htm"),
            (.code, "c h cc cpp hpp m mm swift py ipynb js ts tsx jsx java kt rs go rb php sh zsh json yaml yml toml xml css scss sql lua pl r jl"),
            (.data, "h5 hdf5 mat npy npz csv tsv nc parquet feather db sqlite sqlite3 bin dat pkl pt pth onnx safetensors"),
            (.archives, "zip gz tgz bz2 xz 7z rar tar dmg iso pkg xip zst"),
        ]
        for (category, extensions) in groups {
            for ext in extensions.split(separator: " ") { table[String(ext)] = category }
        }
        return table
    }()
    private static var cache: [String: DiskCategory] = [:]
    private static let lock = NSLock()

    /// Catégorie d'après l'extension (table, puis UTType), mise en cache ; utilisable depuis plusieurs fils.
    static func of(_ name: String) -> DiskCategory {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        if let known = table[ext] { return known }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[ext] { return cached }
        var category = DiskCategory.other
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { category = .images }
            else if type.conforms(to: .movie) { category = .video }
            else if type.conforms(to: .audio) { category = .audio }
            else if type.conforms(to: .sourceCode) || type.conforms(to: .script) { category = .code }
            else if type.conforms(to: .archive) || type.conforms(to: .diskImage) { category = .archives }
            else if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) { category = .documents }
        }
        cache[ext] = category
        return category
    }
}

/// Nœud compact de l'arbre d'occupation : un fichier, un dossier ou un groupe de petits fichiers.
final class DiskNode {
    let name: String
    weak var parent: DiskNode?
    var size: Int64 = 0
    /// Nombre de fichiers (1 pour un fichier, total des descendants pour un dossier ou un groupe).
    var count = 0
    /// Date de modification la plus récente (secondes depuis la date de référence).
    var modified: TimeInterval = 0
    var category = DiskCategory.other
    /// Dossiers seulement (nil pour un fichier ou un groupe).
    var children: [DiskNode]?
    /// Taille par catégorie, pour les dossiers et les groupes.
    var categorySizes: [Int64]?
    /// Groupe « N autres fichiers » (les petits fichiers d'un dossier, agrégés pour économiser la mémoire).
    var isAggregate = false
    /// Racine de l'analyse uniquement.
    var rootURL: URL?

    init(name: String) { self.name = name }

    var isDirectory: Bool { children != nil }
    var url: URL { rootURL ?? parent?.url.appendingPathComponent(name, isDirectory: isDirectory) ?? URL(fileURLWithPath: name) }

    /// Taille d'une catégorie (répartition des dossiers et des groupes, catégorie propre d'un fichier).
    func size(of category: DiskCategory) -> Int64 {
        if let categorySizes { return categorySizes[category.rawValue] }
        return category == self.category ? size : 0
    }

    /// Recalcule les totaux à partir des enfants et les trie du plus gros au plus petit.
    func finish() {
        guard var kids = children else { return }
        kids.sort { $0.size > $1.size }
        children = kids
        var sizes = [Int64](repeating: 0, count: DiskCategory.allCases.count)
        size = 0
        count = 0
        modified = 0
        for kid in kids {
            size += kid.size
            count += kid.count
            modified = max(modified, kid.modified)
            for category in DiskCategory.allCases { sizes[category.rawValue] += kid.size(of: category) }
        }
        categorySizes = sizes
        category = DiskCategory(rawValue: sizes.indices.max { sizes[$0] < sizes[$1] } ?? 7) ?? .other
    }

    /// Sous-dossier désigné par un chemin relatif.
    func descendant(_ components: [String]) -> DiskNode? {
        var node = self
        for component in components {
            guard let next = node.children?.first(where: { $0.isDirectory && $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    /// Détache le nœud (après une mise à la corbeille) et retire sa taille de ses ancêtres.
    func detach() {
        guard let parent else { return }
        parent.children?.removeAll { $0 === self }
        var ancestor: DiskNode? = parent
        while let node = ancestor {
            node.size -= size
            node.count -= count
            if var sizes = node.categorySizes {
                for category in DiskCategory.allCases { sizes[category.rawValue] -= self.size(of: category) }
                node.categorySizes = sizes
            }
            node.children?.sort { $0.size > $1.size }
            ancestor = node.parent
        }
        self.parent = nil
    }
}

/// Analyse récursive d'un dossier, en arrière-plan, parallélisée sur les premiers niveaux.
final class DiskScanner {
    /// Fichiers gardés individuellement par dossier ; les autres sont regroupés.
    static let keptFilesPerFolder = 200

    private let lock = NSLock()
    private var scannedFiles = 0
    private var scannedBytes: Int64 = 0
    private var cancelled = false
    /// Sous-arbres déjà analysés, réutilisés tels quels (par chemin).
    private let reuse: [String: DiskNode]

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey, .totalFileAllocatedSizeKey,
                                                 .fileAllocatedSizeKey, .contentModificationDateKey]
    private static let keySet = Set(keys)

    init(reuse: [String: DiskNode] = [:]) { self.reuse = reuse }

    var progress: (files: Int, bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (scannedFiles, scannedBytes)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Arbre du dossier, ou nil si l'analyse a été annulée.
    func scan(_ url: URL) -> DiskNode? {
        let root = directory(url, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, depth: 0)
        guard !isCancelled else { return nil }
        root.rootURL = url
        return root
    }

    private func directory(_ url: URL, name: String, depth: Int) -> DiskNode {
        if depth > 0, let cached = reuse[url.standardizedFileURL.path] {
            cached.parent = nil
            add(files: cached.count, bytes: cached.size)
            return cached
        }
        let node = DiskNode(name: name)
        node.children = []
        var files: [DiskNode] = []
        var folders: [URL] = []
        var bytes: Int64 = 0
        // Les valeurs de ressources sont autolibérées : le bassin est vidé à chaque dossier.
        autoreleasepool {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.keys, options: []) else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: Self.keySet)
                if values?.isDirectory == true, values?.isSymbolicLink != true {
                    // Pas de traversée des points de montage (autres volumes).
                    if values?.isVolume != true { folders.append(entry) }
                    continue
                }
                let file = DiskNode(name: entry.lastPathComponent)
                file.size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                file.count = 1
                file.modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                file.category = .of(file.name)
                bytes += file.size
                files.append(file)
            }
        }
        add(files: files.count, bytes: bytes)

        var subfolders: [DiskNode]
        if depth < 2, folders.count > 1 {
            var results = [DiskNode?](repeating: nil, count: folders.count)
            let resultsLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: folders.count) { index in
                guard !isCancelled else { return }
                let child = directory(folders[index], name: folders[index].lastPathComponent, depth: depth + 1)
                resultsLock.lock()
                results[index] = child
                resultsLock.unlock()
            }
            subfolders = results.compactMap { $0 }
        } else {
            subfolders = []
            for folder in folders {
                if isCancelled { break }
                subfolders.append(directory(folder, name: folder.lastPathComponent, depth: depth + 1))
            }
        }

        if files.count > Self.keptFilesPerFolder {
            files.sort { $0.size > $1.size }
            let rest = files[Self.keptFilesPerFolder...]
            let group = DiskNode(name: "\(rest.count) autres fichiers")
            group.isAggregate = true
            var sizes = [Int64](repeating: 0, count: DiskCategory.allCases.count)
            for file in rest {
                group.size += file.size
                group.modified = max(group.modified, file.modified)
                sizes[file.category.rawValue] += file.size
            }
            group.count = rest.count
            group.categorySizes = sizes
            group.category = DiskCategory(rawValue: sizes.indices.max { sizes[$0] < sizes[$1] } ?? 7) ?? .other
            files = Array(files.prefix(Self.keptFilesPerFolder)) + [group]
        }
        let children = subfolders + files
        for child in children { child.parent = node }
        node.children = children
        node.finish()
        return node
    }

    private func add(files: Int, bytes: Int64) {
        lock.lock()
        scannedFiles += files
        scannedBytes += bytes
        lock.unlock()
    }
}
