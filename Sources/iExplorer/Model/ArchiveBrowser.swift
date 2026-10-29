import AppKit
import CryptoKit

/// Archives parcourues comme des dossiers : l'archive est dépliée une fois dans le cache de l'app
/// (`~/Library/Caches/iExplorer/Archives/<empreinte>/<nom de l'archive>`), puis le panneau y navigue.
/// Les modifications faites dans ce dossier ne sont pas réécrites dans l'archive.
enum ArchiveBrowser {
    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iExplorer/Archives", isDirectory: true).standardizedFileURL
    }

    /// Chemin de l'archive d'origine, noté à côté du dossier déplié.
    private static let sourceFile = "source.txt"

    /// Les images disque (qu'on monte) et les fichiers compressés seuls (.gz sans tar) ne se parcourent pas.
    static func canBrowse(_ url: URL) -> Bool {
        guard url.isFileURL, FileOperationCenter.isArchive(url) else { return false }
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".iso") { return false }
        let isTar = name.contains(".tar.") || ["tgz", "tbz", "tbz2", "txz"].contains(url.pathExtension.lowercased())
        return isTar || !["gz", "bz2", "xz"].contains(url.pathExtension.lowercased())
    }

    /// Dossier du cache pour cette version de l'archive (chemin, taille et date en font l'empreinte).
    static func folder(for archive: URL) -> URL {
        let values = try? archive.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "\(archive.standardizedFileURL.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return cacheRoot.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(archive.lastPathComponent, isDirectory: true)
    }

    /// L'archive dont `url` fait partie, et le dossier où elle est dépliée.
    static func archive(containing url: URL) -> (archive: URL, root: URL)? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        let base = cacheRoot.path + "/"
        guard path.hasPrefix(base) else { return nil }
        let parts = path.dropFirst(base.count).split(separator: "/", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let entry = cacheRoot.appendingPathComponent(String(parts[0]), isDirectory: true)
        guard let source = try? String(contentsOf: entry.appendingPathComponent(sourceFile), encoding: .utf8) else { return nil }
        return (URL(fileURLWithPath: source), entry.appendingPathComponent(String(parts[1]), isDirectory: true))
    }

    /// Déplie l'archive si besoin (en arrière-plan, avec sa progression) et renvoie son dossier.
    static func open(_ archive: URL, completion: @escaping (URL?) -> Void) {
        let root = folder(for: archive)
        let entry = root.deletingLastPathComponent()
        let fm = FileManager.default
        if fm.fileExists(atPath: entry.appendingPathComponent(sourceFile).path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
            completion(root)
            return
        }
        let staging = entry.appendingPathComponent(".extraction", isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            FileOperationCenter.shared.showError(error.localizedDescription)
            completion(nil)
            return
        }
        let job = FileJob(title: "Ouverture de « \(archive.lastPathComponent) »")
        job.setStatus("Lecture de l’archive")
        FileOperationCenter.shared.addJob(job)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-x", "-f", archive.path, "-C", staging.path, "--exclude", "__MACOSX"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        job.setCancelAction { process.terminate() }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try process.run()
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus != 0 { failure = message.trimmingCharacters(in: .whitespacesAndNewlines) }
                if failure == nil {
                    try fm.moveItem(at: staging, to: root)
                    try archive.standardizedFileURL.path.write(to: entry.appendingPathComponent(sourceFile), atomically: true, encoding: .utf8)
                }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                FileOperationCenter.shared.removeJob(job)
                guard failure == nil, !job.isCancelled else {
                    try? fm.removeItem(at: entry)
                    if let failure, !job.isCancelled {
                        FileOperationCenter.shared.showError("« \(archive.lastPathComponent) » n’a pas pu être ouverte.\n\(failure)")
                    }
                    completion(nil)
                    return
                }
                completion(root)
            }
        }
    }

    /// Au lancement : retire les archives dépliées qui n'ont pas été ouvertes depuis un jour.
    static func purge() {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-24 * 3600)
        let entries = (try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < limit { try? fm.removeItem(at: entry) }
        }
    }
}
