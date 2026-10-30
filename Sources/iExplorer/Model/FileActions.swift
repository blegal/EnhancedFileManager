import AppKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Sous-ensemble de TOML

/// Valeur d'un fichier de règle : chaînes, booléens, nombres, tableaux et tables en ligne.
enum TOMLValue: Equatable {
    case string(String), bool(Bool), number(Double), array([TOMLValue]), table([String: TOMLValue])

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var table: [String: TOMLValue]? { if case .table(let value) = self { return value }; return nil }
    /// Une chaîne seule ou un tableau de chaînes.
    var strings: [String] {
        switch self {
        case .string(let value): [value]
        case .array(let values): values.compactMap(\.string)
        default: []
        }
    }
}

struct TOMLError: LocalizedError {
    let line: Int
    let message: String
    var errorDescription: String? { "Ligne \(line) : \(message)" }
}

/// Document lu : les clés de premier niveau et les tables `[[nom]]` dans l'ordre du fichier.
struct TOMLDocument {
    var root: [String: TOMLValue] = [:]
    var entries: [(kind: String, values: [String: TOMLValue])] = []
}

/// Lecteur TOML volontairement réduit : commentaires, `clé = valeur`, `[table]`, `[[tableau]]`,
/// chaînes "…", '…', """…""" et '''…''', tableaux (sur plusieurs lignes), tables en ligne `{ … }`.
enum TOMLParser {
    static func parse(_ text: String) throws -> TOMLDocument {
        var scanner = Scanner(chars: Array(text))
        var document = TOMLDocument()
        enum Target { case root, table(String), entry(Int) }
        var target = Target.root

        func assign(_ key: String, _ value: TOMLValue) throws {
            switch target {
            case .root:
                guard document.root[key] == nil else { throw scanner.error("clé « \(key) » déjà définie") }
                document.root[key] = value
            case .table(let name):
                var table = document.root[name]?.table ?? [:]
                guard table[key] == nil else { throw scanner.error("clé « \(key) » déjà définie") }
                table[key] = value
                document.root[name] = .table(table)
            case .entry(let index):
                guard document.entries[index].values[key] == nil else { throw scanner.error("clé « \(key) » déjà définie") }
                document.entries[index].values[key] = value
            }
        }

        while true {
            scanner.skipBlank()
            guard let char = scanner.peek else { break }
            if char == "[" {
                _ = scanner.next()
                let isArray = scanner.peek == "["
                if isArray { _ = scanner.next() }
                var name = ""
                while let c = scanner.peek, c != "]", c != "\n" { name.append(scanner.next()) }
                name = name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, scanner.peek == "]" else { throw scanner.error("en-tête de table mal fermé") }
                _ = scanner.next()
                if isArray {
                    guard scanner.peek == "]" else { throw scanner.error("« ]] » attendu") }
                    _ = scanner.next()
                    document.entries.append((name, [:]))
                    target = .entry(document.entries.count - 1)
                } else {
                    guard document.root[name] == nil else { throw scanner.error("table « \(name) » déjà définie") }
                    document.root[name] = .table([:])
                    target = .table(name)
                }
            } else {
                let key = try scanner.key()
                scanner.skipSpaces()
                guard scanner.peek == "=" else { throw scanner.error("« = » attendu après « \(key) »") }
                _ = scanner.next()
                scanner.skipSpaces()
                try assign(key, try scanner.value())
            }
            try scanner.endOfLine()
        }
        return document
    }

    private struct Scanner {
        let chars: [Character]
        var index = 0
        var line = 1

        var peek: Character? { index < chars.count ? chars[index] : nil }

        mutating func next() -> Character {
            let char = chars[index]
            index += 1
            if char == "\n" { line += 1 }
            return char
        }

