import AppKit

/// Zones de la fenêtre qu'un thème de couleurs peut peindre.
enum ThemeZone { case toolbar, sidebar, header, panel, inspector, terminal }

/// Remplissage d'une zone : couleur, dégradé linéaire (angle CSS) ou verre (flou du fond d'écran).
enum ThemeFill {
    case color(String)
    case gradient(Double, [(String, CGFloat)])
    case glass
}

/// Une variante (claire ou sombre) d'un thème, reprise des croquis.
struct ThemeVariant {
    var window: ThemeFill
    var toolbar: String? = nil
    var sidebar: ThemeFill? = nil
    var panel: String? = nil
    var header: String? = nil
    var inspector: String? = nil
    var text: String
    var secondaryText: String
    var accent: String
    var selectedText = "#FFFFFF"
    var inactiveSelection: String
    var sidebarSelection: String? = nil
    var terminal: String
    var terminalText: String
    var terminalAccent: String? = nil
    var folder: String? = nil
    /// Barre latérale sombre même en apparence claire (elle prend alors les couleurs de la variante sombre).
    var darkSidebar = false
}

enum ColorTheme: Int, CaseIterable {
    case system
    case graphite, slate, sand, ink
    case workbench, atelier, nord, solarized
    case liquidGlass, aurora, grainedPaper, mist
    case dusk, smoke, human, orchis, whiteSur, monochrome, candy, flatRemix

    static let changed = Notification.Name("ColorThemeChanged")

