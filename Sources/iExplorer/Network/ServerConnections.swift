import AppKit

/// Une connexion serveur enregistrée (favori réseau).
struct ServerConnection: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case sftp, smb, afp, nfs, webdav

        var title: String {
            switch self {
            case .sftp: "SFTP"
            case .smb: "SMB (partage Windows / macOS)"
            case .afp: "AFP"
            case .nfs: "NFS"
            case .webdav: "WebDAV"
            }
        }

        var defaultPort: Int {
            switch self {
            case .sftp: 22
            case .smb: 445
            case .afp: 548
            case .nfs: 2049
            case .webdav: 443
            }
        }

        var symbol: String {
            switch self {
            case .sftp: "lock.fill"
            case .smb: "externaldrive.connected.to.line.below"
            case .afp, .nfs: "server.rack"
            case .webdav: "globe"
            }
        }

        var scheme: String { self == .webdav ? "https" : rawValue }
    }

    static let colors: [NSColor] = [.systemBlue, .systemGray, .systemGreen, .systemPurple, .systemTeal, .systemYellow, .systemRed, .systemOrange]

    var id = UUID()
    var name = ""
    var kind: Kind = .sftp
    var host = ""
    var port: Int?
    var user = ""
    var path = ""
    var identityFile = ""
    var color = 0

    var effectivePort: Int { port ?? kind.defaultPort }
    var tint: NSColor { Self.colors[min(max(color, 0), Self.colors.count - 1)] }
    var displayName: String { name.isEmpty ? host : name }

    var sftpEndpoint: SFTPEndpoint {
        SFTPEndpoint(host: host, port: effectivePort, user: user, identityFile: identityFile)
    }

    /// Adresse complète, affichée en tête du panneau et utilisée pour le montage.
    var url: URL? {
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = kind.scheme
        components.host = host
        if !user.isEmpty { components.user = user }
        if let port, port != kind.defaultPort { components.port = port }
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        components.path = trimmed.isEmpty ? "" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        return components.url
    }

    /// Compte du trousseau (le même que celui utilisé par le mode askpass pour SFTP).
    var keychainAccount: String {
        kind == .sftp ? sftpEndpoint.key : "\(kind.rawValue)://\(user.isEmpty ? "" : user + "@")\(host)"
    }
}

enum SavedConnections {
    private static let key = "server.connections"

    static var all: [ServerConnection] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([ServerConnection].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            NotificationCenter.default.post(name: Preferences.favoritesChanged, object: nil)
        }
    }

    static func save(_ connection: ServerConnection) {
        var list = all
        if let index = list.firstIndex(where: { $0.id == connection.id }) { list[index] = connection } else { list.append(connection) }
        all = list
    }

    static func remove(_ connection: ServerConnection) {
        all.removeAll { $0.id == connection.id }
    }

    /// Options enregistrées (clé privée…) pour un serveur SFTP donné.
    static func endpoint(matching endpoint: SFTPEndpoint) -> SFTPEndpoint? {
        all.first { $0.kind == .sftp && $0.sftpEndpoint.key == endpoint.key }?.sftpEndpoint
    }
}

/// Établit une connexion (montage NetFS ou session SFTP) et renvoie l'emplacement à afficher.
enum ConnectionService {
    static func connect(_ connection: ServerConnection, password: String?, remember: Bool,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        let account = connection.keychainAccount
        if let password, !password.isEmpty { Keychain.save(password, for: account) }
        // Un mot de passe non mémorisé ne sert que le temps de la connexion.
        let forget = { if !remember, password?.isEmpty == false { Keychain.delete(account) } }

        if connection.kind == .sftp {
            let endpoint = connection.sftpEndpoint
            SFTPManager.shared.configure(endpoint)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = try SFTPManager.shared.session(for: endpoint.url(path: "/"))
                    try session.connect()
                    let requested = connection.path.trimmingCharacters(in: .whitespaces)
                    let path = requested.isEmpty ? (session.homeDirectory ?? "/") : requested
                    DispatchQueue.main.async { forget(); completion(.success(endpoint.url(path: path))) }
                } catch {
                    DispatchQueue.main.async { forget(); completion(.failure(error)) }
                }
            }
            return
        }

        guard let url = connection.url else {
            completion(.failure(SFTPError.connection("Adresse du serveur incomplète.")))
            return
        }
        let secret = password.flatMap { $0.isEmpty ? nil : $0 } ?? Keychain.password(for: account)
        NetworkConnector.mount(url, user: connection.user.isEmpty ? nil : connection.user, password: secret) { result in
            forget()
            completion(result)
        }
    }
}