        func error(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

        func starts(with text: String) -> Bool {
            let needle = Array(text)
            return index + needle.count <= chars.count && Array(chars[index..<index + needle.count]) == needle
        }

        mutating func skip(_ count: Int) { for _ in 0..<count { _ = next() } }

        mutating func skipSpaces() { while let c = peek, c == " " || c == "\t" { index += 1 } }

        /// Espaces, fins de ligne et commentaires.
        mutating func skipBlank() {
            while let c = peek {
                if c == " " || c == "\t" || c == "\r" || c == "\n" { _ = next() }
                else if c == "#" { while let d = peek, d != "\n" { index += 1 } }
                else { break }
            }
        }

        mutating func endOfLine() throws {
            skipSpaces()
            if peek == "#" { while let c = peek, c != "\n" { index += 1 } }
            if peek == "\r" { index += 1 }
            guard peek == nil || peek == "\n" else { throw error("fin de ligne attendue") }
        }

        mutating func key() throws -> String {
            if peek == "\"" { _ = next(); return try basicString() }
            if peek == "'" { _ = next(); return try literalString() }
            var key = ""
            while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" { key.append(next()) }
            guard !key.isEmpty else { throw error("clé attendue") }
            return key
        }

        mutating func value() throws -> TOMLValue {
            guard let c = peek else { throw error("valeur attendue") }
            if starts(with: "\"\"\"") { skip(3); return .string(try multilineString(basic: true)) }
            if starts(with: "'''") { skip(3); return .string(try multilineString(basic: false)) }
            switch c {
            case "\"": _ = next(); return .string(try basicString())
            case "'": _ = next(); return .string(try literalString())
            case "[":
                _ = next()
                var values: [TOMLValue] = []
                while true {
                    skipBlank()
                    if peek == "]" { _ = next(); return .array(values) }
                    values.append(try value())
                    skipBlank()
                    if peek == "," { _ = next() } else if peek != "]" { throw error("« , » ou « ] » attendu") }
                }
            case "{":
                _ = next()
                var table: [String: TOMLValue] = [:]
                while true {
                    skipBlank()
                    if peek == "}" { _ = next(); return .table(table) }
                    let key = try key()
                    skipSpaces()
                    guard peek == "=" else { throw error("« = » attendu après « \(key) »") }
                    _ = next()
                    skipSpaces()
                    table[key] = try value()
                    skipBlank()
                    if peek == "," { _ = next() } else if peek != "}" { throw error("« , » ou « } » attendu") }
                }
            default:
                var word = ""
                while let d = peek, d.isLetter || d.isNumber || "+-._".contains(d) { word.append(next()) }
                if word == "true" { return .bool(true) }
                if word == "false" { return .bool(false) }
                if let number = Double(word.replacingOccurrences(of: "_", with: "")) { return .number(number) }
                throw error(word.isEmpty ? "valeur attendue" : "valeur inconnue « \(word) » (une chaîne s’écrit entre guillemets)")
            }
        }

        mutating func escape() throws -> String {
            guard peek != nil else { throw error("chaîne non terminée") }
            switch next() {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "\\": return "\\"
            case "\"": return "\""
            case "u":
                var hex = ""
                for _ in 0..<4 { if let c = peek, c.isHexDigit { hex.append(next()) } }
                guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { throw error("\\u invalide") }
                return String(Character(scalar))
            case let other: throw error("échappement « \\\(other) » inconnu (doublez la barre : \\\\)")
            }
        }

        mutating func basicString() throws -> String {
            var text = ""
            while let c = peek, c != "\n" {
                _ = next()
                if c == "\"" { return text }
                text += c == "\\" ? try escape() : String(c)
            }
            throw error("chaîne non terminée")
        }

        mutating func literalString() throws -> String {
            var text = ""
            while let c = peek, c != "\n" {
                _ = next()
                if c == "'" { return text }
                text.append(c)
            }
            throw error("chaîne non terminée")
        }

        mutating func multilineString(basic: Bool) throws -> String {
            let end = basic ? "\"\"\"" : "'''"
            if peek == "\n" { _ = next() } else if starts(with: "\r\n") { skip(2) }
            var text = ""
            while peek != nil {
                if starts(with: end) { skip(3); return text }
                let c = next()
                text += basic && c == "\\" ? try escape() : String(c)
            }
            throw error("chaîne sur plusieurs lignes non terminée")
        }
    }
}

// MARK: - Règles

/// Nombre d'éléments sélectionnés exigé par une règle ou une action.
enum FileActionCount: String {
    case one, many, any
    func accepts(_ count: Int) -> Bool {
        switch self {
        case .one: count == 1
        case .many: count > 1
        case .any: count >= 1
        }
    }
}

/// Une entrée du menu : action fixe, liste générée par une commande, ou séparateur.
struct FileActionEntry {
    enum Kind { case action, list, separator }
    enum Mode: String { case terminal, background, open }

