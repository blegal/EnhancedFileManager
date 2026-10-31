import AppKit
import CryptoKit

/// Algorithmes d'empreinte proposés (CRC32, MD5 et SHA-1 pour la compatibilité, SHA-256 par défaut).
enum ChecksumAlgorithm: String, CaseIterable {
    case crc32 = "CRC32", md5 = "MD5", sha1 = "SHA-1", sha256 = "SHA-256", sha512 = "SHA-512"

    /// Extension du fichier de somme posé à côté du fichier (« photo.jpg.sha256 », « photo.jpg.sfv »).
    var fileExtension: String {
        switch self {
        case .crc32: "sfv"
        case .md5: "md5"
        case .sha1: "sha1"
        case .sha256: "sha256"
        case .sha512: "sha512"
        }
    }

    /// Longueur de l'empreinte en hexadécimal : permet de reconnaître l'algorithme d'une empreinte collée.
    var hexLength: Int {
        switch self {
        case .crc32: 8
        case .md5: 32
        case .sha1: 40
        case .sha256: 64
        case .sha512: 128
        }
    }
}

/// CRC-32 (polynôme IEEE, celui des fichiers .sfv et du zip).
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }
    private var value: UInt32 = 0xFFFF_FFFF

    mutating func update(data: Data) {
        var crc = value
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes { crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        value = crc
    }

    var hex: String { String(format: "%08x", value ^ 0xFFFF_FFFF) }
}

enum Checksums {
    static let listExtensions: Set<String> = ["md5", "sha1", "sha256", "sha512", "sfv", "crc", "crc32"]

    struct Cancelled: Error {}

    /// Empreintes d'un fichier, lu par blocs de 1 Mo (les gros fichiers ne passent pas en mémoire).
    static func compute(_ url: URL, algorithms: Set<ChecksumAlgorithm> = Set(ChecksumAlgorithm.allCases),
                        progress: (Double) -> Void, isCancelled: () -> Bool) throws -> [ChecksumAlgorithm: String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var crc = CRC32(), md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256(), sha512 = SHA512()
        var done = 0.0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if isCancelled() { throw Cancelled() }
            if algorithms.contains(.crc32) { crc.update(data: chunk) }
            if algorithms.contains(.md5) { md5.update(data: chunk) }
            if algorithms.contains(.sha1) { sha1.update(data: chunk) }
            if algorithms.contains(.sha256) { sha256.update(data: chunk) }
            if algorithms.contains(.sha512) { sha512.update(data: chunk) }
            done += Double(chunk.count)
            if total > 0 { progress(done / total) }
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
        var result: [ChecksumAlgorithm: String] = [:]
        if algorithms.contains(.crc32) { result[.crc32] = crc.hex }
        if algorithms.contains(.md5) { result[.md5] = hex(md5.finalize()) }
        if algorithms.contains(.sha1) { result[.sha1] = hex(sha1.finalize()) }
        if algorithms.contains(.sha256) { result[.sha256] = hex(sha256.finalize()) }
        if algorithms.contains(.sha512) { result[.sha512] = hex(sha512.finalize()) }
        return result
    }

    /// Lignes d'un fichier de sommes : « empreinte  nom », « empreinte *nom » (shasum, md5sum),
    /// « SHA256 (nom) = empreinte » (format BSD de macOS) ou « nom CRC32 » (fichiers .sfv).
    static func parseList(_ text: String) -> [(hash: String, name: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";") else { return nil }
            if let open = line.firstIndex(of: "("), let close = line.range(of: ") = ", options: .backwards), open < close.lowerBound {
                return (String(line[close.upperBound...]).lowercased(), String(line[line.index(after: open)..<close.lowerBound]))
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].allSatisfy(\.isHexDigit), algorithm(forHexLength: parts[0].count) != nil {
                var name = parts[1].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("*") { name.removeFirst() }
                return (parts[0].lowercased(), name)
            }
            // SFV : le nom puis le CRC32 (8 chiffres hexadécimaux) en fin de ligne.
            if let space = line.lastIndex(of: " ") {
                let hash = line[line.index(after: space)...]
                if hash.count == 8, hash.allSatisfy(\.isHexDigit) {
                    return (hash.lowercased(), line[..<space].trimmingCharacters(in: .whitespaces))
                }
            }
            return nil
        }
    }

    /// Fichier de somme posé à côté de `url` pour cet algorithme.
    static func sidecar(for url: URL, _ algorithm: ChecksumAlgorithm) -> URL {
        url.appendingPathExtension(algorithm.fileExtension)
    }

    /// Fichiers de somme déjà présents à côté de `url`.
    static func existingSidecars(for url: URL) -> [(algorithm: ChecksumAlgorithm, url: URL)] {
        ChecksumAlgorithm.allCases.compactMap { algorithm in
            let candidate = sidecar(for: url, algorithm)
            return FileManager.default.fileExists(atPath: candidate.path) ? (algorithm, candidate) : nil
        }
    }

    /// Écrit le fichier de somme d'un fichier (format shasum, ou SFV pour le CRC32).
    static func writeSidecar(for url: URL, _ algorithm: ChecksumAlgorithm, hash: String) throws -> URL {
        let target = sidecar(for: url, algorithm)
        let line = algorithm == .crc32 ? "\(url.lastPathComponent) \(hash.uppercased())\n" : "\(hash)  \(url.lastPathComponent)\n"
        try line.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    static func algorithm(forHexLength length: Int) -> ChecksumAlgorithm? {
        ChecksumAlgorithm.allCases.first { $0.hexLength == length }
    }
}

