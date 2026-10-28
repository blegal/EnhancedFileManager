import AppKit

enum TransferKind {
    case copy, move

    var verb: String { self == .copy ? "copier" : "déplacer" }
}

/// Une opération de copie / déplacement en cours. Thread-safe.
final class FileJob {
    let title: String
    private let lock = NSLock()
    private let pauseCondition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var done: Int64 = 0
    private var total: Int64 = 0
    private var status = ""
    private var cancelAction: (() -> Void)?
    /// Progression en nombre d'éléments plutôt qu'en octets (transferts SFTP).
    var countsItems = false

    init(title: String) { self.title = title }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let action = lock.withLock { () -> (() -> Void)? in
            cancelled = true
            return cancelAction
        }
        setPaused(false)
        action?()
    }

    // MARK: Pause

    var isPaused: Bool { pauseCondition.withLock { paused } }

    func setPaused(_ value: Bool) {
        pauseCondition.lock()
        paused = value
        pauseCondition.broadcast()
        pauseCondition.unlock()
    }

    /// Bloque le fil de copie tant que l'opération est en pause.
    func waitIfPaused() {
        pauseCondition.lock()
        while paused { pauseCondition.wait() }
        pauseCondition.unlock()
    }

    /// Action qui interrompt l'opération en cours (ex. : arrêt du processus sftp).
    func setCancelAction(_ action: (() -> Void)?) { lock.withLock { cancelAction = action } }
    func setTotal(_ value: Int64) { lock.withLock { total = value } }
    func setDone(_ value: Int64) { lock.withLock { done = value } }
    func setStatus(_ value: String) { lock.withLock { status = value } }

    var snapshot: (done: Int64, total: Int64, status: String) { lock.withLock { (done, total, status) } }
}

enum ConflictChoice { case replace, keepBoth, skip, stop }

/// Point d'entrée unique des opérations sur les fichiers (copie, déplacement,
/// corbeille, renommage…), avec annulation via `UndoManager`.
final class FileOperationCenter {
    static let shared = FileOperationCenter()
    static let jobsChanged = Notification.Name("FileJobsChanged")

    private(set) var jobs: [FileJob] = []
    private let fm = FileManager.default

    // MARK: Copie / déplacement

    /// Copie ou déplace `sources` dans `destination`. `completion` reçoit les URL créées.
    func transfer(_ kind: TransferKind, sources: [URL], to destination: URL,
                  undoManager: UndoManager?, completion: (([URL]) -> Void)? = nil) {
        let destination = destination.isRemote ? destination.standardized : destination.standardizedFileURL
        let isRemote = destination.isRemote || sources.contains(where: \.isRemote)
        var valid: [URL] = []
        for source in sources.map({ $0.isRemote ? $0.standardized : $0.standardizedFileURL }) {
            if destination.isInside(source) {
                showError("Impossible de \(kind.verb) « \(source.lastPathComponent) » dans lui-même.")
                continue
            }
            if kind == .move, source.deletingLastPathComponent().isSameLocation(as: destination) { continue }
            valid.append(source)
        }
        guard !valid.isEmpty else { completion?([]); return }

        let verb = kind == .copy ? "Copie" : "Déplacement"
        let title = valid.count == 1
            ? "\(verb) de « \(valid[0].lastPathComponent) » vers « \(destination.lastPathComponent) »"
            : "\(verb) de \(valid.count) éléments vers « \(destination.lastPathComponent) »"
        let job = FileJob(title: title)
        addJob(job)

        DispatchQueue.global(qos: .userInitiated).async {
            let pairs = isRemote
                ? self.runRemoteTransfer(kind, sources: valid, destination: destination, job: job)
                : self.runTransfer(kind, sources: valid, destination: destination, job: job)
            DispatchQueue.main.async {
                self.removeJob(job)
                if !pairs.isEmpty, !isRemote, let undoManager {
                    undoManager.registerUndo(withTarget: self) { center in
                        switch kind {
                        case .copy: center.trash(pairs.map(\.to), undoManager: undoManager, actionName: "Copie")
                        case .move: center.move(pairs.map { ($0.to, $0.from) }, actionName: "Déplacement", undoManager: undoManager)
                        }
                    }
                    undoManager.setActionName(verb)
                }
                completion?(pairs.map(\.to))
            }
        }
    }

    var hasActiveJobs: Bool { !jobs.isEmpty }

    func addJob(_ job: FileJob) {
        jobs.append(job)
        NotificationCenter.default.post(name: Self.jobsChanged, object: nil)
    }

