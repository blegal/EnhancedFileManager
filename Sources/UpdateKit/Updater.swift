import AppKit

/// Mise à jour automatique depuis les releases GitHub, sans bibliothèque externe.
/// Réglages lus dans Info.plist : `UpdateRepository` (« propriétaire/dépôt ») et
/// `UpdatePublicKey` (clé publique Ed25519 en base64, voir Tools/make-update-key.swift).
/// L'image disque attendue s'appelle « <CFBundleExecutable>-<version>.dmg », signée par « … .dmg.sig ».
@MainActor
package final class Updater: NSObject {
    package static let shared = Updater()

    /// Appelé juste avant de quitter pour installer (sauvegarde de la session, etc.).
    package var beforeRelaunch: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "UpdateLastCheck"
    private let skippedKey = "UpdateSkippedVersion"
    private var isChecking = false
    private var window: UpdateWindowController?
    private var installTask: Task<Void, Never>?

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var repository: String? { info["UpdateRepository"] as? String }
    private var publicKey: String? { (info["UpdatePublicKey"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private var appName: String {
        (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ProcessInfo.processInfo.processName
    }
    private var assetPrefix: String { ((info["CFBundleExecutable"] as? String) ?? ProcessInfo.processInfo.processName) + "-" }
    package var currentVersion: AppVersion { AppVersion((info["CFBundleShortVersionString"] as? String) ?? "0") }

    /// Vérification discrète au lancement, au plus une fois par jour. Aucune erreur affichée.
    package func checkAtLaunch() {
        if let last = defaults.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < 24 * 3600 { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await check(manual: false)
        }
    }

    /// Menu « Rechercher les mises à jour… ».
    @objc package func checkForUpdates(_ sender: Any?) {
        if let window { window.showWindow(nil); return }
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        guard !isChecking, window == nil, let repository else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await ReleaseFeed.latest(repository: repository, assetPrefix: assetPrefix)
            defaults.set(Date(), forKey: lastCheckKey)
            if release.version > currentVersion, manual || defaults.string(forKey: skippedKey) != release.version.description {
                propose(release)
            } else if manual {
                alert("\(appName) est à jour.", "La version \(currentVersion) est la plus récente.")
            }
        } catch {
            // Dépôt privé ou réseau absent : silence au lancement, message clair à la demande.
            if manual { alert("Impossible de rechercher les mises à jour.", error.localizedDescription) }
        }
    }

    private func propose(_ release: Release) {
        let controller = UpdateWindowController(release: release, appName: appName, current: currentVersion)
        controller.onInstall = { [weak self] in self?.install(release) }
        controller.onLater = { [weak self] in self?.close() }
        controller.onSkip = { [weak self] in
            self?.defaults.set(release.version.description, forKey: self?.skippedKey ?? "")
            self?.close()
        }
        controller.onCancel = { [weak self] in self?.installTask?.cancel() }
        window = controller
        NSApp.activate()
        controller.showWindow(nil)
    }

    private func close() {
        installTask?.cancel()
        // windowWillClose rappelle close() : on oublie la fenêtre avant de la fermer.
        let closing = window
        window = nil
        closing?.close()
    }

    private func install(_ release: Release) {
        guard let window else { return }
        let target = Bundle.main.bundleURL
        let identifier = Bundle.main.bundleIdentifier ?? ""
        installTask = Task {
            do {
                guard target.pathExtension == "app" else {
                    throw UpdateError.command("L’application ne s’exécute pas depuis un paquet .app : installation impossible.")
                }
                guard let dmgURL = release.dmg else { throw UpdateError.missingAsset }
                guard let signatureURL = release.signature else { throw UpdateError.missingSignature }
                guard let publicKey else { throw UpdateError.missingPublicKey }

                window.showProgress("Téléchargement…", fraction: nil)
                let (signature, response) = try await URLSession.shared.data(from: signatureURL)
                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw UpdateError.http(status) }
                let dmg = try await Downloader.download(dmgURL) { fraction in
                    window.showProgress("Téléchargement…", fraction: fraction)
                }
                defer { try? FileManager.default.removeItem(at: dmg) }

                window.showProgress("Vérification de la signature…", fraction: nil)
                guard try UpdateSignature.isValid(file: dmg, signature: signature, publicKey: publicKey) else {
                    throw UpdateError.badSignature
                }
                try Task.checkCancellation()

                window.showProgress("Installation…", fraction: nil)
                let staged = try await Task.detached {
                    try UpdateInstaller.stage(dmg: dmg, bundleIdentifier: identifier, target: target)
                }.value
                beforeRelaunch?()
                try UpdateInstaller.launchReplacement(pid: getpid(), staged: staged, target: target, relaunch: true)
                NSApp.terminate(nil)
                // Si la fermeture est refusée (opérations en cours), l'installation se fera à la sortie.
                window.showProgress("La mise à jour sera installée en quittant \(appName).", fraction: 1)
            } catch is CancellationError {
                window.showProposal()
            } catch let error as URLError where error.code == .cancelled {
                window.showProposal()
            } catch {
                window.showProposal()
                let open = alert("La mise à jour a échoué.", error.localizedDescription,
                                 buttons: release.page == nil ? ["OK"] : ["OK", "Ouvrir la page de la version"])
                if open == .alertSecondButtonReturn, let page = release.page { NSWorkspace.shared.open(page) }
            }
        }
    }

    @discardableResult
    private func alert(_ message: String, _ detail: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate()
        return alert.runModal()
    }
}

/// Téléchargement avec progression (URLSession, délégué de téléchargement).
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: @MainActor (Double) -> Void

    private init(progress: @escaping @MainActor (Double) -> Void) { self.progress = progress }

    static func download(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let downloader = Downloader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        let fraction = Double(written) / Double(expected)
        Task { @MainActor in progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Le fichier temporaire disparaît au retour : on le déplace tout de suite.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            finish(.failure(UpdateError.http(status)))
            return
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
