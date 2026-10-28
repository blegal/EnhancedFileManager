import AppKit

/// Commandes git ponctuelles (indexer, valider, pousser…) avec la saisie des identifiants via l'app.
enum GitCommand {
    struct Output {
        let status: Int32
        let output: String
        let error: String
        var succeeded: Bool { status == 0 }
    }

    static func run(_ arguments: [String], in repository: URL) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        // Pas de saisie dans un terminal : phrases de passe et identifiants passent par la fenêtre de l'app.
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["SSH_ASKPASS"] = executable
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["GIT_ASKPASS"] = executable
        environment["EFM_ASKPASS"] = "1"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Output(status: -1, output: "", error: error.localizedDescription)
        }
        // Lecture des deux flux en parallèle (évite le blocage sur une sortie volumineuse).
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                      error: String(decoding: errorData, as: UTF8.self))
    }
}

/// Section « Git » de l'inspecteur : état, actions, diff et historique de l'élément sélectionné.
final class GitInspectorSection: NSStackView {
    private let header = NSTextField(labelWithString: "Git")
    private let summary = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let diffScroll = NSTextView.scrollableTextView()
    private var diffView: NSTextView { diffScroll.documentView as! NSTextView }
    private let historyView = NSTextField(wrappingLabelWithString: "")
    private var buttons: [String: NSButton] = [:]
    private let spinner = NSProgressIndicator()

