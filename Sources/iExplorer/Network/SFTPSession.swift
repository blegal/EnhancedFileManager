import AppKit
import UniformTypeIdentifiers

/// Paramètres de connexion SFTP.
struct SFTPEndpoint: Hashable {
    var host: String
    var port: Int = 22
    var user: String?
    var identityFile: String?

    /// Même forme que `URL.sftpKey` : « utilisateur@hôte:port ».
    var key: String { "\(user.map { $0 + "@" } ?? "")\(host):\(port)" }

    init(host: String, port: Int = 22, user: String? = nil, identityFile: String? = nil) {
        self.host = host
        self.port = port
        self.user = user.flatMap { $0.isEmpty ? nil : $0 }
        self.identityFile = identityFile.flatMap { $0.isEmpty ? nil : $0 }
    }

    init?(url: URL) {
        guard url.isRemote, let host = url.host, !host.isEmpty else { return nil }
        self.init(host: host, port: url.port ?? 22, user: url.user)
    }

    /// URL `sftp://` d'un chemin sur ce serveur.
    func url(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "sftp"
        components.user = user
        components.host = host
        if port != 22 { components.port = port }
        components.path = path.isEmpty ? "/" : path
        return components.url!
    }
}

enum SFTPError: LocalizedError {
    case connection(String)
    case command(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .connection(let message): return message
        case .command(let message): return message
        case .timeout: return "Le serveur SFTP ne répond pas."
        }
    }
}

/// Une entrée d'une liste distante (`ls -lan`).
struct SFTPEntry {
    let path: String
    let name: String
    let type: Character   // d, -, l…
    let size: Int64
    let date: Date?
    /// Mode symbolique (« drwxr-xr-x »), propriétaire et groupe (numériques avec `ls -n`).
    var mode = ""
    var owner = ""
    var group = ""

    var isDirectory: Bool { type == "d" }

    /// Bits de permission (rwx × 3) lus dans le mode symbolique.
    var permissions: Int {
        let characters = Array(mode.dropFirst().prefix(9))
        var value = 0
        for (index, character) in characters.enumerated() where character != "-" && character != "S" && character != "T" {
            value |= 1 << (8 - index)
        }
        return value
    }
    var isSymlink: Bool { type == "l" }
}

/// Une connexion `sftp` pilotée par ses entrées / sorties standard.
/// Chaque commande est suivie d'un marqueur unique pour délimiter sa réponse.
final class SFTPSession {
    let endpoint: SFTPEndpoint
    private(set) var homeDirectory: String?

    private var process: Process?
    private var input: FileHandle?
    private let condition = NSCondition()
    private let commandLock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var exited = false
    private var counter = 0

    init(endpoint: SFTPEndpoint) { self.endpoint = endpoint }

    deinit { close() }

    static var controlDirectory: String {
        let path = "/tmp/efm-\(getuid())"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }

