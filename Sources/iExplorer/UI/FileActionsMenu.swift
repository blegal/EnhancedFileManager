import AppKit

/// Actions par type de fichier dans le menu contextuel du panneau, et leur exécution.
extension PanelViewController {
    /// Sections des règles qui s'appliquent à la sélection (ou au dossier courant si rien n'est sélectionné).
    func fileActionMenuItems() -> [NSMenuItem] {
        guard !currentURL.isRemote else { return [] }
        let selection = selectedURLs
        let (rules, untrusted) = FileActionStore.shared.rules(for: currentURL)
        var items: [NSMenuItem] = []
        var matched: [FileActionRule] = []
        for rule in rules {
            guard let context = rule.context(selection: selection, directory: currentURL) else { continue }
            let section = FileActionMenu.items(for: rule, context: context, target: self, action: #selector(runFileAction(_:)))
            guard !section.isEmpty else { continue }
            items += section
            matched.append(rule)
        }
        for file in untrusted {
            let item = NSMenuItem(title: "Actions du projet « \(file.deletingPathExtension().lastPathComponent) » à approuver…",
                                  action: #selector(approveProjectActions(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.shield", accessibilityDescription: nil)
            item.representedObject = file
            items.append(item)
        }
        if let rule = matched.first {
            let edit = NSMenuItem(title: matched.count == 1 ? "Personnaliser les actions « \(rule.name) »…" : "Personnaliser les actions…",
                                  action: #selector(AppDelegate.manageFileActions(_:)), keyEquivalent: "")
            edit.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
            edit.representedObject = rule.url
            items.append(edit)
        }
        return items
    }

    @objc func runFileAction(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? FileActionInvocation else { return }
        let entry = invocation.entry
        let context = invocation.context
        let other = host?.targetPanels(for: self).first?.currentURL
        let variables = context.variables(item: invocation.item, other: other?.isFileURL == true ? other : nil)
        let title = expandFileActionVariables(entry.title, variables)
        if let message = entry.confirm {
            let alert = NSAlert()
            alert.messageText = "\(title) ?"
            alert.informativeText = message.isEmpty ? entry.run : message
            alert.addButton(withTitle: "Exécuter")
            alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        switch entry.mode {
        case .terminal:
            (view.window?.windowController as? MainWindowController)?
                .runInTerminal(Self.terminalCommand(entry.run, variables: variables, files: context.files), in: context.directory)
        case .background, .open:
            runFileActionProcess(entry, title: title, variables: variables, context: context)
        }
    }

    /// Ligne envoyée au terminal intégré : un sous-shell qui définit les variables utilisées, puis la commande.
    static func terminalCommand(_ run: String, variables: [String: String], files: [URL]) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let used = variables.keys.sorted().filter { run.contains("$\($0)") || run.contains("${\($0)") }
        var prefix = used.isEmpty ? "" : "export " + used.map { "\($0)=\(quote(variables[$0]!))" }.joined(separator: " ") + "; "
        if run.contains("$@") || run.contains("$*") || run.contains("$#") || run.contains("$1") {
            prefix += "set -- " + files.map { quote($0.path) }.joined(separator: " ") + "; "
        }
        let body = run.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? body : "(\(prefix)\(body))"
    }

    private func runFileActionProcess(_ entry: FileActionEntry, title: String, variables: [String: String], context: FileActionContext) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", entry.run, "iexplorer"] + context.files.map(\.path)
        process.currentDirectoryURL = context.directory
        var environment = ShellEnvironment.environment
        environment.merge(variables) { $1 }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if entry.mode == .open {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { presentMessage("« \(title) » n’a pas pu être lancé.\n\n\(error.localizedDescription)", warning: true) }
            return
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let job = FileJob(title: title)
        job.setStatus(entry.run.trimmingCharacters(in: .whitespacesAndNewlines))
        job.setCancelAction { process.terminate() }
        FileOperationCenter.shared.addJob(job)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var text = ""
            do {
                try process.run()
                text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
            } catch {
                text = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                FileOperationCenter.shared.removeJob(job)
                guard let self, !job.isCancelled else { return }
                let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000))
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    presentMessage("« \(title) » a échoué (code \(process.terminationStatus)).\n\n" + (trimmed.isEmpty ? entry.run : trimmed), warning: true)
                    reload()
                    return
                }
                finishFileAction(entry.then, title: title, output: trimmed, variables: variables, directory: context.directory)
            }
        }
    }

    /// Suite d'une action réussie : `reveal <fichier>`, `open <fichier>`, `output` ou `refresh` (par défaut).
    private func finishFileAction(_ then: String?, title: String, output: String, variables: [String: String], directory: URL) {
        let parts = (then ?? "refresh").split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? expandFileActionVariables(parts[1], variables) : ""
        let target = argument.hasPrefix("/") ? URL(fileURLWithPath: argument) : directory.appendingPathComponent(argument)
        switch parts.first {
        case "output":
            reload()
            presentMessage("« \(title) » terminé.\n\n" + (output.isEmpty ? "Aucune sortie." : output))
        case "open" where !argument.isEmpty:
            reload()
            NSWorkspace.shared.open(target)
        case "reveal" where !argument.isEmpty:
            if target.deletingLastPathComponent().standardizedFileURL == currentURL.standardizedFileURL {
                reload(selecting: [target], scrollToSelection: true)
            } else {
                navigate(to: target.deletingLastPathComponent(), select: target)
            }
        default:
            reload()
        }
    }

    /// Règle d'un dossier `.iexplorer/actions` : on montre son contenu avant d'accepter de l'exécuter.
    @objc func approveProjectActions(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? URL else { return }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Autoriser les actions de « \(file.lastPathComponent) » ?"
        alert.informativeText = "Ce fichier vient du projet \(file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path) et peut exécuter n’importe quelle commande. Vérifiez son contenu ; il faudra l’approuver de nouveau s’il change."
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        if let textView = scroll.documentView as? NSTextView {
            textView.string = text
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Autoriser")
        alert.addButton(withTitle: "Annuler")
        if alert.runModal() == .alertFirstButtonReturn { FileActionStore.shared.trust(file) }
    }
}
