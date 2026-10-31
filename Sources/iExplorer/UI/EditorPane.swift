import AppKit
import Quartz
import UniformTypeIdentifiers

/// Éditeur à côté du panneau quand un seul panneau est affiché : le fichier texte sélectionné s'ouvre
/// dans un onglet, se modifie et s'enregistre (⌘S) ; s'il est suivi par Git, « Enregistrer, commit et push ».
/// Les autres fichiers (images, PDF, vidéos…) s'affichent en Coup d'œil.
final class EditorViewController: NSViewController, NSTextViewDelegate {
    static let enabledChanged = Notification.Name("EditorEnabledChanged")

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "editorInSingleLayout") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "editorInSingleLayout")
            NotificationCenter.default.post(name: enabledChanged, object: nil)
        }
    }

    /// Éditeurs ouverts, pour prévenir avant de quitter avec des modifications.
    private static var instances = NSHashTable<EditorViewController>.weakObjects()
    static var hasUnsavedChanges: Bool { instances.allObjects.contains { $0.documents.contains(where: \.isModified) } }

    private final class Document {
        let url: URL
        var text: String
        var encoding: String.Encoding
        var isModified = false
        /// `nil` tant que la question n'a pas été posée à Git ; puis la racine du dépôt si le fichier est suivi.
        var gitRoot: URL??
        var selection = NSRange(location: 0, length: 0)

        init(url: URL, text: String, encoding: String.Encoding) {
            self.url = url
            self.text = text
            self.encoding = encoding
        }
    }

    private var documents: [Document] = []
    private var current: Document?

    private let tabs = NSStackView()
    private let saveButton = NSButton(title: "Enregistrer", target: nil, action: nil)
    private let commitButton = NSButton(title: "Enregistrer, commit et push", target: nil, action: nil)
    private let findButton = NSButton(title: "Rechercher", target: nil, action: nil)
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private var quickLook: QLPreviewView?
    private let placeholder = NSTextField(labelWithString: "Sélectionnez un fichier texte dans le panneau pour le modifier ici.")
    private let statusLeft = NSTextField(labelWithString: "")
    private let statusRight = NSTextField(labelWithString: "")
    private var highlightWork: DispatchWorkItem?
    private var isLoading = false

    override func loadView() {
        Self.instances.add(self)
        let root = NSView()

        tabs.orientation = .horizontal
        tabs.spacing = 2
        let tabScroll = NSScrollView()
        tabScroll.documentView = tabs
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = false
        tabs.translatesAutoresizingMaskIntoConstraints = false

        for button in [findButton, saveButton, commitButton] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.target = self
        }
        findButton.action = #selector(showSearch(_:))
        findButton.toolTip = "Rechercher et remplacer dans le fichier (⌘F)"
        saveButton.action = #selector(saveDocument(_:))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.toolTip = "Enregistrer (⌘S)"
        commitButton.action = #selector(saveCommitAndPush(_:))
        commitButton.keyEquivalent = "s"
        commitButton.keyEquivalentModifierMask = [.command, .option]
        commitButton.toolTip = "Enregistrer, puis git add, commit et push de ce fichier (⌥⌘S)"
        commitButton.isHidden = true
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer l’onglet")!,
                             target: self, action: #selector(closeCurrent))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Fermer l’onglet"
        let header = NSStackView(views: [tabScroll, findButton, saveButton, commitButton, close])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        tabScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureTextView()
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.lineBreakMode = .byWordWrapping

        for label in [statusLeft, statusRight] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        statusLeft.lineBreakMode = .byTruncatingTail
        statusLeft.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSStackView(views: [statusLeft, NSView(), statusRight])
        status.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        let topLine = NSBox(), bottomLine = NSBox()
        topLine.boxType = .separator
        bottomLine.boxType = .separator
        for view in [header, topLine, textScroll, placeholder, bottomLine, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),
            tabScroll.heightAnchor.constraint(equalTo: header.heightAnchor),
            tabs.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            topLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            textScroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            textScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            placeholder.centerXAnchor.constraint(equalTo: textScroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: textScroll.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: textScroll.widthAnchor, constant: -40),
            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24),
        ])
        ThemeBackgroundView.install(.toolbar, in: root, bottom: root.safeAreaLayoutGuide.topAnchor)
        ThemeBackgroundView.install(.header, in: root, top: root.safeAreaLayoutGuide.topAnchor, bottom: topLine.bottomAnchor)
        ThemeBackgroundView.install(.panel, in: root, top: topLine.bottomAnchor)
        view = root
        showDocument(nil)
    }

    private func configureTextView() {
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.hasHorizontalScroller = true
        textScroll.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.delegate = self
        // Lignes longues : défilement horizontal plutôt que retour à la ligne (code).
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        let ruler = LineNumberRuler(textView: textView)
        textScroll.verticalRulerView = ruler
        textScroll.hasVerticalRuler = true
        textScroll.rulersVisible = true
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    // MARK: Suivre la sélection du panneau

    /// Un seul fichier sélectionné : il s'ouvre (le dernier onglet non modifié est réutilisé, comme un aperçu).
    func follow(_ items: [FileItem]) {
        guard isViewLoaded, items.count == 1, let item = items.first, !item.isNavigableDirectory, item.url.isFileURL else { return }
        open(item.url)
    }

    func open(_ url: URL) {
        if let existing = documents.first(where: { $0.url == url }) {
            if !existing.isModified, let fresh = Self.load(url) { existing.text = fresh.text; existing.encoding = fresh.encoding }
            showDocument(existing)
            return
        }
        guard let loaded = Self.load(url) else {
            showQuickLook(url)
            return
        }
        let document = Document(url: url, text: loaded.text, encoding: loaded.encoding)
        if let reusable = current, !reusable.isModified, let index = documents.firstIndex(where: { $0 === reusable }) {
            documents[index] = document
        } else {
            documents.append(document)
            if documents.count > 10, let index = documents.firstIndex(where: { !$0.isModified && $0 !== current }) { documents.remove(at: index) }
        }
        showDocument(document)
        lookUpGit(document)
    }

    /// Texte du fichier (UTF-8, sinon Latin-1), ou `nil` pour un fichier binaire ou trop gros.
    private static func load(_ url: URL) -> (text: String, encoding: String.Encoding)? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size < 5_000_000, let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let looksText = type?.conforms(to: .text) == true || SyntaxHighlighter.language(for: url) != nil || type == nil
        guard looksText, !data.prefix(8000).contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, .isoLatin1) }
        return nil
    }

    private func showQuickLook(_ url: URL) {
        storeSelection()
        current = nil
        if quickLook == nil, let preview = QLPreviewView(frame: .zero, style: .normal) {
            preview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: textScroll.topAnchor),
                preview.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: textScroll.trailingAnchor),
                preview.bottomAnchor.constraint(equalTo: textScroll.bottomAnchor),
            ])
            quickLook = preview
        }
        quickLook?.previewItem = url as NSURL
        quickLook?.isHidden = false
        textScroll.isHidden = true
        placeholder.isHidden = true
        saveButton.isHidden = true
        commitButton.isHidden = true
        findButton.isHidden = true
        statusLeft.stringValue = "Aperçu · \(url.lastPathComponent)"
        statusRight.stringValue = ""
        rebuildTabs()
    }

    private func showDocument(_ document: Document?) {
        storeSelection()
        current = document
        quickLook?.isHidden = true
        quickLook?.previewItem = nil
        textScroll.isHidden = document == nil
        placeholder.isHidden = document != nil
        saveButton.isHidden = document == nil
        findButton.isHidden = document == nil
        if let document {
            isLoading = true
            textView.string = document.text
            textView.undoManager?.removeAllActions()
            applyHighlight()
            isLoading = false
            textView.setSelectedRange(NSRange(location: min(document.selection.location, (document.text as NSString).length), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        updateState()
        rebuildTabs()
    }

    private func storeSelection() {
        current?.selection = textView.selectedRange()
    }

    // MARK: Onglets

    private func rebuildTabs() {
        tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for document in documents {
            let title = document.url.lastPathComponent + (document.isModified ? " ●" : "")
            let button = NSButton(title: title, target: self, action: #selector(selectTab(_:)))
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.setButtonType(.pushOnPushOff)
            button.state = document === current ? .on : .off
            button.toolTip = document.url.path
            button.tag = documents.firstIndex { $0 === document } ?? 0
            tabs.addArrangedSubview(button)
        }
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard documents.indices.contains(sender.tag) else { return }
        showDocument(documents[sender.tag])
    }

    @objc private func closeCurrent() {
        guard let document = current else {
            showDocument(documents.last)
            return
        }
        if document.isModified {
            let alert = NSAlert()
            alert.messageText = "Enregistrer les modifications de « \(document.url.lastPathComponent) » ?"
            alert.addButton(withTitle: "Enregistrer")
            alert.addButton(withTitle: "Annuler")
            alert.addButton(withTitle: "Ne pas enregistrer")
            switch alert.runModal() {
            case .alertFirstButtonReturn: guard save(document) else { return }
            case .alertSecondButtonReturn: return
            default: break
            }
        }
        documents.removeAll { $0 === document }
        current = nil
        showDocument(documents.last)
    }

    // MARK: Édition

    func textDidChange(_ notification: Notification) {
        guard !isLoading, let document = current else { return }
        document.text = textView.string
        if !document.isModified {
            document.isModified = true
            rebuildTabs()
        }
        updateState()
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyHighlight() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateStatus()
    }

    /// Couleurs de la coloration syntaxique appliquées sans toucher au texte (l'annulation reste intacte).
    private func applyHighlight() {
        guard let document = current, let storage = textView.textStorage else { return }
        let text = textView.string
        let length = (text as NSString).length
        storage.beginEditing()
        storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.textColor], range: NSRange(location: 0, length: length))
        if length < 400_000, let language = SyntaxHighlighter.language(for: document.url) {
            let dark = Theme.isDark(view.effectiveAppearance)
            let colored = SyntaxHighlighter.highlight(text, language: language, dark: dark)
            colored.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: min(length, colored.length))) { value, range, _ in
                if let color = value as? NSColor, color != NSColor.textColor { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.textColor]
    }

    private func updateState() {
        saveButton.isEnabled = current?.isModified == true
        let root = current?.gitRoot ?? nil
        commitButton.isHidden = current == nil || root == nil
        updateStatus()
    }

    private func updateStatus() {
        guard let document = current else {
            if quickLook?.isHidden != false { statusLeft.stringValue = ""; statusRight.stringValue = "" }
            return
        }
        let text = textView.string as NSString
        let location = min(textView.selectedRange().location, text.length)
        let before = text.substring(to: location)
        let line = before.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let lastNewline = (before as NSString).range(of: "\n", options: .backwards).location
        let column = lastNewline == NSNotFound ? location + 1 : location - lastNewline
        let language = SyntaxHighlighter.language(for: document.url).map { "\($0)".capitalized } ?? "Texte"
        let endings = document.text.contains("\r\n") ? "CRLF" : "LF"
        let encoding = document.encoding == .utf8 ? "UTF-8" : "ISO Latin-1"
        statusLeft.stringValue = "\(language) · \(encoding) · \(endings) · Ligne \(line), colonne \(column)"
        let root = document.gitRoot ?? nil
        statusRight.stringValue = root.map { "Git : \($0.lastPathComponent)" + (document.isModified ? " · non enregistré" : "") } ?? (document.isModified ? "Non enregistré" : "")
    }

    // MARK: Enregistrer

    @objc func saveDocument(_ sender: Any?) {
        guard let document = current else { return }
        _ = save(document)
    }

    @discardableResult
    private func save(_ document: Document) -> Bool {
        if document === current { document.text = textView.string }
        do {
            guard let data = document.text.data(using: document.encoding) else {
                throw NSError(domain: "iExplorer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Le texte contient des caractères impossibles à écrire dans l’encodage du fichier."])
            }
            try data.write(to: document.url, options: .atomic)
            document.isModified = false
            rebuildTabs()
            updateState()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Le fichier est-il suivi par Git ? (question posée en arrière-plan, une fois par document)
    private func lookUpGit(_ document: Document) {
        guard document.gitRoot == nil else { return }
        guard GitService.shared.isAvailable, let root = GitService.shared.repositoryRoot(for: document.url) else {
            document.gitRoot = .some(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = document.url.resolvingSymlinksInPath().path
            let tracked = GitCommand.run(["ls-files", "--error-unmatch", "--", path], in: root).succeeded
            DispatchQueue.main.async {
                document.gitRoot = .some(tracked ? root : nil)
                if document === self?.current { self?.updateState() }
            }
        }
    }

    @objc func saveCommitAndPush(_ sender: Any?) {
        guard let document = current, let root = document.gitRoot ?? nil else { return }
        if document.isModified { guard save(document) else { return } }
        let alert = NSAlert()
        alert.messageText = "Commit et push de « \(document.url.lastPathComponent) »"
        alert.informativeText = "Seul ce fichier est ajouté au commit, puis poussé vers la branche distante."
        let field = NSTextField(string: "Mise à jour de \(document.url.lastPathComponent)")
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Commit et push")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let message = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { NSSound.beep(); return }
        let path = document.url.resolvingSymlinksInPath().path
        commitButton.isEnabled = false
        statusRight.stringValue = "Commit et push en cours…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            let add = GitCommand.run(["add", "--", path], in: root)
            if !add.succeeded { failure = add.error }
            if failure == nil {
                let commit = GitCommand.run(["commit", "-m", message, "--", path], in: root)
                if !commit.succeeded { failure = commit.error.isEmpty ? commit.output : commit.error }
            }
            var pushed = false
            if failure == nil {
                let push = GitCommand.run(["push"], in: root)
                pushed = push.succeeded
                if !push.succeeded { failure = "Le commit est fait, mais le push a échoué :\n" + push.error }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.commitButton.isEnabled = true
                self.updateStatus()
                if let failure {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Git"
                    alert.informativeText = failure.trimmingCharacters(in: .whitespacesAndNewlines)
                    alert.runModal()
                } else if pushed {
                    self.statusRight.stringValue = "Commit et push effectués"
                }
            }
        }
    }

    /// ⌘F dans l'éditeur : barre de recherche du texte (et non la recherche du panneau).
    @objc func showSearch(_ sender: Any?) {
        guard current != nil else { return }
        view.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        textView.performTextFinderAction(item)
    }
}

/// Numéros de ligne dans la marge de l'éditeur.
private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                                                         .foregroundColor: NSColor.tertiaryLabelColor]
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = text.substring(to: characters.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var index = characters.location
        let inset = textView.textContainerInset.height
        while index <= NSMaxRange(characters) && index <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: min(index, max(0, text.length - 1)), length: 0))
            let glyph = layout.glyphIndexForCharacter(at: min(index, max(0, text.length - 1)))
            var rectLine = text.length == 0 ? .zero : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rectLine.origin.y += inset - visible.minY
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: rectLine.minY + (rectLine.height - size.height) / 2), withAttributes: attributes)
            if text.length == 0 || NSMaxRange(lineRange) <= index { break }
            index = NSMaxRange(lineRange)
            line += 1
            if index == text.length, !text.hasSuffix("\n") { break }
        }
    }
}