    var kind = Kind.action
    var title = ""
    var icon: String?
    var run = ""
    var mode = Mode.background
    var confirm: String?
    var then: String?
    var requires: [String] = []
    var missing: [String] = []
    var count = FileActionCount.any
    /// Liste : commande qui imprime une entrée par ligne, et entrées gardées en tête.
    var from = ""
    var pinned: [String] = []

    init() {}

    init(kind: String, values: [String: TOMLValue], line: Int) throws {
        func error(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }
        switch kind {
        case "action": self.kind = .action
        case "list": self.kind = .list
        case "separator": self.kind = .separator; return
        default: throw error("table [[\(kind)]] inconnue (action, list ou separator)")
        }
        title = values["title"]?.string ?? ""
        run = values["run"]?.string ?? ""
        guard !title.isEmpty else { throw error("[[\(kind)]] sans « title »") }
        guard !run.isEmpty else { throw error("« \(title) » : « run » manquant") }
        icon = values["icon"]?.string
        if let raw = values["in"]?.string {
            guard let mode = Mode(rawValue: raw) else { throw error("« in » vaut terminal, background ou open (et non « \(raw) »)") }
            self.mode = mode
        }
        switch values["confirm"] {
        case .bool(true): confirm = ""
        case .string(let text): confirm = text
        default: break
        }
        then = values["then"]?.string
        requires = values["requires"]?.strings ?? []
        missing = values["missing"]?.strings ?? []
        if let raw = values["count"]?.string {
            guard let count = FileActionCount(rawValue: raw) else { throw error("« count » vaut one, many ou any") }
            self.count = count
        }
        if self.kind == .list {
            from = values["from"]?.string ?? ""
            guard !from.isEmpty else { throw error("« \(title) » : « from » manquant") }
            pinned = values["pinned"]?.strings ?? []
        }
    }
}

/// Règle lue dans un fichier .toml : à quels fichiers elle s'applique et ses actions.
struct FileActionRule {
    let url: URL
    var name = ""
    var icon: String?
    var names: [String] = []
    var extensions: [String] = []
    var types: [UTType] = []
    var folderContains = false
    var count = FileActionCount.any
    var requires: [String] = []
    var entries: [FileActionEntry] = []
    var isProject = false

    init(url: URL, text: String) throws {
        self.url = url
        let document = try TOMLParser.parse(text)
        name = document.root["name"]?.string ?? url.deletingPathExtension().lastPathComponent
        icon = document.root["icon"]?.string
        let match = document.root["match"]?.table ?? [:]
        names = match["names"]?.strings ?? []
        extensions = (match["extensions"]?.strings ?? []).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        types = (match["types"]?.strings ?? []).compactMap { UTType($0) }
        folderContains = match["folderContains"]?.bool ?? false
        if let raw = match["count"]?.string {
            guard let count = FileActionCount(rawValue: raw) else { throw TOMLError(line: 1, message: "« count » vaut one, many ou any") }
            self.count = count
        }
        guard !names.isEmpty || !extensions.isEmpty || !types.isEmpty else {
            throw TOMLError(line: 1, message: "« match » doit donner names, extensions ou types")
        }
        requires = document.root["requires"]?.strings ?? []
        // Numéros de ligne approximatifs : ceux des en-têtes [[…]] dans le texte.
        let headerLines = text.components(separatedBy: "\n").enumerated()
            .filter { $0.element.trimmingCharacters(in: .whitespaces).hasPrefix("[[") }.map { $0.offset + 1 }
        entries = try document.entries.enumerated().map { index, entry in
            try FileActionEntry(kind: entry.kind, values: entry.values, line: index < headerLines.count ? headerLines[index] : 1)
        }
    }

