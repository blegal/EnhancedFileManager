import AppKit
import CryptoKit

/// Découper un gros fichier en morceaux « nom.001, nom.002… » et les réassembler, comme Total Commander.
/// Le format est celui de 7-Zip : les morceaux se recollent aussi avec « cat nom.0* > nom ».
extension FileOperationCenter {
    private static let chunk = 1 << 20

    /// Morceaux d'un fichier découpé, à partir de l'un d'eux (« nom.001 », « nom.002 »…), dans l'ordre.
    static func splitParts(from part: URL) -> [URL]? {
        let ext = part.pathExtension
        guard ext.count >= 3, ext.allSatisfy(\.isNumber) else { return nil }
        let base = part.deletingPathExtension()
        var parts: [URL] = []
        var index = 1
        while true {
            let candidate = base.appendingPathExtension(String(format: "%0\(ext.count)d", index))
            guard FileManager.default.fileExists(atPath: candidate.path) else { break }
            parts.append(candidate)
            index += 1
        }
        return parts.isEmpty ? nil : parts
    }

    /// Découpe `file` en morceaux de `partSize` octets dans `folder` ; écrit au besoin « nom.sha256 ».
    func split(_ file: URL, partSize: Int64, into folder: URL, writeChecksum: Bool, completion: @escaping ([URL]) -> Void) {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0, partSize > 0 else { showError("Ce fichier est vide."); return }
        let count = Int((size + partSize - 1) / partSize)
        let digits = max(3, String(count).count)
        let job = FileJob(title: "Découpage de « \(file.lastPathComponent) »")
        job.setTotal(size)
        addJob(job)
        DispatchQueue.global(qos: .userInitiated).async {
            var created: [URL] = []
            var failure: String?
            var hasher = SHA256()
            do {
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                var done: Int64 = 0
                for index in 1...count {
                    let part = folder.appendingPathComponent(file.lastPathComponent + "." + String(format: "%0\(digits)d", index))
                    guard !FileManager.default.fileExists(atPath: part.path) else { throw self.splitError("« \(part.lastPathComponent) » existe déjà.") }
                    FileManager.default.createFile(atPath: part.path, contents: nil)
                    created.append(part)
                    let output = try FileHandle(forWritingTo: part)
                    defer { try? output.close() }
                    job.setStatus(part.lastPathComponent)
                    var written: Int64 = 0
                    while written < partSize {
                        job.waitIfPaused()
                        if job.isCancelled { throw CancellationError() }
                        let wanted = Int(min(Int64(Self.chunk), partSize - written))
                        guard let data = try input.read(upToCount: wanted), !data.isEmpty else { break }
                        try output.write(contentsOf: data)
                        if writeChecksum { hasher.update(data: data) }
                        written += Int64(data.count)
                        done += Int64(data.count)
                        job.setDone(done)
                    }
                }
                if writeChecksum {
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    let list = folder.appendingPathComponent(file.lastPathComponent + ".sha256")
                    try "\(digest)  \(file.lastPathComponent)\n".write(to: list, atomically: true, encoding: .utf8)
                    created.append(list)
                }
            } catch is CancellationError {
                failure = ""
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.removeJob(job)
                if let failure {
                    for url in created { try? FileManager.default.removeItem(at: url) }
                    if !failure.isEmpty { self.showError("Le découpage a échoué.\n\(failure)") }
                    completion([])
                } else {
                    completion(created)
                }
            }
        }
    }