/// Panneau de configuration d'une connexion (SFTP, SMB, AFP, NFS, WebDAV).
final class ConnectionPanelController: NSViewController {
    var onConnect: ((ServerConnection, String?, Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private var connection: ServerConnection
    private let isEditing: Bool

    private let urlLabel = NSTextField(labelWithString: "")
    private let urlIcon = NSImageView()
    private let kindPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let pathField = NSTextField()
    private let keyField = NSTextField()
    private let rememberBox = NSButton(checkboxWithTitle: "Mémoriser le mot de passe dans le trousseau", target: nil, action: nil)
    private var colorButtons: [NSButton] = []
    private var keyRow: NSGridRow!

    init(connection: ServerConnection?) {
        self.connection = connection ?? ServerConnection()
        isEditing = connection != nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        urlIcon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        urlLabel.font = .systemFont(ofSize: 17, weight: .medium)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        let header = NSStackView(views: [urlIcon, urlLabel])
        header.spacing = 10

        for kind in ServerConnection.Kind.allCases {
            kindPopup.addItem(withTitle: kind.title)
            kindPopup.lastItem?.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        }
        kindPopup.target = self
        kindPopup.action = #selector(fieldChanged(_:))

        nameField.placeholderString = "Facultatif"
        hostField.placeholderString = "serveur.exemple.fr ou 192.168.1.10"
        userField.placeholderString = NSUserName()
        passwordField.placeholderString = "Demandé à la connexion si vide"
        pathField.placeholderString = "Dossier de départ (facultatif)"
        keyField.placeholderString = "~/.ssh/id_ed25519 (facultatif, sinon agent ssh)"
        for field in [nameField, hostField, portField, userField, passwordField, pathField, keyField] {
            field.delegate = self
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }

        let chooseKey = NSButton(title: "Choisir…", target: self, action: #selector(chooseKey(_:)))
        chooseKey.controlSize = .small
        let keyStack = NSStackView(views: [keyField, chooseKey])

        let colors = NSStackView()
        colors.spacing = 6
        for (index, color) in ServerConnection.colors.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!, target: self, action: #selector(colorPicked(_:)))
            button.isBordered = false
            button.contentTintColor = color
            button.tag = index
            button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            colorButtons.append(button)
            colors.addArrangedSubview(button)
        }

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.textColor = .secondaryLabelColor
            return field
        }
        let grid = NSGridView(views: [
            [label("Protocole"), kindPopup],
            [label("Nom"), nameField],
            [label("Serveur"), hostField],
            [label("Port"), portField],
            [label("Utilisateur"), userField],
            [label("Mot de passe"), passwordField],
            [NSGridCell.emptyContentView, rememberBox],
            [label("Chemin"), pathField],
            [label("Clé privée"), keyStack],
            [label("Couleur"), colors],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        keyRow = grid.row(at: 8)

        let favorite = NSButton(title: isEditing ? "Enregistrer" : "Ajouter aux favoris", target: self, action: #selector(saveOnly(_:)))
        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let connect = NSButton(title: "Se connecter", target: self, action: #selector(connect(_:)))
        connect.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [favorite, spacer, cancel, connect])
        buttons.spacing = 8

        let root = NSStackView(views: [header, NSBox.separator(), grid, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        root.arrangedSubviews[1].widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        view = root
        load()
    }

    private func load() {
        kindPopup.selectItem(at: ServerConnection.Kind.allCases.firstIndex(of: connection.kind) ?? 0)
        nameField.stringValue = connection.name
        hostField.stringValue = connection.host
        portField.stringValue = connection.port.map(String.init) ?? ""
        userField.stringValue = connection.user
        pathField.stringValue = connection.path
        keyField.stringValue = connection.identityFile
        rememberBox.state = Keychain.password(for: connection.keychainAccount) != nil || !isEditing ? .on : .off
        refresh()
    }

    private func readFields(parseAddress: Bool = false) {
        connection.kind = ServerConnection.Kind.allCases[max(0, kindPopup.indexOfSelectedItem)]
        connection.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        var host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        // Accepte aussi une adresse complète collée (sftp://user@hote:port/chemin).
        if parseAddress, host.contains("://"), let url = URL(string: host) {
            if let kind = ServerConnection.Kind.allCases.first(where: { $0.scheme == url.scheme || $0.rawValue == url.scheme }) { connection.kind = kind }
            if let user = url.user { connection.user = user; userField.stringValue = user }
            if let port = url.port { portField.stringValue = String(port) }
            if !url.path.isEmpty { pathField.stringValue = url.path }
            host = url.host ?? host
            hostField.stringValue = host
            kindPopup.selectItem(at: ServerConnection.Kind.allCases.firstIndex(of: connection.kind) ?? 0)
        }
        connection.host = host
        connection.port = Int(portField.stringValue)
        connection.user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        connection.path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        connection.identityFile = keyField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func refresh() {
        readFields()
        portField.placeholderString = String(connection.kind.defaultPort)
        urlIcon.image = NSImage(systemSymbolName: connection.kind.symbol, accessibilityDescription: nil)
        urlIcon.contentTintColor = connection.tint
        urlLabel.stringValue = connection.url?.absoluteString ?? "\(connection.kind.scheme)://"
        keyRow.isHidden = connection.kind != .sftp
        for button in colorButtons {
            button.image = NSImage(systemSymbolName: button.tag == connection.color ? "largecircle.fill.circle" : "circle.fill",
                                   accessibilityDescription: nil)
        }
    }

    @objc private func fieldChanged(_ sender: Any?) { refresh() }

    @objc private func colorPicked(_ sender: NSButton) {
        connection.color = sender.tag
        refresh()
    }

    @objc private func chooseKey(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            keyField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            refresh()
        }
    }

    private func validate() -> Bool {
        readFields(parseAddress: true)
        refresh()
        guard !connection.host.isEmpty else {
            NSSound.beep()
            view.window?.makeFirstResponder(hostField)
            return false
        }
        return true
    }

    private func storePassword() {
        let password = passwordField.stringValue
        if rememberBox.state == .on, !password.isEmpty { Keychain.save(password, for: connection.keychainAccount) }
        if rememberBox.state == .off { Keychain.delete(connection.keychainAccount) }
    }

    @objc private func saveOnly(_ sender: Any?) {
        guard validate() else { return }
        storePassword()
        SavedConnections.save(connection)
        close()
    }

    @objc private func connect(_ sender: Any?) {
        guard validate() else { return }
        if isEditing { SavedConnections.save(connection) }
        storePassword()
        let password = passwordField.stringValue
        onConnect?(connection, password.isEmpty ? nil : password, rememberBox.state == .on)
        close()
    }

    @objc private func cancel(_ sender: Any?) { close() }

    private func close() {
        if let window = view.window, let parent = window.sheetParent { parent.endSheet(window) }
        onDismiss?()
    }
}

extension ConnectionPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) { refresh() }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