    static var current: ColorTheme {
        get { ColorTheme(rawValue: UserDefaults.standard.integer(forKey: "colorTheme")) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "colorTheme")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    var title: String {
        switch self {
        case .system: "Système (macOS)"
        case .graphite: "Graphite neutre"
        case .slate: "Ardoise bleutée"
        case .sand: "Sable chaud"
        case .ink: "Encre profonde"
        case .workbench: "Établi"
        case .atelier: "Atelier"
        case .nord: "Nord"
        case .solarized: "Solarisé"
        case .liquidGlass: "Verre liquide"
        case .aurora: "Aurore"
        case .grainedPaper: "Papier grainé"
        case .mist: "Brume"
        case .dusk: "Crépuscule"
        case .smoke: "Fumée"
        case .human: "Humain"
        case .orchis: "Orchis"
        case .whiteSur: "WhiteSur"
        case .monochrome: "Monochrome"
        case .candy: "Bonbon"
        case .flatRemix: "Flat Remix violet"
        }
    }

    /// Famille, pour regrouper le menu.
    var family: String? {
        switch self {
        case .system: nil
        case .graphite, .slate, .sand, .ink: "Uni"
        case .workbench, .atelier, .nord, .solarized: "Uni par zones"
        case .liquidGlass, .aurora, .grainedPaper, .mist: "Non uni"
        case .dusk, .smoke, .human, .orchis, .whiteSur, .monochrome, .candy, .flatRemix: "Bureaux libres"
        }
    }

    var hasGrain: Bool { self == .grainedPaper }

    func variant(dark: Bool) -> ThemeVariant? {
        let pair = Self.palettes[self]
        return dark ? pair?.1 : pair?.0
    }

    // MARK: Palettes (clair, sombre)

    private static let palettes: [ColorTheme: (ThemeVariant, ThemeVariant)] = [
        .graphite: (
            ThemeVariant(window: .color("#F5F5F7"), text: "#1D1D1F", secondaryText: "#86868B", accent: "#007AFF", inactiveSelection: "#DCDCE0",
                         sidebarSelection: "#0000001A", terminal: "#E9E9EC", terminalText: "#3A3A3C", folder: "#8E9AAB"),
            ThemeVariant(window: .color("#1E1E20"), text: "#F2F2F4", secondaryText: "#8E8E93", accent: "#0A84FF", inactiveSelection: "#3A3A3D",
                         sidebarSelection: "#FFFFFF1F", terminal: "#171719", terminalText: "#C7C7CC", folder: "#7C8796")),
        .slate: (
            ThemeVariant(window: .color("#EEF1F5"), text: "#1F2A37", secondaryText: "#7A8696", accent: "#3D6B99", inactiveSelection: "#D5DCE5",
                         terminal: "#E3E8EF", terminalText: "#33404F", folder: "#7F9BB8"),
            ThemeVariant(window: .color("#1A2029"), text: "#E6EBF2", secondaryText: "#8592A3", accent: "#7AA7D6", selectedText: "#0F1620",
                         inactiveSelection: "#2E3743", terminal: "#141922", terminalText: "#B8C4D3", folder: "#5F7E9E")),
        .sand: (
            ThemeVariant(window: .color("#F3F0EA"), text: "#2B2822", secondaryText: "#8C857A", accent: "#5B7B3A", inactiveSelection: "#E1DBD0",
                         terminal: "#EAE5DC", terminalText: "#4A443B", folder: "#A39A86"),
            ThemeVariant(window: .color("#211F1B"), text: "#EDE8DF", secondaryText: "#948C7F", accent: "#A3C27E", selectedText: "#1A1D14",
                         inactiveSelection: "#38342D", terminal: "#1A1916", terminalText: "#C9C1B3", folder: "#8A806E")),
        .ink: (
            ThemeVariant(window: .color("#F6F7F9"), text: "#141A26", secondaryText: "#7D8494", accent: "#946200", inactiveSelection: "#DEE1E7",
                         terminal: "#ECEEF2", terminalText: "#2A3140", folder: "#8B93A3"),
            ThemeVariant(window: .color("#0E1320"), text: "#E8ECF4", secondaryText: "#7A849A", accent: "#E3B341", selectedText: "#1A1405",
                         inactiveSelection: "#232B3D", terminal: "#090D17", terminalText: "#B9C2D4", folder: "#4F5D7A")),
        .workbench: (
            ThemeVariant(window: .color("#ECECEE"), toolbar: "#F3F3F5", sidebar: .color("#E4E4E7"), panel: "#FFFFFF", header: "#F7F7F8", inspector: "#F6F6F7",
                         text: "#1C1C1E", secondaryText: "#8A8A8E", accent: "#2A6FDB", inactiveSelection: "#E3E3E6", sidebarSelection: "#0000001C",
                         terminal: "#1F2124", terminalText: "#D4D6DA", terminalAccent: "#7FB0FF", folder: "#6E9BD8"),
            ThemeVariant(window: .color("#232325"), toolbar: "#2A2A2C", sidebar: .color("#202022"), panel: "#1A1A1C", header: "#222224", inspector: "#1F1F21",
                         text: "#F0F0F2", secondaryText: "#8D8D92", accent: "#4C8DF6", inactiveSelection: "#38383B", sidebarSelection: "#FFFFFF1C",
                         terminal: "#111113", terminalText: "#C8CACE", terminalAccent: "#7FB0FF", folder: "#5B82BD")),
        .atelier: (
            ThemeVariant(window: .color("#E7E2DC"), toolbar: "#F1EEEA", sidebar: .color("#E7E2DC"), panel: "#FCFBFA", header: "#F5F3F0", inspector: "#F3F0EC",
                         text: "#26221E", secondaryText: "#8D847A", accent: "#1F6F78", inactiveSelection: "#E6E1DA", sidebarSelection: "#26221E17",
                         terminal: "#2A2622", terminalText: "#DCD4CA", terminalAccent: "#6CC3CC", folder: "#9C8F80"),
            ThemeVariant(window: .color("#2A2623"), toolbar: "#262220", sidebar: .color("#2A2623"), panel: "#1A1817", header: "#211F1D", inspector: "#1F1D1B",
                         text: "#EEE8E1", secondaryText: "#9A9086", accent: "#4FB3BF", selectedText: "#0D1E20", inactiveSelection: "#3A3531",
                         sidebarSelection: "#FFFFFF1A", terminal: "#121110", terminalText: "#CFC6BB", terminalAccent: "#6CC3CC", folder: "#7D7166")),
        .nord: (
            ThemeVariant(window: .color("#E5E9F0"), toolbar: "#D8DEE9", sidebar: .color("#E5E9F0"), panel: "#ECEFF4", header: "#E5E9F0", inspector: "#E5E9F0",
                         text: "#2E3440", secondaryText: "#6B7489", accent: "#5E81AC", inactiveSelection: "#D8DEE9",
                         terminal: "#2E3440", terminalText: "#D8DEE9", terminalAccent: "#88C0D0", folder: "#81A1C1"),
            ThemeVariant(window: .color("#3B4252"), toolbar: "#3B4252", sidebar: .color("#353B49"), panel: "#2E3440", header: "#323946", inspector: "#323946",
                         text: "#ECEFF4", secondaryText: "#8C96AA", accent: "#88C0D0", selectedText: "#1F2530", inactiveSelection: "#434C5E",
                         terminal: "#242933", terminalText: "#D8DEE9", terminalAccent: "#A3BE8C", folder: "#81A1C1")),
        .solarized: (
            ThemeVariant(window: .color("#EEE8D5"), toolbar: "#EEE8D5", sidebar: .color("#E8E1CB"), panel: "#FDF6E3", header: "#F5EEDA", inspector: "#F5EEDA",
                         text: "#3F4F55", secondaryText: "#93A1A1", accent: "#268BD2", inactiveSelection: "#E6DFC8",
                         terminal: "#002B36", terminalText: "#93A1A1", terminalAccent: "#859900", folder: "#B58900"),
            ThemeVariant(window: .color("#073642"), toolbar: "#073642", sidebar: .color("#06303B"), panel: "#002B36", header: "#03313D", inspector: "#03313D",
                         text: "#C6D0D0", secondaryText: "#6E8A90", accent: "#268BD2", inactiveSelection: "#0E4250",
                         terminal: "#00212B", terminalText: "#93A1A1", terminalAccent: "#859900", folder: "#B58900")),
        .liquidGlass: (
            ThemeVariant(window: .glass, toolbar: "#FFFFFF8C", sidebar: .color("#FFFFFF52"), panel: "#FFFFFFD9", inspector: "#FFFFFFA6",
                         text: "#14181C", secondaryText: "#5F6B76", accent: "#0071E3", inactiveSelection: "#00000014", sidebarSelection: "#FFFFFF8C",
                         terminal: "#1C2228D9", terminalText: "#D6DEE6", terminalAccent: "#7FC1FF", folder: "#5E95C8"),
            ThemeVariant(window: .glass, toolbar: "#1E232999", sidebar: .color("#1A1F2566"), panel: "#16191DE0", inspector: "#1A1E23B3",
                         text: "#EEF2F6", secondaryText: "#8D99A6", accent: "#0A84FF", inactiveSelection: "#FFFFFF1A", sidebarSelection: "#FFFFFF24",
                         terminal: "#0B0E12E0", terminalText: "#C3CDD8", terminalAccent: "#7FC1FF", folder: "#4F7FAE")),
        .aurora: (
            ThemeVariant(window: .color("#F6F7F7"), toolbar: "#F6F7F7",
                         sidebar: .gradient(172, [("#D3F0E3", 0), ("#CFE6F1", 0.48), ("#E0DCF2", 1)]), panel: "#FFFFFF", header: "#FAFBFB", inspector: "#F8F9F9",
                         text: "#15201D", secondaryText: "#7A8784", accent: "#0F9D7A", inactiveSelection: "#E5E9E8", sidebarSelection: "#FFFFFF99",
                         terminal: "#13201C", terminalText: "#CFE3DC", terminalAccent: "#5EE0B7", folder: "#6FB3A0"),
            ThemeVariant(window: .color("#16191B"), toolbar: "#191C1E",
                         sidebar: .gradient(172, [("#0E2B24", 0), ("#0F2434", 0.5), ("#1D1A31", 1)]), panel: "#131517", header: "#17191B", inspector: "#16181A",
                         text: "#E9F0EE", secondaryText: "#7E8C89", accent: "#34D3A6", selectedText: "#06201A", inactiveSelection: "#2B3032",
                         sidebarSelection: "#FFFFFF1F", terminal: "#0B0E0F", terminalText: "#BFD3CC", terminalAccent: "#5EE0B7", folder: "#3E8C78")),
        .grainedPaper: (
            ThemeVariant(window: .color("#EBEBE7"), toolbar: "#EFEFEB", sidebar: .color("#E4E4DF"), panel: "#F7F7F4", header: "#F1F1ED", inspector: "#F1F1ED",
                         text: "#1F2128", secondaryText: "#83857F", accent: "#233E8B", inactiveSelection: "#E0E0DA", sidebarSelection: "#1F212815",
                         terminal: "#25272C", terminalText: "#D3D4CF", terminalAccent: "#9DB2F0", folder: "#8D93A3"),
            ThemeVariant(window: .color("#1D1D1C"), toolbar: "#21211F", sidebar: .color("#1A1A19"), panel: "#161615", header: "#1C1C1B", inspector: "#1A1A19",
                         text: "#ECEBE6", secondaryText: "#8D8C86", accent: "#8EA6E8", selectedText: "#0F1730", inactiveSelection: "#33332F",
                         sidebarSelection: "#FFFFFF1A", terminal: "#0F0F0E", terminalText: "#C9C8C2", terminalAccent: "#9DB2F0", folder: "#6B7183")),
        .mist: (
            ThemeVariant(window: .gradient(135, [("#DCE6EE", 0), ("#ECEEEC", 0.5), ("#F1E4E2", 1)]), toolbar: "#FFFFFF4D", sidebar: .color("#FFFFFF33"),
                         panel: "#FFFFFFB3", inspector: "#FFFFFF73", text: "#22232A", secondaryText: "#7D7F88", accent: "#B4536A",
                         inactiveSelection: "#22232A12", sidebarSelection: "#FFFFFF99", terminal: "#22232AE6", terminalText: "#E2DCDD",
                         terminalAccent: "#F2A7B8", folder: "#A88A93"),
            ThemeVariant(window: .gradient(135, [("#121A22", 0), ("#17191C", 0.5), ("#221A1E", 1)]), toolbar: "#FFFFFF08", sidebar: .color("#00000026"),
                         panel: "#0E0F1199", inspector: "#FFFFFF08", text: "#EDE9EA", secondaryText: "#8C878B", accent: "#E28AA0", selectedText: "#2A0F17",
                         inactiveSelection: "#FFFFFF1A", sidebarSelection: "#FFFFFF1C", terminal: "#08090BCC", terminalText: "#CFC7C9",
                         terminalAccent: "#F2A7B8", folder: "#8A6F78")),
        // Bureaux libres : inspirés de thèmes GTK / GNOME (Nordic, GNOME Shell, Human d'Ubuntu, Orchis, WhiteSur,
        // Graphite, Candy, Flat Remix). Couleurs reprises à l'œil, sans leurs images.
        .dusk: (
            ThemeVariant(window: .color("#E6EAF0"), toolbar: "#EDF0F4", sidebar: .color("#DFE4EB"), panel: "#F5F7FA", header: "#EEF1F5", inspector: "#EEF1F5",
                         text: "#2A303B", secondaryText: "#7B8494", accent: "#4F6F9E", inactiveSelection: "#DCE2EA", sidebarSelection: "#2A303B14",
                         terminal: "#2F3542", terminalText: "#D5DCE6", terminalAccent: "#A9C1E6", folder: "#7F98BA"),
            ThemeVariant(window: .color("#2F3542"), toolbar: "#333A47", sidebar: .color("#2C323E"), panel: "#353B48", header: "#323845", inspector: "#323845",
                         text: "#E3E8F0", secondaryText: "#8F99AB", accent: "#8AA9D6", selectedText: "#1A2230", inactiveSelection: "#444C5B",
                         sidebarSelection: "#FFFFFF1A", terminal: "#262B35", terminalText: "#C8D0DC", terminalAccent: "#A9C1E6", folder: "#8EA5C4")),
        .smoke: (
            ThemeVariant(window: .glass, toolbar: "#F4F4F4B3", sidebar: .color("#EDEDED99"), panel: "#FAFAFAE6", inspector: "#F4F4F4CC",
                         text: "#1E1E1E", secondaryText: "#6E6E6E", accent: "#3C3C3C", inactiveSelection: "#0000001A", sidebarSelection: "#00000014",
                         terminal: "#1E1E1EE6", terminalText: "#E0E0E0", terminalAccent: "#FFFFFF", folder: "#8A8A8A"),
            ThemeVariant(window: .glass, toolbar: "#1C1C1CB3", sidebar: .color("#141414A6"), panel: "#202020E6", inspector: "#1C1C1CCC",
                         text: "#EDEDED", secondaryText: "#9A9A9A", accent: "#C8C8C8", selectedText: "#151515", inactiveSelection: "#FFFFFF1F",
                         sidebarSelection: "#FFFFFF24", terminal: "#0E0E0EE6", terminalText: "#D0D0D0", terminalAccent: "#FFFFFF", folder: "#9E9E9E")),
        .human: (
            ThemeVariant(window: .color("#E3D9CC"), toolbar: "#DED2C2", sidebar: .gradient(180, [("#EDE5DA", 0), ("#E2D6C6", 1)]), panel: "#F6F1EA",
                         header: "#EDE5DA", inspector: "#EFE8DE", text: "#3C3027", secondaryText: "#8E7F70", accent: "#9C5E3B", inactiveSelection: "#E2D6C6",
                         sidebarSelection: "#9C5E3B26", terminal: "#2E2620", terminalText: "#E8DCCB", terminalAccent: "#E0A16E", folder: "#B98B63"),
            ThemeVariant(window: .color("#2A2420"), toolbar: "#2F2823", sidebar: .color("#26201C"), panel: "#1F1A17", header: "#29231F", inspector: "#25201C",
                         text: "#EEE3D6", secondaryText: "#A39282", accent: "#D08B5B", selectedText: "#24150B", inactiveSelection: "#3D342D",
                         sidebarSelection: "#FFFFFF1A", terminal: "#171310", terminalText: "#DCCFBF", terminalAccent: "#E0A16E", folder: "#B07D55")),
        .orchis: (
            ThemeVariant(window: .color("#F2F2F2"), toolbar: "#F7F7F7", sidebar: .color("#F0F0F0"), panel: "#FFFFFF", header: "#FAFAFA", inspector: "#FAFAFA",
                         text: "#212121", secondaryText: "#7A7A7A", accent: "#1A73E8", inactiveSelection: "#E6E6E6", sidebarSelection: "#1A73E81F",
                         terminal: "#2A2A2A", terminalText: "#DADADA", terminalAccent: "#5FA8FF", folder: "#3C84F7"),
            ThemeVariant(window: .color("#242424"), toolbar: "#2A2A2A", sidebar: .color("#2C2C2C"), panel: "#212121", header: "#262626", inspector: "#262626",
                         text: "#F2F2F2", secondaryText: "#9E9E9E", accent: "#3C84F7", inactiveSelection: "#3A3A3A", sidebarSelection: "#FFFFFF1A",
                         terminal: "#1A1A1A", terminalText: "#D6D6D6", terminalAccent: "#5FA8FF", folder: "#3C84F7")),
        .whiteSur: (
            ThemeVariant(window: .color("#F5F5F5"), toolbar: "#F5F5F5", sidebar: .color("#EBDFE3"), panel: "#FFFFFF", header: "#FFFFFF", inspector: "#FAFAFA",
                         text: "#242424", secondaryText: "#8A8A8E", accent: "#0860F2", inactiveSelection: "#E5E5EA", sidebarSelection: "#00000017",
                         terminal: "#252525", terminalText: "#DDDDDD", terminalAccent: "#5AA9FF", folder: "#3FA2F5"),
            ThemeVariant(window: .color("#2A2A2C"), toolbar: "#2E2E30", sidebar: .color("#2B2730"), panel: "#232325", header: "#28282A", inspector: "#262628",
                         text: "#F0F0F2", secondaryText: "#8E8E93", accent: "#2E8AF6", inactiveSelection: "#3A3A3C", sidebarSelection: "#FFFFFF1C",
                         terminal: "#1A1A1C", terminalText: "#D0D0D4", terminalAccent: "#5AA9FF", folder: "#3FA2F5")),
        .monochrome: (
            ThemeVariant(window: .color("#F2F2F2"), toolbar: "#FAFAFA", sidebar: .color("#F0F0F0"), panel: "#FFFFFF", header: "#FFFFFF", inspector: "#FAFAFA",
                         text: "#1A1A1A", secondaryText: "#7A7A7A", accent: "#2B2B2B", inactiveSelection: "#E4E4E4", sidebarSelection: "#0000001A",
                         terminal: "#FFFFFF", terminalText: "#1A1A1A", terminalAccent: "#2B2B2B", folder: "#4A4A4A", darkSidebar: true),
            ThemeVariant(window: .color("#242424"), toolbar: "#2B2B2B", sidebar: .color("#1A1A1A"), panel: "#2A2A2A", header: "#262626", inspector: "#262626",
                         text: "#EDEDED", secondaryText: "#8F8F8F", accent: "#E6E6E6", selectedText: "#1A1A1A", inactiveSelection: "#3D3D3D",
                         sidebarSelection: "#FFFFFF2E", terminal: "#1A1A1A", terminalText: "#D8D8D8", terminalAccent: "#FFFFFF", folder: "#9A9A9A")),
        .candy: (
            ThemeVariant(window: .color("#F7F6F0"), toolbar: "#F7F6F0", sidebar: .color("#EFEDE5"), panel: "#FAF9F4", header: "#F5F4EE", inspector: "#F5F4EE",
                         text: "#2A2A33", secondaryText: "#8C8A82", accent: "#F0533A", inactiveSelection: "#ECE9DF", sidebarSelection: "#F0533A26",
                         terminal: "#22222C", terminalText: "#E6E4DC", terminalAccent: "#FF8A6B", folder: "#F0533A", darkSidebar: true),
            ThemeVariant(window: .color("#1F1F28"), toolbar: "#232330", sidebar: .color("#1C1C24"), panel: "#26262F", header: "#23232C", inspector: "#23232C",
                         text: "#F2F1EC", secondaryText: "#8F8E99", accent: "#FF6A4D", inactiveSelection: "#3A3A46", sidebarSelection: "#FF6A4D33",
                         terminal: "#16161D", terminalText: "#DAD8E0", terminalAccent: "#FF8A6B", folder: "#FF6A4D")),
        .flatRemix: (
            ThemeVariant(window: .color("#F1EFF7"), toolbar: "#F6F4FB", sidebar: .color("#EAE6F4"), panel: "#FFFFFF", header: "#F8F7FC", inspector: "#F8F7FC",
                         text: "#221A3A", secondaryText: "#7E7697", accent: "#13A89A", inactiveSelection: "#E4E0EF", sidebarSelection: "#13A89A24",
                         terminal: "#2A2048", terminalText: "#E0D9F2", terminalAccent: "#3BE3D4", folder: "#7B5CE0"),
            ThemeVariant(window: .color("#221A3A"), toolbar: "#271E42", sidebar: .color("#1E1734"), panel: "#2A2048", header: "#261D41", inspector: "#261D41",
                         text: "#F0ECFA", secondaryText: "#A096BF", accent: "#2EDCC8", selectedText: "#0E2B28", inactiveSelection: "#3B3060",
                         sidebarSelection: "#FFFFFF1A", terminal: "#1A1430", terminalText: "#D8D0EE", terminalAccent: "#3BE3D4", folder: "#9D7DF2")),
    ]
}

/// Couleurs du thème courant, qui suivent l'apparence claire / sombre.
enum Theme {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func variant(for appearance: NSAppearance = NSAppearance.currentDrawing()) -> ThemeVariant? {
        ColorTheme.current.variant(dark: isDark(appearance))
    }

