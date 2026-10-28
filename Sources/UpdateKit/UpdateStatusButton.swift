import AppKit

/// Indicateur de mise à jour (barre d'outils, barre de titre) :
/// flèche de rafraîchissement au repos, flèche verte si une version est disponible,
/// flèches circulaires jaunes pendant le téléchargement et l'installation.
/// Un clic recherche les mises à jour ou rouvre la fenêtre de proposition.
@MainActor
package final class UpdateStatusButton: NSButton {
    private var observer: NSObjectProtocol?

    package init(bezelStyle: NSButton.BezelStyle = .toolbar) {
        super.init(frame: .zero)
        self.bezelStyle = bezelStyle
        imagePosition = .imageOnly
        target = Updater.shared
        action = #selector(Updater.checkForUpdates(_:))
        observer = NotificationCenter.default.addObserver(forName: Updater.stateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func update() {
        let symbol: String, tint: NSColor?, tip: String
        switch Updater.shared.state {
        case .idle:
            (symbol, tint, tip) = ("arrow.clockwise", nil, "Rechercher les mises à jour")
        case .checking:
            (symbol, tint, tip) = ("arrow.clockwise", .tertiaryLabelColor, "Recherche des mises à jour…")
        case .available(let version):
            (symbol, tint, tip) = ("arrow.down.circle.fill", .systemGreen, "Version \(version) disponible : cliquer pour l’installer")
        case .installing:
            (symbol, tint, tip) = ("arrow.triangle.2.circlepath.circle.fill", .systemYellow, "Mise à jour en cours de téléchargement…")
        }
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        contentTintColor = tint
        toolTip = tip
        isEnabled = Updater.shared.state != .checking
    }
}