/// Fenêtre des sommes de contrôle : calcule CRC32, MD5, SHA-1, SHA-256 et SHA-512 des fichiers choisis,
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
            verifyField.placeholderString = "Coller une empreinte pour la vérifier (CRC32, MD5, SHA-1, SHA-256 ou SHA-512)"
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

    /// Menu « Créer une somme de contrôle » : un fichier « nom.ext.sha256 » (…) par fichier sélectionné.
    func checksumMenuItems(for selection: [FileItem]) -> [NSMenuItem] {
        let files = selection.filter { !$0.isNavigableDirectory && !Checksums.listExtensions.contains($0.url.pathExtension.lowercased()) }
        guard !files.isEmpty else { return [] }
        var items: [NSMenuItem] = []
        let create = NSMenuItem(title: "Créer une somme de contrôle", action: nil, keyEquivalent: "")
        create.image = NSImage(systemSymbolName: "number.square", accessibilityDescription: nil)
        create.submenu = NSMenu()
        for algorithm in ChecksumAlgorithm.allCases {
            let entry = NSMenuItem(title: "\(algorithm.rawValue) (.\(algorithm.fileExtension))", action: #selector(createChecksumFiles(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = algorithm.rawValue
            create.submenu?.addItem(entry)
        }
        items.append(create)
        // Fichier de somme déjà présent à côté : proposer de valider.
        if files.count == 1 {
            for (algorithm, sidecar) in Checksums.existingSidecars(for: files[0].url) {
                let validate = NSMenuItem(title: "Valider la somme \(algorithm.rawValue)", action: #selector(validateChecksumFile(_:)), keyEquivalent: "")
                validate.target = self
                validate.representedObject = sidecar
                validate.image = NSImage(systemSymbolName: "checkmark.seal", accessibilityDescription: nil)
                items.append(validate)
            }
        }
        return items
    }

    @objc func validateChecksumFile(_ sender: NSMenuItem) {
        guard let sidecar = sender.representedObject as? URL else { return }
        ChecksumWindowController.show(files: [sidecar])
    }

    @objc func createChecksumFiles(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let algorithm = ChecksumAlgorithm(rawValue: raw) else { return }
        let files = selectedItems.filter { !$0.isNavigableDirectory }.map(\.url)
        let job = FileJob(title: "Sommes \(algorithm.rawValue) de \(files.count == 1 ? "« \(files[0].lastPathComponent) »" : "\(files.count) fichiers")")
        job.setTotal(files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
        FileOperationCenter.shared.addJob(job)
        let folder = currentURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var created: [URL] = []
            var failures: [String] = []
            var base: Int64 = 0
            for url in files where !job.isCancelled {
                job.waitIfPaused()
                job.setStatus(url.lastPathComponent)
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                do {
                    let hashes = try Checksums.compute(url, algorithms: [algorithm], progress: { job.setDone(base + Int64($0 * Double(size))) },
                                                       isCancelled: { job.isCancelled })
                    if let hash = hashes[algorithm] { created.append(try Checksums.writeSidecar(for: url, algorithm, hash: hash)) }
                } catch is Checksums.Cancelled {
                } catch {
                    failures.append("\(url.lastPathComponent) : \(error.localizedDescription)")
                }
                base += size
            }
            DispatchQueue.main.async {
                FileOperationCenter.shared.removeJob(job)
                if !failures.isEmpty { FileOperationCenter.shared.showError(failures.joined(separator: "\n")) }
                if let self, folder.isSameLocation(as: self.currentURL), !created.isEmpty { self.reload() }
            }
        }
    }
}