    private static func dynamic(_ pick: @escaping (ThemeVariant) -> String?, fallback: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            guard let variant = variant(for: appearance), let hex = pick(variant) else { return fallback }
            return NSColor(hex: hex)
        }
    }

    static let accent = dynamic({ $0.accent }, fallback: .controlAccentColor)
    static let text = dynamic({ $0.text }, fallback: .labelColor)
    static let secondaryText = dynamic({ $0.secondaryText }, fallback: .secondaryLabelColor)
    static let inactiveSelection = dynamic({ $0.inactiveSelection }, fallback: .unemphasizedSelectedContentBackgroundColor)

    /// Remplissage de la sélection active ; atténué quand le texte sélectionné est foncé (accent clair).
    static func selectionFill(for appearance: NSAppearance) -> NSColor? {
        guard let variant = variant(for: appearance) else { return nil }
        let accent = NSColor(hex: variant.accent)
        return selectedTextIsLight(variant) ? accent : accent.withAlphaComponent(0.42)
    }

    static func selectedTextIsLight(_ variant: ThemeVariant) -> Bool {
        NSColor(hex: variant.selectedText).luminance > 0.5
    }
}

extension NSColor {
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }
}

// MARK: - Fond d'une zone

/// Fond peint d'une zone (placé sous son contenu). Invisible avec le thème « Système ».
final class ThemeBackgroundView: NSView {
    let zone: ThemeZone
    private var glass: NSVisualEffectView?
    private var observer: NSObjectProtocol?

