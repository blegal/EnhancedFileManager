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

    /// Indicateur prêt pour un `NSTitlebarAccessoryViewController` : l'accessoire prend
    /// la taille du cadre de sa vue, d'où un conteneur de taille fixe.
    package static func titlebarAccessory() -> NSView {
        let button = UpdateStatusButton(bezelStyle: .accessoryBarAction)
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
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
