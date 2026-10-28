import AppKit

enum ArchiveFormat: Int, CaseIterable {
    case zip, tarGz, tarBz2, tarXz

    var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .tarGz: "tar.gz"
        case .tarBz2: "tar.bz2"
        case .tarXz: "tar.xz"
        }
    }
}

/// Compression et décompression avec les outils du système (bsdtar / libarchive, gzip, bzip2).
extension FileOperationCenter {
    private static let archiveSuffixes = ["zip", "tar", "tgz", "tbz", "tbz2", "txz", "tar.gz", "tar.bz2", "tar.xz", "tar.zst",
                                          "gz", "bz2", "xz", "7z", "rar", "cpio", "xar", "iso", "jar", "cab", "lha", "lzh"]

    static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return archiveSuffixes.contains { name.hasSuffix("." + $0) }
    }

    /// Compresse les éléments (tous dans le même dossier) en une archive à côté d'eux.
    func compress(_ urls: [URL], format: ArchiveFormat, undoManager: UndoManager?, completion: @escaping (URL?) -> Void) {
        guard let first = urls.first else { return }
        let directory = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.lastPathComponent : "Archive"
        let target = uniqueURL(for: directory.appendingPathComponent("\(base).\(format.fileExtension)"), suffix: "")
        let arguments = ["-a", "-c", "--no-mac-metadata", "-f", target.path, "-C", directory.path, "--"] + urls.map(\.lastPathComponent)
        let title = "Compression de « \(urls.count == 1 ? first.lastPathComponent : "\(urls.count) éléments") »"
        runArchiveTool("/usr/bin/tar", arguments, title: title, output: target, undoManager: undoManager, completion: completion)
    }

    /// Décompresse une archive dans un nouveau dossier nommé d'après elle, dans `directory`.
    func extract(_ archive: URL, into directory: URL, undoManager: UndoManager?, completion: @escaping (URL?) -> Void) {
        let lower = archive.lastPathComponent.lowercased()
        var base = archive.lastPathComponent
        for suffix in Self.archiveSuffixes.sorted(by: { $0.count > $1.count }) where lower.hasSuffix("." + suffix) {
            base = String(base.dropLast(suffix.count + 1))
            break
        }
        let title = "Décompression de « \(archive.lastPathComponent) »"
        let isTar = lower.contains(".tar.") || ["tgz", "tbz", "tbz2", "txz"].contains(archive.pathExtension.lowercased())
        // Fichier unique compressé (.gz / .bz2 sans tar) : on restitue le fichier.
        if !isTar, let tool = ["gz": "/usr/bin/gzip", "bz2": "/usr/bin/bzip2"][archive.pathExtension.lowercased()] {
            let target = uniqueURL(for: directory.appendingPathComponent(base), suffix: "")
            runArchiveTool(tool, ["-d", "-c", archive.path], title: title, output: target, stdoutTo: target,
                           undoManager: undoManager, completion: completion)
            return
        }
        let target = uniqueURL(for: directory.appendingPathComponent(base), suffix: "")
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch {
            showError(error.localizedDescription)
            return
        }
        runArchiveTool("/usr/bin/tar", ["-x", "-f", archive.path, "-C", target.path], title: title, output: target,
                       undoManager: nil) { [weak self] folder in
            guard let self, let folder else { completion(nil); return }
            let result = flattenSingleItem(folder)
            undoManager?.registerUndo(withTarget: self) { $0.trash([result], undoManager: undoManager, actionName: "Décompression") }
            undoManager?.setActionName("Décompression")
            completion(result)
        }
    }

    /// Évite « Dossier/Dossier/… » quand l'archive ne contient qu'un élément au premier niveau.
    private func flattenSingleItem(_ folder: URL) -> URL {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              children.count == 1, let only = children.first else { return folder }
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".efm-extract-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: only, to: staging)
            try fm.removeItem(at: folder)
            let target = uniqueURL(for: folder.deletingLastPathComponent().appendingPathComponent(only.lastPathComponent), suffix: "")
            try fm.moveItem(at: staging, to: target)
            return target
        } catch {
            return fm.fileExists(atPath: folder.path) ? folder : staging
        }
    }

    private func runArchiveTool(_ tool: String, _ arguments: [String], title: String, output: URL, stdoutTo: URL? = nil,
                                undoManager: UndoManager?, completion: @escaping (URL?) -> Void) {
        let job = FileJob(title: title)
        job.setStatus(output.lastPathComponent)
        addJob(job)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        if let stdoutTo {
            FileManager.default.createFile(atPath: stdoutTo.path, contents: nil)
            process.standardOutput = try? FileHandle(forWritingTo: stdoutTo)
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        job.setCancelAction { process.terminate() }

        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try process.run()
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus != 0 && !job.isCancelled {
                    failure = message.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.removeJob(job)
                if job.isCancelled || failure != nil {
                    try? FileManager.default.removeItem(at: output)
                    if let failure { self.showError("\(title) a échoué.\n\(failure)") }
                    completion(nil)
                    return
                }
                undoManager?.registerUndo(withTarget: self) { $0.trash([output], undoManager: undoManager, actionName: "Archive") }
                undoManager?.setActionName(title.components(separatedBy: " ").first ?? "Archive")
                completion(output)
            }
        }
    }
}