    init(zone: ThemeZone) {
        self.zone = zone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        observer = NotificationCenter.default.addObserver(forName: ColorTheme.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Insère le fond sous tous les autres éléments de `container`, bord à bord (ou à partir de `top`).
    @discardableResult
    static func install(_ zone: ThemeZone, in container: NSView, top: NSLayoutYAxisAnchor? = nil, bottom: NSLayoutYAxisAnchor? = nil) -> ThemeBackgroundView {
        let view = ThemeBackgroundView(zone: zone)
        container.addSubview(view, positioned: .below, relativeTo: container.subviews.first)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: top ?? container.topAnchor),
            view.bottomAnchor.constraint(equalTo: bottom ?? container.bottomAnchor),
        ])
        return view
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    private func refresh() {
        let variant = Theme.variant(for: effectiveAppearance)
        isHidden = variant == nil
        let wantsGlass: Bool
        if case .glass = variant?.window { wantsGlass = true } else { wantsGlass = false }
        if wantsGlass, glass == nil {
            let effect = NSVisualEffectView()
            effect.blendingMode = .behindWindow
            effect.material = .underWindowBackground
            effect.state = .followsWindowActiveState
            effect.frame = bounds
            effect.autoresizingMask = [.width, .height]
            addSubview(effect, positioned: .below, relativeTo: nil)
            glass = effect
        } else if !wantsGlass, let effect = glass {
            effect.removeFromSuperview()
            glass = nil
        }
        needsDisplay = true
    }