    var actionCount: Int { entries.filter { $0.kind != .separator }.count }

    /// Résumé lisible de « match ».
    var matchDescription: String {
        var parts: [String] = []
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if !extensions.isEmpty { parts.append(extensions.map { "." + $0 }.joined(separator: ", ")) }
        if !types.isEmpty { parts.append(types.map { $0.localizedDescription ?? $0.identifier }.joined(separator: ", ")) }
        return parts.joined(separator: " · ") + (folderContains ? " (et les dossiers qui en contiennent)" : "")
    }

    func matches(file url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        if let type = values?.contentType, types.contains(where: { type.conforms(to: $0) }) { return true }
        if isFolder { return false }
        let name = url.lastPathComponent
        if extensions.contains(url.pathExtension.lowercased()) { return true }
        return names.contains { fnmatch($0, name, 0) == 0 }
    }

    /// Contexte d'exécution pour cette sélection, ou nil si la règle ne s'applique pas.
    func context(selection: [URL], directory: URL) -> FileActionContext? {
        if !selection.isEmpty, count.accepts(selection.count), selection.allSatisfy(matches(file:)) {
            return FileActionContext(files: selection, directory: selection[0].deletingLastPathComponent())
        }
        guard folderContains else { return nil }
        let folder: URL
        if selection.isEmpty {
            folder = directory
        } else if selection.count == 1, (try? selection[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            folder = selection[0]
        } else {
            return nil
        }
        // Noms exacts d'abord (cas le plus courant : Makefile, package.json…), motifs ensuite.
        for name in names where !name.contains(where: { "*?[".contains($0) }) {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return FileActionContext(files: [candidate], directory: folder)
            }
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if let child = children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(where: matches(file:)) {
            return FileActionContext(files: [child], directory: folder)
        }
        return nil
    }
}

/// Fichiers concernés et dossier de travail d'une action.
struct FileActionContext {
    let files: [URL]
    let directory: URL

    /// Variables proposées aux commandes (exportées dans l'environnement).
    func variables(item: String? = nil, other: URL? = nil) -> [String: String] {
        let file = files.first ?? directory
        var values = [
            "FILE": file.path,
            "DIR": directory.path,
            "NAME": file.lastPathComponent,
            "STEM": file.deletingPathExtension().lastPathComponent,
            "EXT": file.pathExtension,
        ]
        if let item { values["ITEM"] = item }
        if let other { values["OTHER"] = other.path }
        return values
    }
}

/// Remplace `$NOM` et `${NOM}` par leur valeur, sans protection (titres, chemins de « then »).
func expandFileActionVariables(_ text: String, _ variables: [String: String]) -> String {
    variables.keys.sorted { $0.count > $1.count }.reduce(text) { result, key in
        result.replacingOccurrences(of: "${\(key)}", with: variables[key]!)
            .replacingOccurrences(of: "$\(key)", with: variables[key]!)
    }
}

// MARK: - Environnement du shell

/// PATH du shell de connexion (Homebrew, TeX…), que les apps lancées depuis le Finder n'ont pas.
enum ShellEnvironment {
    static let path: String = {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/Library/TeX/texbin:/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = output(executable: shell, arguments: ["-lc", "printf '%s' \"$PATH\""], environment: nil,
                                  directory: nil, timeout: 5)?.trimmingCharacters(in: .whitespacesAndNewlines),
              output.contains("/") else { return fallback }
        return output.components(separatedBy: "\n").last ?? fallback
    }()

    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment["LANG"] = environment["LANG"] ?? "fr_FR.UTF-8"
        return environment
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tools: [String: Bool] = [:]