    func removeJob(_ job: FileJob) {
        jobs.removeAll { $0 === job }
        NotificationCenter.default.post(name: Self.jobsChanged, object: nil)
    }

    private func runTransfer(_ kind: TransferKind, sources: [URL], destination: URL, job: FileJob) -> [(from: URL, to: URL)] {
        job.setStatus("Préparation…")
        let plans = sources.map { source -> (source: URL, needsCopy: Bool, size: Int64) in
            let needsCopy = kind == .copy || !Self.sameVolume(source, destination)
            return (source, needsCopy, needsCopy ? totalSize(of: source) : 0)
        }
        job.setTotal(plans.reduce(0) { $0 + $1.size })

        var results: [(from: URL, to: URL)] = []
        var applyToAll: ConflictChoice?
        var completed: Int64 = 0

        for (index, plan) in plans.enumerated() where !job.isCancelled {
            job.waitIfPaused()
            let source = plan.source
            let remaining = plans.count - index - 1
            job.setStatus(source.lastPathComponent)
            var target = destination.appendingPathComponent(source.lastPathComponent)
            defer { completed += plan.size; job.setDone(completed) }

            if source.isSameLocation(as: target) {
                target = uniqueURL(for: target, suffix: " copie")
            } else if itemExists(target) {
                if source.isInside(target) {
                    showErrorSync("« \(target.lastPathComponent) » ne peut pas être remplacé car il contient l’élément à \(kind.verb).")
                    continue
                }
                let choice: ConflictChoice
                if let applyToAll { choice = applyToAll } else {
                    let answer = askConflict(name: target.lastPathComponent, folder: destination, kind: kind, hasMore: remaining > 0)
                    choice = answer.choice
                    if answer.applyToAll { applyToAll = choice }
                }
                switch choice {
                case .replace:
                    do {
                        try fm.trashItem(at: target, resultingItemURL: nil)
                    } catch {
                        do { try fm.removeItem(at: target) } catch {
                            if !askContinue(after: error, item: target.lastPathComponent, hasMore: remaining > 0) { job.cancel() }
                            continue
                        }
                    }
                case .keepBoth: target = uniqueURL(for: target, suffix: "")
                case .skip: continue
                case .stop: job.cancel(); continue
                }
            }

            do {
                if plan.needsCopy {
                    do {
                        try copyItem(at: source, to: target, job: job, alreadyDone: completed)
                        if Preferences.verifyCopies {
                            job.setStatus("Vérification de « \(source.lastPathComponent) »")
                            try Self.verifyCopy(source, target, job: job)
                        }
                    } catch {
                        try? fm.removeItem(at: target) // copie partielle ou non conforme
                        throw error
                    }
                    // L'original n'est supprimé qu'après une copie complète (et vérifiée si demandé).
                    if kind == .move { try fm.removeItem(at: source) }
                } else {
                    try fm.moveItem(at: source, to: target)
                }
                results.append((source, target))
            } catch {
                if job.isCancelled { break }
                if !askContinue(after: error, item: source.lastPathComponent, hasMore: remaining > 0) { break }
            }
        }
        return results
    }

