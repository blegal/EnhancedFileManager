// Génère les propositions d'icône de l'app (PNG 1024 px) : swift Tools/make-icons.swift <dossier>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size: CGFloat = 1024

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// Forme d'icône macOS : carré à coins continus (824 px dans un canevas de 1024).
func squircle() -> NSBezierPath {
    let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
    return NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
}

func render(_ name: String, _ draw: (NSRect) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Ombre portée douce sous l'icône.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 28
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    squircle().fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    squircle().addClip()
    draw(NSRect(x: 100, y: 100, width: 824, height: 824))
    // Reflet « verre » en haut et liseré lumineux.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])?
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let rim = squircle()
    rim.lineWidth = 4
    NSColor.white.withAlphaComponent(0.35).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

/// Un panneau de liste : fond translucide, pastilles de dossiers et lignes.
func pane(_ rect: NSRect, tint: NSColor, active: Bool) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 46, yRadius: 46)
    NSColor.white.withAlphaComponent(active ? 0.95 : 0.78).setFill()
    path.fill()
    if active {
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 40, y: rect.maxY - 38, width: rect.width - 80, height: 12), xRadius: 6, yRadius: 6).fill()
    }
    for row in 0..<5 {
        let y = rect.maxY - 110 - CGFloat(row) * 88
        let selected = active && row == 1
        if selected {
            tint.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 22, y: y - 22, width: rect.width - 44, height: 70), xRadius: 18, yRadius: 18).fill()
        }
        (row < 2 ? tint : hex(0x9AA4B2)).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 44, y: y - 4, width: 44, height: 34), xRadius: 8, yRadius: 8).fill()
        hex(0x55606E, 0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 108, y: y + 6, width: rect.width - 176 - CGFloat(row % 3) * 40, height: 14), xRadius: 7, yRadius: 7).fill()
    }
}

// A — Double panneau : deux listes côte à côte et une flèche de transfert.
render("icone-A-double-panneau") { r in
    NSGradient(colors: [hex(0x2F7BF5), hex(0x1747B8)])?.draw(in: r, angle: -90)
    pane(NSRect(x: 190, y: 250, width: 300, height: 540), tint: hex(0x2F7BF5), active: true)
    pane(NSRect(x: 534, y: 250, width: 300, height: 540), tint: hex(0x2F7BF5), active: false)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 440, y: 190)); arrow.line(to: NSPoint(x: 584, y: 190))
    arrow.move(to: NSPoint(x: 548, y: 222)); arrow.line(to: NSPoint(x: 590, y: 190)); arrow.line(to: NSPoint(x: 548, y: 158))
    arrow.lineWidth = 26; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor.white.setStroke(); arrow.stroke()
}

// B — Dossier fendu : un dossier coupé en deux panneaux, graphite et accent.
render("icone-B-dossier-fendu") { r in
    NSGradient(colors: [hex(0x3A3F47), hex(0x1C1F24)])?.draw(in: r, angle: -90)
    let back = NSBezierPath(roundedRect: NSRect(x: 210, y: 270, width: 604, height: 470), xRadius: 54, yRadius: 54)
    back.append(NSBezierPath(roundedRect: NSRect(x: 210, y: 660, width: 250, height: 120), xRadius: 40, yRadius: 40))
    hex(0xF0A93B).setFill(); back.fill()
    NSGradient(colors: [hex(0xFFD27A), hex(0xF5B342)])?.draw(in: NSBezierPath(roundedRect: NSRect(x: 210, y: 270, width: 290, height: 400), xRadius: 50, yRadius: 50), angle: -90)
    NSGradient(colors: [hex(0x7CC4FF), hex(0x2F86F0)])?.draw(in: NSBezierPath(roundedRect: NSRect(x: 524, y: 270, width: 290, height: 400), xRadius: 50, yRadius: 50), angle: -90)
}

// C — Grille 2×2 : les quatre panneaux, chacun de sa couleur, sur bleu nuit.
render("icone-C-grille") { r in
    NSGradient(colors: [hex(0x1B2A4A), hex(0x0B1222)])?.draw(in: r, angle: -90)
    let colors: [(UInt32, UInt32)] = [(0x5AC8FA, 0x2F7BF5), (0x34D399, 0x0F9D7A), (0xFBBF24, 0xF59E0B), (0xF472B6, 0xC026D3)]
    for (i, pair) in colors.enumerated() {
        let x: CGFloat = i % 2 == 0 ? 200 : 532, y: CGFloat = i < 2 ? 532 : 200
        let tile = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 292, height: 292), xRadius: 64, yRadius: 64)
        NSGradient(colors: [hex(pair.0), hex(pair.1)])?.draw(in: tile, angle: -60)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + 60, y: y + 150, width: 80, height: 60), xRadius: 14, yRadius: 14).fill()
        NSBezierPath(roundedRect: NSRect(x: x + 60, y: y + 92, width: 172, height: 20), xRadius: 10, yRadius: 10).fill()
    }
}

// D — Flèches d'échange : un dossier traversé par deux flèches (copier / déplacer), turquoise.
render("icone-D-echange") { r in
    NSGradient(colors: [hex(0x2DD4BF), hex(0x0E7490)])?.draw(in: r, angle: -90)
    let folder = NSBezierPath(roundedRect: NSRect(x: 220, y: 260, width: 584, height: 440), xRadius: 56, yRadius: 56)
    folder.append(NSBezierPath(roundedRect: NSRect(x: 220, y: 640, width: 240, height: 110), xRadius: 40, yRadius: 40))
    NSColor.white.withAlphaComponent(0.95).setFill(); folder.fill()
    let arrows = NSBezierPath()
    arrows.move(to: NSPoint(x: 340, y: 540)); arrows.line(to: NSPoint(x: 680, y: 540))
    arrows.move(to: NSPoint(x: 620, y: 590)); arrows.line(to: NSPoint(x: 686, y: 540)); arrows.line(to: NSPoint(x: 620, y: 490))
    arrows.move(to: NSPoint(x: 684, y: 400)); arrows.line(to: NSPoint(x: 344, y: 400))
    arrows.move(to: NSPoint(x: 404, y: 450)); arrows.line(to: NSPoint(x: 338, y: 400)); arrows.line(to: NSPoint(x: 404, y: 350))
    arrows.lineWidth = 34; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round
    hex(0x0E7490).setStroke(); arrows.stroke()
}
print("ok")