    private func zoneFill(_ variant: ThemeVariant) -> ThemeFill? {
        switch zone {
        case .toolbar: variant.toolbar.map(ThemeFill.color)
        case .sidebar: variant.sidebar
        case .header: (variant.header ?? variant.panel).map(ThemeFill.color)
        case .panel: variant.panel.map(ThemeFill.color)
        case .inspector: (variant.inspector ?? variant.panel).map(ThemeFill.color)
        case .terminal: .color(variant.terminal)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let variant = Theme.variant(for: effectiveAppearance) else { return }
        // Fond de fenêtre (le dégradé est dessiné dans les coordonnées de la fenêtre pour être continu entre zones).
        if zone != .terminal { fill(variant.window, in: bounds, windowWide: true) }
        if let fill = zoneFill(variant) { self.fill(fill, in: bounds, windowWide: false) }
        if ColorTheme.current.hasGrain, zone != .terminal {
            Self.grain.set()
            bounds.fill(using: .sourceOver)
        }
    }

    private func fill(_ fill: ThemeFill, in rect: NSRect, windowWide: Bool) {
        switch fill {
        case .glass:
            break
        case .color(let hex):
            NSColor(hex: hex).setFill()
            rect.fill(using: .sourceOver)
        case .gradient(let cssAngle, let stops):
            let colors = stops.map { NSColor(hex: $0.0) }
            var locations = stops.map(\.1)
            guard let gradient = NSGradient(colors: colors, atLocations: &locations, colorSpace: .sRGB) else { return }
            var area = rect
            if windowWide, let content = window?.contentView {
                area = convert(content.bounds, from: content)
            }
            // Angle CSS (0° = vers le haut, sens horaire) → angle AppKit (repère non retourné).
            gradient.draw(in: area, angle: CGFloat(90 - cssAngle))
        }
    }

    /// Grain très fin (≈ 5 %), texture fixe générée une fois.
    private static let grain: NSColor = {
        let size = 96
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 2,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
        var generator = SystemRandomNumberGenerator()
        for y in 0..<size {
            for x in 0..<size {
                // Valeurs prémultipliées : le gris ne doit pas dépasser l'opacité.
                let alpha = Int.random(in: 0...14, using: &generator)
                var pixel = [Int.random(in: 0...255, using: &generator) * alpha / 255, alpha]
                rep.setPixel(&pixel, atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return NSColor(patternImage: image)
    }()
}

// MARK: - Sélection

/// Ligne de liste qui dessine sa sélection aux couleurs du thème.
final class ThemedRowView: NSTableRowView {
    var isSidebar = false

    override func drawSelection(in dirtyRect: NSRect) {
        guard let variant = Theme.variant(for: effectiveAppearance) else {
            super.drawSelection(in: dirtyRect)
            return
        }
        let color: NSColor
        if isSidebar {
            color = NSColor(hex: variant.sidebarSelection ?? variant.accent + "2E")
        } else if isEmphasized, let fill = Theme.selectionFill(for: effectiveAppearance) {
            color = fill
        } else {
            color = NSColor(hex: variant.inactiveSelection)
        }
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: isSidebar ? 2 : 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        guard let variant = Theme.variant(for: effectiveAppearance) else { return super.interiorBackgroundStyle }
        if isSidebar || !isSelected || !isEmphasized { return .normal }
        return Theme.selectedTextIsLight(variant) ? .emphasized : .normal
    }
}

// MARK: - Menu

extension ColorTheme {
    /// Pastille du menu : fond, panneau et accent de la variante courante.
    func swatch(dark: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 16), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            guard let variant = self.variant(dark: dark) else {
                NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)?.draw(in: rect.insetBy(dx: 5, dy: 0))
                return true
            }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            switch variant.window {
            case .color(let hex): NSColor(hex: hex).setFill(); rect.fill()
            case .gradient(let angle, let stops):
                var locations = stops.map(\.1)
                NSGradient(colors: stops.map { NSColor(hex: $0.0) }, atLocations: &locations, colorSpace: .sRGB)?.draw(in: rect, angle: CGFloat(90 - angle))
            case .glass:
                NSGradient(colors: [NSColor(hex: "#7FB3D5"), NSColor(hex: "#9FD3B8")])?.draw(in: rect, angle: -30)
            }
            if case .gradient(let angle, let stops)? = variant.sidebar {
                var locations = stops.map(\.1)
                NSGradient(colors: stops.map { NSColor(hex: $0.0) }, atLocations: &locations, colorSpace: .sRGB)?
                    .draw(in: NSRect(x: 0, y: 0, width: rect.width * 0.35, height: rect.height), angle: CGFloat(90 - angle))
            } else if case .color(let hex)? = variant.sidebar {
                NSColor(hex: hex).setFill()
                NSRect(x: 0, y: 0, width: rect.width * 0.35, height: rect.height).fill(using: .sourceOver)
            }
            if let panel = variant.panel {
                NSColor(hex: panel).setFill()
                NSRect(x: rect.width * 0.35, y: 0, width: rect.width * 0.65, height: rect.height).fill(using: .sourceOver)
            }
            NSColor(hex: variant.accent).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 11, y: rect.midY - 3.5, width: 7, height: 7)).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
        image.accessibilityDescription = title
        return image
    }