    /// Copie récursive avec `copyfile(3)` : clonage APFS quand c'est possible,
    /// progression octet par octet et annulation.
    private func copyItem(at source: URL, to target: URL, job: FileJob, alreadyDone: Int64) throws {
        guard let state = copyfile_state_alloc() else { throw CocoaError(.fileWriteUnknown) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(job: job, base: alreadyDone)
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), UnsafeRawPointer(unmanaged.toOpaque()))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyProgressCallback, to: UnsafeRawPointer.self))

        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
        if copyfile(source.path, target.path, state, flags) != 0 {
            let code = errno
            if job.isCancelled { throw CocoaError(.userCancelled) }
            let path = context.failedPath ?? source.path
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "Impossible de copier « \((path as NSString).lastPathComponent) » : \(String(cString: strerror(code))).",
            ])
        }
    }

    private func totalSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return Int64(values?.fileSize ?? 0) }
        var sum: Int64 = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            sum += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return sum
    }

    // MARK: Corbeille, renommage, création

    /// Place les éléments dans la corbeille ; l'annulation les remet en place.
    func trash(_ urls: [URL], undoManager: UndoManager?, actionName: String = "Placer dans la corbeille") {
        var restored: [(from: URL, to: URL)] = []
        var failures: [URL] = []
        for url in urls {
            var resulting: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &resulting)
                if let trashed = resulting as URL? { restored.append((trashed, url)) }
            } catch {
                failures.append(url)
            }
        }
        if !restored.isEmpty, let undoManager {
            undoManager.registerUndo(withTarget: self) { $0.move(restored, actionName: actionName, undoManager: undoManager) }
            undoManager.setActionName(actionName)
        }
        if !failures.isEmpty { offerPermanentDeletion(failures) }
    }

    private func offerPermanentDeletion(_ urls: [URL]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? "« \(urls[0].lastPathComponent) » ne peut pas être placé dans la corbeille."
            : "\(urls.count) éléments ne peuvent pas être placés dans la corbeille."
        alert.informativeText = "Voulez-vous les supprimer immédiatement ? Cette action est irréversible."
        alert.addButton(withTitle: "Annuler")
        alert.addButton(withTitle: "Supprimer").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        for url in urls {
            do { try fm.removeItem(at: url) } catch { showError(error.localizedDescription) }
        }
    }

    /// Déplacements synchrones (annulation, renommage) ; enregistre l'opération inverse.
    func move(_ pairs: [(from: URL, to: URL)], actionName: String, undoManager: UndoManager?) {
        var done: [(from: URL, to: URL)] = []
        for pair in pairs {
            do {
                try moveFile(at: pair.from, to: pair.to)
                done.append(pair)
            } catch {
                showError(error.localizedDescription)
            }
        }
        guard !done.isEmpty, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { $0.move(done.map { ($0.to, $0.from) }, actionName: actionName, undoManager: undoManager) }
        undoManager.setActionName(actionName)
    }

    func rename(_ url: URL, to newName: String, undoManager: UndoManager?) throws -> URL {
        if newName.isEmpty || newName == url.lastPathComponent { return url }
        if newName.contains("/") { throw makeError("Le nom ne peut pas contenir « / ».") }
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        try moveFile(at: url, to: target)
        undoManager?.registerUndo(withTarget: self) { $0.move([(target, url)], actionName: "Renommer", undoManager: undoManager) }
        undoManager?.setActionName("Renommer")
        return target
    }

    func createFolder(in directory: URL, undoManager: UndoManager?) throws -> URL {
        let url = uniqueURL(for: directory.appendingPathComponent("nouveau dossier"), suffix: "")
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        undoManager?.registerUndo(withTarget: self) { $0.trash([url], undoManager: undoManager, actionName: "Nouveau dossier") }
        undoManager?.setActionName("Nouveau dossier")
        return url
    }

    /// Déplacement qui gère le changement de casse seul (« a » → « A »).
    private func moveFile(at source: URL, to target: URL) throws {
        if itemExists(target) {
            guard Self.isSameFile(source, target) else {
                throw makeError("Un élément nommé « \(target.lastPathComponent) » existe déjà.")
            }
            if Darwin.rename(source.path, target.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return
        }
        try fm.moveItem(at: source, to: target)
    }

    // MARK: Utilitaires

    private func itemExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        if a.isRemote || b.isRemote { return a.isRemote && b.isRemote && a.sftpKey == b.sftpKey }
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let va = volume(a), let vb = volume(b) else { return false }
        return va.isEqual(vb)
    }

    /// « nom.ext » → « nom copie.ext », « nom copie 2.ext »… (ou « nom 2.ext »).
    func uniqueURL(for url: URL, suffix: String) -> URL {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let ext = (name as NSString).pathExtension
        let isFolder = url.hasDirectoryPath || url.isExistingDirectory
        let base = ext.isEmpty || isFolder ? name : (name as NSString).deletingPathExtension
        let fullExt = ext.isEmpty || isFolder ? "" : "." + ext
        func candidate(_ n: Int) -> URL {
            let number = n > 1 || suffix.isEmpty ? " \(n)" : ""
            return directory.appendingPathComponent(base + suffix + number + fullExt)
        }
        if !suffix.isEmpty, !itemExists(candidate(1)) { return candidate(1) }
        if suffix.isEmpty, !itemExists(url) { return url }
        var n = 2
        while itemExists(candidate(n)) { n += 1 }
        return candidate(n)
    }

    /// Opération de dépôt par défaut, comme le Finder : déplacer sur le même volume,
    /// copier vers un autre ; ⌥ force la copie, ⌘ force le déplacement.
    static func dropOperation(for info: NSDraggingInfo, sources: [URL], destination: URL) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if mask == .copy { return .copy }
        if mask == .generic || mask == .move { return .move }
        if mask.contains(.copy) && mask.contains(.move) {
            return sources.allSatisfy { sameVolume($0, destination) } ? .move : .copy
        }
        if mask.contains(.copy) { return .copy }
        if mask.contains(.move) || mask.contains(.generic) { return .move }
        return []
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "iExplorer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Dialogues

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }

    private func showErrorSync(_ message: String) {
        DispatchQueue.main.sync { showError(message) }
    }

    func askConflict(name: String, folder: URL, kind: TransferKind, hasMore: Bool) -> (choice: ConflictChoice, applyToAll: Bool) {
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = "Un élément nommé « \(name) » existe déjà dans « \(folder.lastPathComponent) »."
            alert.informativeText = "Voulez-vous le remplacer par celui que vous \(kind == .copy ? "copiez" : "déplacez") ? L’élément existant sera placé dans la corbeille."
            alert.addButton(withTitle: "Garder les deux")
            alert.addButton(withTitle: "Remplacer")
            alert.addButton(withTitle: "Ignorer")
            alert.addButton(withTitle: "Arrêter")
            if hasMore {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Appliquer à tous"
            }
            let response = alert.runModal()
            let all = alert.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn: return (.keepBoth, all)
            case .alertSecondButtonReturn: return (.replace, all)
            case .alertThirdButtonReturn: return (.skip, all)
            default: return (.stop, false)
            }
        }
    }

    func askContinue(after error: Error, item: String, hasMore: Bool) -> Bool {
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Une erreur est survenue avec « \(item) »."
            alert.informativeText = error.localizedDescription
            if hasMore {
                alert.addButton(withTitle: "Continuer")
                alert.addButton(withTitle: "Arrêter")
            }
            return alert.runModal() == .alertFirstButtonReturn && hasMore
        }
    }
}

