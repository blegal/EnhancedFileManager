import AppKit
import Security

/// Mots de passe des serveurs, rangés dans le trousseau de session.
enum Keychain {
    private static let service = "EnhancedFileManager"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func password(for account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for account: String) {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Enhanced File Manager — \(account)"
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Mode « SSH_ASKPASS » : ssh relance l'exécutable de l'app pour demander un mot de passe,
/// une phrase de passe ou la confirmation d'une nouvelle clé de serveur.
/// La réponse est écrite sur la sortie standard.
enum AskPass {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["EFM_ASKPASS"] == "1" }

    static func run() -> Never {
        let environment = ProcessInfo.processInfo.environment
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = prompt.lowercased()
        let account = environment["EFM_ASKPASS_ACCOUNT"]
        let isConfirmation = lower.contains("yes/no")
        let isSecret = lower.contains("password") || lower.contains("passphrase") || lower.contains("mot de passe")

        // Premier essai : le mot de passe enregistré (une seule fois par connexion, pour ne pas
        // boucler sur un mot de passe devenu faux).
        if isSecret, !isConfirmation, let account, let token = environment["EFM_ASKPASS_TOKEN"] {
            let marker = "\(SFTPSession.controlDirectory)/askpass-\(token)"
            if !FileManager.default.fileExists(atPath: marker) {
                FileManager.default.createFile(atPath: marker, contents: nil, attributes: [.posixPermissions: 0o600])
                if let saved = Keychain.password(for: account) {
                    print(saved)
                    exit(0)
                }
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: isConfirmation ? "lock.shield" : "key.fill", accessibilityDescription: nil)
        if isConfirmation {
            alert.messageText = "Première connexion à ce serveur"
            alert.informativeText = prompt + "\n\nVérifiez l’empreinte auprès de l’administrateur du serveur avant d’accepter."
            alert.addButton(withTitle: "Faire confiance et se connecter")
            alert.addButton(withTitle: "Annuler")
            alert.window.level = .floating
            let accepted = alert.runModal() == .alertFirstButtonReturn
            print(accepted ? "yes" : "no")
            exit(accepted ? 0 : 1)
        }

        alert.messageText = account.map { "Connexion à \($0)" } ?? "Connexion SFTP"
        alert.informativeText = prompt
        let field: NSTextField = isSecret ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                                          : NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Se connecter")
        alert.addButton(withTitle: "Annuler")
        if isSecret, account != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Enregistrer dans le trousseau"
        }
        alert.window.initialFirstResponder = field
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        if let account, alert.suppressionButton?.state == .on {
            Keychain.save(field.stringValue, for: account)
        }
        print(field.stringValue)
        exit(0)
    }
}
