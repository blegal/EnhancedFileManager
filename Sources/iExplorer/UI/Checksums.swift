import AppKit
import CryptoKit

/// Algorithmes d'empreinte proposés (MD5 et SHA-1 pour la compatibilité, SHA-256 par défaut).
enum ChecksumAlgorithm: String, CaseIterable {
    case md5 = "MD5", sha1 = "SHA-1", sha256 = "SHA-256"

    var fileExtension: String {
        switch self {
        case .md5: "md5"
        case .sha1: "sha1"
        case .sha256: "sha256"
        }
    }

    /// Longueur de l'empreinte en hexadécimal : permet de reconnaître l'algorithme d'une empreinte collée.
    var hexLength: Int {
        switch self {
        case .md5: 32
        case .sha1: 40
        case .sha256: 64
        }
    }
}

enum Checksums {
    static let listExtensions: Set<String> = ["md5", "sha1", "sha256"]

    struct Cancelled: Error {}

    /// Empreintes d'un fichier, lu par blocs de 1 Mo (les gros fichiers ne passent pas en mémoire).
    static func compute(_ url: URL, progress: (Double) -> Void, isCancelled: () -> Bool) throws -> [ChecksumAlgorithm: String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256()
        var done = 0.0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if isCancelled() { throw Cancelled() }
            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
            done += Double(chunk.count)
            if total > 0 { progress(done / total) }
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
        return [.md5: hex(md5.finalize()), .sha1: hex(sha1.finalize()), .sha256: hex(sha256.finalize())]
    }

    /// Lignes d'un fichier de sommes : « empreinte  nom », « empreinte *nom » (shasum, md5sum)
    /// ou « SHA256 (nom) = empreinte » (format BSD de macOS).
    static func parseList(_ text: String) -> [(hash: String, name: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = line.firstIndex(of: "("), let close = line.range(of: ") = ", options: .backwards), open < close.lowerBound {
                return (String(line[close.upperBound...]).lowercased(), String(line[line.index(after: open)..<close.lowerBound]))
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].allSatisfy(\.isHexDigit) else { return nil }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            return (parts[0].lowercased(), name)
        }
    }

    static func algorithm(forHexLength length: Int) -> ChecksumAlgorithm? {
        ChecksumAlgorithm.allCases.first { $0.hexLength == length }
    }
}

