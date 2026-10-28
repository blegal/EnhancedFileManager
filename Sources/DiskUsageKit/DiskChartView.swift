import AppKit

/// Les sept représentations de l'occupation du disque.
package enum DiskChartStyle: Int, CaseIterable {
    case cushion, flat, sunburst, icicle, histogram, donut, baobab

    package var title: String {
        switch self {
        case .cushion: "Carte coussin"
        case .flat: "Carte épurée"
        case .sunburst: "Soleil"
        case .icicle: "Partition empilée"
        case .histogram: "Histogramme"
        case .donut: "Anneau et liste"
        case .baobab: "Liste et soleil"
        }
    }

    package var symbol: String {
        switch self {
        case .cushion: "square.grid.3x3.square"
        case .flat: "rectangle.split.3x3"
        case .sunburst: "sun.max"
        case .icicle: "align.horizontal.left"
        case .histogram: "chart.bar.doc.horizontal"
        case .donut: "chart.pie"
        case .baobab: "list.bullet.indent"
        }
    }

    var hasList: Bool { self == .donut || self == .baobab }
}

enum DiskColorMode: Int, CaseIterable {
    case type, age, branch

    var title: String {
        switch self {
        case .type: "Par type"
        case .age: "Par ancienneté"
        case .branch: "Par branche"
        }
    }

    /// Dégradé de l'ancienneté : récent (vert) → plus de quatre ans (brun).
    static let ageStops = ["#2FB57A", "#D9C43C", "#E0773A", "#8C3A2B"].map(NSColor.init(hex:))

    static func ageColor(_ modified: TimeInterval) -> NSColor {
        let days = max(0, (Date.timeIntervalSinceReferenceDate - modified) / 86_400)
        let t = min(1, log1p(days) / log1p(1500)) * Double(ageStops.count - 1)
        let index = min(Int(t), ageStops.count - 2)
        return ageStops[index].blended(withFraction: t - Double(index), of: ageStops[index + 1]) ?? ageStops[index]
    }
}

/// Graphique d'occupation dessiné avec Core Graphics. La mise en page n'est recalculée que si la taille,
/// la racine, le style ou les couleurs changent ; le survol est dessiné par une vue superposée légère.
final class DiskChartView: NSView {
    struct Shape {
        let node: DiskNode
        let depth: Int
        let rect: CGRect
        /// Secteur (rayons et angles depuis le haut, sens horaire) pour le soleil et l'anneau.
        var arc: (r0: CGFloat, r1: CGFloat, a0: CGFloat, a1: CGFloat)?
        let color: NSColor
        /// Dossier trop petit pour être subdivisé : dessiné comme un bloc plein.
        var isLeaf = false
    }

    var style = DiskChartStyle.flat { didSet { invalidate() } }
    var colorMode = DiskColorMode.type { didSet { invalidate() } }
    var root: DiskNode? { didSet { hovered = nil; invalidate() } }

