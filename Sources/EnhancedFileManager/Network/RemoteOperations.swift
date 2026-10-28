import AppKit

/// Opérations sur les fichiers distants (SFTP). Pas d'annulation via ⌘Z : sftp n'a pas de corbeille.
extension FileOperationCenter {
    /// Copie / déplacement dont la source ou la destination est sur un serveur SFTP.
    func runRemoteTransfer(_ kind: TransferKind, sources: [URL], destination: URL, job: FileJob) -> [(from: URL, to: URL)] {
        let fm = FileManager.default
        job.countsItems = true
        job.setTotal(Int64(sources.count))
        job.setStatus("Connexion…")

        var sessions: [String: SFTPSession] = [:]
        func session(_ url: URL) throws -> SFTPSession {
            if let existing = sessions[url.sftpKey] { return existing }
            let session = try SFTPManager.shared.dedicatedSession(for: url)
            sessions[url.sftpKey] = session
            try session.connect()
            return session
        }
        let temporary = fm.temporaryDirectory.appendingPathComponent("efm-transfer-\(UUID().uuidString)")
        defer {
            sessions.values.forEach { $0.close() }
            try? fm.removeItem(at: temporary)
        }

        var existing: Set<String>
        do {
            existing = destination.isRemote
                ? Set(try session(destination).list(destination.path).entries.map(\.name))
                : Set(try fm.contentsOfDirectory(atPath: destination.path))
        } catch {
            DispatchQueue.main.sync { showError("Impossible de lire « \(destination.lastPathComponent) » : \(error.localizedDescription)") }
            return []
        }

        var results: [(from: URL, to: URL)] = []
        var applyToAll: ConflictChoice?
        for (index, source) in sources.enumerated() where !job.isCancelled {
            let remaining = sources.count - index - 1
            job.setStatus(source.lastPathComponent)
            defer { job.setDone(Int64(index + 1)) }
            var name = source.lastPathComponent
            if source.deletingLastPathComponent().isSameLocation(as: destination) {
                name = uniqueName(name, in: existing, suffix: " copie")
            } else if existing.contains(name) {
                let choice: ConflictChoice
                if let applyToAll { choice = applyToAll } else {
                    let answer = askConflict(name: name, folder: destination, kind: kind, hasMore: remaining > 0)
                    choice = answer.choice
                    if answer.applyToAll { applyToAll = choice }
                }
                switch choice {
                case .replace:
                    let existingURL = destination.appendingPathComponent(name)
                    do {
                        if existingURL.isRemote { try session(existingURL).removeRecursively(existingURL.path) }
                        else { try fm.trashItem(at: existingURL, resultingItemURL: nil) }
                    } catch {
                        if !askContinue(after: error, item: name, hasMore: remaining > 0) { job.cancel() }
                        continue
                    }
                case .keepBoth: name = uniqueName(name, in: existing, suffix: "")
                case .skip: continue
                case .stop: job.cancel(); continue
                }
            }
            let target = destination.appendingPathComponent(name)

            do {
                switch (source.isRemote, destination.isRemote) {
                case (false, true):
                    let remote = try session(destination)
                    job.setCancelAction { remote.cancel() }
                    try remote.upload(source.path, to: target.path)
                    if kind == .move { try fm.removeItem(at: source) }
                case (true, false):
                    let remote = try session(source)
                    job.setCancelAction { remote.cancel() }
                    try remote.download(source.path, to: target.path)
                    if kind == .move { try remote.removeRecursively(source.path) }
                default:
                    let from = try session(source)
                    if kind == .move, source.sftpKey == destination.sftpKey {
                        try from.rename(source.path, to: target.path)
                    } else {
                        // Pas de copie côté serveur en SFTP : on passe par un dossier temporaire local.
                        let to = try session(destination)
                        let staging = temporary.appendingPathComponent(UUID().uuidString)
                        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                        let local = staging.appendingPathComponent(name)
                        job.setCancelAction { from.cancel() }
                        try from.download(source.path, to: local.path)
                        job.setCancelAction { to.cancel() }
                        try to.upload(local.path, to: target.path)
                        if kind == .move { try from.removeRecursively(source.path) }
                    }
                }
                job.setCancelAction(nil)
                existing.insert(name)
                results.append((source, target))
            } catch {
                if job.isCancelled {
                    if !target.isRemote { try? fm.removeItem(at: target) }
                    break
                }
                if !askContinue(after: error, item: source.lastPathComponent, hasMore: remaining > 0) { break }
            }
        }
        return results
    }

    func uniqueName(_ name: String, in existing: Set<String>, suffix: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let dotted = ext.isEmpty ? "" : "." + ext
        if !suffix.isEmpty, !existing.contains(base + suffix + dotted) { return base + suffix + dotted }
        if suffix.isEmpty, !existing.contains(name) { return name }
        var n = 2
        while existing.contains("\(base)\(suffix) \(n)\(dotted)") { n += 1 }
        return "\(base)\(suffix) \(n)\(dotted)"
    }

    /// Suppression définitive sur le serveur (confirmée au préalable par l'appelant).
    func deleteRemote(_ urls: [URL], completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            for url in urls {
                do { try SFTPManager.shared.session(for: url).removeRecursively(url.path) } catch {
                    failures.append("\(url.lastPathComponent) : \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                if !failures.isEmpty { self.showError("Certains éléments n’ont pas pu être supprimés.\n" + failures.joined(separator: "\n")) }
                completion()
            }
        }
    }

    func renameRemote(_ url: URL, to newName: String, completion: @escaping (Result<URL, Error>) -> Void) {
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> URL in
                guard !newName.contains("/") else { throw SFTPError.command("Le nom ne peut pas contenir « / ».") }
                try SFTPManager.shared.session(for: url).rename(url.path, to: target.path)
                return target
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func createRemoteFolder(in directory: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> URL in
                let session = try SFTPManager.shared.session(for: directory)
                let names = Set(try session.list(directory.path).entries.map(\.name))
                let url = directory.appendingPathComponent(self.uniqueName("nouveau dossier", in: names, suffix: ""))
                try session.makeDirectory(url.path)
                return url
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Télécharge des fichiers distants dans le cache puis les ouvre avec l'application par défaut.
    func openRemote(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EnhancedFileManager/SFTP/\(first.host ?? "serveur")/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        transfer(.copy, sources: urls, to: cache, undoManager: nil) { downloaded in
            downloaded.forEach { NSWorkspace.shared.open($0) }
        }
    }
}