    private var repository: URL?
    private var relativePath = ""
    private var target: URL?
    private var generation = 0

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        let line = NSBox()
        line.boxType = .separator
        summary.font = .systemFont(ofSize: 12)
        summary.lineBreakMode = .byTruncatingTail
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        // Boutons compacts (icône + info-bulle) : l'inspecteur est étroit.
        func button(_ key: String, _ title: String, _ symbol: String, _ tip: String) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: #selector(runAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(key)
            button.bezelStyle = .accessoryBarAction
            button.toolTip = "\(title) (\(tip))"
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            buttons[key] = button
            return button
        }
        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = .tertiaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
            return label
        }
        let fileRow = NSStackView(views: [
            caption("Fichier"),
            button("add", "Indexer", "plus.circle", "git add"),
            button("unstage", "Désindexer", "minus.circle", "git restore --staged"),
            button("discard", "Abandonner les modifications", "arrow.uturn.backward.circle", "git restore"),
        ])
        let repoRow = NSStackView(views: [
            caption("Dépôt"),
            button("commit", "Valider…", "checkmark.circle", "git commit"),
            button("fetch", "Récupérer", "arrow.triangle.2.circlepath.circle", "git fetch"),
            button("pull", "Tirer", "arrow.down.circle", "git pull --ff-only"),
            button("push", "Pousser", "arrow.up.circle", "git push"),
            spinner,
        ])
        fileRow.spacing = 4
        repoRow.spacing = 4
        let fileActions = NSStackView(views: [fileRow, repoRow])
        fileActions.orientation = .vertical
        fileActions.alignment = .leading
        fileActions.spacing = 4

        diffView.isEditable = false
        diffView.drawsBackground = true
        diffView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6)
        diffView.textContainerInset = NSSize(width: 4, height: 4)
        diffView.isHorizontallyResizable = true
        diffView.textContainer?.widthTracksTextView = false
        diffView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffScroll.hasVerticalScroller = true
        diffScroll.hasHorizontalScroller = true
        diffScroll.autohidesScrollers = true
        diffScroll.borderType = .noBorder
        diffScroll.wantsLayer = true
        diffScroll.layer?.cornerRadius = 6
        diffScroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        historyView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        historyView.textColor = .secondaryLabelColor

        let diffTitle = NSTextField(labelWithString: "Modifications")
        diffTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        let historyTitle = NSTextField(labelWithString: "Historique")
        historyTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        for view in [header, line, summary, fileActions, message, diffTitle, diffScroll, historyTitle, historyView] {
            addArrangedSubview(view)
        }
        line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        diffScroll.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        historyView.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        setCustomSpacing(10, after: fileActions)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Affiche l'état Git de `url` (masqué hors d'un dépôt).
    func show(_ url: URL?) {
        generation += 1
        let current = generation
        guard let url, url.isFileURL else { isHidden = true; return }
        // Attend que la sélection soit stable avant de lancer git.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            guard GitService.shared.isAvailable, let root = GitService.shared.repositoryRoot(for: url) else {
                DispatchQueue.main.async { if self.isCurrent(current) { self.isHidden = true } }
                return
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            let relative = resolved == root.path ? "." : String(resolved.dropFirst(root.path.count + 1))
            let status = GitService.shared.status(ofRepository: root, includeIgnored: false)
            let state = status?.state(forRelativePath: relative, isDirectory: url.isExistingDirectory)
            let diff = Self.diff(relative, in: root, untracked: state == .untracked)
            let log = GitCommand.run(["log", "-n", "20", "--date=short", "--pretty=format:%h  %ad  %an%n    %s", "--", relative], in: root).output
            DispatchQueue.main.async {
                guard self.isCurrent(current) else { return }
                self.repository = root
                self.relativePath = relative
                self.target = url
                self.update(summary: status?.summary, state: state, diff: diff, log: log)
            }
        }
    }

    private func isCurrent(_ value: Int) -> Bool {
        if Thread.isMainThread { return value == generation }
        return DispatchQueue.main.sync { value == generation }
    }

    private static func diff(_ relative: String, in root: URL, untracked: Bool) -> String {
        if untracked {
            return GitCommand.run(["diff", "--no-index", "--no-color", "--", "/dev/null", relative], in: root).output
        }
        let output = GitCommand.run(["diff", "--no-color", "HEAD", "--", relative], in: root)
        return output.succeeded ? output.output : GitCommand.run(["diff", "--no-color", "--cached", "--", relative], in: root).output
    }

    private func update(summary: GitSummary?, state: GitFileState?, diff: String, log: String) {
        isHidden = false
        var parts: [String] = []
        if let branch = summary?.branch { parts.append("⎇ \(branch)") }
        if let summary, summary.ahead > 0 { parts.append("↑\(summary.ahead) à pousser") }
        if let summary, summary.behind > 0 { parts.append("↓\(summary.behind) à tirer") }
        let stateText: String = switch state {
        case .modified?: "modifié"
        case .added?: "ajouté"
        case .untracked?: "non suivi"
        case .deleted?: "supprimé"
        case .renamed?: "renommé"
        case .conflict?: "en conflit"
        case .ignored?: "ignoré"
        case nil: "à jour"
        }
        parts.append(stateText)
        self.summary.stringValue = parts.joined(separator: " · ")
        self.summary.textColor = state?.color ?? .labelColor
        let hasChanges = state != nil && state != .ignored
        buttons["add"]?.isEnabled = hasChanges
        buttons["unstage"]?.isEnabled = hasChanges && state != .untracked
        buttons["discard"]?.isEnabled = hasChanges && state != .untracked
        buttons["push"]?.isEnabled = (summary?.ahead ?? 0) > 0 || summary?.hasUpstream == false
        buttons["pull"]?.isEnabled = summary?.hasUpstream == true
        diffView.textStorage?.setAttributedString(Self.colorize(diff.isEmpty ? "Aucune modification." : String(diff.prefix(60_000))))
        // La section vient peut-être de redevenir visible : recalcul de la mise en page du texte.
        if let container = diffView.textContainer { diffView.layoutManager?.ensureLayout(for: container) }
        diffView.sizeToFit()
        diffView.scroll(.zero)
        historyView.stringValue = log.isEmpty ? "Aucun commit pour cet élément." : log
    }

    /// Diff coloré : ajouts en vert, suppressions en rouge, en-têtes de bloc en bleu.
    private static func colorize(_ diff: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let result = NSMutableAttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let color: NSColor = if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                .secondaryLabelColor
            } else if line.hasPrefix("+") {
                GitFileState.added.color
            } else if line.hasPrefix("-") {
                GitFileState.deleted.color
            } else if line.hasPrefix("@@") {
                .systemBlue
            } else {
                .textColor
            }
            result.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }

    // MARK: Actions

    @objc private func runAction(_ sender: NSButton) {
        guard let repository, let key = sender.identifier?.rawValue else { return }
        let path = relativePath
        switch key {
        case "add": execute(["add", "--", path], label: "Indexé")
        case "unstage": execute(["restore", "--staged", "--", path], label: "Désindexé")
        case "discard":
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Abandonner les modifications de « \((path as NSString).lastPathComponent) » ?"
            alert.informativeText = "Le fichier revient à sa version du dernier commit. Cette action est irréversible."
            alert.addButton(withTitle: "Abandonner").hasDestructiveAction = true
            alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            execute(["restore", "--", path], label: "Modifications abandonnées")
        case "commit": commit(in: repository)
        case "fetch": execute(["fetch", "--prune"], label: "Récupération terminée")
        case "pull": execute(["pull", "--ff-only"], label: "Branche à jour")
        case "push":
            let hasUpstream = GitCommand.run(["rev-parse", "--abbrev-ref", "@{u}"], in: repository).succeeded
            execute(hasUpstream ? ["push"] : ["push", "-u", "origin", "HEAD"], label: "Poussé")
        default: break
        }
    }

    private func commit(in repository: URL) {
        let alert = NSAlert()
        alert.messageText = "Valider (commit)"
        alert.informativeText = "Message du commit :"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        let all = NSButton(checkboxWithTitle: "Inclure tous les fichiers suivis modifiés (-a)", target: nil, action: nil)
        let box = NSStackView(views: [field, all])
        box.orientation = .vertical
        box.alignment = .leading
        box.frame = NSRect(x: 0, y: 0, width: 320, height: 52)
        alert.accessoryView = box
        alert.addButton(withTitle: "Valider")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        execute(["commit"] + (all.state == .on ? ["-a"] : []) + ["-m", text], label: "Commit créé")
    }

    /// Lance une commande git en arrière-plan puis rafraîchit la section et les panneaux.
    private func execute(_ arguments: [String], label: String) {
        guard let repository else { return }
        spinner.startAnimation(nil)
        buttons.values.forEach { $0.isEnabled = false }
        message.isHidden = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = GitCommand.run(arguments, in: repository)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                spinner.stopAnimation(nil)
                let detail = (output.succeeded ? output.output : output.error).trimmingCharacters(in: .whitespacesAndNewlines)
                message.stringValue = output.succeeded ? "✓ \(label)" + (detail.isEmpty ? "" : "\n" + detail.suffix(400)) : "⚠︎ " + String(detail.suffix(600))
                message.textColor = output.succeeded ? .secondaryLabelColor : .systemRed
                message.isHidden = false
                show(target)
                // Les panneaux surveillent le dépôt (FSEvents) et se mettent à jour d'eux-mêmes.
            }
        }
    }
}
