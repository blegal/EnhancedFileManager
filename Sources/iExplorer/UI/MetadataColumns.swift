import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Colonnes facultatives de la liste détaillée : création, EXIF, médias, documents.
/// Clic droit sur l'en-tête des colonnes pour les afficher ou les masquer.
enum MetadataColumn: String, CaseIterable {
    case created, shotDate, dimensions, camera, duration, authors, pages

    var title: String {
        switch self {
        case .created: "Créé le"
        case .shotDate: "Prise de vue"
        case .dimensions: "Dimensions"
        case .camera: "Appareil"
        case .duration: "Durée"
        case .authors: "Auteurs"
        case .pages: "Pages"
        }
    }

    var width: CGFloat {
        switch self {
        case .created, .shotDate: 128
        case .dimensions: 90
        case .camera: 130
        case .duration, .pages: 60
        case .authors: 140
        }
    }

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("meta." + rawValue) }

    init?(identifier: NSUserInterfaceItemIdentifier) {
        guard identifier.rawValue.hasPrefix("meta.") else { return nil }
        self.init(rawValue: String(identifier.rawValue.dropFirst(5)))
    }

    static let visibilityChanged = Notification.Name("MetadataColumnsChanged")

    static var visible: Set<MetadataColumn> {
        get { Set((UserDefaults.standard.stringArray(forKey: "metadataColumns") ?? []).compactMap(MetadataColumn.init(rawValue:))) }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "metadataColumns")
            NotificationCenter.default.post(name: visibilityChanged, object: nil)
        }
    }
}

/// Métadonnées lues en arrière-plan (Spotlight, puis l'image elle-même), gardées tant que le fichier ne change pas.
final class MetadataCache {
    static let shared = MetadataCache()

    private struct Entry {
        let modified: Date?
        let values: [MetadataColumn: String]
    }

    private var entries: [String: Entry] = [:]
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "iExplorer.metadata", qos: .utility, attributes: .concurrent)

    /// Valeur en cache, ou `nil` en lançant sa lecture ; `loaded` est appelé (fil principal) quand elle arrive.
    func value(_ column: MetadataColumn, for item: FileItem, loaded: @escaping (URL) -> Void) -> String? {
        let url = item.url
        guard url.isFileURL, !item.isNavigableDirectory || column == .created else { return "" }
        let key = url.path
        if let entry = entries[key], entry.modified == item.modificationDate { return entry.values[column] ?? "" }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        let modified = item.modificationDate
        queue.async { [weak self] in
            let values = Self.read(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(key)
                self.entries[key] = Entry(modified: modified, values: values)
                if self.entries.count > 20_000 { self.entries.removeAll() }
                loaded(url)
            }
        }
        return nil
    }

    private static func read(_ url: URL) -> [MetadataColumn: String] {
        var values: [MetadataColumn: String] = [:]
        if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
            values[.created] = Format.dateFormatter.string(from: created)
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let isImage = type?.conforms(to: .image) == true
        let isMedia = type?.conforms(to: .audiovisualContent) == true

        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            func attribute(_ name: CFString) -> Any? { MDItemCopyAttribute(item, name) }
            if isImage || isMedia, let date = attribute(kMDItemContentCreationDate) as? Date {
                values[.shotDate] = Format.dateFormatter.string(from: date)
            }
            if let width = attribute(kMDItemPixelWidth) as? Int, let height = attribute(kMDItemPixelHeight) as? Int, width > 0 {
                values[.dimensions] = "\(width) × \(height)"
            }
            values[.camera] = camera(make: attribute(kMDItemAcquisitionMake) as? String, model: attribute(kMDItemAcquisitionModel) as? String)
            if let seconds = attribute(kMDItemDurationSeconds) as? Double, seconds > 0 { values[.duration] = duration(seconds) }
            if let authors = attribute(kMDItemAuthors) as? [String], !authors.isEmpty { values[.authors] = authors.joined(separator: ", ") }
            if let pages = attribute(kMDItemNumberOfPages) as? Int, pages > 0 { values[.pages] = "\(pages)" }
        }

        // Volumes non indexés par Spotlight : on lit l'image directement.
        if isImage, values[.dimensions] == nil || values[.shotDate] == nil,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if values[.dimensions] == nil, let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                values[.dimensions] = "\(width) × \(height)"
            }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            if values[.shotDate] == nil, let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String, let date = exifFormatter.date(from: text) {
                values[.shotDate] = Format.dateFormatter.string(from: date)
            }
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            if values[.camera] == nil {
                values[.camera] = camera(make: tiff?[kCGImagePropertyTIFFMake] as? String, model: tiff?[kCGImagePropertyTIFFModel] as? String)
            }
        }
        if values[.duration] == nil, isMedia, let seconds = mediaDuration(url), seconds > 0 {
            values[.duration] = duration(seconds)
        }
        if values[.pages] == nil, type?.conforms(to: .pdf) == true, let document = CGPDFDocument(url as CFURL) {
            values[.pages] = "\(document.numberOfPages)"
        }
        return values
    }

    private final class Box: @unchecked Sendable { var seconds: Double? }

    /// Durée lue dans le fichier lui-même (hors Spotlight) ; on est déjà sur une file d'arrière-plan.
    private static func mediaDuration(_ url: URL) -> Double? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.seconds = try? await AVURLAsset(url: url).load(.duration).seconds
            done.signal()
        }
        return done.wait(timeout: .now() + 5) == .success ? box.seconds : nil
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// « Apple iPhone 15 Pro » devient « iPhone 15 Pro » : la marque n'est ajoutée que si le modèle ne la contient pas.
    private static func camera(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        if make.isEmpty || model.lowercased().contains(make.lowercased().split(separator: " ").first ?? "") || make == "Apple" { return model }
        return "\(make) \(model)"
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

extension PanelViewController {
    func addMetadataColumns() {
        let visible = MetadataColumn.visible
        for column in MetadataColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 50
            tableColumn.isHidden = !visible.contains(column)
            tableView.addTableColumn(tableColumn)
        }
        let menu = NSMenu()
        menu.delegate = MetadataColumnMenu.shared
        tableView.headerView?.menu = menu
        NotificationCenter.default.addObserver(forName: MetadataColumn.visibilityChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            applyViewMode()
            tableView.sizeToFit()
        }
    }

    func metadataText(_ column: MetadataColumn, for item: FileItem) -> String {
        MetadataCache.shared.value(column, for: item) { [weak self] url in self?.metadataLoaded(url) } ?? ""
    }

    private func metadataLoaded(_ url: URL) {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        let row = tableRow(forItem: index)
        let columns = IndexSet(MetadataColumn.allCases.map { tableView.column(withIdentifier: $0.identifier) }.filter { $0 >= 0 })
        guard row >= 0, row < tableView.numberOfRows, !columns.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: columns)
    }
}

/// Menu de l'en-tête des colonnes : une case par colonne facultative.
private final class MetadataColumnMenu: NSObject, NSMenuDelegate {
    static let shared = MetadataColumnMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Colonnes"))
        let visible = MetadataColumn.visible
        for column in MetadataColumn.allCases {
            let item = NSMenuItem(title: column.title, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = visible.contains(column) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = MetadataColumn(rawValue: raw) else { return }
        var visible = MetadataColumn.visible
        if visible.contains(column) { visible.remove(column) } else { visible.insert(column) }
        MetadataColumn.visible = visible
    }
}