// MARK: - Progression de copyfile

private final class CopyContext {
    let job: FileJob
    let base: Int64
    var counted: Int64 = 0
    var currentFileCounted: Int64 = 0
    var failedPath: String?

    init(job: FileJob, base: Int64) {
        self.job = job
        self.base = base
    }

    func add(_ bytes: Int64) {
        guard bytes > 0 else { return }
        counted += bytes
        job.setDone(base + counted)
    }
}

private let copyProgressCallback: copyfile_callback_t = { what, stage, state, source, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
    if context.job.isCancelled { return COPYFILE_QUIT }

    if stage == COPYFILE_ERR || what == COPYFILE_RECURSE_ERROR {
        context.failedPath = source.map { String(cString: $0) }
        return COPYFILE_QUIT
    }
    switch (what, stage) {
    case (COPYFILE_RECURSE_FILE, COPYFILE_START):
        context.currentFileCounted = 0
        if let source { context.job.setStatus((String(cString: source) as NSString).lastPathComponent) }
    case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
        // Pause au milieu d'un fichier : le fil de copie attend ici.
        context.job.waitIfPaused()
        if context.job.isCancelled { return COPYFILE_QUIT }
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        context.add(Int64(copied) - context.currentFileCounted)
        context.currentFileCounted = Int64(copied)
    case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
        var st = stat()
        if let source, lstat(source, &st) == 0 {
            context.add(Int64(st.st_size) - context.currentFileCounted)
        }
        context.currentFileCounted = 0
    default:
        break
    }
    return COPYFILE_CONTINUE
}

// MARK: - Vérification des copies

extension FileOperationCenter {
    /// Compare le contenu de la copie à l'original, bloc par bloc (dossiers parcourus récursivement).
    static func verifyCopy(_ source: URL, _ target: URL, job: FileJob) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: { _, _ in true })
            let base = source.standardizedFileURL.path
            while let file = enumerator?.nextObject() as? URL {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
                try compareFiles(file, target.appendingPathComponent(relative), job: job)
            }
        } else {
            try compareFiles(source, target, job: job)
        }
    }

    private static func compareFiles(_ a: URL, _ b: URL, job: FileJob) throws {
        let mismatch = NSError(domain: "iExplorer", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "La copie de « \(a.lastPathComponent) » ne correspond pas à l’original.",
        ])
        guard let left = try? FileHandle(forReadingFrom: a), let right = try? FileHandle(forReadingFrom: b) else { throw mismatch }
        defer { try? left.close(); try? right.close() }
        let chunk = 4 * 1024 * 1024
        while true {
            if job.isCancelled { throw CocoaError(.userCancelled) }
            job.waitIfPaused()
            let x = try left.read(upToCount: chunk) ?? Data()
            let y = try right.read(upToCount: chunk) ?? Data()
            if x != y { throw mismatch }
            if x.isEmpty { return }
        }
    }
}
