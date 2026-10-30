import AppKit
import CoreServices

/// État Git d'un fichier, par ordre de priorité croissante (un dossier prend le pire état de son contenu).
enum GitFileState: Int, Comparable {
    case ignored, untracked, added, renamed, modified, deleted, conflict

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Lettre affichée à droite du nom, comme dans VS Code.
    var letter: String {
        switch self {
        case .ignored: ""
        case .untracked: "U"
        case .added: "A"
        case .renamed: "R"
        case .modified: "M"
        case .deleted: "D"
        case .conflict: "!"
        }
    }

    var color: NSColor {
        switch self {
        case .ignored: return .tertiaryLabelColor
        case .untracked, .added: return Self.dynamic(light: 0x007100, dark: 0x73C991)
        case .renamed: return Self.dynamic(light: 0x007100, dark: 0x73C991)
        case .modified: return Self.dynamic(light: 0x895503, dark: 0xE2C08D)
        case .deleted: return Self.dynamic(light: 0xAD0707, dark: 0xC74E39)
        case .conflict: return Self.dynamic(light: 0xAD0707, dark: 0xE4676B)
        }
    }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

/// Résumé d'un dépôt : branche, commits à pousser / à tirer, modifications non validées.
struct GitSummary {
    var branch: String?
    var ahead = 0
    var behind = 0
    var hasUpstream = false
    var changes = 0

    var isClean: Bool { ahead == 0 && behind == 0 && changes == 0 }
}

/// État complet d'un dépôt (sortie de `git status --porcelain=v2`).
struct GitRepositoryStatus {
    let root: URL
    var summary = GitSummary()
    /// Chemins relatifs à la racine → état.
    var files: [String: GitFileState] = [:]
    /// État agrégé des dossiers qui contiennent des modifications.
    var folders: [String: GitFileState] = [:]
    /// Dossiers ignorés et dossiers non suivis en entier (préfixes terminés par « / ») :
    /// leur contenu hérite de leur état.
    var ignoredFolders: [String] = []
    var untrackedFolders: [String] = []

    func state(forRelativePath path: String, isDirectory: Bool) -> GitFileState? {
        if let state = files[path] { return state }
        if isDirectory, let state = folders[path] { return state }
        let probe = isDirectory ? path + "/" : path
        if untrackedFolders.contains(where: { probe.hasPrefix($0) }) { return .untracked }
        if ignoredFolders.contains(where: { probe.hasPrefix($0) }) { return .ignored }
        return nil
    }

    static func parse(_ data: Data, root: URL) -> GitRepositoryStatus {
        var status = GitRepositoryStatus(root: root)
        let records = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        func record(_ path: String, _ state: GitFileState) {
            status.files[path] = state
            if state != .ignored { status.summary.changes += 1 }
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if state != .ignored, (status.folders[parent] ?? .ignored) < state { status.folders[parent] = state }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        while index < records.count {
            let line = records[index]
            index += 1
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.summary.branch = head == "(detached)" ? "détachée" : head
            } else if line.hasPrefix("# branch.upstream ") {
                status.summary.hasUpstream = true
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.split(separator: " ")
                if parts.count >= 4 {
                    status.summary.ahead = Int(parts[2].dropFirst()) ?? 0
                    status.summary.behind = Int(parts[3].dropFirst()) ?? 0
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let renamed = line.hasPrefix("2 ")
                let fields = line.split(separator: " ", maxSplits: renamed ? 9 : 8, omittingEmptySubsequences: false)
                guard fields.count >= (renamed ? 10 : 9) else { continue }
                let xy = Array(fields[1])
                let path = String(fields[renamed ? 9 : 8])
                if renamed { index += 1 } // chemin d'origine
                record(path, state(x: xy[0], y: xy[1], renamed: renamed))
            } else if line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if let path = fields.last { record(String(path), .conflict) }
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst(2))
                if path.hasSuffix("/") {
                    record(String(path.dropLast()), .untracked)
                    status.untrackedFolders.append(path)
                } else {
                    record(path, .untracked)
                }
            } else if line.hasPrefix("! ") {
                let path = String(line.dropFirst(2))
                if path.hasSuffix("/") { status.ignoredFolders.append(path) } else { status.files[path] = .ignored }
            }
        }
        return status
    }

    private static func state(x: Character, y: Character, renamed: Bool) -> GitFileState {
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { return .conflict }
        if x == "D" || y == "D" { return .deleted }
        if renamed || x == "R" || x == "C" { return .renamed }
        if x == "A" { return .added }
        return .modified
    }
}

/// Lance `git status` en arrière-plan, met les résultats en cache et surveille les dépôts.
final class GitService {
    static let shared = GitService()
    static let enabledChanged = Notification.Name("GitEnabledChanged")

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "git.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "git.enabled")
            NotificationCenter.default.post(name: enabledChanged, object: nil)
        }
    }

    private let queue = OperationQueue()
    private let lock = NSLock()
    private var rootCache: [String: URL?] = [:]

    lazy var isAvailable: Bool = {
        // /usr/bin/git sans outils de développement ouvrirait une fenêtre d'installation : on vérifie d'abord.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "git"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }()

    init() {
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
    }

    /// Racine du dépôt contenant `url` (dossier qui contient `.git`), ou `nil`.
    func repositoryRoot(for url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let start = url.resolvingSymlinksInPath().standardizedFileURL
        if let cached = lock.withLock({ rootCache[start.path] }) { return cached }
        let found = start.ancestorPaths.first { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        lock.withLock { rootCache[start.path] = found }
        return found
    }

    static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// État complet du dépôt (fichiers inclus). Appel bloquant : à faire hors du fil principal.
    func status(ofRepository root: URL, includeIgnored: Bool = true) -> GitRepositoryStatus? {
        var arguments = ["-C", root.path, "--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"]
        if includeIgnored { arguments.append("--ignored=matching") }
        guard let data = runGit(arguments) else { return nil }
        return GitRepositoryStatus.parse(data, root: root)
    }

    /// Résumés de plusieurs dépôts, calculés en parallèle (indicateurs des dossiers de dépôt).
    func summaries(of repositories: [URL], completion: @escaping ([String: GitSummary]) -> Void) {
        guard !repositories.isEmpty else { completion([:]); return }
        var results: [String: GitSummary] = [:]
        let resultsLock = NSLock()
        let group = DispatchGroup()
        for repository in repositories {
            group.enter()
            queue.addOperation { [weak self] in
                defer { group.leave() }
                guard let status = self?.status(ofRepository: repository, includeIgnored: false) else { return }
                resultsLock.withLock { results[repository.standardizedFileURL.path] = status.summary }
            }
        }
        group.notify(queue: .main) { completion(results) }
    }

    private func runGit(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

}

/// Flux FSEvents récursif sur la racine d'un dépôt (modifications regroupées par seconde).
final class RepositoryWatcher {
    let root: URL

    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    /// `onChange` reçoit les chemins modifiés (regroupés par FSEvents sur une seconde).
    init(root: URL, onChange: @escaping ([String]) -> Void) {
        self.root = root
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            // Ignore l'activité interne de git (objets, verrous) sauf l'index et les références.
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = list.prefix(count).filter { path in
                !path.contains("/.git/") || path.hasSuffix("/.git/index") || path.contains("/.git/refs/") || path.hasSuffix("/.git/HEAD")
            }
            if !relevant.isEmpty { watcher.onChange(relevant) }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
