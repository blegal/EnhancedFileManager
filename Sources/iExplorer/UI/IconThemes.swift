import AppKit
import UniformTypeIdentifiers

/// Catégories d'icônes communes à tous les thèmes.
enum IconKind: Hashable {
    case folder, documents, images, downloads, desktop, music, movies, applications
    case swift, code, pdf, image, archive, markdown, text, audio, video, generic

    var isFolder: Bool {
        switch self {
        case .folder, .documents, .images, .downloads, .desktop, .music, .movies, .applications: true
        default: false
        }
    }

    /// Pictogramme dessiné sur le dossier ou la page.
    var glyph: String? {
        switch self {
        case .folder, .generic: nil
        case .documents, .text: "docs"
        case .images: "images"
        case .downloads: "download"
        case .desktop: "desktop"
        case .music, .audio: "audio"
        case .movies, .video: "video"
        case .applications: "apps"
        case .swift: "swift"
        case .code: "code"
        case .pdf: "pdf"
        case .image: "jpg"
        case .archive: "zip"
        case .markdown: "mdin"
        }
    }

    static func of(_ item: FileItem) -> IconKind {
        if item.isNavigableDirectory { return folderKind(item.url) }
        let ext = item.url.pathExtension.lowercased()
        if ext == "swift" { return .swift }
        if ["md", "markdown", "mdown"].contains(ext) { return .markdown }
        if FileOperationCenter.isArchive(item.url) { return .archive }
        guard let type = UTType(filenameExtension: ext) else { return .generic }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || ["json", "yaml", "yml", "xml", "html", "css", "toml"].contains(ext) { return .code }
        if type.conforms(to: .text) { return .text }
        if type.conforms(to: .archive) { return .archive }
        return .generic
    }

    private static let specialFolders: [String: IconKind] = {
        let fm = FileManager.default
        var map: [String: IconKind] = ["/Applications": .applications]
        let pairs: [(FileManager.SearchPathDirectory, IconKind)] = [
            (.documentDirectory, .documents), (.picturesDirectory, .images), (.downloadsDirectory, .downloads),
            (.desktopDirectory, .desktop), (.musicDirectory, .music), (.moviesDirectory, .movies), (.applicationDirectory, .applications),
        ]
        for (directory, kind) in pairs {
            if let url = fm.urls(for: directory, in: .userDomainMask).first { map[url.standardizedFileURL.path] = kind }
        }
        return map
    }()

    private static func folderKind(_ url: URL) -> IconKind {
        url.isRemote ? .folder : specialFolders[url.standardizedFileURL.path] ?? .folder
    }
}

/// Les thèmes d'icônes. Dessins vectoriels originaux inspirés des jeux open source cités
/// (Material Icon Theme, Catppuccin, Seti, Lucide, Phosphor, Fluent, vscode-icons, Tabler/Nord, Papirus, Dracula,
/// Candy Icons, Nordic, WhiteSur).
enum IconTheme: Int, CaseIterable {
    case system, material, catppuccin, seti, thin, duotone, fluent, badges, nord, papirus, dracula
    case candy, steel, sur

    static let changed = Notification.Name("IconThemeChanged")

    static var current: IconTheme {
        get { IconTheme(rawValue: UserDefaults.standard.integer(forKey: "iconTheme")) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "iconTheme")
            IconThemeRenderer.clearCaches()
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    var title: String {
        switch self {
        case .system: "Système (macOS)"
        case .material: "Matériau coloré"
        case .catppuccin: "Catppuccin pastel"
        case .seti: "Seti minimal"
        case .thin: "Trait fin"
        case .duotone: "Duotone"
        case .fluent: "Fluent doux"
        case .badges: "Badges d’extension"
        case .nord: "Nord givré"
        case .papirus: "Papirus plat"
        case .dracula: "Néon Dracula"
        case .candy: "Bonbons dégradés"
        case .steel: "Acier doux"
        case .sur: "Bleu Sur"
        }
    }

    /// Icône du thème pour un élément ; `nil` pour garder l'icône système (applications, paquets…).
    func icon(for item: FileItem) -> NSImage? {
        guard self != .system, !item.isPackage else { return nil }
        let kind = IconKind.of(item)
        let label = self == .badges && !kind.isFolder ? IconThemeRenderer.badgeLabel(for: item.url, kind: kind) : nil
        return IconThemeRenderer.image(theme: self, kind: kind, label: label)
    }
}

/// Rendu : chaque icône est un SVG 24×24 (mis en cache) dessiné selon l'apparence claire ou sombre.
enum IconThemeRenderer {
    static var cache: [String: NSImage] = [:]