    /// Recolle les morceaux dans `folder` ; vérifie la somme « nom.sha256 » si elle est à côté des morceaux.
    func join(_ parts: [URL], into folder: URL, trashParts: Bool, undoManager: UndoManager?, completion: @escaping (URL?) -> Void) {
        guard let first = parts.first else { return }
        let name = first.deletingPathExtension().lastPathComponent
        let output = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: output.path) else { showError("« \(name) » existe déjà dans ce dossier."); return }
        let expected = (try? String(contentsOf: first.deletingPathExtension().appendingPathExtension("sha256"), encoding: .utf8))
            .flatMap { Checksums.parseList($0).first { $0.name == name }?.hash }
        let total = parts.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let job = FileJob(title: "Réassemblage de « \(name) »")
        job.setTotal(total)
        addJob(job)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            var hasher = SHA256()
            do {
                FileManager.default.createFile(atPath: output.path, contents: nil)
                let writer = try FileHandle(forWritingTo: output)
                defer { try? writer.close() }
                var done: Int64 = 0
                for part in parts {
                    job.setStatus(part.lastPathComponent)
                    let reader = try FileHandle(forReadingFrom: part)
                    defer { try? reader.close() }
                    while let data = try reader.read(upToCount: Self.chunk), !data.isEmpty {
                        job.waitIfPaused()
                        if job.isCancelled { throw CancellationError() }
                        try writer.write(contentsOf: data)
                        if expected != nil { hasher.update(data: data) }
                        done += Int64(data.count)
                        job.setDone(done)
                    }
                }
                if let expected, hasher.finalize().map({ String(format: "%02x", $0) }).joined() != expected {
                    throw self.splitError("La somme SHA-256 ne correspond pas : un morceau est abîmé ou manquant.")
                }
            } catch is CancellationError {
                failure = ""
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.removeJob(job)
                if let failure {
                    try? FileManager.default.removeItem(at: output)
                    if !failure.isEmpty { self.showError("Le réassemblage a échoué.\n\(failure)") }
                    completion(nil)
                    return
                }
                if trashParts { self.trash(parts, undoManager: undoManager, actionName: "Réassembler") }
                completion(output)
            }
        }
    }

    private func splitError(_ message: String) -> NSError {
        NSError(domain: "iExplorer", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension PanelViewController {
    private static let splitPresets: [(String, Int64)] = [
        ("100 Mo (pièce jointe)", 100_000_000), ("700 Mo (CD)", 700_000_000),
        ("4 Go (clé USB en FAT32)", 4_294_967_295), ("Taille personnalisée", 0),
    ]

    var splitCandidate: FileItem? {
        let selection = selectedItems
        guard selection.count == 1, !selection[0].isNavigableDirectory, selection[0].url.isFileURL else { return nil }
        return selection[0]
    }

    var joinCandidate: [URL]? {
        guard let item = splitCandidate else { return nil }
        return FileOperationCenter.splitParts(from: item.url)
    }

    @objc func splitFile(_ sender: Any?) {
        guard let item = splitCandidate, let window = view.window else { return }
        let size = item.size ?? 0
        let alert = NSAlert()
        alert.messageText = "Découper « \(item.name) »"
        alert.informativeText = "\(Format.size(size)). Les morceaux s’appellent « \(item.name).001 », « .002 »… et se recollent avec iExplorer, 7-Zip ou « cat »."
        let presets = NSPopUpButton(frame: NSRect(x: 0, y: 84, width: 300, height: 26))
        presets.addItems(withTitles: Self.splitPresets.map(\.0))
        presets.selectItem(at: 2)
        let custom = NSTextField(frame: NSRect(x: 0, y: 56, width: 120, height: 22))
        custom.placeholderString = "Taille en Mo"
        let destination = NSPopUpButton(frame: NSRect(x: 0, y: 26, width: 300, height: 26))
        destination.addItems(withTitles: ["Dans ce dossier", "Dans l’autre panneau"])
        destination.item(at: 1)?.isEnabled = host?.targetPanels(for: self).first != nil
        destination.autoenablesItems = false
        let checksum = NSButton(checkboxWithTitle: "Écrire une somme SHA-256 pour vérifier le réassemblage", target: nil, action: nil)
        checksum.frame = NSRect(x: 0, y: 0, width: 340, height: 20)
        checksum.state = .on
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 112))
        [presets, custom, destination, checksum].forEach(accessory.addSubview)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Découper")
        alert.addButton(withTitle: "Annuler")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var partSize = Self.splitPresets[presets.indexOfSelectedItem].1
            if partSize == 0 { partSize = Int64((Double(custom.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0) * 1_000_000) }
            guard partSize > 0 else { NSSound.beep(); return }
            guard partSize < size else {
                FileOperationCenter.shared.showError("Le fichier fait moins de \(Format.size(partSize)) : rien à découper.")
                return
            }
            let target = destination.indexOfSelectedItem == 1 ? host?.targetPanels(for: self).first ?? self : self
            FileOperationCenter.shared.split(item.url, partSize: partSize, into: target.currentURL, writeChecksum: checksum.state == .on) { [weak target] created in
                if !created.isEmpty { target?.reload(selecting: created) }
            }
        }
    }

    @objc func joinFiles(_ sender: Any?) {
        guard let parts = joinCandidate, let window = view.window else { return }
        let name = parts[0].deletingPathExtension().lastPathComponent
        let hasChecksum = FileManager.default.fileExists(atPath: parts[0].deletingPathExtension().appendingPathExtension("sha256").path)
        let alert = NSAlert()
        alert.messageText = "Réassembler « \(name) »"
        alert.informativeText = "\(parts.count) morceau\(parts.count > 1 ? "x" : "") trouvé\(parts.count > 1 ? "s" : "") (\(parts.first!.pathExtension) à \(parts.last!.pathExtension))."
            + (hasChecksum ? "\nLa somme SHA-256 sera vérifiée." : "")
        let trash = NSButton(checkboxWithTitle: "Mettre les morceaux à la corbeille ensuite", target: nil, action: nil)
        trash.frame = NSRect(x: 0, y: 0, width: 320, height: 20)
        alert.accessoryView = trash
        alert.addButton(withTitle: "Réassembler")
        alert.addButton(withTitle: "Annuler")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let folder = currentURL
            FileOperationCenter.shared.join(parts, into: folder, trashParts: trash.state == .on, undoManager: undoManager) { [weak self] output in
                if let output, folder.isSameLocation(as: self?.currentURL ?? folder) { self?.reload(selecting: [output]) }
            }
        }
    }
}
