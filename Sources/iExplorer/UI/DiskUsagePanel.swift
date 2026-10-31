import AppKit

/// Mode « Occupation du disque » d'un panneau (⌘5) : le dossier courant est analysé et affiché
/// en « Liste et soleil » par défaut ; la navigation reste celle du panneau (fil d'Ariane, historique, onglets).
extension PanelViewController {
    func configureDiskUsage() {
        // Vue par défaut ; le style choisi ensuite est gardé tant que le panneau existe.
        diskUsageView.style = .baobab
        diskUsageView.onNavigate = { [weak self] url in self?.navigate(to: url) }
        diskUsageView.onUp = { [weak self] in self?.goUp(nil) }
        diskUsageView.onExit = { [weak self] in self?.setDiskUsageVisible(false) }
        diskUsageView.onOpen = { url in
            NSWorkspace.shared.open(url)
        }
        diskUsageView.onRevealInList = { [weak self] url in
            guard let self else { return }
            setDiskUsageVisible(false)
            navigate(to: url.deletingLastPathComponent(), select: url)
        }
        diskUsageView.onTrash = { [weak self] url in
            guard let self else { return }
            FileOperationCenter.shared.trash([url], undoManager: undoManager)
            diskUsageView.remove(url)
        }
    }

    /// ⌘5 : bascule entre les fichiers et l'occupation du disque.
    @objc func toggleDiskUsage(_ sender: Any?) {
        setDiskUsageVisible(!isShowingDiskUsage)
    }

    /// Menu contextuel : analyse le dossier sélectionné (ou le dossier courant).
    @objc func analyzeDiskUsage(_ sender: Any?) {
        if let folder = selectedItems.first(where: \.isNavigableDirectory), selectedItems.count == 1 {
            navigate(to: folder.url)
        }
        setDiskUsageVisible(true)
    }

    func setDiskUsageVisible(_ visible: Bool) {
        guard visible != isShowingDiskUsage else { return }
        if visible, currentURL.isRemote { NSSound.beep(); return }
        if isSearching { endSearch() }
        isShowingDiskUsage = visible
        if visible {
            showDiskUsage()
        } else {
            // Libère l'arbre analysé (mémoire).
            diskUsageView.stop()
        }
        applyViewMode()
        updateNavigationControl()
        view.window?.makeFirstResponder(focusView)
        host?.panelDidChangeDirectory(self)
    }

    func showDiskUsage() {
        guard isShowingDiskUsage else { return }
        if currentURL.isRemote { setDiskUsageVisible(false); return }
        diskUsageView.show(currentURL)
    }
}