    var onHover: ((DiskNode?) -> Void)?
    var onDive: ((DiskNode) -> Void)?
    var onUp: (() -> Void)?
    var onOpen: ((DiskNode) -> Void)?
    var menuProvider: ((DiskNode) -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?

    private(set) var shapes: [Shape] = []
    private var layoutSize = CGSize.zero
    private var layoutValid = false
    private var center = CGPoint.zero
    private var centerRadius: CGFloat = 0
    private let overlay = HighlightOverlay()
    private var hovered: DiskNode? { didSet { if hovered !== oldValue { updateOverlay() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func invalidate() {
        layoutValid = false
        needsDisplay = true
        updateOverlay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize != layoutSize { invalidate() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Survol, clics, clavier

    /// Met en évidence un nœud (ou son ancêtre affiché le plus proche), par exemple depuis la liste.
    func highlight(_ node: DiskNode?) {
        ensureLayout()
        var candidate = node
        while let current = candidate, !shapes.contains(where: { $0.node === current }) { candidate = current.parent }
        hovered = candidate === root && style != .icicle ? nil : candidate
    }

    func node(at point: CGPoint) -> DiskNode? {
        ensureLayout()
        if style == .sunburst || style == .baobab || style == .donut {
            if hypot(point.x - center.x, point.y - center.y) < centerRadius { return root }
        }
        // Les formes les plus profondes sont ajoutées après leurs parents.
        for shape in shapes.reversed() where contains(shape, point) { return shape.node }
        return nil
    }

    private func contains(_ shape: Shape, _ point: CGPoint) -> Bool {
        guard let arc = shape.arc else { return shape.rect.contains(point) }
        let dx = point.x - center.x, dy = point.y - center.y
        let radius = hypot(dx, dy)
        guard radius >= arc.r0, radius < arc.r1 else { return false }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return angle >= arc.a0 && angle < arc.a1
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let node = node(at: point)
        hovered = node === root && style != .icicle ? nil : node
        onHover?(node)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let node = node(at: convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount == 2, !node.isDirectory, !node.isAggregate { onOpen?(node); return }
        guard event.clickCount == 1 else { return }
        if node === root { onUp?(); return }
        // Un fichier mène à son dossier, comme dans les cartes de GdMap.
        let target = node.isDirectory ? node : node.parent
        if let target, target !== root { onDive?(target) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let node = node(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuProvider?(node)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    private func updateOverlay() {
        guard let hovered, let shape = shapes.last(where: { $0.node === hovered }), layoutValid else {
            overlay.path = nil
            return
        }
        overlay.path = path(for: shape)
    }

    private func path(for shape: Shape) -> CGPath {
        if let arc = shape.arc {
            let path = CGMutablePath()
            path.addArc(center: center, radius: arc.r1, startAngle: arc.a0 - .pi / 2, endAngle: arc.a1 - .pi / 2, clockwise: false)
            path.addArc(center: center, radius: arc.r0, startAngle: arc.a1 - .pi / 2, endAngle: arc.a0 - .pi / 2, clockwise: true)
            path.closeSubpath()
            return path
        }
        let radius: CGFloat = style == .flat ? 4 : style == .icicle || style == .histogram ? 3 : 0
        let rect = shape.rect.insetBy(dx: 0.5, dy: 0.5)
        return CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil)
    }

    // MARK: Couleurs

    private var hues: [ObjectIdentifier: CGFloat] = [:]

    private func color(_ node: DiskNode, depth: Int, branch: DiskNode?) -> NSColor {
        switch colorMode {
        case .type: return node.category.color
        case .age: return DiskColorMode.ageColor(node.modified)
        case .branch:
            let hue = branch.flatMap { hues[ObjectIdentifier($0)] } ?? 0.6
            let level = CGFloat(max(0, depth - 1))
            return NSColor(hue: hue, saturation: max(0.22, 0.62 - level * 0.08), brightness: min(0.96, 0.8 + level * 0.04), alpha: 1)
        }
    }

    private func assignHues() {
        hues = [:]
        let first = root?.children ?? []
        for (index, child) in first.enumerated() {
            hues[ObjectIdentifier(child)] = (CGFloat(index) / CGFloat(max(first.count, 1)) + 0.55).truncatingRemainder(dividingBy: 1)
        }
    }

    // MARK: Mise en page

    private func ensureLayout() {
        guard !layoutValid else { return }
        layoutValid = true
        layoutSize = bounds.size
        shapes = []
        centerRadius = 0
        guard let root, root.size > 0, bounds.width > 20, bounds.height > 20 else { return }
        assignHues()
        switch style {
        case .cushion: layoutTreemap(root, in: bounds.insetBy(dx: 1, dy: 1), depth: 0, branch: nil, flat: false)
        case .flat: layoutTreemap(root, in: bounds.insetBy(dx: 2, dy: 2), depth: 0, branch: nil, flat: true)
        case .sunburst, .baobab: layoutSunburst(root)
        case .icicle: layoutIcicle(root)
        case .histogram: layoutHistogram(root)
        case .donut: layoutDonut(root)
        }
    }

    /// Les enfants qui comptent (taille non nulle), déjà triés du plus gros au plus petit.
    private func visibleChildren(_ node: DiskNode) -> [DiskNode] {
        (node.children ?? []).filter { $0.size > 0 }
    }

    private func layoutTreemap(_ node: DiskNode, in rect: CGRect, depth: Int, branch: DiskNode?, flat: Bool) {
        let kids = visibleChildren(node)
        // Carte épurée : les petits dossiers restent des blocs pleins plutôt qu'un semis de points.
        var subdivides = !kids.isEmpty && rect.width >= 4 && rect.height >= 4
        if flat, depth > 0, let largest = kids.first {
            // Le plus gros enfant doit pouvoir former un bloc lisible.
            let share = Double(largest.size) / Double(max(node.size, 1))
            subdivides = subdivides && rect.width >= 40 && rect.height >= 32 && Double(rect.width * rect.height) * share >= 400
        }
        let index = shapes.count
        if depth > 0 {
            var shape = Shape(node: node, depth: depth, rect: rect, color: color(node, depth: depth, branch: branch))
            shape.isLeaf = !node.isDirectory || !subdivides
            shapes.append(shape)
        }
        guard subdivides else { return }
        var inner = rect
        if depth > 0 {
            let padding: CGFloat = flat ? 3 : 2
            let header: CGFloat = flat ? (depth == 1 ? 20 : depth == 2 ? 16 : 0) : (depth == 1 ? 15 : 0)
            let showsHeader = header > 0 && rect.height > header + 24 && rect.width > 60
            inner = CGRect(x: rect.minX + padding, y: rect.minY + (showsHeader ? header : padding),
                           width: rect.width - padding * 2, height: rect.height - padding - (showsHeader ? header : padding))
        }
        guard inner.width >= 2, inner.height >= 2 else { return }
        let rects = Self.squarify(kids.map { Double($0.size) }, in: inner)
        let gap: CGFloat = flat ? 2 : 0
        for (kid, kidRect) in zip(kids, rects) {
            let r = kidRect.insetBy(dx: gap / 2, dy: gap / 2)
            let minimum: CGFloat = flat ? 8 : 1
            guard r.width >= minimum, r.height >= minimum, r.width * r.height >= 2 else { continue }
            layoutTreemap(kid, in: r, depth: depth + 1, branch: depth == 0 ? kid : branch, flat: flat)
        }
        // Aucun enfant assez grand : le dossier redevient un bloc plein.
        if depth > 0, shapes.count == index + 1 { shapes[index].isLeaf = true }
    }

    /// Carte proportionnelle « squarified » (Bruls, Huizing, van Wijk) : des blocs aussi carrés que possible.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var remaining = rect
        var index = 0
        func worst(_ sum: Double, _ smallest: Double, _ largest: Double, _ side: Double) -> Double {
            let s2 = sum * sum, w2 = side * side
            return max(w2 * largest / s2, s2 / (w2 * smallest))
        }
        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = index
            var sum = 0.0, smallest = Double.infinity, largest = 0.0
            var current = Double.infinity
            while end < areas.count {
                let area = max(areas[end], 1e-9)
                let candidate = worst(sum + area, min(smallest, area), max(largest, area), side)
                if end > index, candidate > current { break }
                sum += area
                smallest = min(smallest, area)
                largest = max(largest, area)
                current = candidate
                end += 1
            }
            if remaining.width >= remaining.height {
                let width = CGFloat(sum / Double(remaining.height))
                var y = remaining.minY
                for i in index..<end {
                    let height = CGFloat(areas[i]) / width
                    result.append(CGRect(x: remaining.minX, y: y, width: width, height: height))
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = CGFloat(sum / Double(remaining.width))
                var x = remaining.minX
                for i in index..<end {
                    let width = CGFloat(areas[i]) / height
                    result.append(CGRect(x: x, y: remaining.minY, width: width, height: height))
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
            index = end
        }
        return result
    }

    private func maxDepth(_ node: DiskNode, limit: Int) -> Int {
        guard limit > 0, let kids = node.children, !kids.isEmpty else { return 0 }
        return 1 + (kids.map { maxDepth($0, limit: limit - 1) }.max() ?? 0)
    }

    private func layoutSunburst(_ root: DiskNode) {
        let baobab = style == .baobab
        let side = min(bounds.width, bounds.height) - 8
        let radius = side / 2
        center = CGPoint(x: bounds.midX, y: bounds.midY)
        let levels = max(1, maxDepth(root, limit: baobab ? 5 : 4))
        // Baobab : anneaux de plus en plus fins vers l'extérieur ; soleil : anneaux égaux.
        var radii: [CGFloat]
        if baobab {
            let weights: [CGFloat] = Array([1, 0.85, 0.7, 0.56, 0.45].prefix(levels))
            let r0 = radius * 0.24
            radii = [r0]
            let total = weights.reduce(0, +)
            for weight in weights { radii.append(radii.last! + (radius - r0) * weight / total) }
        } else {
            radii = (0...levels).map { radius * CGFloat($0 + 1) / CGFloat(levels + 1) }
        }
        centerRadius = radii[0]
        func place(_ node: DiskNode, a0: CGFloat, a1: CGFloat, depth: Int, branch: DiskNode?) {
            guard depth < radii.count, let kids = node.children else { return }
            var angle = a0
            let span = a1 - a0
            for kid in kids where kid.size > 0 {
                let sweep = span * CGFloat(Double(kid.size) / Double(max(node.size, 1)))
                defer { angle += sweep }
                guard sweep > 0.004 else { continue }
                let b = depth == 1 ? kid : branch
                var shape = Shape(node: kid, depth: depth, rect: .zero, color: color(kid, depth: depth, branch: b))
                shape.arc = (radii[depth - 1] + 0.5, radii[depth] - 0.5, angle, angle + sweep)
                shapes.append(shape)
                place(kid, a0: angle, a1: angle + sweep, depth: depth + 1, branch: b)
            }
        }
        place(root, a0: 0, a1: 2 * .pi, depth: 1, branch: nil)
    }

    private func layoutIcicle(_ root: DiskNode) {
        let levels = min(maxDepth(root, limit: 6), max(1, Int(bounds.height / 34) - 1))
        let rowHeight = min(48, (bounds.height - 4) / CGFloat(levels + 1))
        shapes.append(Shape(node: root, depth: 0, rect: CGRect(x: 2, y: 2, width: bounds.width - 4, height: rowHeight - 2), color: .tertiaryLabelColor))
        func place(_ node: DiskNode, x: CGFloat, width: CGFloat, depth: Int, branch: DiskNode?) {
            guard depth <= levels, let kids = node.children else { return }
            var cursor = x
            for kid in kids where kid.size > 0 {
                let w = width * CGFloat(Double(kid.size) / Double(max(node.size, 1)))
                defer { cursor += w }
                guard w >= 1 else { continue }
                let b = depth == 1 ? kid : branch
                let rect = CGRect(x: cursor, y: 2 + CGFloat(depth) * rowHeight, width: w > 4 ? w - 1 : w, height: rowHeight - 2)
                shapes.append(Shape(node: kid, depth: depth, rect: rect, color: color(kid, depth: depth, branch: b)))
                place(kid, x: cursor, width: w, depth: depth + 1, branch: b)
            }
        }
        place(root, x: 2, width: bounds.width - 4, depth: 1, branch: nil)
    }

    /// Enfants directs, les derniers regroupés au-delà de `limit` (ou sous la part `minimum`).
    private func groupedChildren(_ node: DiskNode, limit: Int, minimum: Double = 0) -> [DiskNode] {
        let kids = visibleChildren(node)
        let total = Double(max(node.size, 1))
        var kept = Array(kids.prefix(limit).filter { Double($0.size) / total >= minimum })
        if kept.count < kids.count {
            let rest = kids[kept.count...]
            let group = DiskNode(name: "\(rest.count) autres éléments")
            group.isAggregate = true
            var sizes = [Int64](repeating: 0, count: DiskCategory.allCases.count)
            for item in rest {
                group.size += item.size
                group.count += item.count
                group.modified = max(group.modified, item.modified)
                for category in DiskCategory.allCases { sizes[category.rawValue] += item.size(of: category) }
            }
            group.categorySizes = sizes
            group.category = .other
            group.parent = node
            kept.append(group)
        }
        return kept
    }

    private func layoutHistogram(_ root: DiskNode) {
        let rowHeight: CGFloat = 24
        let items = groupedChildren(root, limit: max(1, Int((bounds.height - 8) / rowHeight) - 1))
        let largest = Double(items.map(\.size).max() ?? 1)
        let labelWidth = min(220, bounds.width * 0.32)
        let valueWidth: CGFloat = 112
        let track = max(10, bounds.width - labelWidth - valueWidth - 24)
        for (index, item) in items.enumerated() {
            let y = 6 + CGFloat(index) * rowHeight
            let width = max(2, track * CGFloat(Double(item.size) / max(largest, 1)))
            let rect = CGRect(x: labelWidth + 12, y: y + 4, width: width, height: rowHeight - 8)
            shapes.append(Shape(node: item, depth: 1, rect: rect, color: color(item, depth: 1, branch: item)))
        }
    }

    private func layoutDonut(_ root: DiskNode) {
        let radius = min(bounds.width, bounds.height) / 2 - 6
        center = CGPoint(x: bounds.midX, y: bounds.midY)
        centerRadius = radius * 0.6
        var angle: CGFloat = 0
        for item in groupedChildren(root, limit: 12, minimum: 0.015) {
            let sweep = 2 * .pi * CGFloat(Double(item.size) / Double(max(root.size, 1)))
            var shape = Shape(node: item, depth: 1, rect: .zero, color: color(item, depth: 1, branch: item))
            shape.arc = (centerRadius, radius, angle, angle + sweep)
            shapes.append(shape)
            angle += sweep
        }
    }

    // MARK: Dessin

    override func draw(_ dirtyRect: NSRect) {
        ensureLayout()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let root, root.size > 0 else {
            drawText(root == nil ? "" : "Dossier vide", in: bounds.insetBy(dx: 20, dy: bounds.height / 2 - 10),
                     font: .systemFont(ofSize: 13), color: .secondaryLabelColor, alignment: .center)
            return
        }
        switch style {
        case .cushion: drawCushion(context)
        case .flat: drawFlat(context)
        case .sunburst, .baobab, .donut: drawArcs(context, root: root)
        case .icicle: drawIcicle(context)
        case .histogram: drawHistogram(context, root: root)
        }
    }

    private func drawCushion(_ context: CGContext) {
        let frame = NSColor(white: 0.55, alpha: 1)
        context.setFillColor(frame.cgColor)
        context.fill(bounds)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for shape in shapes {
            let r = shape.rect
            if !shape.isLeaf {
                context.setFillColor((frame.shadow(withLevel: min(0.35, 0.07 * CGFloat(shape.depth))) ?? frame).cgColor)
                context.fill(r)
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                context.setLineWidth(1)
                context.stroke(r.insetBy(dx: 0.5, dy: 0.5))
                if shape.depth == 1, r.width > 50, r.height > 30 {
                    drawText("\(shape.node.name) · \(Format.size(shape.node.size))", in: CGRect(x: r.minX + 4, y: r.minY + 1, width: r.width - 8, height: 14),
                             font: .systemFont(ofSize: 10.5, weight: .semibold), color: .white, shadow: true)
                }
                continue
            }
            // Relief en coussin : dégradé radial clair au centre, sombre sur les bords.
            let base = shape.color.usingColorSpace(.sRGB) ?? shape.color
            let light = base.highlight(withLevel: 0.45) ?? base, dark = base.shadow(withLevel: 0.55) ?? base
            guard let gradient = CGGradient(colorsSpace: space, colors: [light.cgColor, base.cgColor, dark.cgColor] as CFArray, locations: [0, 0.5, 1]) else { continue }
            context.saveGState()
            context.clip(to: r)
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: r.minX + r.width * 0.38, y: r.minY + r.height * 0.34), startRadius: 0,
                                       endCenter: CGPoint(x: r.midX, y: r.midY), endRadius: hypot(r.width, r.height) * 0.6, options: [.drawsAfterEndLocation])
            context.restoreGState()
        }
    }

    private func drawFlat(_ context: CGContext) {
        let folderFill = NSColor.labelColor.withAlphaComponent(0.045).cgColor
        let folderStroke = NSColor.separatorColor.cgColor
        for shape in shapes {
            let r = shape.rect
            let radius = min(shape.isLeaf ? 4 : 7, r.width / 2, r.height / 2)
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            if !shape.isLeaf {
                context.setFillColor(folderFill)
                context.setStrokeColor(folderStroke)
                context.setLineWidth(1)
                context.drawPath(using: .fillStroke)
                let header: CGFloat = shape.depth == 1 ? 20 : shape.depth == 2 ? 16 : 0
                if header > 0, r.height > header + 24, r.width > 60 {
                    let font = NSFont.systemFont(ofSize: shape.depth == 1 ? 12 : 11, weight: .semibold)
                    let size = Format.size(shape.node.size)
                    let sizeWidth = (size as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
                    let y = r.minY + (header - font.pointSize - 4) / 2 + 1
                    drawText(shape.node.name, in: CGRect(x: r.minX + 7, y: y, width: max(0, r.width - sizeWidth - 22), height: font.pointSize + 4),
                             font: font, color: .labelColor)
                    if r.width > sizeWidth + 50 {
                        drawText(size, in: CGRect(x: r.maxX - sizeWidth - 8, y: y + 0.5, width: sizeWidth + 2, height: 15), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
                    }
                }
                continue
            }
            context.setFillColor(shape.color.cgColor)
            context.fillPath()
            if r.width > 46, r.height > 24 {
                drawText(shape.node.name, in: CGRect(x: r.minX + 6, y: r.minY + 4, width: r.width - 10, height: 15),
                         font: .systemFont(ofSize: 11, weight: .semibold), color: .white, shadow: true)
                if r.height > 38 {
                    drawText(Format.size(shape.node.size), in: CGRect(x: r.minX + 6, y: r.minY + 18, width: r.width - 10, height: 15),
                             font: .systemFont(ofSize: 10.5), color: NSColor.white.withAlphaComponent(0.9), shadow: true)
                }
            }
        }
    }

    private func drawArcs(_ context: CGContext, root: DiskNode) {
        context.setStrokeColor(NSColor.windowBackgroundColor.cgColor)
        context.setLineWidth(style == .donut ? 2 : 1)
        for shape in shapes {
            guard let arc = shape.arc else { continue }
            context.addPath(path(for: shape))
            context.setFillColor(shape.color.withAlphaComponent(shape.node.isDirectory && style == .sunburst ? 0.92 : 1).cgColor)
            // Pas de liseré sur les secteurs très fins : il les masquerait.
            context.drawPath(using: (arc.a1 - arc.a0) * arc.r1 > 4 ? .fillStroke : .fill)
        }
        // Noms des secteurs du premier anneau quand ils tiennent.
        if style == .sunburst {
            for shape in shapes where shape.depth == 1 {
                guard let arc = shape.arc else { continue }
                let middle = (arc.a0 + arc.a1) / 2 - .pi / 2, radius = (arc.r0 + arc.r1) / 2
                let available = min((arc.a1 - arc.a0) * radius, (arc.r1 - arc.r0) * 1.6)
                guard available > 40 else { continue }
                let point = CGPoint(x: center.x + cos(middle) * radius, y: center.y + sin(middle) * radius)
                drawText(shape.node.name, in: CGRect(x: point.x - available / 2, y: point.y - 7, width: available, height: 15),
                         font: .systemFont(ofSize: 10.5, weight: .semibold), color: .white, shadow: true, alignment: .center)
            }
        }
        // Centre : dossier affiché, taille, et retour au parent.
        let r = centerRadius - (style == .donut ? 0 : 2)
        if style != .donut {
            context.setFillColor(NSColor.controlBackgroundColor.cgColor)
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            context.drawPath(using: .fillStroke)
        }
        let width = r * 1.7
        guard width > 44 else { return }
        let large = style == .donut && width > 100
        drawText(style == .donut ? Format.size(root.size) : root.name, in: CGRect(x: center.x - width / 2, y: center.y - (large ? 14 : 15), width: width, height: large ? 22 : 16),
                 font: .systemFont(ofSize: large ? 17 : 12, weight: large ? .bold : .semibold), color: .labelColor, alignment: .center)
        drawText(style == .donut ? Format.items(visibleChildren(root).count) : Format.size(root.size), in: CGRect(x: center.x - width / 2, y: center.y + (large ? 8 : 1), width: width, height: 15),
                 font: .systemFont(ofSize: 11), color: .secondaryLabelColor, alignment: .center)
        if style != .donut, root.parent != nil || root.rootURL?.path != "/", r > 34 {
            drawText("↑ remonter", in: CGRect(x: center.x - width / 2, y: center.y + 16, width: width, height: 14),
                     font: .systemFont(ofSize: 10), color: .tertiaryLabelColor, alignment: .center)
        }
    }

    private func drawIcicle(_ context: CGContext) {
        for shape in shapes {
            let r = shape.rect
            context.addPath(CGPath(roundedRect: r, cornerWidth: min(3, r.width / 2), cornerHeight: min(3, r.height / 2), transform: nil))
            context.setFillColor(shape.depth == 0 ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : shape.color.cgColor)
            context.fillPath()
            guard r.width > 34 else { continue }
            let onColor = shape.depth > 0
            let title = shape.depth == 0 && root?.rootURL?.path != "/" ? "\(shape.node.name)   (cliquer pour remonter)" : shape.node.name
            drawText(title, in: CGRect(x: r.minX + 6, y: r.minY + 4, width: r.width - 10, height: 15),
                     font: .systemFont(ofSize: 11, weight: .semibold), color: onColor ? .white : .labelColor, shadow: onColor)
            if r.width > 50, r.height > 32 {
                drawText(Format.size(shape.node.size), in: CGRect(x: r.minX + 6, y: r.minY + 18, width: r.width - 10, height: 14),
                         font: .systemFont(ofSize: 10), color: onColor ? NSColor.white.withAlphaComponent(0.9) : .secondaryLabelColor, shadow: onColor)
            }
        }
    }

    private func drawHistogram(_ context: CGContext, root: DiskNode) {
        let labelWidth = min(220, bounds.width * 0.32)
        let total = Double(max(root.size, 1))
        for shape in shapes {
            let r = shape.rect
            let node = shape.node
            let suffix = node.isDirectory ? "/" : ""
            drawText(node.name + suffix, in: CGRect(x: 8, y: r.minY, width: labelWidth, height: 16), font: .systemFont(ofSize: 12), color: .labelColor)
            let path = CGPath(roundedRect: r, cornerWidth: min(3, r.width / 2), cornerHeight: 3, transform: nil)
            context.saveGState()
            context.addPath(path)
            context.clip()
            if colorMode == .type {
                // Barre empilée par type de fichier.
                var x = r.minX
                for category in DiskCategory.allCases {
                    let part = node.size(of: category)
                    guard part > 0 else { continue }
                    let w = r.width * CGFloat(Double(part) / Double(max(node.size, 1)))
                    context.setFillColor(category.color.cgColor)
                    context.fill(CGRect(x: x, y: r.minY, width: w, height: r.height))
                    x += w
                }
            } else {
                context.setFillColor(shape.color.cgColor)
                context.fill(r)
            }
            context.restoreGState()
            let percent = Double(node.size) / total
            let text = "\(Format.size(node.size))  \(Self.percent(percent))"
            drawText(text, in: CGRect(x: bounds.width - 118, y: r.minY, width: 110, height: 16), font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                     color: .secondaryLabelColor, alignment: .right)
        }
    }

    static func percent(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.001 { return "< 0,1 %" }
        return (fraction * 100).formatted(.number.precision(.fractionLength(fraction >= 0.1 ? 0 : 1))) + " %"
    }

    private func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, shadow: Bool = false, alignment: NSTextAlignment = .left) {
        guard rect.width > 8, rect.height > 4 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if shadow {
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            textShadow.shadowBlurRadius = 2
            textShadow.shadowOffset = .zero
            attributes[.shadow] = textShadow
        }
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

/// Contour du bloc survolé, dessiné au-dessus du graphique sans le redessiner.
private final class HighlightOverlay: NSView {
    var path: CGPath? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let path, let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(path)
        context.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.strokePath()
    }
}