    static func clearCaches() {
        cache.removeAll()
        imageCache.removeAll()
    }

    private static var imageCache: [String: NSImage] = [:]

    /// Une seule image (dynamique clair / sombre) par thème, type et étiquette.
    static func image(theme: IconTheme, kind: IconKind, label: String?) -> NSImage {
        let key = "\(theme.rawValue)|\(kind)|\(label ?? "")"
        if let cached = imageCache[key] { return cached }
        let image = makeImage(theme: theme, kind: kind, label: label)
        imageCache[key] = image
        return image
    }

    private static func makeImage(theme: IconTheme, kind: IconKind, label: String?) -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            svgImage(theme: theme, kind: kind, dark: dark).draw(in: rect)
            if let label { drawBadgeLabel(label, in: rect, kind: kind) }
            return true
        }
        image.accessibilityDescription = kind.isFolder ? "Dossier" : label
        return image
    }

    private static func svgImage(theme: IconTheme, kind: IconKind, dark: Bool) -> NSImage {
        let key = "\(theme.rawValue)-\(kind)-\(dark)"
        if let cached = cache[key] { return cached }
        let body = SVG.icon(theme: theme, kind: kind, dark: dark)
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">"## + body + "</svg>"
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        cache[key] = image
        return image
    }

    static func badgeLabel(for url: URL, kind: IconKind) -> String {
        let ext = url.pathExtension.uppercased()
        if !ext.isEmpty { return String(ext.prefix(4)) }
        return kind == .generic ? "" : "•"
    }

    private static func drawBadgeLabel(_ label: String, in rect: NSRect, kind: IconKind) {
        guard !label.isEmpty else { return }
        let scale = rect.width / 24
        let size = (label.count > 3 ? 5.0 : label.count > 2 ? 6.6 : 7.8) * scale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let bounds = text.size()
        text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.minY + 12 * scale - bounds.height / 2))
    }
}

// MARK: - Dessins (portage des croquis)

private enum SVG {
    static let folder = "M2 6.5A1.5 1.5 0 0 1 3.5 5h5.2l2 2.2h9.8A1.5 1.5 0 0 1 22 8.7v9.8a1.5 1.5 0 0 1-1.5 1.5h-17A1.5 1.5 0 0 1 2 18.5z"
    static let folderFront = "M2 10a1.5 1.5 0 0 1 1.5-1.5h17A1.5 1.5 0 0 1 22 10v8.5a1.5 1.5 0 0 1-1.5 1.5h-17A1.5 1.5 0 0 1 2 18.5z"
    static let page = "M6.5 2.5H14l5 5v13a1 1 0 0 1-1 1H6.5a1 1 0 0 1-1-1v-17a1 1 0 0 1 1-1z"
    static let pageFold = "M14 2.5v4a1 1 0 0 0 1 1h4"
    static let swiftBird = "M20 15.2c.9-2.9-.4-6.6-3.9-9.4 1.6 2.3 2.1 4.8 1.3 6.6C14.9 10.9 11.5 8.3 9 5.6c1.4 2 3.2 3.8 5 5.3-2.2-1.1-5-3-7.6-5.2 2.4 3.6 5.7 6.6 9 8.3-2.4 1-5.6.9-9-.5 2.7 2.5 6.4 3.8 9.9 3 1.7-.4 2.8.1 3.7 1.2.4-.9.3-1.6 0-2.5z"