    /// Options ssh communes : connexion maîtresse partagée (une seule authentification).
    var sshOptions: [String] {
        var options = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(Self.controlDirectory)/%C",
            "-o", "ControlPersist=600",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=20",
            "-o", "NumberOfPasswordPrompts=3",
        ]
        if let identity = endpoint.identityFile {
            options += ["-i", (identity as NSString).expandingTildeInPath]
        }
        return options
    }

    private var destination: String {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        return endpoint.user.map { "\($0)@\(host)" } ?? host
    }

    var isConnected: Bool {
        condition.lock()
        defer { condition.unlock() }
        return process != nil && !exited
    }

    // MARK: Connexion

    /// Démarre `sftp` si nécessaire. Bloquant (peut attendre la saisie d'un mot de passe).
    func connect() throws {
        commandLock.lock()
        defer { commandLock.unlock() }
        try connectLocked()
    }

    private func connectLocked() throws {
        if process != nil && !exited { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = ["-q"] + sshOptions + ["-P", String(endpoint.port), destination]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        // Sans locale UTF-8, sftp affiche les caractères accentués en séquences octales.
        environment["LC_CTYPE"] = "en_US.UTF-8"
        environment["EFM_ASKPASS"] = "1"
        environment["EFM_ASKPASS_ACCOUNT"] = endpoint.key
        environment["EFM_ASKPASS_TOKEN"] = UUID().uuidString
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.append(handle.availableData, error: false) }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.append(handle.availableData, error: true) }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            condition.lock()
            exited = true
            condition.broadcast()
            condition.unlock()
            DispatchQueue.main.async { NotificationCenter.default.post(name: SFTPManager.sessionsChanged, object: nil) }
        }

        condition.lock()
        output.removeAll()
        errors.removeAll()
        exited = false
        condition.unlock()

        do { try process.run() } catch {
            throw SFTPError.connection("Impossible de lancer sftp : \(error.localizedDescription)")
        }
        self.process = process
        input = stdin.fileHandleForWriting

        do {
            let lines = try runLocked("pwd", timeout: 300)
            if let line = lines.first(where: { $0.hasPrefix("Remote working directory:") }) {
                homeDirectory = String(line.dropFirst("Remote working directory:".count)).trimmingCharacters(in: .whitespaces)
            }
        } catch {
            close()
            throw error
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: SFTPManager.sessionsChanged, object: nil) }
    }

    func close() {
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    /// Interrompt la commande en cours (annulation d'un transfert).
    func cancel() {
        process?.terminate()
    }

    private func append(_ data: Data, error: Bool) {
        guard !data.isEmpty else { return }
        condition.lock()
        if error { errors.append(data) } else { output.append(data) }
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Commandes

    /// Exécute une commande sftp ; renvoie les lignes de sortie, lève une erreur si sftp en signale une.
    @discardableResult
    func run(_ command: String, timeout: TimeInterval = 120) throws -> [String] {
        commandLock.lock()
        defer { commandLock.unlock() }
        try connectLocked()
        return try runLocked(command, timeout: timeout)
    }

    private func runLocked(_ command: String, timeout: TimeInterval) throws -> [String] {
        counter += 1
        let marker = "__EFM_\(counter)_\(UUID().uuidString.prefix(8))__"
        condition.lock()
        output.removeAll()
        errors.removeAll()
        condition.unlock()

        let text = "\(command)\n!echo \(marker); echo \(marker) >&2\n"
        do {
            try input?.write(contentsOf: Data(text.utf8))
        } catch {
            throw SFTPError.connection("La connexion SFTP a été interrompue.")
        }

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            let out = String(decoding: output, as: UTF8.self)
            let err = String(decoding: errors, as: UTF8.self)
            let outLines = out.components(separatedBy: "\n")
            let errLines = err.components(separatedBy: "\n")
            if outLines.contains(marker), errLines.contains(marker) {
                let result = Array(outLines.prefix(while: { $0 != marker })).filter { !$0.hasPrefix("sftp> ") && !$0.isEmpty }
                let problems = Array(errLines.prefix(while: { $0 != marker })).filter { !$0.isEmpty }
                if !problems.isEmpty { throw SFTPError.command(Self.describe(problems)) }
                return result
            }
            if exited {
                let problems = errLines.filter { !$0.isEmpty && $0 != marker }
                throw SFTPError.connection(Self.describe(problems, connection: true))
            }
            if !condition.wait(until: deadline) { throw SFTPError.timeout }
        }
    }

    private static func describe(_ lines: [String], connection: Bool = false) -> String {
        let text = lines.joined(separator: "\n")
        if text.contains("Permission denied") && connection { return "Authentification refusée par le serveur." }
        if text.contains("Host key verification failed") { return "La clé du serveur n’a pas été acceptée." }
        if text.contains("Could not resolve hostname") { return "Serveur introuvable." }
        if text.contains("Connection refused") { return "Connexion refusée (le service SSH est-il actif ?)." }
        if text.contains("timed out") { return "Le délai de connexion a expiré." }
        if text.isEmpty { return connection ? "La connexion SFTP a été fermée." : "Erreur SFTP." }
        return text
    }

    /// Échappe un chemin pour la ligne de commande sftp (espaces, guillemets, caractères de motif).
    static func escape(_ path: String) -> String {
        var result = ""
        for character in path {
            if " \t\"'\\*?[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: Opérations

    /// Liste un chemin. `isDirectory` est faux si le chemin désigne un fichier.
    func list(_ path: String) throws -> (isDirectory: Bool, entries: [SFTPEntry]) {
        let lines = try run("ls -lan \(Self.escape(path))")
        let prefix = path == "/" ? "/" : path + "/"
        var isDirectory = false
        var entries: [SFTPEntry] = []
        for line in lines {
            guard let entry = Self.parse(line) else { continue }
            if entry.path == prefix + "." { isDirectory = true; continue }
            if entry.path == prefix + ".." { continue }
            let name = entry.path.hasPrefix(prefix) ? String(entry.path.dropFirst(prefix.count)) : (entry.path as NSString).lastPathComponent
            var child = SFTPEntry(path: prefix + name, name: name, type: entry.type, size: entry.size, date: entry.date)
            child.mode = entry.mode
            child.owner = entry.owner
            child.group = entry.group
            entries.append(child)
        }
        return (isDirectory, entries)
    }

    func isDirectory(_ path: String) -> Bool {
        (try? list(path).isDirectory) ?? false
    }

    func makeDirectory(_ path: String) throws { try run("mkdir \(Self.escape(path))") }

    /// Permissions, propriétaire et groupe d'un chemin : identifiants numériques et noms.
    func attributes(_ path: String) throws -> (entry: SFTPEntry, ownerName: String, groupName: String) {
        func entry(_ options: String) throws -> SFTPEntry? {
            let entries = try run("ls \(options) \(Self.escape(path))").compactMap(Self.parse)
            // Un dossier se décrit par son entrée « . » ; un fichier par son unique ligne.
            return entries.first { $0.path.hasSuffix("/.") || $0.path == "." } ?? (entries.count == 1 ? entries[0] : nil)
        }
        guard let numeric = try entry("-lan") else { throw SFTPError.command("Impossible de lire les permissions de « \(path) ».") }
        let named = try? entry("-la")
        return (numeric, named?.owner ?? numeric.owner, named?.group ?? numeric.group)
    }

    func changeMode(_ mode: Int, of path: String) throws { try run("chmod \(String(mode, radix: 8)) \(Self.escape(path))") }
    func changeOwner(_ uid: String, of path: String) throws { try run("chown \(uid) \(Self.escape(path))") }
    func changeGroup(_ gid: String, of path: String) throws { try run("chgrp \(gid) \(Self.escape(path))") }

    func rename(_ from: String, to: String) throws { try run("rename \(Self.escape(from)) \(Self.escape(to))") }

    /// Suppression récursive (sftp ne sait pas supprimer un dossier non vide).
    func removeRecursively(_ path: String) throws {
        let listing = try list(path)
        guard listing.isDirectory else {
            try run("rm \(Self.escape(path))")
            return
        }
        for entry in listing.entries {
            if entry.isDirectory { try removeRecursively(entry.path) } else { try run("rm \(Self.escape(entry.path))") }
        }
        try run("rmdir \(Self.escape(path))")
    }

    func download(_ remote: String, to local: String) throws {
        try run("get -r \(Self.escape(remote)) \(Self.escape(local))", timeout: 24 * 3600)
    }

    func upload(_ local: String, to remote: String) throws {
        try run("put -r \(Self.escape(local)) \(Self.escape(remote))", timeout: 24 * 3600)
    }

    // MARK: Analyse de `ls -lan`

    private static let recentFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm yyyy"
        return f
    }()

    private static let oldFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d yyyy"
        return f
    }()

    /// « drwxr-xr-x  ? 502  20  128 Oct 28 14:42 /chemin/nom »
    static func parse(_ line: String) -> SFTPEntry? {
        var fields: [Substring] = []
        var index = line.startIndex
        while fields.count < 8 {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            guard index < line.endIndex else { return nil }
            let start = index
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            fields.append(line[start..<index])
        }
        guard index < line.endIndex, let type = fields[0].first, fields[0].count >= 10 else { return nil }
        let path = String(line[line.index(after: index)...])
        let size = Int64(fields[4]) ?? 0
        let stamp = "\(fields[5]) \(fields[6])"
        var date: Date?
        if fields[7].contains(":") {
            let year = Calendar.current.component(.year, from: Date())
            date = recentFormatter.date(from: "\(stamp) \(fields[7]) \(year)")
            if let d = date, d > Date().addingTimeInterval(86_400) {
                date = recentFormatter.date(from: "\(stamp) \(fields[7]) \(year - 1)")
            }
        } else {
            date = oldFormatter.date(from: "\(stamp) \(fields[7])")
        }
        var entry = SFTPEntry(path: path, name: (path as NSString).lastPathComponent, type: type, size: size, date: date)
        entry.mode = String(fields[0])
        entry.owner = String(fields[2])
        entry.group = String(fields[3])
        return entry
    }
}

