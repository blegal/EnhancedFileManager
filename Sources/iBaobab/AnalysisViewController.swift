import AppKit
import DiskUsageKit

/// Onglet d'analyse : barre de navigation (précédent, suivant, parent, fil d'Ariane, Finder)
/// au-dessus de la vue d'occupation partagée avec EnhancedFileManager.
final class AnalysisViewController: NSViewController, NSMenuItemValidation {
    var onOpenInNewTab: ((URL) -> Void)?

    let usage = DiskUsageView()
    private let history = NSSegmentedControl()
    private let upButton = NSButton()
    private let pathControl = NSPathControl()
    private let finderButton = NSButton()
    private weak var source: AnalysisViewController?

    private(set) var currentURL: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    init(url: URL, source: AnalysisViewController?) {
        currentURL = url.standardizedFileURL
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 680))

        history.segmentCount = 2
        history.trackingMode = .momentary
        history.segmentStyle = .separated
        history.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Précédent"), forSegment: 0)
        history.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Suivant"), forSegment: 1)
        history.setToolTip("Précédent (⌘[)", forSegment: 0)
        history.setToolTip("Suivant (⌘])", forSegment: 1)
        history.target = self
        history.action = #selector(historyClicked(_:))

        configure(upButton, symbol: "arrow.up", tip: "Dossier parent (⌘↑)", action: #selector(goUp(_:)))
        configure(finderButton, symbol: "macwindow", tip: "Afficher dans le Finder (⌥⌘R)", action: #selector(revealInFinder(_:)))

        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [history, upButton, pathControl, finderButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.setCustomSpacing(12, after: upButton)

        let separator = NSBox()
        separator.boxType = .separator

        for view in [bar, separator, usage] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            usage.topAnchor.constraint(equalTo: separator.bottomAnchor),
            usage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            usage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            usage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        usage.onNavigate = { [weak self] url in self?.navigate(to: url) }
        usage.onUp = { [weak self] in self?.goUp(nil) }
        usage.onExit = { [weak self] in self?.goBack(nil) }
        usage.onOpen = { url in NSWorkspace.shared.open(url) }
        usage.onOpenInNewTab = { [weak self] url in self?.onOpenInNewTab?(url) }
        usage.onTrash = { [weak self] url in self?.trash(url) }
        usage.onScanFinished = { url, size in RecentAnalyses.add(url, size: size) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let source { usage.show(currentURL, sharingTreeOf: source.usage) } else { usage.show(currentURL) }
        source = nil
        update()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(usage.focusView)
        update()
    }

    /// Fermeture de l'onglet : annule l'analyse et libère l'arbre.
    func close() {
        usage.stop()
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = true
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    // MARK: Navigation

    func navigate(to url: URL) {
        let url = url.standardizedFileURL
        guard url != currentURL else { return }
        backStack.append(currentURL)
        forwardStack.removeAll()
        go(to: url)
    }

    private func go(to url: URL) {
        currentURL = url
        usage.show(url)
        update()
    }

    @objc func goBack(_ sender: Any?) {
        guard let url = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        go(to: url)
    }

    @objc func goForward(_ sender: Any?) {
        guard let url = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        go(to: url)
    }

    /// Au-dessus du dossier analysé, le parent est analysé à son tour (en réutilisant l'arbre).
    @objc func goUp(_ sender: Any?) {
        guard currentURL.path != "/" else { NSSound.beep(); return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    @objc private func historyClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { goBack(sender) } else { goForward(sender) }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url else { return }
        if NSEvent.modifierFlags.contains(.command) { onOpenInNewTab?(url) } else { navigate(to: url) }
    }

    private func update() {
        history.setEnabled(!backStack.isEmpty, forSegment: 0)
        history.setEnabled(!forwardStack.isEmpty, forSegment: 1)
        upButton.isEnabled = currentURL.path != "/"
        pathControl.url = currentURL
        guard let window = view.window else { return }
        window.title = currentURL.displayName
        window.representedURL = currentURL
        window.tab.toolTip = currentURL.path
    }

    // MARK: Actions

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([currentURL])
    }

    @objc func rescan(_ sender: Any?) {
        usage.rescan()
    }

    @objc func selectStyle(_ sender: NSMenuItem) {
        guard let style = DiskChartStyle(rawValue: sender.tag) else { return }
        usage.style = style
    }

    private func trash(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            guard let self else { return }
            if let error {
                NSAlert(error: error).beginSheetModal(for: view.window ?? NSWindow())
                return
            }
            usage.remove(url)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goUp(_:)): return currentURL.path != "/"
        case #selector(selectStyle(_:)):
            menuItem.state = menuItem.tag == usage.style.rawValue ? .on : .off
            return true
        default: return true
        }
    }
}