    static func glyphBody(_ key: String, color: String) -> String {
        switch key {
        case "docs": return ##"<path d="M6 7h12M6 12h12M6 17h8"/>"##
        case "images": return ##"<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="15.5" cy="9.5" r="1.5"/><path d="M3 17l5-5 4 4 2.5-2.5L21 19"/>"##
        case "jpg": return ##"<circle cx="9" cy="8" r="2.2"/><path d="M3 19l6-6 4 4 3-3 5 5"/>"##
        case "swift": return ##"<path fill="\##(color)" stroke="none" d="\##(swiftBird)"/>"##
        case "pdf": return ##"<path d="M5.5 18.5c2.5-1.6 4.4-4.6 5.4-8 .5-1.9.4-4.5-.9-4.5s-1.1 2.6-.4 4.4c1.2 3.2 3.6 5.7 7.2 6.5 1.7.4 2.2-1.2.6-1.5-2.8-.5-7.6.8-10.4 2.5"/>"##
        case "zip": return ##"<path d="M12 3v1.5M12 6.5V8M12 10v1.5"/><rect x="9.5" y="13" width="5" height="6" rx="1"/>"##
        case "md": return ##"<rect x="2.5" y="6" width="19" height="12" rx="2"/><path d="M6 15V9l2.5 3L11 9v6M16.5 9v6M14 12.5l2.5 2.5 2.5-2.5"/>"##
        case "mdin": return ##"<path d="M5 16V8l3 3.6L11 8v8M17 8v8M14 13l3 3 3-3"/>"##
        case "audio": return ##"<path d="M9 18V6l10-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="16.5" cy="16" r="2.5"/>"##
        case "video": return ##"<rect x="3" y="6" width="12.5" height="12" rx="2"/><path d="M15.5 10.5 21 7.5v9l-5.5-3"/>"##
        case "code": return ##"<path d="M8 7.5 3.5 12 8 16.5M16 7.5l4.5 4.5-4.5 4.5M13.6 5.5l-3.2 13"/>"##
        case "download": return ##"<path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/>"##
        case "desktop": return ##"<rect x="3" y="4" width="18" height="12" rx="1.5"/><path d="M8 20h8M12 16v4"/>"##
        case "apps": return ##"<rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/>"##
        default: return ""
        }
    }

    /// Pictogramme `key` en `color`, translaté et mis à l'échelle (comme `g()` dans les croquis).
    static func glyph(_ key: String?, _ color: String, _ x: Double, _ y: Double, _ s: Double, _ sw: Double) -> String {
        guard let key else { return "" }
        return ##"<g transform="translate(\##(x) \##(y)) scale(\##(s))" fill="none" stroke="\##(color)" stroke-width="\##(sw)" stroke-linecap="round" stroke-linejoin="round">\##(glyphBody(key, color: color))</g>"##
    }

    static func outlinedFolder(_ c: String, _ kind: IconKind, glyphColor: String? = nil, sw: Double, fillOpacity: Double = 0, fill: String? = nil) -> String {
        ##"<path d="\##(folder)" fill="\##(fill ?? c)" fill-opacity="\##(fillOpacity)" stroke="\##(c)" stroke-width="\##(sw)" stroke-linejoin="round"/>"##
            + glyph(kind.glyph, glyphColor ?? c, 7.2, 9.2, 0.4, sw / 0.55)
    }

    static func outlinedPage(_ c: String, _ kind: IconKind, glyphColor: String? = nil, sw: Double, fillOpacity: Double = 0, fill: String? = nil) -> String {
        ##"<path d="\##(page)" fill="\##(fill ?? c)" fill-opacity="\##(fillOpacity)" stroke="\##(c)" stroke-width="\##(sw)" stroke-linejoin="round"/><path d="\##(pageFold)" fill="none" stroke="\##(c)" stroke-width="\##(sw)" stroke-linejoin="round"/>"##
            + glyph(kind.glyph, glyphColor ?? c, 7.2, 10.2, 0.4, sw / 0.55)
    }