/// Registre des connexions SFTP ouvertes (une session de navigation par serveur).
final class SFTPManager {
    static let shared = SFTPManager()
    static let sessionsChanged = Notification.Name("SFTPSessionsChanged")

    private let lock = NSLock()
    private var sessions: [String: SFTPSession] = [:]
    private var configurations: [String: SFTPEndpoint] = [:]

    /// Mémorise les options (clé privée…) à utiliser pour un serveur.
    func configure(_ endpoint: SFTPEndpoint) {
        lock.withLock { configurations[endpoint.key] = endpoint }
    }

    func endpoint(for url: URL) -> SFTPEndpoint? {
        guard let base = SFTPEndpoint(url: url) else { return nil }
        return lock.withLock { configurations[base.key] } ?? SavedConnections.endpoint(matching: base) ?? base
    }

    func session(for url: URL) throws -> SFTPSession {
        guard let endpoint = endpoint(for: url) else { throw SFTPError.connection("Adresse SFTP invalide.") }
        return lock.withLock {
            if let existing = sessions[endpoint.key] { return existing }
            let session = SFTPSession(endpoint: endpoint)
            sessions[endpoint.key] = session
            return session
        }
    }

    /// Une session séparée pour un transfert (réutilise l'authentification de la connexion maîtresse).
    func dedicatedSession(for url: URL) throws -> SFTPSession {
        guard let endpoint = endpoint(for: url) else { throw SFTPError.connection("Adresse SFTP invalide.") }
        return SFTPSession(endpoint: endpoint)
    }

