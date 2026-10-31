import AppKit
import CommonCrypto
import CryptoKit

/// Chiffrement d'un fichier par mot de passe : AES-256-GCM (« .aes256 ») ou ChaCha20-Poly1305 (« .chacha20 »).
/// L'extension dit l'algorithme : l'app propose « Déchiffrer » sur ces fichiers. AES n'existe pas en 512 bits :
/// 256 bits est la clé la plus longue, et ChaCha20 est l'autre chiffrement moderne de référence (clé de 256 bits).
///
/// Format (lecture par blocs, gros fichiers acceptés) : en-tête « IEXENC1 », algorithme, itérations PBKDF2-SHA256,
/// sel (16 o), préfixe de nonce (8 o), taille de bloc ; puis des blocs scellés (nonce = préfixe + numéro de bloc,
/// en-tête et drapeau « dernier bloc » authentifiés : un bloc retiré, déplacé ou modifié est détecté).
enum FileCipher: UInt8, CaseIterable {
    case aes256 = 1, chacha20 = 2

    var title: String {
        switch self {
        case .aes256: "AES-256-GCM"
        case .chacha20: "ChaCha20-Poly1305"
        }
    }

    var fileExtension: String {
        switch self {
        case .aes256: "aes256"
        case .chacha20: "chacha20"
        }
    }

    init?(encryptedFile url: URL) {
        guard let cipher = Self.allCases.first(where: { $0.fileExtension == url.pathExtension.lowercased() }) else { return nil }
        self = cipher
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let wrongPassword = Failure(message: "Mot de passe incorrect, ou fichier abîmé.")

    private static let magic = Data("IEXENC1\0".utf8)
    private static let chunkSize = 1 << 20
    private static let iterations: UInt32 = 600_000
    private static let tagSize = 16

    private static func deriveKey(_ password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, passwordBytes.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &key, key.count)
        }
        guard status == kCCSuccess else { throw Failure(message: "Dérivation de la clé impossible.") }
        return SymmetricKey(data: key)
    }

    private static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func nonce(_ prefix: Data, _ counter: UInt32) -> Data {
        prefix + withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }

    private func seal(_ plain: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        switch self {
        case .aes256:
            let box = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
            return box.ciphertext + box.tag
        case .chacha20:
            let box = try ChaChaPoly.seal(plain, using: key, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
            return box.ciphertext + box.tag
        }
    }

    private func open(_ sealed: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        let ciphertext = sealed.prefix(sealed.count - Self.tagSize), tag = sealed.suffix(Self.tagSize)
        do {
            switch self {
            case .aes256:
                return try AES.GCM.open(AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag), using: key, authenticating: aad)
            case .chacha20:
                return try ChaChaPoly.open(ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag), using: key, authenticating: aad)
            }
        } catch {
            throw Self.wrongPassword
        }
    }

    func encrypt(_ source: URL, to target: URL, password: String, job: FileJob) throws {
        let salt = Self.random(16), prefix = Self.random(8)
        var header = Self.magic
        header.append(rawValue)
        header += withUnsafeBytes(of: Self.iterations.bigEndian) { Data($0) }
        header += salt + prefix
        header += withUnsafeBytes(of: UInt32(Self.chunkSize).bigEndian) { Data($0) }
        let key = try Self.deriveKey(password, salt: salt, iterations: Self.iterations)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try output.write(contentsOf: header)
        var counter: UInt32 = 0
        var done: Int64 = 0
        var current = try input.read(upToCount: Self.chunkSize) ?? Data()
        while true {
            job.waitIfPaused()
            if job.isCancelled { throw CancellationError() }
            let next = current.count < Self.chunkSize ? Data() : (try input.read(upToCount: Self.chunkSize) ?? Data())
            let isLast = next.isEmpty
            let aad = header + Data([isLast ? 1 : 0])
            try output.write(contentsOf: seal(current, key: key, nonce: Self.nonce(prefix, counter), aad: aad))
            done += Int64(current.count)
            job.setDone(done)
            if isLast { break }
            current = next
            counter += 1
        }
    }

    /// Déchiffre ; l'algorithme est lu dans l'en-tête (l'extension ne sert qu'à reconnaître le fichier).
    static func decrypt(_ source: URL, to target: URL, password: String, job: FileJob) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let headerSize = magic.count + 1 + 4 + 16 + 8 + 4
        guard let header = try input.read(upToCount: headerSize), header.count == headerSize, header.prefix(magic.count) == magic,
              let cipher = FileCipher(rawValue: header[header.startIndex + magic.count]) else {
            throw Failure(message: "Ce fichier n’a pas été chiffré par iExplorer.")
        }
        func uint32(at offset: Int) -> UInt32 { header.subdata(in: offset..<offset + 4).reduce(0) { $0 << 8 | UInt32($1) } }
        let iterations = uint32(at: magic.count + 1)
        let salt = header.subdata(in: magic.count + 5..<magic.count + 21)
        let prefix = header.subdata(in: magic.count + 21..<magic.count + 29)
        let chunk = Int(uint32(at: magic.count + 29)) + tagSize
        let key = try deriveKey(password, salt: salt, iterations: iterations)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var counter: UInt32 = 0
        var done: Int64 = 0
        var current = try input.read(upToCount: chunk) ?? Data()
        while true {
            job.waitIfPaused()
            if job.isCancelled { throw CancellationError() }
            guard current.count >= tagSize else { throw wrongPassword }
            let next = current.count < chunk ? Data() : (try input.read(upToCount: chunk) ?? Data())
            let isLast = next.isEmpty
            let plain = try cipher.open(current, key: key, nonce: nonce(prefix, counter), aad: header + Data([isLast ? 1 : 0]))
            try output.write(contentsOf: plain)
            done += Int64(current.count)
            job.setDone(done)
            if isLast { break }
            current = next
            counter += 1
        }
    }
}