    /// Menu des thèmes, rempli à chaque ouverture : on ne le remplace jamais pendant qu'il est affiché
    /// (le changement de thème ou d'apparence arrive alors que le menu est encore ouvert).
    static func menu() -> NSMenu {
        let menu = NSMenu(title: "Thème de couleurs")
        menu.delegate = ColorThemeMenuDelegate.shared
        fill(menu)
        return menu
    }

    fileprivate static func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Apparence"))
        for appearance in AppAppearance.allCases {
            let item = NSMenuItem(title: appearance.title, action: #selector(AppDelegate.chooseAppearance(_:)), keyEquivalent: "")
            item.tag = appearance.rawValue
            item.image = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: nil)
            item.state = appearance == AppAppearance.current ? .on : .off
            item.toolTip = appearance.toolTip
            menu.addItem(item)
        }
        let dark = Theme.isDark(NSApp.effectiveAppearance)
        var family: String? = "Apparence"
        for theme in allCases {
            if theme.family != family {
                menu.addItem(.separator())
                if let name = theme.family { menu.addItem(.sectionHeader(title: name)) }
                family = theme.family
            }
            let item = NSMenuItem(title: theme.title, action: #selector(AppDelegate.setColorTheme(_:)), keyEquivalent: "")
            item.tag = theme.rawValue
            item.image = theme.swatch(dark: dark)
            item.state = theme == current ? .on : .off
            menu.addItem(item)
        }
    }
}

final class ColorThemeMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ColorThemeMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) { ColorTheme.fill(menu) }
}

/// Apparence de l'app : celle de macOS, ou toujours claire / sombre (chaque thème a ses deux variantes).
enum AppAppearance: Int, CaseIterable {
    case automatic, light, dark

    static var current: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.integer(forKey: "appearance")) ?? .automatic }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appearance")
            apply()
            NotificationCenter.default.post(name: ColorTheme.changed, object: nil)
        }
    }

    static func apply() {
        NSApp.appearance = switch current {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var title: String {
        switch self {
        case .automatic: "Automatique"
        case .light: "Claire"
        case .dark: "Sombre"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var toolTip: String {
        switch self {
        case .automatic: "Suit le réglage clair / sombre de macOS"
        case .light: "Variante claire du thème, même si macOS est en mode sombre"
        case .dark: "Variante sombre du thème, même si macOS est en mode clair"
        }
    }
}