    var connectedSessions: [SFTPSession] {
        lock.withLock { Array(sessions.values) }.filter(\.isConnected).sorted { $0.endpoint.host < $1.endpoint.host }
    }

    func disconnect(_ endpoint: SFTPEndpoint) {
        let session = lock.withLock { sessions.removeValue(forKey: endpoint.key) }
        session?.close()
        // Ferme aussi la connexion maîtresse partagée.
        let exit = Process()
        exit.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        exit.arguments = SFTPSession(endpoint: endpoint).sshOptions + ["-p", String(endpoint.port), "-O", "exit",
                                                                       endpoint.user.map { "\($0)@\(endpoint.host)" } ?? endpoint.host]
        exit.standardOutput = FileHandle.nullDevice
        exit.standardError = FileHandle.nullDevice
        try? exit.run()
        NotificationCenter.default.post(name: Self.sessionsChanged, object: nil)
    }

    func disconnectAll() {
        let all = lock.withLock { Array(sessions.values) }
        all.forEach { disconnect($0.endpoint) }
    }
}

extension FileItem {
    /// Contenu d'un dossier local ou distant.
    static func contents(at url: URL, showHidden: Bool) throws -> [FileItem] {
        guard url.isRemote else { return try contents(of: url, showHidden: showHidden) }
        let session = try SFTPManager.shared.session(for: url)
        let listing = try session.list(url.path.isEmpty ? "/" : url.path)
        guard listing.isDirectory else { throw SFTPError.command("« \(url.lastPathComponent) » n’est pas un dossier.") }
        return listing.entries
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .map { FileItem(remote: url.appendingPathComponent($0.name), entry: $0) }
    }
}
