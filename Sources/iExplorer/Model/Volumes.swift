import AppKit

/// Volumes : capacité, éjection et montage d'images disque.
enum Volumes {
    static let imageExtensions: Set<String> = ["dmg", "iso", "img", "sparseimage", "sparsebundle", "cdr"]

    static func isDiskImage(_ url: URL) -> Bool { url.isFileURL && imageExtensions.contains(url.pathExtension.lowercased()) }

    /// Capacité totale et espace disponible d'un volume.
    static func capacity(of url: URL) -> (total: Int64, available: Int64)? {
        guard let total = (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity, total > 0,
              let available = Format.availableCapacity(at: url) else { return nil }
        return (Int64(total), available)
    }

    /// Éjecte un volume en arrière-plan ; les erreurs sont affichées.
    static func eject(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Monte des images disque avec hdiutil (le volume apparaît ensuite dans la barre latérale).
    static func mount(_ images: [URL], completion: ((URL?) -> Void)? = nil) {
        for image in images {
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = ["attach", "-plist", image.path]
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                var mountPoint: URL?
                var message = ""
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                    if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                       let entities = plist["system-entities"] as? [[String: Any]],
                       let point = entities.compactMap({ $0["mount-point"] as? String }).first {
                        mountPoint = URL(fileURLWithPath: point, isDirectory: true)
                    }
                } catch {
                    message = error.localizedDescription
                }
                DispatchQueue.main.async {
                    if process.terminationStatus != 0 {
                        let alert = NSAlert()
                        alert.messageText = "Impossible de monter « \(image.lastPathComponent) »."
                        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        alert.runModal()
                    }
                    completion?(mountPoint)
                }
            }
        }
    }

    /// Choisit des images disque et les monte.
    static func chooseAndMount(completion: ((URL?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Monter une image disque"
        panel.prompt = "Monter"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = imageExtensions.compactMap { .init(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        mount(panel.urls, completion: completion)
    }
}

extension PanelViewController {
    /// Menu contextuel : monte les images disque sélectionnées et ouvre la première.
    @objc func mountDiskImages(_ sender: Any?) {
        let images = selectedURLs.filter(Volumes.isDiskImage)
        Volumes.mount(images) { [weak self] mountPoint in
            if let mountPoint, images.count == 1 { self?.navigate(to: mountPoint) }
        }
    }
}
