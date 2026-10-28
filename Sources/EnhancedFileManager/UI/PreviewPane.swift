import AppKit
import AVKit
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// Aperçu de l'inspecteur : code coloré, texte, PDF feuilletable, vidéo / audio, image ou Coup d'œil.
/// Chaque type de vue n'est créé qu'au premier besoin, et la lecture s'arrête au changement de sélection.
final class PreviewPane: NSView {
    private enum Kind { case image, text, pdf, media, quickLook }

    let imageView = NSImageView()
    private var textScroll: NSScrollView?
    private var textView: NSTextView?
    private var pdfView: PDFView?
    private var playerView: AVPlayerView?
    private var quickLookView: QLPreviewView?
    private var heightConstraint: NSLayoutConstraint!
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        embed(imageView)
        heightConstraint = heightAnchor.constraint(equalToConstant: 190)
        heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Affiche l'icône ou la miniature (cas par défaut).
    func showImage(_ image: NSImage?) {
        activate(.image)
        imageView.image = image
    }

    /// Choisit l'aperçu adapté au fichier ; `false` si l'image / la miniature suffit.
    @discardableResult
    func show(_ url: URL) -> Bool {
        generation += 1
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) ?? (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else {
            return false
        }
        if type.conforms(to: .pdf) {
            let view = pdfView ?? makePDFView()
            view.document = PDFDocument(url: url)
            activate(.pdf)
            return true
        }
        if type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) {
            let view = playerView ?? makePlayerView()
            view.player = AVPlayer(url: url)
            activate(.media)
            return true
        }
        if SyntaxHighlighter.language(for: url) != nil || type.conforms(to: .text) || type.conforms(to: .sourceCode) {
            showText(url, type: type)
            return true
        }
        if type.conforms(to: .image) { return false }
        // Documents divers (Office, Keynote, archives…) : Coup d'œil intégré.
        if let view = quickLookView ?? makeQuickLookView() {
            view.previewItem = url as NSURL
            activate(.quickLook)
            return true
        }
        return false
    }

    private func showText(_ url: URL, type: UTType) {
        let (scroll, textView) = textScroll.flatMap { scroll in self.textView.map { (scroll, $0) } } ?? makeTextView()
        _ = scroll
        activate(.text)
        textView.string = ""
        let current = generation
        let dark = Theme.isDark(effectiveAppearance)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Les 200 premiers Ko suffisent pour un aperçu.
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            let data = (try? handle.read(upToCount: 200_000)) ?? Data()
            try? handle.close()
            let text = String(decoding: data, as: UTF8.self)
            let highlighted = SyntaxHighlighter.highlight(text, language: SyntaxHighlighter.language(for: url), dark: dark)
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                textView.textStorage?.setAttributedString(highlighted)
                textView.scroll(.zero)
            }
        }
    }

    /// Arrête la lecture et libère les documents chargés.
    func reset() {
        generation += 1
        playerView?.player?.pause()
        playerView?.player = nil
        pdfView?.document = nil
        quickLookView?.previewItem = nil
        textView?.string = ""
    }

    private func activate(_ kind: Kind) {
        if kind != .media { playerView?.player?.pause(); playerView?.player = nil }
        if kind != .pdf { pdfView?.document = nil }
        if kind != .quickLook { quickLookView?.previewItem = nil }
        imageView.isHidden = kind != .image
        textScroll?.isHidden = kind != .text
        pdfView?.isHidden = kind != .pdf
        playerView?.isHidden = kind != .media
        quickLookView?.isHidden = kind != .quickLook
        heightConstraint.constant = switch kind {
        case .image: 190
        case .text: 300
        case .pdf, .quickLook: 320
        case .media: 220
        }
    }

    private func makePDFView() -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.backgroundColor = .clear
        embed(view)
        pdfView = view
        return view
    }

    private func makePlayerView() -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        embed(view)
        playerView = view
        return view
    }

    private func makeQuickLookView() -> QLPreviewView? {
        guard let view = QLPreviewView(frame: bounds, style: .compact) else { return nil }
        view.autostarts = true
        embed(view)
        quickLookView = view
        return view
    }

    private func makeTextView() -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        embed(scroll)
        textScroll = scroll
        self.textView = textView
        return (scroll, textView)
    }
}

/// Coloration syntaxique légère par expressions régulières (sans dépendance).
enum SyntaxHighlighter {
    enum Language { case swift, cFamily, python, javascript, java, go, rust, shell, json, tex, markdown, plain }

