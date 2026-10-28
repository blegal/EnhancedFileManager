import AppKit
import NetFS

/// Montage des partages réseau (SMB, AFP, NFS, WebDAV) avec NetFS.
/// Sans mot de passe fourni, la fenêtre d'authentification du système (et son trousseau) prend le relais.
enum NetworkConnector {
    static func mount(_ url: URL, user: String?, password: String?, completion: @escaping (Result<URL, Error>) -> Void) {
        // Constantes de NetFS/NetFS.h (macros CFSTR non importées en Swift).
        let openOptions = NSMutableDictionary(dictionary: ["UIOption": password == nil ? "AllowUI" : "NoUI"])
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, user as CFString?, password as CFString?,
                                        openOptions as CFMutableDictionary, nil, &requestID, DispatchQueue.main) { status, _, mountPoints in
            if status == 0, let path = (mountPoints as? [String])?.first {
                completion(.success(URL(fileURLWithPath: path, isDirectory: true)))
            } else if status == EEXIST, let existing = mountedVolume(for: url) {
                completion(.success(existing))
            } else if status == ECANCELED || status == -128 /* userCanceledErr */ {
                return
            } else {
                completion(.failure(error(for: status, url: url)))
            }
        }
        if status != 0 { completion(.failure(error(for: status, url: url))) }
    }

    /// Retrouve un volume déjà monté depuis le même serveur.
    private static func mountedVolume(for url: URL) -> URL? {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
        return volumes.first { volume in
            let remote = (try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting
            return remote?.host?.lowercased() == url.host?.lowercased()
                && (url.path.isEmpty || url.path == "/" || remote?.path.lowercased() == url.path.lowercased())
        }
    }

    private static func error(for status: Int32, url: URL) -> NSError {
        let reason = status > 0 ? String(cString: strerror(status)) : "code \(status)"
        return NSError(domain: NSPOSIXErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Impossible de se connecter à « \(url.host ?? url.absoluteString) ».",
            NSLocalizedRecoverySuggestionErrorKey: "Vérifiez l’adresse, le nom du partage et vos identifiants (\(reason)).",
        ])
    }
}
