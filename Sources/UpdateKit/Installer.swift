import Foundation

/// Installation d'une mise à jour : on prépare la nouvelle application à côté de l'ancienne
/// (même volume, donc échange instantané), puis un petit script détaché attend la fin du
/// processus, remplace le paquet et relance l'application.
package enum UpdateInstaller {
    /// Monte l'image disque, copie l'application de même identifiant à côté de `target`
    /// et renvoie l'emplacement de cette copie préparée.
    package static func stage(dmg: URL, bundleIdentifier: String, target: URL) throws -> URL {
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder) }

        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let contents = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: {
            $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == bundleIdentifier
        }) else { throw UpdateError.appNotFound }

        let staged = folder.appendingPathComponent(".\(target.lastPathComponent).update")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// Lance le script de remplacement, qui attend la fin du processus `pid`.
    /// Renvoie le processus du script (utile pour les tests ; l'application, elle, quitte aussitôt).
    @discardableResult
    package static func launchReplacement(pid: Int32, staged: URL, target: URL, relaunch: Bool) throws -> Process {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString).sh")
        try replacementScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(pid), target.path, staged.path, relaunch ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Arguments : PID, application à remplacer, copie préparée, relance (1/0).
    /// En cas d'échec de l'échange, l'ancienne application est remise en place.
    private static let replacementScript = """
    #!/bin/sh
    PID="$1"; TARGET="$2"; STAGED="$3"; RELAUNCH="$4"
    while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
    OLD="$STAGED.old"
    rm -rf "$OLD"
    if mv "$TARGET" "$OLD"; then
        if mv "$STAGED" "$TARGET"; then rm -rf "$OLD"; else mv "$OLD" "$TARGET"; fi
    fi
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    [ "$RELAUNCH" = 1 ] && open "$TARGET"
    rm -f "$0"
    """

    package static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.command("\((tool as NSString).lastPathComponent) a échoué : \(detail)")
        }
    }
}