    static func gradient(_ id: String, _ a: String, _ b: String, diagonal: Bool = false) -> String {
        ##"<linearGradient id="\##(id)" x1="0" y1="0" x2="\##(diagonal ? 1 : 0)" y2="1"><stop offset="0" stop-color="\##(a)"/><stop offset="1" stop-color="\##(b)"/></linearGradient>"##
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func icon(theme: IconTheme, kind: IconKind, dark d: Bool) -> String {
        switch theme {
        case .system:
            return ""

        case .material:
            let folders: [IconKind: (String, String)] = [
                .folder: ("#90A4AE", ""), .documents: ("#42A5F5", "#1565C0"), .images: ("#4DB6AC", "#00695C"),
                .downloads: ("#66BB6A", "#1B5E20"), .desktop: ("#7986CB", "#283593"), .music: ("#EF5350", "#B71C1C"),
                .movies: ("#FF7043", "#BF360C"), .applications: ("#AB47BC", "#4A148C"),
            ]
            if let (fill, glyphColor) = folders[kind] {
                return ##"<path d="\##(folder)" fill="\##(fill)"/>"## + (glyphColor.isEmpty ? "" : glyph(kind.glyph, glyphColor, 9.8, 9.6, 0.5, 3))
            }
            switch kind {
            case .swift: return glyph("swift", "#FF7043", 0, 0, 1, 1)
            case .image: return ##"<rect x="2.5" y="4.5" width="19" height="15" rx="2" fill="#26A69A"/><circle cx="16" cy="9" r="1.8" fill="#fff"/><path d="M4 18l5-6 4 4 2.5-2.5L20 18z" fill="#fff" opacity=".9"/>"##
            case .archive: return ##"<rect x="4" y="2.5" width="16" height="19" rx="2" fill="#AFB42B"/>"## + glyph("zip", "#fff", 4, 1, 0.67, 2.6)
            case .markdown: return ##"<rect x="1.5" y="5" width="21" height="14" rx="2.5" fill="#42A5F5"/>"## + glyph("mdin", "#fff", 0, 0, 1, 2)
            default:
                let colors: [IconKind: String] = [.pdf: "#EF5350", .code: "#7E57C2", .text: "#78909C", .audio: "#EC407A", .video: "#FF7043", .generic: "#B0BEC5"]
                return ##"<path d="\##(page)" fill="\##(colors[kind] ?? "#B0BEC5")"/>"## + glyph(kind.glyph, "#fff", 6.5, 9, 0.46, 2.8)
            }

        case .catppuccin:
            let c = d ? (blue: "#89b4fa", mauve: "#cba6f7", peach: "#fab387", red: "#f38ba8", green: "#a6e3a1", yellow: "#f9e2af", pink: "#f5c2e7", teal: "#94e2d5", overlay: "#9399b2")
                      : (blue: "#1e66f5", mauve: "#8839ef", peach: "#fe640b", red: "#d20f39", green: "#40a02b", yellow: "#df8e1d", pink: "#ea76cb", teal: "#179299", overlay: "#7c7f93")
            let colors: [IconKind: String] = [
                .folder: c.overlay, .documents: c.blue, .images: c.green, .downloads: c.teal, .desktop: c.mauve, .music: c.pink,
                .movies: c.peach, .applications: c.mauve, .swift: c.peach, .code: c.mauve, .pdf: c.red, .image: c.mauve,
                .archive: c.yellow, .markdown: c.blue, .text: c.overlay, .audio: c.pink, .video: c.peach, .generic: c.overlay,
            ]
            let color = colors[kind] ?? c.overlay
            if kind.isFolder { return outlinedFolder(color, kind, sw: 1.6, fillOpacity: 0.14) }
            switch kind {
            case .swift: return glyph("swift", color, 0, 0, 1, 1)
            case .image: return glyph("images", color, 0, 0, 1, 1.7)
            case .markdown: return glyph("md", color, 0, 0, 1, 1.7)
            default: return outlinedPage(color, kind, sw: 1.6, fillOpacity: 0.12)
            }

        case .seti:
            let grey = d ? "#6d8086" : "#8a979c"
            let background = d ? "#1e1e1e" : "#ffffff"
            let shape: String
            if kind.isFolder {
                shape = ##"<path d="\##(folder)" fill="\##(grey)"/>"## + glyph(kind.glyph, background, 7.4, 9.4, 0.38, 3.4)
            } else if kind == .generic || kind == .text {
                shape = outlinedPage(grey, kind, sw: 1.8)
            } else {
                let colors: [IconKind: String] = [.swift: "#e37933", .code: "#8dc149", .pdf: "#cc3e44", .image: "#a074c4",
                                                  .archive: d ? "#cbcb41" : "#a3a31c", .markdown: "#519aba", .audio: "#e37933", .video: "#cc3e44"]
                shape = glyph(kind.glyph, colors[kind] ?? grey, 0, 0, 1, 2.4)
            }
            return ##"<g transform="translate(2.4 2.4) scale(.8)">\##(shape)</g>"##

        case .thin:
            let c = d ? "#d1d1d6" : "#3a3a3c"
            return kind.isFolder ? outlinedFolder(c, kind, sw: 1.5) : outlinedPage(c, kind, sw: 1.5)

        case .duotone:
            let c = d ? "#b3a1ff" : "#6a4cf0"
            return kind.isFolder ? outlinedFolder(c, kind, sw: 1.7, fillOpacity: 0.22) : outlinedPage(c, kind, sw: 1.7, fillOpacity: 0.22)

        case .fluent:
            let badges: [IconKind: (String, String)] = [
                .swift: ("#ffa66b", "#e8541c"), .code: ("#a78bfa", "#6d28d9"), .pdf: ("#ff7a7a", "#c4262e"), .image: ("#4fd1b8", "#038387"),
                .archive: ("#ffd56b", "#b88a00"), .markdown: ("#62b4ff", "#0f6cbd"), .text: ("#9ca3af", "#4b5563"),
                .audio: ("#f472b6", "#be185d"), .video: ("#fb923c", "#c2410c"),
                .documents: ("#62b4ff", "#0f6cbd"), .images: ("#6fd690", "#107c10"), .downloads: ("#34d399", "#047857"),
                .desktop: ("#818cf8", "#4338ca"), .music: ("#f472b6", "#be185d"), .movies: ("#fb923c", "#c2410c"), .applications: ("#a78bfa", "#6d28d9"),
            ]
            func badge(_ x: Double, _ y: Double) -> String {
                guard let (a, b) = badges[kind] else { return "" }
                return "<defs>" + gradient("badge", a, b, diagonal: true) + ##"</defs><rect x="\##(x)" y="\##(y)" width="10.5" height="10.5" rx="2.6" fill="url(#badge)"/>"##
                    + glyph(kind.glyph, "#fff", x + 1.3, y + 1.3, 0.33, 3)
            }
            if kind.isFolder {
                return "<defs>" + gradient("back", "#f0b21a", "#d99400") + gradient("front", "#ffdc73", "#ffc233") + "</defs>"
                    + ##"<path d="\##(folder)" fill="url(#back)"/><path d="\##(folderFront)" fill="url(#front)"/>"## + badge(12.5, 12.5)
            }
            let edge = d ? "#a19f9d" : "#c8c6c4"
            return "<defs>" + gradient("paper", "#ffffff", "#ecebea") + "</defs>"
                + ##"<path d="\##(page)" fill="url(#paper)" stroke="\##(edge)" stroke-width=".8"/><path d="\##(pageFold)" fill="none" stroke="\##(edge)" stroke-width=".8"/>"##
                + badge(3, 11.5)

        case .badges:
            if kind.isFolder {
                return ##"<path d="\##(folder)" fill="#4f9fe0"/><path d="\##(folderFront)" fill="#7dbff2"/>"## + glyph(kind.glyph, "#2f7fc4", 7.4, 10.2, 0.38, 3.2)
            }
            let colors: [IconKind: String] = [.swift: "#F05138", .code: "#6E56CF", .pdf: "#D93025", .image: "#1E9E6A", .archive: "#8D6E63",
                                              .markdown: "#3B6FD9", .text: "#607D8B", .audio: "#D6336C", .video: "#E8590C", .generic: "#8E8E93"]
            return ##"<rect x="2.5" y="3.5" width="19" height="17" rx="4.5" fill="\##(colors[kind] ?? "#8E8E93")"/><rect x="2.5" y="3.5" width="19" height="8" rx="4.5" fill="#fff" opacity=".12"/>"##

        case .nord:
            let frost = d ? (folder: "#81a1c1", documents: "#88c0d0", images: "#8fbcbb", page: "#81a1c1")
                          : (folder: "#5e81ac", documents: "#4c8fa6", images: "#4f8f8c", page: "#5e81ac")
            let aurora: [IconKind: String] = [.swift: "#d08770", .code: "#b48ead", .pdf: "#bf616a", .image: "#b48ead", .archive: d ? "#ebcb8b" : "#b98a2e",
                                              .markdown: d ? "#88c0d0" : "#4c8fa6", .audio: "#d08770", .video: "#bf616a", .text: frost.page, .generic: frost.page]
            if kind.isFolder {
                let color = kind == .documents ? frost.documents : kind == .images ? frost.images : frost.folder
                return outlinedFolder(color, kind, sw: 1.4, fillOpacity: 0.3)
            }
            return outlinedPage(frost.page, kind, glyphColor: aurora[kind], sw: 1.4, fillOpacity: 0.16)

        case .papirus:
            if kind.isFolder {
                return ##"<path d="\##(folder)" fill="#3f6fa8"/><path d="\##(folderFront)" fill="#5294e2"/>"## + glyph(kind.glyph, "#2d5a8f", 7.2, 10.4, 0.4, 3)
            }
            let colors: [IconKind: String] = [.swift: "#f68a2e", .code: "#7e57c2", .pdf: "#d8403b", .image: "#9b59b6", .archive: "#a1887f",
                                              .markdown: "#455a64", .text: "#78909c", .audio: "#e91e63", .video: "#ff7043", .generic: "#90a4ae"]
            return ##"<path d="\##(page)" fill="\##(colors[kind] ?? "#90a4ae")"/><path d="\##(pageFold)z" fill="#fff" opacity=".35"/>"##
                + glyph(kind.glyph, "#fff", 6.9, 9.6, 0.42, 2.8)

        case .dracula:
            let palette: [IconKind: String] = d
                ? [.folder: "#bd93f9", .documents: "#8be9fd", .images: "#50fa7b", .downloads: "#50fa7b", .desktop: "#bd93f9", .music: "#ff79c6",
                   .movies: "#ffb86c", .applications: "#bd93f9", .swift: "#ffb86c", .code: "#bd93f9", .pdf: "#ff5555", .image: "#ff79c6",
                   .archive: "#f1fa8c", .markdown: "#8be9fd", .text: "#f8f8f2", .audio: "#ff79c6", .video: "#ffb86c", .generic: "#6272a4"]
                : [.folder: "#644ac9", .documents: "#036a96", .images: "#14710a", .downloads: "#14710a", .desktop: "#644ac9", .music: "#a3144d",
                   .movies: "#a34d14", .applications: "#644ac9", .swift: "#a34d14", .code: "#644ac9", .pdf: "#cb3a2a", .image: "#a3144d",
                   .archive: "#846e15", .markdown: "#036a96", .text: "#1f1f1f", .audio: "#a3144d", .video: "#a34d14", .generic: "#6c664b"]
            let color = palette[kind] ?? "#6272a4"
            let shape = kind.isFolder ? outlinedFolder(color, kind, sw: 1.6, fillOpacity: 0.12) : outlinedPage(color, kind, sw: 1.6, fillOpacity: 0.1)
            guard d else { return shape }
            // Lueur néon : copie floutée sous le tracé (feMerge n'est pas géré par CoreSVG).
            return ##"<defs><filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="1"/></filter></defs><g filter="url(#glow)" opacity=".85">\##(shape)</g>\##(shape)"##

        case .candy:
            // Dossiers en dégradés acidulés, pictogramme blanc (inspiré de Candy Icons).
            let colors: [IconKind: (String, String)] = [
                .folder: ("#8CDCD3", "#3FB8AC"), .documents: ("#C77DFF", "#8E3BDB"), .images: ("#FFB347", "#FF6A2B"),
                .downloads: ("#FF7EC7", "#E0409C"), .desktop: ("#E2B6F0", "#B37BD3"), .music: ("#A8E66B", "#3FBF6E"),
                .movies: ("#5EDCF5", "#1E8FEF"), .applications: ("#FF8A80", "#F0435A"),
                .swift: ("#FFB347", "#FF5E2B"), .code: ("#C77DFF", "#8E3BDB"), .pdf: ("#FF8A80", "#E8344E"), .image: ("#FFB347", "#FF6A2B"),
                .archive: ("#FFE074", "#F2A922"), .markdown: ("#5EDCF5", "#1E8FEF"), .text: ("#B8C2CC", "#7D8A97"),
                .audio: ("#A8E66B", "#3FBF6E"), .video: ("#5EDCF5", "#1E8FEF"), .generic: ("#C9D1D9", "#8B97A3"),
            ]
            let (light, deep) = colors[kind] ?? ("#C9D1D9", "#8B97A3")
            if kind.isFolder {
                return "<defs>" + gradient("front", light, deep, diagonal: true) + "</defs>"
                    + ##"<path d="\##(folder)" fill="\##(deep)"/><path d="\##(folderFront)" fill="url(#front)"/>"##
                    + glyph(kind.glyph, "#fff", 7.2, 10.4, 0.4, 3.4)
            }
            return "<defs>" + gradient("paper", light, deep, diagonal: true) + "</defs>"
                + ##"<path d="\##(page)" fill="url(#paper)"/><path d="\##(pageFold)z" fill="#fff" opacity=".4"/>"##
                + glyph(kind.glyph, "#fff", 6.9, 9.6, 0.42, 3)

        case .steel:
            // Dossiers plats bleu acier, pictogramme ton sur ton (inspiré de Nordic).
            let back = d ? "#7F96B6" : "#8AA2C2"
            let front = d ? "#93AACB" : "#A3B9D6"
            let ink = d ? "#5F7697" : "#6A83A6"
            if kind.isFolder {
                return ##"<path d="\##(folder)" fill="\##(back)"/><path d="\##(folderFront)" fill="\##(front)"/>"## + glyph(kind.glyph, ink, 7.2, 10.4, 0.4, 3)
            }
            let accents: [IconKind: String] = [.swift: "#C98A6B", .code: "#9C88B8", .pdf: "#BF6F78", .image: "#7FA88E", .archive: "#C2A15E",
                                               .markdown: ink, .audio: "#B888A8", .video: "#C98A6B"]
            return ##"<path d="\##(page)" fill="\##(d ? "#C7D3E3" : "#DCE4EF")"/><path d="\##(pageFold)z" fill="\##(front)"/>"##
                + glyph(kind.glyph, accents[kind] ?? ink, 6.9, 9.6, 0.42, 2.6)

        case .sur:
            // Dossiers bleu vif à onglet, pictogramme blanc (inspiré de WhiteSur / Orchis).
            if kind.isFolder {
                return "<defs>" + gradient("front", "#62B6FA", "#3A8EEA") + "</defs>"
                    + ##"<path d="\##(folder)" fill="#2C78D2"/><path d="\##(folderFront)" fill="url(#front)"/>"##
                    + glyph(kind.glyph, "#fff", 7.2, 10.4, 0.4, 3)
            }
            let colors: [IconKind: String] = [.swift: "#F2742E", .code: "#7B61FF", .pdf: "#E5484D", .image: "#30A46C", .archive: "#B08A3E",
                                              .markdown: "#3A8EEA", .text: "#6B7785", .audio: "#E5487F", .video: "#F2742E", .generic: "#8A96A3"]
            let edge = d ? "#9AA4AF" : "#C9D0D8"
            return ##"<path d="\##(page)" fill="#FFFFFF" stroke="\##(edge)" stroke-width=".8"/><path d="\##(pageFold)" fill="#EEF2F6" stroke="\##(edge)" stroke-width=".8"/>"##
                + glyph(kind.glyph, colors[kind] ?? "#8A96A3", 6.9, 9.6, 0.42, 2.6)
        }
    }
}