extension PanelViewController {
    var encryptableFiles: [URL] {
        selectedItems.filter { !$0.isNavigableDirectory && $0.url.isFileURL && FileCipher(encryptedFile: $0.url) == nil }.map(\.url)
    }

    var encryptedFiles: [URL] {
        selectedItems.filter { !$0.isNavigableDirectory && FileCipher(encryptedFile: $0.url) != nil }.map(\.url)
    }

    @objc func encryptFiles(_ sender: Any?) {
        let files = encryptableFiles
        guard !files.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = files.count == 1 ? "Chiffrer « \(files[0].lastPathComponent) »" : "Chiffrer \(files.count) fichiers"
        alert.informativeText = "Le fichier chiffré porte l’extension de l’algorithme (.aes256 ou .chacha20) ; iExplorer propose ensuite « Déchiffrer ». Sans le mot de passe, il est irrécupérable."
        let cipher = NSPopUpButton(frame: NSRect(x: 0, y: 86, width: 300, height: 26))
        cipher.addItems(withTitles: FileCipher.allCases.map { "\($0.title) (.\($0.fileExtension))" })
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 56, width: 300, height: 24))
        password.placeholderString = "Mot de passe"
        let confirm = NSSecureTextField(frame: NSRect(x: 0, y: 26, width: 300, height: 24))
        confirm.placeholderString = "Confirmer le mot de passe"
        let trash = NSButton(checkboxWithTitle: "Mettre l’original à la corbeille ensuite", target: nil, action: nil)
        trash.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 114))
        [cipher, password, confirm, trash].forEach(accessory.addSubview)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Chiffrer")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = password
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard !password.stringValue.isEmpty, password.stringValue == confirm.stringValue else {
                FileOperationCenter.shared.showError(password.stringValue.isEmpty ? "Le mot de passe est vide." : "Les deux mots de passe ne correspondent pas.")
                return
            }
            let algorithm = FileCipher.allCases[cipher.indexOfSelectedItem]
            runCipherJob(files, title: "Chiffrement", password: password.stringValue, trashOriginals: trash.state == .on,
                         target: { FileOperationCenter.shared.uniqueURL(for: $0.appendingPathExtension(algorithm.fileExtension), suffix: "") }) {
                try algorithm.encrypt($0, to: $1, password: $3, job: $2)
            }
        }
    }

    @objc func decryptFiles(_ sender: Any?) {
        let files = encryptedFiles
        guard !files.isEmpty else { return }
        askDecryptionPassword(files, retry: false)
    }

    private func askDecryptionPassword(_ files: [URL], retry: Bool) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = retry ? "Mot de passe incorrect" : (files.count == 1 ? "Déchiffrer « \(files[0].lastPathComponent) »" : "Déchiffrer \(files.count) fichiers")
        alert.informativeText = "Saisissez le mot de passe choisi au chiffrement."
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = password
        alert.addButton(withTitle: "Déchiffrer")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = password
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !password.stringValue.isEmpty else { return }
            runCipherJob(files, title: "Déchiffrement", password: password.stringValue, trashOriginals: false,
                         onWrongPassword: { [weak self] remaining in self?.askDecryptionPassword(remaining, retry: true) },
                         target: { FileOperationCenter.shared.uniqueURL(for: $0.deletingPathExtension(), suffix: "") }) {
                try FileCipher.decrypt($0, to: $1, password: $3, job: $2)
            }
        }
    }

    /// Chiffre ou déchiffre les fichiers un à un dans la liste des opérations (progression, pause, annulation).
    private func runCipherJob(_ files: [URL], title: String, password: String, trashOriginals: Bool,
                              onWrongPassword: (([URL]) -> Void)? = nil, target: @escaping (URL) -> URL,
                              work: @escaping (URL, URL, FileJob, String) throws -> Void) {
        let job = FileJob(title: "\(title) de \(files.count == 1 ? "« \(files[0].lastPathComponent) »" : "\(files.count) fichiers")")
        FileOperationCenter.shared.addJob(job)
        let folder = currentURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var created: [URL] = [], done: [URL] = [], failures: [String] = []
            var wrongPassword: [URL] = []
            for source in files where !job.isCancelled {
                job.setStatus(source.lastPathComponent)
                job.setTotal(Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                let destination = target(source)
                do {
                    try work(source, destination, job, password)
                    created.append(destination)
                    done.append(source)
                } catch {
                    // Jamais de fichier à moitié écrit (ou déchiffré avec un mauvais mot de passe) laissé derrière.
                    try? FileManager.default.removeItem(at: destination)
                    if error is CancellationError { break }
                    if let failure = error as? FileCipher.Failure, failure.message == FileCipher.wrongPassword.message {
                        wrongPassword.append(source)
                    } else {
                        failures.append("\(source.lastPathComponent) : \(error.localizedDescription)")
                    }
                }
            }
            DispatchQueue.main.async {
                FileOperationCenter.shared.removeJob(job)
                if trashOriginals, !done.isEmpty { FileOperationCenter.shared.trash(done, undoManager: nil, actionName: title) }
                if !failures.isEmpty { FileOperationCenter.shared.showError(failures.joined(separator: "\n")) }
                if let self, folder.isSameLocation(as: self.currentURL), !created.isEmpty { self.reload(selecting: created) }
                if !wrongPassword.isEmpty { onWrongPassword?(wrongPassword) }
            }
        }
    }
}