    /// L'outil est-il dans le PATH ?
    static func has(_ tool: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let known = tools[tool] { return known }
        let found = path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
        tools[tool] = found
        return found
    }

    static func forgetTools() {
        lock.lock(); tools.removeAll(); lock.unlock()
    }

    /// Lance une commande et rend sa sortie, ou nil après `timeout` secondes.
    static func output(executable: String, arguments: [String], environment: [String: String]?, directory: URL?, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var data = Data()
        do { try process.run() } catch { return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Magasin des règles

/// Règles de l'utilisateur (~/Library/Application Support/iExplorer/Actions) et des projets
/// (dossier `.iexplorer/actions` d'un dossier parent, à approuver avant la première exécution).
final class FileActionStore {
    static let shared = FileActionStore()
    static let changed = Notification.Name("FileActionRulesChanged")

    static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iExplorer/Actions", isDirectory: true)
    }

    static let projectFolderName = ".iexplorer/actions"

    private struct Cached {
        let date: Date?
        let result: Result<FileActionRule, Error>
    }
    private var cache: [URL: Cached] = [:]

    /// Lit (ou relit si le fichier a changé) une règle.
    func load(_ url: URL, isProject: Bool = false) -> Result<FileActionRule, Error> {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = cache[url], cached.date == date { return cached.result }
        let result = Result { () throws -> FileActionRule in
            var rule = try FileActionRule(url: url, text: try String(contentsOf: url, encoding: .utf8))
            rule.isProject = isProject
            return rule
        }
        cache[url] = Cached(date: date, result: result)
        return result
    }

    func ruleFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "toml" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Dossiers `.iexplorer/actions` de `directory` et de ses parents (jusqu'au dossier personnel exclu).
    func projectFolders(for directory: URL) -> [URL] {
        var folders: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for path in directory.ancestorPaths {
            if path == "/" || path == home { break }
            let candidate = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(Self.projectFolderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { folders.append(candidate) }
        }
        return folders
    }

    /// Règles actives applicables à `directory` : celles du projet d'abord.
    func rules(for directory: URL) -> (rules: [FileActionRule], untrusted: [URL]) {
        var rules: [FileActionRule] = []
        var untrusted: [URL] = []
        for folder in projectFolders(for: directory) {
            for file in ruleFiles(in: folder) where isEnabled(file) {
                guard isTrusted(file) else { untrusted.append(file); continue }
                if case .success(let rule) = load(file, isProject: true) { rules.append(rule) }
            }
        }
        for file in ruleFiles(in: Self.userFolder) where isEnabled(file) {
            if case .success(let rule) = load(file) { rules.append(rule) }
        }
        return (rules, untrusted)
    }

    // MARK: Activation

    private static let disabledKey = "disabledFileActionRules"

    func isEnabled(_ file: URL) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []).contains(file.path)
    }

    func setEnabled(_ enabled: Bool, _ file: URL) {
        var disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? [])
        if enabled { disabled.remove(file.path) } else { disabled.insert(file.path) }
        UserDefaults.standard.set(disabled.sorted(), forKey: Self.disabledKey)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Confiance (règles de projet)

    private static let trustedKey = "trustedProjectActions"

    private func digest(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Une règle de projet n'est exécutée qu'une fois approuvée, et de nouveau après chaque modification.
    func isTrusted(_ file: URL) -> Bool {
        guard let digest = digest(file) else { return false }
        return (UserDefaults.standard.dictionary(forKey: Self.trustedKey) as? [String: String])?[file.path] == digest
    }

    func trust(_ file: URL) {
        var trusted = UserDefaults.standard.dictionary(forKey: Self.trustedKey) as? [String: String] ?? [:]
        trusted[file.path] = digest(file)
        UserDefaults.standard.set(trusted, forKey: Self.trustedKey)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Règles fournies

    private static let installedKey = "installedDefaultFileActions"

    /// Copie les règles fournies qui n'ont jamais été installées (une règle supprimée ne revient pas).
    func installDefaults(force: Bool = false) {
        let folder = Self.userFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var installed = Set(UserDefaults.standard.stringArray(forKey: Self.installedKey) ?? [])
        for (file, text) in DefaultFileActions.rules where force || !installed.contains(file) {
            let url = folder.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            installed.insert(file)
        }
        UserDefaults.standard.set(installed.sorted(), forKey: Self.installedKey)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

// MARK: - Menu

/// Ce qu'un élément de menu exécute.
final class FileActionInvocation: NSObject {
    let rule: FileActionRule
    let entry: FileActionEntry
    let context: FileActionContext
    let item: String?

    init(rule: FileActionRule, entry: FileActionEntry, context: FileActionContext, item: String?) {
        self.rule = rule
        self.entry = entry
        self.context = context
        self.item = item
    }
}

enum FileActionMenu {
    private static func available(_ entry: FileActionEntry, _ context: FileActionContext) -> Bool {
        entry.count.accepts(context.files.count)
            && entry.requires.allSatisfy(ShellEnvironment.has)
            && entry.missing.allSatisfy { !ShellEnvironment.has($0) }
    }

    private static func image(_ symbol: String?) -> NSImage? {
        symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    /// Éléments d'une règle pour ce contexte (vide si aucune action n'est disponible).
    static func items(for rule: FileActionRule, context: FileActionContext, target: AnyObject?, action: Selector) -> [NSMenuItem] {
        guard rule.requires.allSatisfy(ShellEnvironment.has) else { return [] }
        var items: [NSMenuItem] = []
        func makeItem(_ entry: FileActionEntry, item: String?) -> NSMenuItem {
            var variables = context.variables(item: item)
            variables["ITEM"] = item ?? ""
            let menuItem = NSMenuItem(title: expandFileActionVariables(entry.title, variables) + (entry.confirm != nil ? "…" : ""),
                                      action: action, keyEquivalent: "")
            menuItem.target = target
            menuItem.image = image(entry.icon ?? (entry.mode == .terminal ? "terminal" : nil))
            menuItem.representedObject = FileActionInvocation(rule: rule, entry: entry, context: context, item: item)
            menuItem.toolTip = entry.run
            return menuItem
        }
        for entry in rule.entries {
            switch entry.kind {
            case .separator:
                if let last = items.last, !last.isSeparatorItem { items.append(.separator()) }
            case .action:
                if available(entry, context) { items.append(makeItem(entry, item: nil)) }
            case .list:
                guard available(entry, context) else { continue }
                var environment = ShellEnvironment.environment
                environment.merge(context.variables()) { $1 }
                let output = ShellEnvironment.output(executable: "/bin/zsh", arguments: ["-c", entry.from, "iexplorer"] + context.files.map(\.path),
                                                     environment: environment, directory: context.directory, timeout: 2) ?? ""
                var seen = Set<String>()
                let values = output.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                    .prefix(80)
                let pinned = entry.pinned.isEmpty ? Array(values.prefix(10)) : entry.pinned.filter(values.contains)
                let others = values.filter { !pinned.contains($0) }
                items += pinned.map { makeItem(entry, item: $0) }
                if !others.isEmpty {
                    let more = NSMenuItem(title: pinned.isEmpty ? expandFileActionVariables(entry.title, ["ITEM": "…"]) : "Autres", action: nil, keyEquivalent: "")
                    more.image = image("ellipsis.circle")
                    let submenu = NSMenu()
                    for value in others { submenu.addItem(makeItem(entry, item: value)) }
                    more.submenu = submenu
                    items.append(more)
                }
            }
        }
        while items.last?.isSeparatorItem == true { items.removeLast() }
        guard !items.isEmpty else { return [] }
        let header = NSMenuItem.sectionHeader(title: rule.name)
        return [header] + items
    }
}
