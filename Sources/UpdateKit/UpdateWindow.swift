import AppKit

/// Fenêtre de proposition : notes de version, puis progression de l'installation.
@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    var onInstall: () -> Void = {}
    var onLater: () -> Void = {}
    var onSkip: () -> Void = {}
    var onCancel: () -> Void = {}

    private let installButton = NSButton(title: "Installer", target: nil, action: nil)
    private let laterButton = NSButton(title: "Plus tard", target: nil, action: nil)
    private let skipButton = NSButton(title: "Ignorer cette version", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Annuler", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private var buttons: NSStackView!
    private var progressRow: NSStackView!

    init(release: Release, appName: String, current: AppVersion) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Mise à jour de \(appName)"
        window.minSize = NSSize(width: 460, height: 320)
        super.init(window: window)
        window.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "Une nouvelle version de \(appName) est disponible.")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let detail = NSTextField(wrappingLabelWithString:
            "La version \(release.version) est disponible ; vous avez la version \(current). Voulez-vous l’installer maintenant ?")
        let header = NSStackView(views: [title, detail])
        header.orientation = .vertical
        header.alignment = .leading
        let top = NSStackView(views: [icon, header])
        top.alignment = .top
        top.spacing = 14

        let notes = NSTextView.scrollableTextView()
        notes.borderType = .bezelBorder
        let text = notes.documentView as! NSTextView
        text.isEditable = false
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.textStorage?.setAttributedString(Self.render(release.notes))

        let notesTitle = NSTextField(labelWithString: "Notes de version :")
        notesTitle.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)

        progress.isIndeterminate = true
        progress.minValue = 0
        progress.maxValue = 1
        status.textColor = .secondaryLabelColor
        progressRow = NSStackView(views: [status, progress, cancelButton])
        progressRow.isHidden = true

        installButton.keyEquivalent = "\r"
        laterButton.keyEquivalent = "\u{1b}"
        for (button, action) in [(installButton, #selector(install)), (laterButton, #selector(later)),
                                 (skipButton, #selector(skip)), (cancelButton, #selector(cancel))] {
            button.target = self
            button.action = action
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttons = NSStackView(views: [skipButton, spacer, laterButton, installButton])

        let content = NSStackView(views: [top, notesTitle, notes, progressRow, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.setHuggingPriority(.defaultLow, for: .vertical)
        for view in [top, notes, progressRow!, buttons!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        notes.setContentHuggingPriority(.init(1), for: .vertical)
        notes.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Notes de version (Markdown de GitHub) : mise en forme simple, titres en gras.
    static func render(_ markdown: String) -> NSAttributedString {
        let source = markdown.isEmpty ? "Aucune note de version." : markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let level = line.prefix { $0 == "#" }.count
                guard level > 0, line.dropFirst(level).first == " " else { return String(line) }
                return "**\(line.dropFirst(level + 1))**"
            }
            .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let result = NSMutableAttributedString(
            attributedString: (try? NSAttributedString(markdown: source, options: options)) ?? NSAttributedString(string: source))
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
        result.enumerateAttribute(.inlinePresentationIntent, in: range) { value, subrange, _ in
            let intent = InlinePresentationIntent(rawValue: (value as? NSNumber)?.uintValue ?? 0)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                                              : NSFont.systemFont(ofSize: NSFont.systemFontSize)
            if !traits.isEmpty { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 0) ?? font }
            result.addAttribute(.font, value: font, range: subrange)
        }
        return result
    }

    func showProgress(_ message: String, fraction: Double?) {
        buttons.isHidden = true
        progressRow.isHidden = false
        status.stringValue = message
        progress.isIndeterminate = fraction == nil
        if let fraction { progress.doubleValue = fraction } else { progress.startAnimation(nil) }
    }

    func showProposal() {
        progress.stopAnimation(nil)
        progressRow.isHidden = true
        buttons.isHidden = false
    }

    @objc private func install() { onInstall() }
    @objc private func later() { onLater() }
    @objc private func skip() { onSkip() }
    @objc private func cancel() { onCancel() }

    func windowWillClose(_ notification: Notification) { onLater() }
}
