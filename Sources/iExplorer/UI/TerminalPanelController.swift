import AppKit
import SwiftTerm

/// Terminal intégré en bas de la fenêtre (SwiftTerm), qui peut suivre le dossier du panneau actif.
final class TerminalPanelController: NSViewController, LocalProcessTerminalViewDelegate {
    static var followsPanel: Bool {
        get { UserDefaults.standard.object(forKey: "terminal.follow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "terminal.follow") }
    }

    private let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    private let titleLabel = NSTextField(labelWithString: "Terminal")
    private let followButton = NSButton()
    private var started = false
    private var pendingDirectory: URL?
    private var appearanceObservation: NSKeyValueObservation?
    /// Dossier du panneau actif (local), utilisé au démarrage et par « Aller au dossier du panneau ».
    var panelDirectory: URL?

    override func loadView() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = Theme.secondaryText
        titleLabel.lineBreakMode = .byTruncatingHead
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        followButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Suivre le panneau actif")
        followButton.setButtonType(.pushOnPushOff)
        followButton.bezelStyle = .accessoryBarAction
        followButton.isBordered = true
        followButton.state = Self.followsPanel ? .on : .off
        followButton.toolTip = "Suivre le dossier du panneau actif"
        followButton.target = self
        followButton.action = #selector(toggleFollow(_:))

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            button.bezelStyle = .accessoryBarAction
            button.toolTip = tip
            return button
        }
        let goButton = button("arrow.down.right.and.arrow.up.left", "Aller au dossier du panneau actif", #selector(goToPanelDirectory(_:)))
        let restartButton = button("arrow.clockwise", "Redémarrer le shell", #selector(restart(_:)))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [icon, titleLabel, spacer, followButton, goButton, restartButton])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)

        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        applyThemeColors()
        NotificationCenter.default.addObserver(forName: ColorTheme.changed, object: nil, queue: .main) { [weak self] _ in self?.applyThemeColors() }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyThemeColors() }
        }
        terminal.optionAsMetaKey = true

        let separator = NSBox()
        separator.boxType = .separator
        let root = NSView()
        for view in [separator, bar, terminal] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
            terminal.topAnchor.constraint(equalTo: bar.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        ThemeBackgroundView.install(.terminal, in: root)
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startIfNeeded()
        view.window?.makeFirstResponder(terminal)
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "iExplorer"
        environment["LANG"] = environment["LANG"] ?? "fr_FR.UTF-8"
        let directory = panelDirectory?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        titleLabel.stringValue = (directory as NSString).abbreviatingWithTildeInPath
        terminal.startProcess(executable: shell, args: ["-l"], environment: environment.map { "\($0.key)=\($0.value)" },
                              execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: directory)
    }

    /// Le panneau actif a changé de dossier.
    func activePanelDidChange(to url: URL) {
        guard url.isFileURL else { return }
        panelDirectory = url
        guard started, Self.followsPanel else { return }
        changeDirectory(to: url)
    }

    /// Envoie `cd` seulement si le shell est au premier plan (pas de vim, top… en cours).
    private func changeDirectory(to url: URL) {
        let process = terminal.process
        guard let process, process.running else { return }
        let foreground = tcgetpgrp(process.childfd)
        guard foreground == process.shellPid else {
            pendingDirectory = url
            return
        }
        pendingDirectory = nil
        let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Ctrl-U efface la saisie en cours ; l'espace initial évite l'historique du shell.
        terminal.send(txt: "\u{15} cd \(quoted)\r")
    }

    /// Exécute une commande dans le shell, après s'être placé dans `folder`.
    func run(_ command: String, in folder: URL) {
        startIfNeeded()
        let quoted = "'" + folder.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Laisse au shell le temps de démarrer s'il vient d'être lancé.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.terminal.send(txt: "\u{15}cd \(quoted) && \(command)\r")
            self?.focus()
        }
    }

    @objc private func toggleFollow(_ sender: NSButton) {
        Self.followsPanel = sender.state == .on
        if Self.followsPanel, let panelDirectory { changeDirectory(to: panelDirectory) }
    }

    @objc private func goToPanelDirectory(_ sender: Any?) {
        if let panelDirectory { changeDirectory(to: panelDirectory) }
        view.window?.makeFirstResponder(terminal)
    }

    @objc private func restart(_ sender: Any?) {
        terminal.terminate()
        started = false
        startIfNeeded()
    }

    func focus() { view.window?.makeFirstResponder(terminal) }

    /// Couleurs du terminal : celles du thème, sinon celles du système.
    private func applyThemeColors() {
        guard let variant = Theme.variant(for: NSApp.effectiveAppearance) else {
            terminal.configureNativeColors()
            return
        }
        terminal.nativeBackgroundColor = NSColor(hex: variant.terminal)
        terminal.nativeForegroundColor = NSColor(hex: variant.terminalText)
        terminal.caretColor = NSColor(hex: variant.terminalAccent ?? variant.accent)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        if !title.isEmpty { titleLabel.stringValue = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let directory, let url = URL(string: directory), url.isFileURL {
            titleLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        }
        if let pendingDirectory { changeDirectory(to: pendingDirectory) }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        started = false
        titleLabel.stringValue = "Shell terminé — cliquez sur ↻ pour le redémarrer"
    }
}