/// Fenêtre des sommes de contrôle : calcule MD5, SHA-1 et SHA-256 des fichiers choisis,
/// vérifie une empreinte collée, ou contrôle un fichier de sommes (.sha256, .md5…).
final class ChecksumWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ChecksumWindowController] = []

    private enum Mode {
        case compute([URL])
        /// Fichier de sommes : entrées à vérifier, relatives à son dossier.
        case verify(list: URL, entries: [(hash: String, name: String)])
    }

    private let mode: Mode
    private var results: [URL: [ChecksumAlgorithm: String]] = [:]
    private var cancelled = false
    private let rows = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let verifyField = NSTextField()
    private let verifyResult = NSTextField(labelWithString: "")
    private var hashLabels: [URL: [ChecksumAlgorithm: NSTextField]] = [:]
    private var statusIcons: [URL: NSTextField] = [:]

    static func show(files: [URL]) {
        let files = files.filter { !$0.hasDirectoryPath && !$0.isExistingDirectory }
        guard !files.isEmpty else { NSSound.beep(); return }
        // Un fichier de sommes seul : on vérifie son contenu.
        if files.count == 1, let list = files.first, Checksums.listExtensions.contains(list.pathExtension.lowercased()),
           let text = try? String(contentsOf: list, encoding: .utf8) {
            let entries = Checksums.parseList(text)
            if !entries.isEmpty { present(ChecksumWindowController(mode: .verify(list: list, entries: entries))); return }
        }
        present(ChecksumWindowController(mode: .compute(files)))
    }

    private static func present(_ controller: ChecksumWindowController) {
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        controller.start()
    }

    private init(mode: Mode) {
        self.mode = mode
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 280)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var files: [URL] {
        switch mode {
        case .compute(let files): files
        case .verify(let list, let entries): entries.map { list.deletingLastPathComponent().appendingPathComponent($0.name) }
        }
    }

    private func build() {
        guard let window, let content = window.contentView else { return }
        switch mode {
        case .compute(let files): window.title = files.count == 1 ? "Sommes de contrôle — \(files[0].lastPathComponent)" : "Sommes de contrôle — \(files.count) fichiers"
        case .verify(let list, _): window.title = "Vérification — \(list.lastPathComponent)"
        }
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for url in files { rows.addArrangedSubview(row(for: url)) }
        let scroll = NSScrollView()
        let flipped = FlippedView()
        flipped.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = flipped
        flipped.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: flipped.topAnchor),
            rows.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        var bottom: [NSView] = []
        if case .compute = mode {
            verifyField.placeholderString = "Coller une empreinte pour la vérifier (MD5, SHA-1 ou SHA-256)"
            verifyField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            verifyField.target = self
            verifyField.action = #selector(verifyPasted)
            NotificationCenter.default.addObserver(self, selector: #selector(verifyPasted), name: NSControl.textDidChangeNotification, object: verifyField)
            verifyResult.font = .systemFont(ofSize: 12, weight: .medium)
            let line = NSStackView(views: [verifyField, verifyResult])
            line.spacing = 8
            verifyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            bottom.append(line)
        }
        let copy = NSButton(title: "Copier les SHA-256", target: self, action: #selector(copySHA256))
        let save = NSButton(title: "Enregistrer un fichier .sha256…", target: self, action: #selector(saveList))
        let close = NSButton(title: "Fermer", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        let buttons: NSStackView
        if case .compute = mode {
            buttons = NSStackView(views: [statusLabel, NSView(), copy, save, close])
        } else {
            buttons = NSStackView(views: [statusLabel, NSView(), close])
        }
        buttons.spacing = 8
        bottom.append(buttons)

        let stack = NSStackView(views: [scroll, progress] + bottom)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 14, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [progress] + bottom {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func row(for url: URL) -> NSView {
        let icon = NSTextField(labelWithString: "…")
        icon.font = .systemFont(ofSize: 13, weight: .bold)
        icon.textColor = .secondaryLabelColor
        statusIcons[url] = icon
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        let title = NSStackView(views: [icon, name])
        title.spacing = 6
        var lines: [NSView] = [title]
        let algorithms: [ChecksumAlgorithm]
        if case .verify(_, let entries) = mode, let entry = entries.first(where: { $0.name == url.lastPathComponent }),
           let algorithm = Checksums.algorithm(forHexLength: entry.hash.count) {
            algorithms = [algorithm]
        } else if case .verify = mode {
            algorithms = []
        } else {
            algorithms = ChecksumAlgorithm.allCases
        }
        var labels: [ChecksumAlgorithm: NSTextField] = [:]
        for algorithm in algorithms {
            let tag = NSTextField(labelWithString: algorithm.rawValue)
            tag.font = .systemFont(ofSize: 11)
            tag.textColor = .secondaryLabelColor
            tag.widthAnchor.constraint(equalToConstant: 60).isActive = true
            let value = NSTextField(labelWithString: "calcul…")
            value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            value.isSelectable = true
            value.lineBreakMode = .byCharWrapping
            labels[algorithm] = value
            let line = NSStackView(views: [tag, value])
            line.spacing = 6
            line.alignment = .firstBaseline
            lines.append(line)
        }
        hashLabels[url] = labels
        let stack = NSStackView(views: lines)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func start() {
        let files = files
        let total = Double(files.count)
        statusLabel.stringValue = "Calcul en cours…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (index, url) in files.enumerated() {
                guard let self, !cancelled else { return }
                let result: [ChecksumAlgorithm: String]?
                do {
                    result = try Checksums.compute(url, progress: { fraction in
                        DispatchQueue.main.async { self.progress.doubleValue = (Double(index) + fraction) / total }
                    }, isCancelled: { self.cancelled })
                } catch is Checksums.Cancelled {
                    return
                } catch {
                    result = nil
                }
                DispatchQueue.main.async { self.show(result, for: url) }
            }
            DispatchQueue.main.async { self?.finish() }
        }
    }

    private func show(_ result: [ChecksumAlgorithm: String]?, for url: URL) {
        guard let result else {
            statusIcons[url]?.stringValue = "✗"
            statusIcons[url]?.textColor = .systemRed
            hashLabels[url]?.values.forEach { $0.stringValue = "fichier illisible ou absent" }
            if hashLabels[url]?.isEmpty ?? true { statusIcons[url]?.toolTip = "Fichier illisible ou absent" }
            return
        }
        results[url] = result
        for (algorithm, label) in hashLabels[url] ?? [:] { label.stringValue = result[algorithm] ?? "" }
        switch mode {
        case .compute:
            statusIcons[url]?.stringValue = "✓"
            statusIcons[url]?.textColor = .secondaryLabelColor
        case .verify(_, let entries):
            guard let entry = entries.first(where: { $0.name == url.lastPathComponent }) else { return }
            let ok = result.values.contains(entry.hash)
            statusIcons[url]?.stringValue = ok ? "✓" : "✗"
            statusIcons[url]?.textColor = ok ? .systemGreen : .systemRed
        }
        verifyPasted()
    }

    private func finish() {
        progress.isHidden = true
        switch mode {
        case .compute:
            statusLabel.stringValue = "\(results.count) fichier\(results.count > 1 ? "s" : "") calculé\(results.count > 1 ? "s" : "")"
        case .verify(_, let entries):
            let good = entries.filter { entry in
                files.first { $0.lastPathComponent == entry.name }.flatMap { results[$0] }?.values.contains(entry.hash) == true
            }.count
            statusLabel.stringValue = good == entries.count ? "Tout est conforme (\(good) fichiers)" : "\(entries.count - good) fichier(s) non conforme(s) sur \(entries.count)"
            statusLabel.textColor = good == entries.count ? .systemGreen : .systemRed
        }
    }

    @objc private func verifyPasted() {
        let pasted = verifyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pasted.isEmpty else { verifyResult.stringValue = ""; return }
        let match = results.first { $0.value.values.contains(pasted) }
        if let match {
            let algorithm = match.value.first { $0.value == pasted }?.key.rawValue ?? ""
            verifyResult.stringValue = "✓ \(algorithm) de \(match.key.lastPathComponent)"
            verifyResult.textColor = .systemGreen
        } else {
            verifyResult.stringValue = Checksums.algorithm(forHexLength: pasted.count) == nil ? "Empreinte non reconnue" : "✗ Aucune correspondance"
            verifyResult.textColor = .systemRed
        }
    }

    /// Format shasum : « empreinte  nom », une ligne par fichier.
    private var sha256List: String {
        files.compactMap { url in results[url]?[.sha256].map { "\($0)  \(url.lastPathComponent)" } }.joined(separator: "\n") + "\n"
    }

    @objc private func copySHA256() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sha256List.trimmingCharacters(in: .newlines), forType: .string)
    }

    @objc private func saveList() {
        guard let window, let first = files.first else { return }
        let panel = NSSavePanel()
        panel.directoryURL = first.deletingLastPathComponent()
        panel.nameFieldStringValue = (files.count == 1 ? first.lastPathComponent : "SHA256SUMS") + ".sha256"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try sha256List.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func closeWindow() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        cancelled = true
        Self.open.removeAll { $0 === self }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension PanelViewController {
    @objc func showChecksums(_ sender: Any?) {
        ChecksumWindowController.show(files: selectedItems.filter { !$0.isNavigableDirectory }.map(\.url))
    }
}