    static func language(for url: URL) -> Language? {
        switch url.pathExtension.lowercased() {
        case "swift": .swift
        case "c", "h", "cpp", "hpp", "cc", "cxx", "m", "mm", "cu", "cl": .cFamily
        case "py", "pyw": .python
        case "js", "mjs", "cjs", "ts", "tsx", "jsx": .javascript
        case "java", "kt", "kts", "scala", "cs": .java
        case "go": .go
        case "rs": .rust
        case "sh", "bash", "zsh", "fish", "command": .shell
        case "json", "geojson": .json
        case "tex", "sty", "cls", "bib": .tex
        case "md", "markdown": .markdown
        case "txt", "log", "csv", "tsv", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "html", "css", "make", "cmake": .plain
        default: nil
        }
    }

    private static let keywords: [Language: [String]] = [
        .swift: ["func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "class", "struct",
                 "enum", "protocol", "extension", "import", "private", "public", "internal", "static", "self", "init", "try", "catch",
                 "throw", "throws", "async", "await", "nil", "true", "false", "override", "final", "where", "some", "any", "defer"],
        .cFamily: ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "const", "static", "struct", "union",
                   "enum", "typedef", "if", "else", "for", "while", "do", "switch", "case", "default", "return", "break", "continue",
                   "sizeof", "include", "define", "class", "public", "private", "protected", "template", "typename", "namespace",
                   "using", "new", "delete", "true", "false", "nullptr", "auto", "virtual", "inline", "#include", "#define", "#ifdef", "#endif"],
        .python: ["def", "class", "if", "elif", "else", "for", "while", "in", "return", "import", "from", "as", "with", "try", "except",
                  "finally", "raise", "lambda", "yield", "pass", "break", "continue", "None", "True", "False", "and", "or", "not", "is",
                  "self", "async", "await", "global", "nonlocal"],
        .javascript: ["function", "const", "let", "var", "if", "else", "for", "while", "return", "class", "extends", "import", "export",
                      "from", "default", "new", "this", "async", "await", "try", "catch", "throw", "null", "undefined", "true", "false",
                      "interface", "type", "of", "in", "switch", "case"],
        .java: ["public", "private", "protected", "class", "interface", "extends", "implements", "static", "final", "void", "int", "long",
                "double", "boolean", "if", "else", "for", "while", "return", "new", "this", "null", "true", "false", "try", "catch",
                "throw", "throws", "import", "package", "val", "var", "fun", "override"],
        .go: ["func", "package", "import", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "return", "go",
              "defer", "chan", "map", "select", "switch", "case", "default", "nil", "true", "false"],
        .rust: ["fn", "let", "mut", "if", "else", "match", "for", "in", "while", "loop", "return", "struct", "enum", "impl", "trait",
                "pub", "use", "mod", "crate", "self", "Self", "true", "false", "async", "await", "move", "ref", "where", "unsafe"],
        .shell: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export",
                 "local", "echo", "set", "unset", "source"],
    ]

    static func highlight(_ text: String, language: Language?, dark: Bool) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        guard let language, language != .plain else { return result }
        let colors = (keyword: dark ? NSColor(hex: "#FF7AB2") : NSColor(hex: "#AD3DA4"),
                      string: dark ? NSColor(hex: "#FC6A5D") : NSColor(hex: "#C41A16"),
                      comment: dark ? NSColor(hex: "#7F8C98") : NSColor(hex: "#5D6C79"),
                      number: dark ? NSColor(hex: "#D9C97C") : NSColor(hex: "#1C00CF"),
                      command: dark ? NSColor(hex: "#6BDFFF") : NSColor(hex: "#0F68A0"))
        func apply(_ pattern: String, _ color: NSColor, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        switch language {
        case .json:
            apply(#""(?:\\.|[^"\\])*"\s*:"#, colors.keyword)
            apply(#":\s*"(?:\\.|[^"\\])*""#, colors.string)
            apply(#"\b-?\d+(\.\d+)?([eE][+-]?\d+)?\b|\b(true|false|null)\b"#, colors.number)
        case .tex:
            apply(#"\\[A-Za-z@]+"#, colors.command)
            apply(#"\$[^$]*\$"#, colors.number)
            apply(#"(?<!\\)%.*$"#, colors.comment, options: .anchorsMatchLines)
        case .markdown:
            apply(#"^#{1,6} .*$"#, colors.keyword, options: .anchorsMatchLines)
            apply(#"`[^`\n]+`|^```.*$"#, colors.string, options: .anchorsMatchLines)
            apply(#"\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^)\n]+\)"#, colors.command)
        default:
            if let words = keywords[language] {
                let escaped = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                apply(#"(?<![\w#])(\#(escaped))\b"#, colors.keyword)
            }
            apply(#"\b\d+(\.\d+)?\b"#, colors.number)
            apply(#""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#, colors.string)
            let hashComments: Set<Language> = [.python, .shell]
            apply(hashComments.contains(language) ? #"#.*$"# : #"//.*$"#, colors.comment, options: .anchorsMatchLines)
            if !hashComments.contains(language) { apply(#"/\*[\s\S]*?\*/"#, colors.comment) }
        }
        return result
    }
}
