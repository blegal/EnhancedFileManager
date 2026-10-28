import AppKit

/// Les dispositions de panneaux. Les valeurs 1 à 4 restent celles des versions précédentes
/// (sessions déjà enregistrées).
enum PanelLayout: Int, CaseIterable {
    case single = 1, twoColumns = 2, threeColumns = 3, grid = 4
    case twoRows = 5, mainAndStacked = 6, stackedAndMain = 7, pairAndBottom = 8

    /// Ordre d'affichage dans les menus.
    static let ordered: [PanelLayout] = [.single, .twoColumns, .twoRows, .threeColumns, .mainAndStacked, .stackedAndMain, .pairAndBottom, .grid]

    var panelCount: Int {
        switch self {
        case .single: 1
        case .twoColumns, .twoRows: 2
        case .threeColumns, .mainAndStacked, .stackedAndMain, .pairAndBottom: 3
        case .grid: 4
        }
    }

    var title: String {
        switch self {
        case .single: "1 panneau"
        case .twoColumns: "2 panneaux côte à côte"
        case .twoRows: "2 panneaux superposés"
        case .threeColumns: "3 colonnes"
        case .mainAndStacked: "1 à gauche, 2 empilés à droite"
        case .stackedAndMain: "2 empilés à gauche, 1 à droite"
        case .pairAndBottom: "2 en haut, 1 en bas"
        case .grid: "4 panneaux (grille)"
        }
    }

    /// Rectangles des panneaux dans un carré unité (origine en haut à gauche).
    var cells: [CGRect] {
        switch self {
        case .single: [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case .twoColumns: [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .twoRows: [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case .threeColumns: (0..<3).map { CGRect(x: CGFloat($0) / 3, y: 0, width: 1.0 / 3, height: 1) }
        case .mainAndStacked: [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .stackedAndMain: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .pairAndBottom: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case .grid: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        }
    }

    /// Pictogramme (image modèle, teintée par le système) dessinant la disposition.
    func icon(size: NSSize = NSSize(width: 20, height: 15)) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let frame = rect.insetBy(dx: 0.75, dy: 0.75)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: frame, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.3
            outline.stroke()
            let dividers = NSBezierPath()
            dividers.lineWidth = 1.1
            for cell in cells {
                let x = frame.minX + cell.maxX * frame.width, y = frame.minY + cell.maxY * frame.height
                if cell.maxX < 0.99 {
                    dividers.move(to: NSPoint(x: x, y: frame.minY + cell.minY * frame.height))
                    dividers.line(to: NSPoint(x: x, y: y))
                }
                if cell.maxY < 0.99 {
                    dividers.move(to: NSPoint(x: frame.minX + cell.minX * frame.width, y: y))
                    dividers.line(to: NSPoint(x: x, y: y))
                }
            }
            dividers.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = title
        return image
    }
}
